-- roulette/player.lua
-- Roulette player terminal.
-- Hardware: monitor (51+ chars wide), disk drive (any side), wireless modem
-- Channels: listens on 21 (BCAST_CH), sends to 20 (DEALER_CH)
-- Run: player <number 1-6>
--
-- Insert wallet disk, wait for dealer to open betting, place bets, press READY.

local pid = tonumber(arg and arg[1])
assert(pid and pid >= 1 and pid <= 6, "Usage: player <1-6>")

local DEALER_CH = 20
local BCAST_CH  = 21

-- ── wallet ─────────────────────────────────────────────────────────��──────────
local wallet = dofile("/casino/lib/wallet.lua")
local drv  = wallet.find_drive()
local wd   = nil
local chips = 0

local function refresh_wallet()
    wd = nil; chips = 0
    if drv and disk.isPresent(drv) then
        local w, _ = wallet.load(drv)
        if w then wd = w; chips = w.balance end
    end
end

local function flush_wallet()
    if not wd then return end
    wd.balance = chips
    wallet.save(wd, drv)
end

refresh_wallet()

-- ── modem ────────────────────���────────────────────────────────────────────────
local modem = peripheral.find("modem")
assert(modem, "Attach a wireless modem")
modem.open(BCAST_CH)

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local function transmit(msg)
    msg.player = pid
    modem.transmit(DEALER_CH, BCAST_CH, textutils.serialize(msg))
end

local function connect()
    local name = wd and wd.player_name or ("P"..pid)
    transmit({type="hello", name=name})
end

-- ── roulette constants ──────────────────────���──────────────────────────��──────
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do RED_SET[n]=true end

local function num_bg(n)
    if n == 0      then return colors.green end
    if RED_SET[n]  then return colors.red   end
    return colors.gray
end

-- ── bet state ────────────────────���───────────────────────────────���────────────
local sbets = {}       -- sbets[n] = chips on number n (0-36)
local obets = { red=0, black=0, odd=0, even=0, low=0, high=0, d1=0, d2=0, d3=0, c1=0, c2=0, c3=0 }
local chip_val  = 10

local function total_bets()
    local t = 0
    for _,v in pairs(sbets) do t=t+v end
    for _,v in pairs(obets) do t=t+v end
    return t
end

local function clear_bets()
    sbets = {}
    for k in pairs(obets) do obets[k] = 0 end
end

-- ── payout ───────────────────────────────────────────────��────────────────────
local function calc_payout(result)
    local win = 0
    for n, amt in pairs(sbets) do
        if n == result then win = win + amt * 36 end
    end
    if result > 0 then
        local function em(amt, cond) if cond and amt>0 then win=win+amt*2 end end
        em(obets.red,   RED_SET[result]==true)
        em(obets.black, not RED_SET[result])
        em(obets.odd,   result%2==1)
        em(obets.even,  result%2==0)
        em(obets.low,   result>=1  and result<=18)
        em(obets.high,  result>=19 and result<=36)
        local function doz(amt,lo,hi) if result>=lo and result<=hi and amt>0 then win=win+amt*3 end end
        doz(obets.d1,1,12); doz(obets.d2,13,24); doz(obets.d3,25,36)
        local col = result%3
        if col==1 and obets.c1>0 then win=win+obets.c1*3 end
        if col==2 and obets.c2>0 then win=win+obets.c2*3 end
        if col==0 and obets.c3>0 then win=win+obets.c3*3 end
    end
    return win
end

-- ── phase / result state ──────────────────────────────────────────────────────
-- phase: "waiting" | "betting" | "ready" | "spinning" | "result"
local phase      = "waiting"
local last_num   = nil
local last_net   = nil    -- net chips gained/lost last spin
local spin_frame = 0      -- for local spin animation

-- ── drawing ──────────────────────────────────────────────────────��────────────
local function fill(x1,y1,x2,y2,bg)
    mon.setBackgroundColor(bg)
    local row=string.rep(" ",x2-x1+1)
    for y=y1,y2 do mon.setCursorPos(x1,y); mon.write(row) end
