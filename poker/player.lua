-- poker/player.lua
-- Texas Hold'em — private player terminal
-- Monitor: 2w x 1h, attached to THIS computer
-- Modem:   wireless, listens ch11, sends to ch10
-- Run: player <number>    (1, 2, 3, or 4)

local pid = tonumber(arg and arg[1])
assert(pid and pid>=1 and pid<=4, "Usage: player <1-4>")

local BCAST_CH  = 11
local DEALER_CH = 10

-- ── Peripherals ───────────────────────────────────────────────
local mon = peripheral.find("monitor")
assert(mon, "No monitor found")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
assert(modem, "No modem found")
modem.open(BCAST_CH)

-- ── State ─────────────────────────────────────────────────────
local S = {
    hand          = {},
    community     = {},
    phase         = "waiting",
    chips         = 500,
    pot           = 0,
    bets          = {},
    active        = {},
    turn          = 0,
    call_amount   = 0,
    current_bet   = 0,
    valid_actions = {},
    result_lines  = {},
    all_hands     = {},
    -- raise input
    raise_mode    = false,
    raise_digits  = "",
    raise_min     = 0,
}

-- ── Send ──────────────────────────────────────────────────────
local function send(msg)
    msg.player=pid
    modem.transmit(DEALER_CH,BCAST_CH,textutils.serialize(msg))
end

local function connect()
    send({type="hello"})
end

-- ── Drawing ───────────────────────────────────────────────────
local SUIT_COL = {H=colors.red,D=colors.red,C=colors.gray,S=colors.gray}

local function cls(bg)
    mon.setBackgroundColor(bg or colors.black); mon.clear()
end

