-- roulette/player.lua
-- Roulette player terminal. Remove disk to leave — no LEAVE button.
-- Hardware: monitor (51+ chars wide at 0.5 scale), disk drive, wireless modem
-- Channels: listens on 21 (BCAST_CH), sends to 20 (DEALER_CH)
-- Run: player <number 1-6>

local pid = tonumber(arg and arg[1])
assert(pid and pid >= 1 and pid <= 6, "Usage: player <1-6>")

local DEALER_CH = 20
local BCAST_CH  = 21

-- ── wallet ────────────────────────────────────────────────────────────────────
local wallet = dofile("/casino/lib/wallet.lua")
local drv    = wallet.find_drive()
local wd     = nil
local chips  = 0

local function refresh_wallet()
    wd = nil; chips = 0
    if drv and disk.isPresent(drv) then
        local w = wallet.load(drv)
        if w then wd = w; chips = w.balance end
    end
end

local function flush_wallet()
    if not wd then return end
    wd.balance = chips
    wallet.save(wd, drv)
end

refresh_wallet()

-- ── modem / monitor ───────────────────────────────────────────────────────────
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

-- ── roulette constants ────────────────────────────────────────────────────────
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do RED_SET[n]=true end

local function num_bg(n)
    if n == 0     then return colors.green end
    if RED_SET[n] then return colors.red   end
    return colors.gray
end

-- ── bet state ─────────────────────────────────────────────────────────────────
local sbets    = {}
local obets    = {red=0,black=0,odd=0,even=0,low=0,high=0,d1=0,d2=0,d3=0,c1=0,c2=0,c3=0}
local chip_val = 10

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

-- ── payout ────────────────────────────────────────────────────────────────────
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

-- ── state ─────────────────────────────────────────────────────────────────────
-- phase: "attract" | "waiting" | "betting" | "ready" | "spinning" | "result"
local phase      = wd and "waiting" or "attract"
local last_num   = nil
local last_net   = nil
local spin_frame = 0

-- ── drawing helpers ───────────────────────────────────────────────────────────
local function fill(x1,y1,x2,y2,bg)
    mon.setBackgroundColor(bg)
    local row = string.rep(" ", x2-x1+1)
    for y = y1, y2 do mon.setCursorPos(x1,y); mon.write(row) end