end
local function mp(x,y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(s)
end
local function centre(y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(math.floor((W-#s)/2)+1, y); mon.write(s)
end

-- Touch zones
local zones = {}
local function add_zone(x1,y1,x2,y2,kind,key)
    zones[#zones+1]={x1=x1,y1=y1,x2=x2,y2=y2,kind=kind,key=key}
end

-- Draw a number cell (3 wide × 1 tall). Yellow bg = player has bet here.
local CW = 3
local function draw_cell(x,y,n,result_hl)
    local bet = sbets[n] or 0
    local bg  = result_hl and colors.yellow or
                (bet>0    and colors.orange  or num_bg(n))
    local fg  = (result_hl or bet>0) and colors.black or colors.white
    local lbl
    if bet > 0 then
        lbl = bet >= 100 and tostring(bet):sub(1,3) or
              bet >= 10  and tostring(bet).." "      or
              " "..tostring(bet)
    elseif n < 10 then
        lbl = " "..n.." "
    else
        lbl = tostring(n).." "
    end
    lbl = lbl:sub(1,CW)
    if #lbl < CW then lbl = lbl..string.rep(" ",CW-#lbl) end
    mp(x,y,lbl,fg,bg)
    add_zone(x,y,x+CW-1,y,"straight",n)
end

local function draw_obet(x,y,w,key,label,base_bg)
    local amt = obets[key] or 0
    local bg  = amt>0 and colors.orange or base_bg
    local fg  = amt>0 and colors.black  or colors.white
    local lbl = amt>0 and (label:sub(1,w-2).."*"..string.rep(" ",1)) or label
    lbl = lbl:sub(1,w)
    if #lbl < w then lbl=lbl..string.rep(" ",w-#lbl) end
    mp(x,y,lbl,fg,bg)
    add_zone(x,y,x+w-1,y,"outside",key)
end

-- Board anchor positions
local BOARD_X  = 2
local ZERO_W   = 4
local NUM_X    = BOARD_X + ZERO_W

local function draw_board(result_hl)
    local by = 6   -- board starts at row 6

    -- 0 cell (spans 3 rows)
    local z_bg = (result_hl==0) and colors.lime or colors.green
    fill(BOARD_X, by, BOARD_X+ZERO_W-1, by+2, z_bg)
    local zbet = sbets[0] or 0
    local zlbl = zbet>0 and tostring(zbet) or " 0"
    mp(BOARD_X+1, by+1, zlbl, zbet>0 and colors.black or colors.white, z_bg)
    add_zone(BOARD_X, by, BOARD_X+ZERO_W-1, by+2, "straight", 0)

    -- numbers 1-36
    for n=1,36 do
        local col = math.ceil(n/3)
        local row = n%3==0 and 1 or (n%3==2 and 2 or 3)
        local nx  = NUM_X + (col-1)*CW
        local ny  = by + (row-1)
        draw_cell(nx, ny, n, result_hl==n)
    end

    -- column bets (right side)
    local cx = NUM_X + 12*CW + 1
    local col_data = {{"c3"," C3"},{} ,{"c2"," C2"},{"c1"," C1"}}
    for i, key in ipairs({"c3","c2","c1"}) do
        local amt = obets[key] or 0
        local bg  = amt>0 and colors.orange or colors.gray
        local fg  = amt>0 and colors.black  or colors.white
        local lbl = amt>0 and tostring(amt):sub(1,3) or (key=="c3" and "C3 " or key=="c2" and "C2 " or "C1 ")
        mp(cx, by+(i-1), lbl, fg, bg)
        add_zone(cx, by+(i-1), cx+2, by+(i-1), "outside", key)
    end

    -- dozens
    local dz = by+3
    local dw = math.floor(12*CW/3)
    draw_obet(NUM_X,       dz, dw, "d1", "1st 12", colors.gray)
    draw_obet(NUM_X+dw,    dz, dw, "d2", "2nd 12", colors.gray)
    draw_obet(NUM_X+dw*2,  dz, dw, "d3", "3rd 12", colors.gray)

    -- even-money outside bets
    local ow = math.floor(12*CW/6)
    local out_y = dz+1
    local outs = {
        {"low","1-18 ",colors.gray}, {"even","EVEN ",colors.gray},
        {"red","RED  ",colors.red},  {"black","BLK  ",colors.gray},
        {"odd","ODD  ",colors.gray}, {"high","19-36",colors.gray},
    }
    for i,o in ipairs(outs) do
        draw_obet(NUM_X+(i-1)*ow, out_y, ow, o[1], o[2], o[3])
    end
end

-- ── spinning overlay ──────────────────────────────────────────────────────────
local SPIN_FRAMES = {
    "  \x1b  SPINNING  \x1a  ",
    " \x1a\x1b  SPINNING \x1a\x1b  ",
    "\x1a\x1b\x1b  SPINNING\x1a\x1b\x1b ",
    " \x1a\x1b  SPINNING \x1a\x1b  ",
}

local function draw_spin_overlay()
    local oy = math.floor(H/2)
    fill(3,oy-1,W-2,oy+1,colors.orange)
    centre(oy-1, string.rep("\x04",W-6), colors.black, colors.orange)
    centre(oy,   SPIN_FRAMES[(spin_frame%#SPIN_FRAMES)+1], colors.black, colors.orange)
    centre(oy+1, string.rep("\x04",W-6), colors.black, colors.orange)
end

-- ── full render ───────────────────────────────────────────────────���───────────
local function render(result_hl)
    mon.setBackgroundColor(colors.black); mon.clear()
    zones = {}

    -- header
    fill(1,1,W,1,colors.green)
    local pname = wd and wd.player_name or ("P"..pid)
    local hdr = " \x04 ROULETTE  P"..pid.." \x04 "
    centre(1, hdr, colors.black, colors.green)

    -- balance / disk
    fill(1,2,W,2,colors.black)
    if wd then
        mp(2,2,"Balance: "..chips.." chips",colors.white,colors.black)
        mp(W-8,2,"[disk ok]",colors.lime,colors.black)
    else
        mp(2,2,"!! NO DISK -- not saving !!",colors.orange,colors.black)
    end

    -- chip selector (row 3)
    fill(1,3,W,3,colors.black)
    mp(2,3,"CHIP:",colors.lightGray,colors.black)
    local cx = 8
    for _, cv in ipairs({1,5,10,25,50,100}) do
        local lbl = tostring(cv)
        local bw  = #lbl+2
        local bg  = cv==chip_val and colors.orange or colors.gray
        local fg  = cv==chip_val and colors.black  or colors.white
        fill(cx,3,cx+bw-1,3,bg)
        mp(cx+1,3,lbl,fg,bg)
        add_zone(cx,3,cx+bw-1,3,"chip",cv)
        cx = cx+bw+1
    end

    -- phase indicator (row 4-5)
    fill(1,4,W,5,colors.black)
    local ph_msgs = {
        waiting  = "Waiting for dealer...",
        betting  = "Place your bets!",
        ready    = "Bets locked — waiting for spin",
        spinning = "Wheel is spinning!",
        result   = "Round over",
    }
    local ph_cols = {
        waiting=colors.gray, betting=colors.lime, ready=colors.yellow,
        spinning=colors.orange, result=colors.white,
    }
    centre(4, ph_msgs[phase] or phase, ph_cols[phase] or colors.white, colors.black)

    -- total bets display
    local tot = total_bets()
    if tot > 0 and (phase=="betting" or phase=="ready") then
        centre(5, "Total bet: "..tot.." chips", colors.lightGray, colors.black)
    end

    -- betting board
    draw_board(result_hl)

    -- result row
    if phase == "result" and last_num ~= nil then
        local row = H-3
        fill(1,row,W,row+1,colors.black)
        local rb = last_num==0 and "Green" or (RED_SET[last_num] and "Red" or "Black")
        centre(row,   "Result: "..last_num.." ("..rb..")", colors.white, num_bg(last_num))
        if last_net ~= nil then
            if last_net > 0 then
                centre(row+1, "  WIN! +"..last_net.." chips  ", colors.black, colors.lime)
            else
                centre(row+1, "  No win this spin  ",           colors.gray,  colors.black)
            end
        end
    end

    -- action buttons
    local by = H-1
    fill(1,by,W,by+1,colors.black)
    if phase == "betting" then
        local tot2 = total_bets()
        if tot2 > 0 and chips >= tot2 then
            local hw = math.floor((W-3)/2)
            fill(2,by,1+hw,by+1,colors.green)
            centre(by, "READY (" .. tot2 .. "c)", colors.black, colors.green)
            add_zone(2,by,1+hw,by+1,"action","ready")
            fill(3+hw,by,W-1,by+1,colors.orange)
            centre(by, "CLEAR", colors.black, colors.orange)
            add_zone(3+hw,by,W-1,by+1,"action","clear")
        else
            fill(2,by,W-1,by+1,colors.gray)
            centre(by, "Place bets then press READY", colors.lightGray, colors.gray)
            fill(2,by+1,W-1,by+1,colors.orange)
            centre(by+1,"CLEAR BETS",colors.black,colors.orange)
            add_zone(2,by+1,W-1,by+1,"action","clear")
        end
    elseif phase == "ready" then
        fill(2,by,W-1,by+1,colors.orange)
        centre(by, "CANCEL READY", colors.black, colors.orange)
        add_zone(2,by,W-1,by+1,"action","unready")
    end

    -- leave table (always visible)
    fill(1,H,math.floor(W/3),H,colors.purple)
    mp(2,H,"LEAVE TABLE",colors.white,colors.purple)
    add_zone(1,H,math.floor(W/3),H,"action","leave")

    -- spinning overlay on top
    if phase == "spinning" then
        draw_spin_overlay()
    end
end

-- ── spinning animation (local, cosmetic only) ─────────────────────���───────────
-- Called while waiting for the modem result message.
-- Runs briefly then returns — the modem loop handles the actual result.
local function play_spin_anim()
    for f = 1, 12 do
        spin_frame = f
        render()
        sleep(0.1)
    end
end

-- ── touch handler ─────────��───────────────────────────────��─────────────────��─
local function handle_touch(x,y)
    if phase == "spinning" then return end  -- locked during spin
    for _, z in ipairs(zones) do
        if x>=z.x1 and x<=z.x2 and y>=z.y1 and y<=z.y2 then
            if z.kind == "chip" then
                chip_val = z.key; render()
            elseif z.kind == "straight" and phase=="betting" then
                sbets[z.key] = (sbets[z.key] or 0) + chip_val; render()
            elseif z.kind == "outside" and phase=="betting" then
                obets[z.key] = (obets[z.key] or 0) + chip_val; render()
            elseif z.kind == "action" then
                if z.key == "ready" then
                    local tot = total_bets()
                    if tot > 0 and chips >= tot then
                        chips = chips - tot
                        flush_wallet()
                        phase = "ready"
                        transmit({type="ready"})
                        render()
                    end
                elseif z.key == "unready" and phase=="ready" then
                    -- refund and cancel ready
                    chips = chips + total_bets()
                    flush_wallet()
                    phase = "betting"
                    transmit({type="unready"})
                    render()
                elseif z.key == "clear" and phase=="betting" then
                    clear_bets(); render()
                elseif z.key == "leave" then
                    if phase=="ready" then
                        chips = chips + total_bets()   -- refund locked bets
                    end
                    flush_wallet()
                    transmit({type="bye"})
                    fill(1,1,W,H,colors.purple)
                    centre(math.floor(H/2), "Saved "..chips.."c to disk. Goodbye!", colors.white, colors.purple)
                    sleep(2); error("player left")
                end
            end
            return
        end
    end
end

-- ── message handler ───────────────────────���─────────────────────────��─────────
local function handle_msg(msg)
    if not msg then return end
    local t = msg.target
    if t ~= nil and t ~= 0 and t ~= pid then return end

    if msg.type == "dealer_ready" then
        connect()
    elseif msg.type == "ack" then
        phase = msg.phase or "waiting"
        render()
    elseif msg.type == "phase" then
        if msg.phase == "betting" then
            clear_bets()
            last_num = nil; last_net = nil
            phase = "betting"
        elseif msg.phase == "spinning" then
            -- if still in ready, bets already deducted; just update phase
            phase = "spinning"
            play_spin_anim()
            -- after anim loop, wait for result message
        elseif msg.phase == "waiting" then
            phase = "waiting"
        end
        render()
    elseif msg.type == "result" then
        local result = msg.number
        local win    = calc_payout(result)
        chips        = chips + win
        last_num     = result
        last_net     = win - total_bets()  -- total_bets still has the pre-deducted amount
        flush_wallet()
        clear_bets()
        phase = "result"
        render(result)   -- highlight winning number on board
    end
end

-- ── boot ──────────────────────────────────────────────���──────────────────────
centre(math.floor(H/2), "P"..pid.." — connecting...", colors.yellow, colors.black)
connect()

-- ─�� main loop ─────────────────���───────────────────────────────��───────────────
render()
while true do
    local ev = {os.pullEvent()}
    if ev[1] == "monitor_touch" then
        handle_touch(ev[3], ev[4])
    elseif ev[1] == "modem_message" then
        handle_msg(textutils.unserialize(ev[5] or ""))
    elseif ev[1] == "disk" then
        refresh_wallet(); render()
        if phase == "waiting" then connect() end
    elseif ev[1] == "disk_eject" then
        wd = nil; render()
    end
end