local function mprint(x,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(txt)
end

local function mfill(x1,y1,x2,y2,bg,char)
    mon.setBackgroundColor(bg)
    local row=string.rep(char or " ",x2-x1+1)
    for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(row) end
end

local function mcentre(x1,x2,y,txt,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    local x=x1+math.floor((x2-x1+1-#txt)/2)
    mon.setCursorPos(x,y); mon.write(txt)
end

-- Draw a hole card: 9 wide x 5 tall
-- Uses ASCII only: +-------+  |R      |  |   S   |  |      R|  +-------+
local function draw_hole_card(x,y,card)
    if not card then
        mfill(x,y,x+8,y+4,colors.gray)
        mon.setTextColor(colors.lightGray)
        mon.setCursorPos(x,y);   mon.write("+-empty-+")
        mon.setCursorPos(x,y+2); mon.write("|       |")
        mon.setCursorPos(x,y+4); mon.write("+-empty-+")
        return
    end
    local sc = SUIT_COL[card.s] or colors.gray
    local r  = card.r  -- 1-2 chars
    local s  = card.s  -- 1 char: H D C S
    -- inner width = 7
    -- top rank: left-aligned, pad to 7
    local top = r..string.rep(" ",7-#r)
    -- suit line: centred in 7 chars
    local mid = string.rep(" ",3)..s..string.rep(" ",3)
    -- bot rank: right-aligned
    local bot = string.rep(" ",7-#r)..r

    mon.setBackgroundColor(colors.white); mon.setTextColor(sc)
    mon.setCursorPos(x,y);   mon.write("+-"..r..string.rep("-",6-#r).."-+")
    mon.setCursorPos(x,y+1); mon.write("|"..top.."|")
    mon.setCursorPos(x,y+2); mon.write("|"..mid.."|")
    mon.setCursorPos(x,y+3); mon.write("|"..bot.."|")
    mon.setCursorPos(x,y+4); mon.write("+-"..string.rep("-",7-#r)..r.."-+")
end

-- Draw card back (same size)
local function draw_card_back(x,y)
    mon.setBackgroundColor(colors.blue); mon.setTextColor(colors.cyan)
    mon.setCursorPos(x,y);   mon.write("+-//////-+")
    mon.setCursorPos(x,y+1); mon.write("|///////|")
    mon.setCursorPos(x,y+2); mon.write("|/ ??? /|")
    mon.setCursorPos(x,y+3); mon.write("|///////|")
    mon.setCursorPos(x,y+4); mon.write("+-//////-+")
end

-- Numeric keypad for raise input
-- Lays out 12 keys across the full width in 2 rows
-- Returns a table of {x1,x2,y,val} for touch detection
local keypad_btns = {}

local function draw_keypad(y1)
    keypad_btns = {}
    local keys_row1 = {"1","2","3","4","5","6","7","8","9","0"}
    local keys_row2 = {"DEL","OK"}
    -- Row 1: digits 0-9, each ~W/10 wide
    local kw = math.floor(W / #keys_row1)
    for i,k in ipairs(keys_row1) do
        local x1=(i-1)*kw+1; local x2=(i==#keys_row1) and W or i*kw
        local bg = colors.gray; local fg = colors.white
        mfill(x1,y1,x2,y1,bg)
        mcentre(x1,x2,y1,k,fg,bg)
        keypad_btns[#keypad_btns+1]={x1=x1,x2=x2,y=y1,val=k}
    end
    -- Row 2: DEL and OK
    local hw=math.floor(W/2)
    mfill(1,y1+1,hw,y1+1,colors.red); mcentre(1,hw,y1+1,"DEL",colors.white,colors.red)
    mfill(hw+1,y1+1,W,y1+1,colors.lime); mcentre(hw+1,W,y1+1,"OK",colors.black,colors.lime)
    keypad_btns[#keypad_btns+1]={x1=1,x2=hw,y=y1+1,val="DEL"}
    keypad_btns[#keypad_btns+1]={x1=hw+1,x2=W,y=y1+1,val="OK"}
end

-- ── Main render ───────────────────────────────────────────────
local PHASE_LABEL={waiting="Waiting",preflop="Pre-Flop",flop="Flop",
                   turn="Turn",river="River",showdown="Showdown"}

-- Layout constants (computed relative to H)
local CARD_Y  = 2                  -- hole cards start row
local CARD_H  = 5                  -- card height
local INFO_Y  = CARD_Y + CARD_H + 1
local BTN_Y   = H                  -- action row

local function render()
    cls(colors.black)
    keypad_btns = {}

    -- Header
    mfill(1,1,W,1,colors.black)
    local ph = PHASE_LABEL[S.phase] or S.phase
    local hdr = "P"..pid.."  chips:"..S.chips.."  "..ph.."  pot:"..S.pot
    mprint(2,1,hdr,colors.yellow,colors.black)

    -- Hole cards (centred, side by side, 9w each + gap)
    local cw=9; local gap=3
    local total=2*cw+gap
    local cx=math.floor((W-total)/2)+1

    if S.raise_mode then
        -- When entering a raise, show cards smaller and make room for keypad
        -- Just show card labels instead of full art to save space
        local c1=S.hand[1]; local c2=S.hand[2]
        local l1=c1 and (c1.r..c1.s) or "?"
        local l2=c2 and (c2.r..c2.s) or "?"
        mfill(1,CARD_Y,W,CARD_Y+CARD_H,colors.black)
        mcentre(1,HW or math.floor(W/2),CARD_Y+2,l1,
            c1 and (SUIT_COL[c1.s] or colors.white) or colors.gray, colors.black)
        mcentre((HW or math.floor(W/2))+1,W,CARD_Y+2,l2,
            c2 and (SUIT_COL[c2.s] or colors.white) or colors.gray, colors.black)
    else
        draw_hole_card(cx,       CARD_Y, S.hand[1])
        draw_hole_card(cx+cw+gap,CARD_Y, S.hand[2])
    end

    -- Info / status line
    mfill(1,INFO_Y,W,INFO_Y,colors.gray)
    if S.turn==pid and S.phase~="waiting" and S.phase~="showdown" then
        local it="YOUR TURN  current bet:"..S.current_bet.."  call:"..S.call_amount
        mcentre(1,W,INFO_Y,it,colors.black,colors.lime)
    elseif S.phase=="showdown" then
        if #S.result_lines>0 then
            mcentre(1,W,INFO_Y,S.result_lines[1] or "",colors.yellow,colors.gray)
        end
    else
        local bets_str=""
        for i=1,4 do
            if S.active and S.active[i] then
                bets_str=bets_str.."P"..i..":"..((S.bets and S.bets[i]) or 0).."  "
            end
        end
        mprint(2,INFO_Y,bets_str,colors.white,colors.gray)
    end

    -- Raise mode: show keypad + current input
    if S.raise_mode then
        local inp_y=INFO_Y+1
        mfill(1,inp_y,W,inp_y,colors.black)
        local amt_str="Raise to: "..(S.raise_digits=="" and "___" or S.raise_digits)
                      .."  (min "..S.raise_min..")"
        mcentre(1,W,inp_y,amt_str,colors.orange,colors.black)
        draw_keypad(inp_y+1)
        return  -- skip normal action buttons
    end

    -- Showdown: show other hands
    if S.phase=="showdown" then
        local ry=INFO_Y+1
        for other,hand in pairs(S.all_hands) do
            if other~=tostring(pid) and ry<BTN_Y then
                local c1=hand[1]; local c2=hand[2]
                local l1=c1 and (c1.r..c1.s) or "?"
                local l2=c2 and (c2.r..c2.s) or "?"
                mprint(2,ry,"P"..other..": "..l1.." "..l2,colors.lightGray,colors.black)
                ry=ry+1
            end
        end
    end

    -- Action buttons (bottom row)
    mfill(1,BTN_Y,W,BTN_Y,colors.black)
    local acts=S.valid_actions
    if #acts>0 and S.turn==pid then
        local n=#acts; local bw=math.floor(W/n)
        for i,act in ipairs(acts) do
            local bx1=(i-1)*bw+1; local bx2=(i==n) and W or i*bw
            local bg,fg
            if act=="fold" then bg=colors.red; fg=colors.white
            elseif act=="check" then bg=colors.gray; fg=colors.white
            elseif act=="call" then bg=colors.green; fg=colors.black
            elseif act=="raise" then bg=colors.orange; fg=colors.black
            else bg=colors.gray; fg=colors.white end
            mfill(bx1,BTN_Y,bx2,BTN_Y,bg)
            local lbl=act:upper()
            if act=="call" then lbl="CALL "..S.call_amount end
            mcentre(bx1,bx2,BTN_Y,lbl,fg,bg)
        end
    end
end

-- ── Touch ─────────────────────────────────────────────────────
local HW_local = nil  -- set after W known

local function handle_touch(x,y)
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
                        -- flash invalid
                        S.raise_digits=""
                    end
                else
                    if #S.raise_digits<6 then
                        S.raise_digits=S.raise_digits..btn.val
                    end
                end
                render(); return
            end
        end
        return
    end

    -- Normal action buttons on bottom row
    if y==BTN_Y and S.turn==pid and #S.valid_actions>0 then
        local acts=S.valid_actions; local n=#acts
        local bw=math.floor(W/n)
        local idx=math.floor((x-1)/bw)+1
        if idx<1 then idx=1 end; if idx>n then idx=n end
        local action=acts[idx]
        if action=="raise" then
            -- Raise handled: dealer sends enter_raise prompt, but
            -- player can also initiate here by switching to raise mode
            S.raise_mode=true; S.raise_digits=""
            render()
        else
            S.valid_actions={}
            local ca=math.min(S.call_amount, S.chips)
            send({type="action",action=action,raise_to=nil})
            render()
        end
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
        render()
    elseif msg.type=="deal" then
        S.hand=msg.hand or {}; S.phase="preflop"
        S.result_lines={}; S.all_hands={}
        S.raise_mode=false; S.raise_digits=""
        S.valid_actions={}
        render()
        -- brief animation: flip from back to face
        local cw=9; local gap=3; local total=2*cw+gap
        local cx=math.floor((W-total)/2)+1
        draw_card_back(cx,CARD_Y); draw_card_back(cx+cw+gap,CARD_Y)
        sleep(0.2)
        render()
    elseif msg.type=="state" then
        S.phase  =msg.phase  or S.phase
        S.pot    =msg.pot    or S.pot
        S.bets   =msg.bets   or S.bets
        S.chips  =(msg.chips and msg.chips[pid]) or S.chips
        S.active =msg.active or S.active
        S.turn   =msg.turn   or S.turn
        if S.turn~=pid then S.valid_actions={}; S.raise_mode=false end
        render()
    elseif msg.type=="community" then
        S.community=msg.cards or {}; render()
    elseif msg.type=="your_turn" then
        S.valid_actions=msg.valid_actions or {}
        S.call_amount  =msg.call_amount   or 0
        S.pot          =msg.pot           or S.pot
        S.current_bet  =msg.current_bet   or 0
        S.turn=pid
        render()
    elseif msg.type=="enter_raise" then
        S.raise_mode=true; S.raise_digits=""
        S.raise_min =msg.min_raise or (S.current_bet+10)
        render()
    elseif msg.type=="reveal" then
        if msg.player then
            S.all_hands[tostring(msg.player)]=msg.hand
        end
        render()
    elseif msg.type=="result" then
        S.phase       ="showdown"
        S.valid_actions={}
        S.result_lines=msg.result_lines or {}
        S.raise_mode  =false
        if msg.community then S.community=msg.community end
        render()
    end
end

-- ── Boot ──────────────────────────────────────────────────────
HW_local = math.floor(W/2)
cls(colors.black)
mcentre(1,W,math.floor(H/2),"P"..pid.." connecting...",colors.yellow,colors.black)
connect()

while true do
    local ev={os.pullEvent()}
    if ev[1]=="modem_message" then
        handle_msg(textutils.unserialize(ev[5] or ""))
    elseif ev[1]=="monitor_touch" then
        handle_touch(ev[3],ev[4])
    end
end