end
local function mp(x,y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x,y); mon.write(s)
end
local function centre(y,s,fg,bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    local x = math.max(1, math.floor((W-#s)/2)+1)
    mon.setCursorPos(x,y); mon.write(s)
end
-- Centre text within a bounded horizontal region [x1..x2]
local function bcentre(y, x1, x2, s, fg, bg)
    local w = x2-x1+1
    local ox = x1 + math.floor((w-#s)/2)
    if ox < x1 then ox = x1 end
    fill(x1, y, x2, y, bg)
    mp(ox, y, s:sub(1,w), fg, bg)
end

local zones = {}
local function add_zone(x1,y1,x2,y2,kind,key)
    zones[#zones+1] = {x1=x1,y1=y1,x2=x2,y2=y2,kind=kind,key=key}
end

-- ── attract screen ────────────────────────────────────────────────────────────
local function render_attract()
    mon.setBackgroundColor(colors.black); mon.clear()
    zones = {}
    fill(1,1,W,1,colors.green)
    centre(1, "\x04\x04\x04  ROULETTE  \x04\x04\x04", colors.black, colors.green)
    local my = math.floor(H/2)
    local deco = string.rep("\x04", math.min(W-4, 20))
    centre(my-2, deco,                      colors.green,     colors.black)
    centre(my-1, "  Seat " .. pid .. "  ",  colors.yellow,    colors.black)
    centre(my+1, "Insert your chip disk",   colors.white,     colors.black)
    centre(my+2, "to begin",               colors.lightGray, colors.black)
    centre(my+3, deco,                      colors.green,     colors.black)
end

-- ── betting board ─────────────────────────────────────────────────────────────
local CW      = 3
local BOARD_X = 2
local ZERO_W  = 4
local NUM_X   = BOARD_X + ZERO_W

local function draw_cell(x,y,n,result_hl)
    local bet = sbets[n] or 0
    local bg  = result_hl and colors.yellow or
                (bet>0    and colors.orange  or num_bg(n))
    local fg  = (result_hl or bet>0) and colors.black or colors.white
    local lbl
    if bet > 0 then
        lbl = bet>=100 and tostring(bet):sub(1,3) or
              bet>=10  and tostring(bet).." "      or
              " "..tostring(bet)
    elseif n < 10 then lbl = " "..n.." "
    else lbl = tostring(n).." "
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
    local lbl = amt>0 and (label:sub(1,w-2).."* ") or label
    lbl = lbl:sub(1,w)
    if #lbl < w then lbl = lbl..string.rep(" ",w-#lbl) end
    mp(x,y,lbl,fg,bg)
    add_zone(x,y,x+w-1,y,"outside",key)
end

local function draw_board(result_hl)
    local by = 6
    local z_bg = (result_hl==0) and colors.lime or colors.green
    fill(BOARD_X, by, BOARD_X+ZERO_W-1, by+2, z_bg)
    local zbet = sbets[0] or 0
    mp(BOARD_X+1, by+1, zbet>0 and tostring(zbet) or " 0", zbet>0 and colors.black or colors.white, z_bg)
    add_zone(BOARD_X, by, BOARD_X+ZERO_W-1, by+2, "straight", 0)

    for n = 1, 36 do
        local col = math.ceil(n/3)
        local row = n%3==0 and 1 or (n%3==2 and 2 or 3)
        draw_cell(NUM_X+(col-1)*CW, by+(row-1), n, result_hl==n)
    end

    local cx = NUM_X + 12*CW + 1
    for i, key in ipairs({"c3","c2","c1"}) do
        local amt = obets[key] or 0
        local bg  = amt>0 and colors.orange or colors.gray
        local fg  = amt>0 and colors.black  or colors.white
        local lbl = amt>0 and tostring(amt):sub(1,3) or (key=="c3" and "C3 " or key=="c2" and "C2 " or "C1 ")
        mp(cx, by+(i-1), lbl, fg, bg)
        add_zone(cx, by+(i-1), cx+2, by+(i-1), "outside", key)
    end

    local dz = by+3
    local dw = math.floor(12*CW/3)
    draw_obet(NUM_X,      dz, dw, "d1", "1st 12", colors.gray)
    draw_obet(NUM_X+dw,   dz, dw, "d2", "2nd 12", colors.gray)
    draw_obet(NUM_X+dw*2, dz, dw, "d3", "3rd 12", colors.gray)

    local ow    = math.floor(12*CW/6)
    local out_y = dz+1
    local outs  = {
        {"low","1-18 ",colors.gray}, {"even","EVEN ",colors.gray},
        {"red","RED  ",colors.red},  {"black","BLK  ",colors.gray},
        {"odd","ODD  ",colors.gray}, {"high","19-36",colors.gray},
    }
    for i, o in ipairs(outs) do
        draw_obet(NUM_X+(i-1)*ow, out_y, ow, o[1], o[2], o[3])
    end
end

-- ── spinning overlay ──────────────────────────────────────────────────────────
local SPIN_FRAMES = {
    "  \x1b  SPINNING  \x1a  ",
    " \x1a\x1b  SPINNING \x1a\x1b  ",
    "\x1a\x1b\x1b  SPINNING\x1a\x1b\x1b ",
}
local function draw_spin_overlay()
    local oy = math.floor(H/2)
    fill(3, oy-1, W-2, oy+1, colors.orange)
    centre(oy-1, string.rep("\x04", W-6), colors.black, colors.orange)
    centre(oy,   SPIN_FRAMES[(spin_frame%#SPIN_FRAMES)+1], colors.black, colors.orange)
    centre(oy+1, string.rep("\x04", W-6), colors.black, colors.orange)
end

-- ── full render ───────────────────────────────────────────────────────────────
local function render(result_hl)
    if phase == "attract" then render_attract(); return end

    mon.setBackgroundColor(colors.black); mon.clear()
    zones = {}

    -- Row 1: header
    fill(1,1,W,1,colors.green)
    centre(1, "\x04 ROULETTE  Seat "..pid.." \x04", colors.black, colors.green)

    -- Row 2: balance
    fill(1,2,W,2,colors.black)
    if wd then
        mp(2, 2, "\x10 "..chips.." chips", colors.white, colors.black)
        mp(W-8, 2, "[disk ok]", colors.lime, colors.black)
    else
        centre(2, "!! Insert disk to save !!", colors.orange, colors.black)
    end

    -- Row 3: chip selector
    fill(1,3,W,3,colors.black)
    mp(2,3,"CHIP:",colors.lightGray,colors.black)
    local cx = 8
    for _, cv in ipairs({1,5,10,25,50,100}) do
        local lbl = tostring(cv)
        local bw  = #lbl+2
        local sel = cv==chip_val
        fill(cx,3,cx+bw-1,3, sel and colors.orange or colors.gray)
        mp(cx+1,3,lbl, sel and colors.black or colors.white, sel and colors.orange or colors.gray)
        add_zone(cx,3,cx+bw-1,3,"chip",cv)
        cx = cx+bw+1
    end

    -- Row 4: phase message
    fill(1,4,W,5,colors.black)
    local ph_msgs = {
        waiting  = "Waiting for dealer to open bets...",
        betting  = "  Place your bets!  ",
        ready    = "  Bets locked \x11 waiting to spin  ",
        spinning = "  Wheel is spinning!  ",
        result   = "",
    }
    local ph_cols = {
        waiting=colors.gray, betting=colors.lime, ready=colors.yellow,
        spinning=colors.orange, result=colors.white,
    }
    centre(4, ph_msgs[phase] or phase, ph_cols[phase] or colors.white, colors.black)

    -- Row 5: total bets
    local tot = total_bets()
    if tot > 0 and (phase=="betting" or phase=="ready") then
        centre(5, "Total: "..tot.." chips", colors.lightGray, colors.black)
    end

    -- Rows 6-10: betting board
    draw_board(result_hl)

    -- Result rows (H-3 and H-2)
    local res_y = H-3
    fill(1, res_y, W, res_y+1, colors.black)
    if phase == "result" and last_num ~= nil then
        local rb = last_num==0 and "Green" or (RED_SET[last_num] and "Red" or "Black")
        fill(1, res_y, W, res_y, num_bg(last_num))
        centre(res_y, "  Result: "..last_num.."  "..rb.."  ", colors.white, num_bg(last_num))
        if last_net and last_net > 0 then
            centre(res_y+1, "  WIN! +"..last_net.." chips  ", colors.black, colors.lime)
        elseif last_net and last_net < 0 then
            centre(res_y+1, "  Lost "..(- last_net).." chips  ", colors.red, colors.black)
        elseif last_net then
            centre(res_y+1, "  Break even  ", colors.gray, colors.black)
        end
    end

    -- Rows H-1..H: action buttons
    local by = H-1
    fill(1, by, W, H, colors.black)

    if phase == "betting" then
        local tot2 = total_bets()
        if tot2 > 0 then
            local split = math.floor(W*2/5)
            -- CLEAR (left 2/5)
            fill(1, by, split, H, colors.orange)
            bcentre(by,   1, split, "CLEAR", colors.black, colors.orange)
            bcentre(by+1, 1, split, "BETS",  colors.black, colors.orange)
            add_zone(1, by, split, H, "action", "clear")
            -- READY (right 3/5)
            local can = chips >= tot2
            local rbg = can and colors.green or colors.gray
            local rfg = can and colors.black or colors.white
            fill(split+1, by, W, H, rbg)
            bcentre(by,   split+1, W, "READY",                      rfg, rbg)
            bcentre(by+1, split+1, W, can and (tot2.."c") or "need more chips", rfg, rbg)
            if can then add_zone(split+1, by, W, H, "action", "ready") end
        else
            fill(1, by, W, H, colors.gray)
            centre(by,   "Tap the board to place bets", colors.lightGray, colors.gray)
            centre(by+1, "then press READY to lock in", colors.lightGray, colors.gray)
        end
    elseif phase == "ready" then
        fill(1, by, W, H, colors.orange)
        centre(by,   "CANCEL READY",              colors.black, colors.orange)
        centre(by+1, "tap to take your bets back", colors.black, colors.orange)
        add_zone(1, by, W, H, "action", "unready")
    end

    if phase == "spinning" then draw_spin_overlay() end
end

-- ── spin animation (local cosmetic) ──────────────────────────────────────────
local function play_spin_anim()
    for f = 1, 12 do
        spin_frame = f; render(); sleep(0.1)
    end
end

-- ── touch handler ─────────────────────────────────────────────────────────────
local function handle_touch(x,y)
    if phase == "spinning" or phase == "attract" then return end
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
                    local t = total_bets()
                    if t > 0 and chips >= t then
                        chips = chips - t
                        flush_wallet()
                        phase = "ready"
                        transmit({type="ready"})
                        render()
                    end
                elseif z.key == "unready" and phase=="ready" then
                    chips = chips + total_bets()
                    flush_wallet()
                    phase = "betting"
                    transmit({type="unready"})
                    render()
                elseif z.key == "clear" and phase=="betting" then
                    clear_bets(); render()
                end
            end
            return
        end
    end
end

-- ── message handler ───────────────────────────────────────────────────────────
local function handle_msg(msg)
    if not msg then return end
    local t = msg.target
    if t ~= nil and t ~= 0 and t ~= pid then return end

    if msg.type == "dealer_ready" then
        if phase ~= "attract" then connect() end
    elseif msg.type == "ack" then
        if phase ~= "attract" then phase = msg.phase or "waiting" end
        render()
    elseif msg.type == "phase" then
        if msg.phase == "betting" then
            clear_bets(); last_num = nil; last_net = nil
            if phase ~= "attract" then phase = "betting" end
        elseif msg.phase == "spinning" then
            if phase ~= "attract" then
                if phase ~= "ready" then clear_bets() end  -- missed cutoff
                phase = "spinning"
                play_spin_anim()
            end
        elseif msg.phase == "waiting" then
            if phase ~= "attract" then phase = "waiting" end
        end
        render()
    elseif msg.type == "result" then
        if phase == "attract" then return end
        local result = msg.number
        local win    = calc_payout(result)
        chips        = chips + win
        last_num     = result
        last_net     = win - total_bets()
        flush_wallet()
        clear_bets()
        phase = "result"
        render(result)
    end
end

-- ── boot ──────────────────────────────────────────────────────────────────────
if phase ~= "attract" then
    mon.setBackgroundColor(colors.black); mon.clear()
    centre(math.floor(H/2), "Seat "..pid.." — connecting...", colors.yellow, colors.black)
    connect()
end
render()

-- ── main loop ─────────────────────────────────────────────────────────────────
while true do
    local ev = {os.pullEvent()}
    if ev[1] == "monitor_touch" then
        handle_touch(ev[3], ev[4])
    elseif ev[1] == "modem_message" then
        handle_msg(textutils.unserialize(ev[5] or ""))
    elseif ev[1] == "disk" then
        refresh_wallet()
        if wd and phase == "attract" then
            phase = "waiting"
            connect()
        end
        render()
    elseif ev[1] == "disk_eject" then
        if phase == "ready" then transmit({type="unready"}) end
        transmit({type="bye"})
        wd = nil; chips = 0
        clear_bets(); last_num = nil; last_net = nil
        phase = "attract"
        render()
    end
end
