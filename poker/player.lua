-- poker/player.lua
-- Texas Hold'em — player computer (corner display + foot monitor)
-- Run: player <number>
--   Corner display: monitor on the TOP side of this computer
--   Foot monitor:   monitor on the LEFT or RIGHT side (whichever is present)
-- If no top monitor is found, falls back to the first monitor available.

pcall(function()
    local au = dofile("/casino/lib/autoupdate.lua")
    au.check({
        {"/lib/autoupdate.lua",  "/casino/lib/autoupdate.lua"},
        {"/lib/wallet.lua",      "/casino/lib/wallet.lua"},
        {"/poker/player.lua",    "/casino/poker/player.lua"},
    })
end)

local pid = tonumber(arg and arg[1])
assert(pid and pid>=1 and pid<=4, "Usage: player <1-4>")

local BCAST_CH  = 11
local DEALER_CH = 10

-- ── wallet ────────────────────────────────────────────────────────────────────
local wlib        = dofile("/casino/lib/wallet.lua")
local wallet_drv  = wlib.find_drive()   -- disk drive peripheral name, or nil
local wallet_data = nil                 -- loaded wallet table, or nil
local wallet_err  = nil                 -- last load error, or nil

local function reload_wallet()
    wallet_data = nil; wallet_err = nil
    if wallet_drv then
        wallet_data, wallet_err = wlib.load(wallet_drv)
    end
end

local function save_wallet(new_balance)
    if not wallet_data or not wallet_drv then return false end
    wallet_data.balance = new_balance
    local ok, err = wlib.save(wallet_data, wallet_drv)
    if not ok then wallet_err = err end
    return ok
end

reload_wallet()

-- ── Peripherals ───────────────────────────────────────────────
local function try_wrap(side)
    if peripheral.getType(side)=="monitor" then
        return peripheral.wrap(side), side
    end
    return nil, nil
end

-- Corner display: top
local corner_mon, corner_side = try_wrap("top")
if not corner_mon then
    -- fallback: first monitor found
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="monitor" then
            corner_mon=peripheral.wrap(name); corner_side=name; break
        end
    end
end
assert(corner_mon, "No corner monitor found (expected on top)")
corner_mon.setTextScale(0.5)
local CW, CH = corner_mon.getSize()

-- Foot monitor: left or right
local foot_mon, foot_side = try_wrap("left")
if not foot_mon then foot_mon, foot_side = try_wrap("right") end
if foot_mon then
    foot_mon.setTextScale(0.5)
else
    foot_mon = corner_mon  -- single-monitor fallback
end
local FW, FH = foot_mon.getSize()

local modem = peripheral.find("modem")
assert(modem, "No modem found")
modem.open(BCAST_CH)

-- ── State ─────────────────────────────────────────────────────
local START_CHIPS = wallet_data and wallet_data.balance or 500

local S = {
    hand={}, community={}, phase="waiting",
    chips=START_CHIPS, pot=0,
    bets={}, active={}, chips_all={},
    turn=0, call_amount=0, current_bet=0,
    valid_actions={}, result_lines={}, all_hands={},
    raise_mode=false, raise_digits="", raise_min=0,
}

-- ── Modem ─────────────────────────────────────────────────────
local function send(msg) msg.player=pid; modem.transmit(DEALER_CH,BCAST_CH,textutils.serialize(msg)) end
local function connect()
    local m = {type="hello"}
    if wallet_data then
        m.disk_balance = wallet_data.balance
        m.player_name  = wallet_data.player_name
    end
    send(m)
end

-- ── Drawing helpers ───────────────────────────────────────────
local SUIT_COL={H=colors.red,D=colors.red,C=colors.gray,S=colors.gray}

local function mwrite(m,x,y,txt,fg,bg)
    if bg then m.setBackgroundColor(bg) end
    if fg then m.setTextColor(fg) end
    m.setCursorPos(x,y); m.write(txt)
end
local function mfill(m,x1,y1,x2,y2,bg,char)
    m.setBackgroundColor(bg)
    local row=string.rep(char or " ",x2-x1+1)
    for y=y1,y2 do m.setCursorPos(x1,y); m.write(row) end
end
local function mcentre(m,x1,x2,y,txt,fg,bg)
    if bg then m.setBackgroundColor(bg) end
    if fg then m.setTextColor(fg) end
    m.setCursorPos(x1+math.floor((x2-x1+1-#txt)/2),y); m.write(txt)
end

-- ── Foot monitor: hole cards ──────────────────────────────────
-- Card: 9 wide x 5 tall (ASCII only)
local function draw_hole_card(x,y,card,is_back)
    if is_back then
        mfill(foot_mon,x,y,x+8,y+4,colors.blue)
        foot_mon.setTextColor(colors.cyan)
        foot_mon.setCursorPos(x,y);   foot_mon.write("+-------+")
        foot_mon.setCursorPos(x,y+1); foot_mon.write("|///////|")
        foot_mon.setCursorPos(x,y+2); foot_mon.write("|/ ??? /|")
        foot_mon.setCursorPos(x,y+3); foot_mon.write("|///////|")
        foot_mon.setCursorPos(x,y+4); foot_mon.write("+-------+")
        return
    end
    if not card then
        mfill(foot_mon,x,y,x+8,y+4,colors.gray)
        foot_mon.setTextColor(colors.lightGray)
        foot_mon.setCursorPos(x,y+2); foot_mon.write("  empty  ")
        return
    end
    local sc=SUIT_COL[card.s] or colors.gray
    local r=card.r; local s=card.s
    local top=r..string.rep(" ",7-#r)
    local mid=string.rep(" ",3)..s..string.rep(" ",3)
    local bot=string.rep(" ",7-#r)..r
    mfill(foot_mon,x,y,x+8,y+4,colors.white)
    foot_mon.setTextColor(sc)
    foot_mon.setCursorPos(x,y);   foot_mon.write("+-"..r..string.rep("-",6-#r).."-+")
    foot_mon.setCursorPos(x,y+1); foot_mon.write("|"..top.."|")
    foot_mon.setCursorPos(x,y+2); foot_mon.write("|"..mid.."|")
    foot_mon.setCursorPos(x,y+3); foot_mon.write("|"..bot.."|")
    foot_mon.setCursorPos(x,y+4); foot_mon.write("+-"..string.rep("-",7-#r)..r.."-+")
end

local function render_foot()
    foot_mon.setBackgroundColor(colors.black); foot_mon.clear()
    -- header
    mfill(foot_mon,1,1,FW,1,colors.black)
    local ph_label={waiting="Waiting",preflop="Pre-Flop",flop="Flop",
                    turn="Turn",river="River",showdown="Showdown"}
    local hdr="P"..pid.."  "..S.chips.."c  "..(ph_label[S.phase] or S.phase)
    mwrite(foot_mon,2,1,hdr,colors.yellow,colors.black)

    if foot_mon==corner_mon then return end  -- single monitor mode; skip foot drawing

    -- cards centred
    local cw=9; local gap=2
    local total=2*cw+gap
    local cx=math.floor((FW-total)/2)+1
    local cy=math.max(2, math.floor((FH-5)/2))

    if S.phase=="showdown" then
        -- show both cards face up
        draw_hole_card(cx,    cy, S.hand[1], false)
        draw_hole_card(cx+cw+gap,cy, S.hand[2], false)
        -- hand name
        if FH>cy+5 then
            mcentre(foot_mon,1,FW,cy+5,S._hand_name or "",colors.yellow,colors.black)
        end
    else
        draw_hole_card(cx,    cy, S.hand[1], false)
        draw_hole_card(cx+cw+gap,cy, S.hand[2], false)
    end
end

local function anim_deal_foot()
    foot_mon.setBackgroundColor(colors.black); foot_mon.clear()
    local cw=9; local gap=2; local total=2*cw+gap
    local cx=math.floor((FW-total)/2)+1
    local cy=math.max(2,math.floor((FH-5)/2))
    draw_hole_card(cx,cy,nil,true)
    draw_hole_card(cx+cw+gap,cy,nil,true)
    sleep(0.25)
    render_foot()
end

-- ── Corner display ────────────────────────────────────────────
-- Layout (top to bottom):
--   Row 1:       header (pid, chips, phase)
--   Rows 2..CH-3: game info (community summary, pot, bets, whose turn)
--   Rows CH-2..CH-1: raise input area (only in raise mode)
--   Row CH:       action buttons

local keypad_btns={}

local function draw_keypad(y1)
    keypad_btns={}
    local row1={"1","2","3","4","5","6","7","8","9","0"}
    local kw=math.floor(CW/#row1)
    for i,k in ipairs(row1) do
        local x1=(i-1)*kw+1; local x2=(i==#row1) and CW or i*kw
        mfill(corner_mon,x1,y1,x2,y1,colors.gray)
        mcentre(corner_mon,x1,x2,y1,k,colors.white,colors.gray)
        keypad_btns[#keypad_btns+1]={x1=x1,x2=x2,y=y1,val=k}
    end
    local hw=math.floor(CW/2)
    mfill(corner_mon,1,y1+1,hw,y1+1,colors.red)
    mcentre(corner_mon,1,hw,y1+1,"DEL",colors.white,colors.red)
    mfill(corner_mon,hw+1,y1+1,CW,y1+1,colors.lime)
    mcentre(corner_mon,hw+1,CW,y1+1,"OK",colors.black,colors.lime)
    keypad_btns[#keypad_btns+1]={x1=1,x2=hw,y=y1+1,val="DEL"}
    keypad_btns[#keypad_btns+1]={x1=hw+1,x2=CW,y=y1+1,val="OK"}
end

local function render_corner()
    corner_mon.setBackgroundColor(colors.black); corner_mon.clear()
    keypad_btns={}

    local is_turn = S.turn==pid and S.phase~="waiting" and S.phase~="showdown"
    local ph_label={waiting="Waiting",preflop="Pre-Flop",flop="Flop",
                    turn="Turn",river="River",showdown="Showdown"}

    -- Header
    local hdr_bg = is_turn and colors.lime or colors.black
    local hdr_fg = is_turn and colors.black or colors.yellow
    mfill(corner_mon,1,1,CW,1,hdr_bg)
    -- Show player name from disk if available, else P<n>
    local display_name = (wallet_data and wallet_data.player_name) or ("P"..pid)
    local hdr = display_name.."  "..S.chips.."c  "..(ph_label[S.phase] or S.phase)
    mwrite(corner_mon,2,1,hdr,hdr_fg,hdr_bg)
    mwrite(corner_mon,CW-5,1,"POT:"..S.pot,hdr_fg,hdr_bg)

    -- Disk status line (row 2 when not your turn)
    if not is_turn then
        mfill(corner_mon,1,2,CW,2,colors.black)
        if wallet_data then
            mwrite(corner_mon,2,2,"[disk] "..wallet_data.balance.."c saved",colors.green,colors.black)
        elseif wallet_drv then
            mwrite(corner_mon,2,2,"[disk] "..(wallet_err or "no wallet"),colors.orange,colors.black)
        else
            mwrite(corner_mon,2,2,"[no disk drive]",colors.gray,colors.black)
        end
    end

    -- Info rows
    local y=2

    -- Turn indicator
    if is_turn then
        mfill(corner_mon,1,y,CW,y,colors.lime)
        local call_str=S.call_amount>0 and ("  call:"..S.call_amount) or "  check free"
        mcentre(corner_mon,1,CW,y,"YOUR TURN"..call_str,colors.black,colors.lime)
        y=y+1
    elseif S.phase~="waiting" then
        mfill(corner_mon,1,y,CW,y,colors.gray)
        local t_str = S.turn>0 and "P"..S.turn.." acting" or "Waiting..."
        mwrite(corner_mon,2,y,t_str,colors.white,colors.gray)
        y=y+1
    end

    -- Community card summary (text)
    if #S.community>0 and y<=CH-3 then
        mfill(corner_mon,1,y,CW,y,colors.black)
        local line="Board: "
        for i,c in ipairs(S.community) do
            line=line..c.r..c.s.." "
        end
        mwrite(corner_mon,2,y,line,colors.white,colors.black)
        y=y+1
    end

    -- Other players' bets
    if S.phase~="waiting" and y<=CH-3 then
        mfill(corner_mon,1,y,CW,y,colors.black)
        local bline=""
        for i=1,4 do
            if i~=pid then
                local b=S.bets and S.bets[i] or 0
                local a=S.active and S.active[i]
                bline=bline.."P"..i..(a and ":"..b or ":fold").."  "
            end
        end
        mwrite(corner_mon,2,y,bline,colors.lightGray,colors.black)
        y=y+1
    end

    -- My current bet
    if S.phase~="waiting" and y<=CH-3 then
        local my_bet=S.bets and S.bets[pid] or 0
        if my_bet>0 or S.current_bet>0 then
            mfill(corner_mon,1,y,CW,y,colors.black)
            mwrite(corner_mon,2,y,"My bet: "..my_bet.."  Street bet: "..S.current_bet,
                   colors.orange,colors.black)
            y=y+1
        end
    end

    -- Showdown results
    if S.phase=="showdown" then
        for i,line in ipairs(S.result_lines) do
            if y<=CH-2 then
                mfill(corner_mon,1,y,CW,y,colors.black)
                mcentre(corner_mon,1,CW,y,line,colors.yellow,colors.black)
                y=y+1
            end
        end
        -- Revealed hands
        for other,hand in pairs(S.all_hands) do
            if other~=tostring(pid) and y<=CH-2 then
                local c1=hand[1]; local c2=hand[2]
                local l1=c1 and c1.r..c1.s or "?"
                local l2=c2 and c2.r..c2.s or "?"
                mfill(corner_mon,1,y,CW,y,colors.black)
                mwrite(corner_mon,2,y,"P"..other..": "..l1.." "..l2,colors.lightGray,colors.black)
                y=y+1
            end
        end
    end

    -- Raise input area
    if S.raise_mode then
        mfill(corner_mon,1,CH-2,CW,CH-2,colors.black)
        local amt_str="Raise to: "..(S.raise_digits=="" and "___" or S.raise_digits)
                      .."  (min "..S.raise_min..")"
        mcentre(corner_mon,1,CW,CH-2,amt_str,colors.orange,colors.black)
        draw_keypad(CH-1)
        -- bottom row used by keypad row 2, skip normal buttons
        return
    end

    -- Action buttons (bottom row)
    mfill(corner_mon,1,CH,CW,CH,colors.black)
    local acts=S.valid_actions
    if #acts>0 and is_turn then
        local n=#acts; local bw=math.floor(CW/n)
        for i,act in ipairs(acts) do
            local bx1=(i-1)*bw+1; local bx2=(i==n) and CW or i*bw
            local bg,fg
            if act=="fold" then bg=colors.red; fg=colors.white
            elseif act=="check" then bg=colors.gray; fg=colors.white
            elseif act=="call" then bg=colors.green; fg=colors.black
            elseif act=="raise" then bg=colors.orange; fg=colors.black
            else bg=colors.gray; fg=colors.white end
            mfill(corner_mon,bx1,CH,bx2,CH,bg)
            local lbl=act:upper()
            if act=="call" then lbl="CALL "..S.call_amount end
            mcentre(corner_mon,bx1,bx2,CH,lbl,fg,bg)
        end
    elseif S.phase=="waiting" or S.phase=="showdown" then
        -- Show "LEAVE TABLE" button when no action is needed
        -- Pressing it writes the current balance to disk and exits.
        mfill(corner_mon,1,CH,CW,CH,colors.purple)
        mcentre(corner_mon,1,CW,CH,"LEAVE TABLE",colors.white,colors.purple)
    end
end

-- ── Touch ─────────────────────────────────────────────────────
local function handle_corner_touch(x,y)
    -- Raise keypad
    if S.raise_mode then
        for _,btn in ipairs(keypad_btns) do
            if y==btn.y and x>=btn.x1 and x<=btn.x2 then
                if btn.val=="DEL" then
                    S.raise_digits=S.raise_digits:sub(1,-2)
                elseif btn.val=="OK" then
                    local amt=tonumber(S.raise_digits)
                    if amt and amt>=S.raise_min then
                        S.raise_mode=false; S.raise_digits=""
                        send({type="action",action="raise",raise_to=amt})
                        S.valid_actions={}
                    else
                        S.raise_digits=""  -- invalid, clear
                    end
                elseif #S.raise_digits<6 then
                    S.raise_digits=S.raise_digits..btn.val
                end
                render_corner(); return
            end
        end
        return
    end
    -- Action buttons on bottom row
    if y==CH and S.turn==pid and #S.valid_actions>0 then
        local n=#S.valid_actions; local bw=math.floor(CW/n)
        local idx=math.floor((x-1)/bw)+1
        idx=math.max(1,math.min(n,idx))
        local action=S.valid_actions[idx]
        if action=="raise" then
            S.raise_mode=true; S.raise_digits=""
            render_corner()
        else
            S.valid_actions={}
            send({type="action",action=action})
            render_corner()
        end
    elseif y==CH and (S.phase=="waiting" or S.phase=="showdown") then
        -- LEAVE TABLE button
        local saved = save_wallet(S.chips)
        -- Flash confirmation on screen then exit
        mfill(corner_mon,1,CH,CW,CH,saved and colors.lime or colors.orange)
        local lbl = saved and ("Saved "..S.chips.."c to disk. Goodbye!")
                           or "No disk — chips not saved!"
        mcentre(corner_mon,1,CW,CH,lbl,colors.black,saved and colors.lime or colors.orange)
        sleep(2)
        error("Player left table")   -- terminates the program cleanly
    end
end

-- ── Message handler ───────────────────────────────────────────
local function handle_msg(msg)
    if not msg then return end
    local t=msg.target
    if t~=nil and t~=0 and t~=pid then return end

    if msg.type=="dealer_ready" then
        connect()
    elseif msg.type=="ack" then
        S.chips=msg.chips or S.chips; S.phase=msg.phase or S.phase
        render_corner(); render_foot()
    elseif msg.type=="deal" then
        S.hand=msg.hand or {}; S.phase="preflop"
        S.result_lines={}; S.all_hands={}; S._hand_name=nil
        S.raise_mode=false; S.raise_digits=""; S.valid_actions={}
        if foot_mon~=corner_mon then anim_deal_foot()
        else render_foot() end
        render_corner()
    elseif msg.type=="state" then
        S.phase      =msg.phase or S.phase
        S.pot        =msg.pot   or S.pot
        S.bets       =msg.bets  or S.bets
        S.chips      =(msg.chips and msg.chips[pid]) or S.chips
        S.chips_all  =msg.chips or S.chips_all
        S.active     =msg.active or S.active
        S.turn       =msg.turn  or S.turn
        S.current_bet=msg.current_bet or S.current_bet
        if S.turn~=pid then S.valid_actions={}; S.raise_mode=false end
        render_corner(); render_foot()
    elseif msg.type=="community" then
        S.community=msg.cards or {}
        render_corner()
    elseif msg.type=="your_turn" then
        S.valid_actions=msg.valid_actions or {}
        S.call_amount =msg.call_amount   or 0
        S.pot         =msg.pot           or S.pot
        S.current_bet =msg.current_bet   or 0
        S.turn=pid
        render_corner()
    elseif msg.type=="enter_raise" then
        S.raise_mode=true; S.raise_digits=""
        S.raise_min=msg.min_raise or (S.current_bet+10)
        render_corner()
    elseif msg.type=="reveal" then
        if msg.player then S.all_hands[tostring(msg.player)]=msg.hand end
        render_corner()
    elseif msg.type=="result" then
        S.phase="showdown"; S.valid_actions={}; S.raise_mode=false
        S.result_lines=msg.result_lines or {}
        S._hand_name=msg.hand_name
        if msg.community   then S.community=msg.community end
        if msg.final_chips then S.chips=msg.final_chips   end
        -- Write updated balance to disk after every hand
        save_wallet(S.chips)
        render_corner(); render_foot()
    end
end

-- ── Boot ──────────────────────────────────────────────────────
corner_mon.setBackgroundColor(colors.black); corner_mon.clear()
mcentre(corner_mon,1,CW,math.floor(CH/2),"P"..pid.." connecting...",colors.yellow,colors.black)
if foot_mon~=corner_mon then
    foot_mon.setBackgroundColor(colors.black); foot_mon.clear()
    mcentre(foot_mon,1,FW,math.floor(FH/2),"P"..pid.." cards",colors.gray,colors.black)
end
connect()

while true do
    local ev={os.pullEvent()}
    if ev[1]=="modem_message" then
        handle_msg(textutils.unserialize(ev[5] or ""))
    elseif ev[1]=="monitor_touch" then
        -- CC reports the peripheral name in ev[2]; corner_side holds the side
        -- string which IS the peripheral name for built-in sides ("top" etc.)
        local touched=ev[2]
        if touched==corner_side or touched==peripheral.getName(corner_mon) then
            handle_corner_touch(ev[3],ev[4])
        end
        -- foot monitor is display-only; no touch handling needed
    elseif ev[1]=="disk" then
        -- Disk inserted — try to load wallet (only before a hand starts)
        if S.phase=="waiting" then
            reload_wallet()
            if wallet_data then
                S.chips = wallet_data.balance
                connect()   -- re-announce with disk balance
            end
            render_corner()
        end
    elseif ev[1]=="disk_eject" then
        wallet_data = nil; wallet_err = "disk removed"
        render_corner()
    end
end
