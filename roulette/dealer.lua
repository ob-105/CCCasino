-- roulette/dealer.lua
-- Fully automatic roulette wheel — no operator interaction needed.
-- Spins automatically when 2+ players are ready (30s countdown),
-- or immediately when ALL connected players are ready.
-- Hardware: monitor (2+ wide recommended), wireless modem
-- Channels: listens on 20 (DEALER_CH), broadcasts on 21 (BCAST_CH)

local MAX_PLAYERS = tonumber(arg and arg[1]) or 6
local DEALER_CH   = 20
local BCAST_CH    = 21
local SPIN_DELAY  = 30

math.randomseed(os.epoch("utc"))

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the roulette dealer computer")
mon.setTextScale(1.0)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
assert(modem, "Attach a wireless modem to the roulette dealer computer")
modem.open(DEALER_CH); modem.open(BCAST_CH)

-- ── roulette constants ────────────────────────────────────────────────────────
local WHEEL = {0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26}
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do RED_SET[n]=true end

local function num_bg(n)
    if n == 0     then return colors.green end
    if RED_SET[n] then return colors.red   end
    return colors.gray
end
local function wheel_pos(n)
    for i, v in ipairs(WHEEL) do if v == n then return i end end
    return 1
end

-- ── state ─────────────────────────────────────────────────────────────────────
local phase     = "betting"
local players   = {}
local history   = {}
local last_num  = nil
local countdown = 0
local spin_tmr  = nil
local tick_tmr  = nil

local function bcast(msg)       modem.transmit(BCAST_CH, DEALER_CH, textutils.serialize(msg)) end
local function send_p(pid, msg) msg.target = pid; bcast(msg) end

local function count_connected()
    local n = 0
    for _, p in pairs(players) do if p.connected then n=n+1 end end
    return n
end
local function count_ready()
    local n = 0
    for _, p in pairs(players) do if p.connected and p.ready then n=n+1 end end
    return n
end
local function all_ready()
    if count_connected() == 0 then return false end
    for _, p in pairs(players) do
        if p.connected and not p.ready then return false end
    end
    return true
end
local function cancel_countdown()
    spin_tmr = nil; tick_tmr = nil; countdown = 0
end
local function start_countdown()
    cancel_countdown()
    countdown = SPIN_DELAY
    spin_tmr  = os.startTimer(SPIN_DELAY)
    tick_tmr  = os.startTimer(1)
end

-- ── drawing ───────────────────────────────────────────────────────────────────
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

-- Wheel strip: 5 numbers centred on wheel position `center`.
local STRIP_CELLS = 5
local CELL_W      = 4   -- " 32 " format

local function draw_strip(center, highlight)
    local total_w = STRIP_CELLS * CELL_W
    local sx      = math.floor((W - total_w) / 2) + 1
    local sy      = 3
    fill(1, sy, W, sy, colors.black)
    for i = 1, STRIP_CELLS do
        local offset = i - math.ceil(STRIP_CELLS / 2)
        local idx    = ((center + offset - 1) % #WHEEL) + 1
        local n      = WHEEL[idx]
        local mid    = (i == math.ceil(STRIP_CELLS / 2))
        local bg     = mid and colors.yellow or num_bg(n)
        local fg     = mid and colors.black  or colors.white
        if highlight == n and mid then bg = colors.lime; fg = colors.black end
        local lbl    = string.format(" %2d ", n)
        local cx     = sx + (i-1) * CELL_W
        fill(cx, sy, cx+CELL_W-1, sy, bg)
        mp(cx, sy, lbl, fg, bg)
    end
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white)
    local asx = math.max(1, sx-2)
    mon.setCursorPos(asx, sy); mon.write("\x11\x11")
    if sx+total_w+1 <= W then
        mon.setCursorPos(sx+total_w+1, sy); mon.write("\x10\x10")
    end
end

-- ── render ────────────────────────────────────────────────────────────────────
local function render()
    mon.setBackgroundColor(colors.black); mon.clear()

    -- Row 1: header
    fill(1, 1, W, 1, colors.green)
    centre(1, "\x04\x04\x04  ROULETTE  \x04\x04\x04", colors.black, colors.green)

    -- Row 2: phase banner
    local ph_txt = { betting=" BETS OPEN ", spinning=" SPINNING! ", result="  RESULT  " }
    local ph_col = { betting=colors.lime,   spinning=colors.orange,  result=colors.yellow }
    fill(1, 2, W, 2, colors.black)
    centre(2, ph_txt[phase] or "  \x1b  ", colors.black, ph_col[phase] or colors.gray)

    -- Row 3: wheel strip
    if last_num ~= nil then
        draw_strip(wheel_pos(last_num), phase=="result" and last_num or nil)
    else
        fill(1, 3, W, 3, colors.black)
        centre(3, " \x1b  \x1b  \x1b  \x1b  \x1b ", colors.gray, colors.black)
    end

    -- Rows 4-5: big number / status
    fill(1, 4, W, 5, colors.black)
    if phase == "result" and last_num ~= nil then
        local rb = last_num==0 and "Green" or (RED_SET[last_num] and "Red" or "Black")
        local bg = num_bg(last_num)
        fill(1, 4, W, 5, bg)
        centre(4, "  " .. last_num .. "  ", colors.white, bg)
        centre(5, "  " .. rb:upper() .. "  ", colors.white, bg)
    elseif phase == "spinning" then
        fill(1, 4, W, 5, colors.orange)
        centre(4, "  SPINNING  ", colors.black, colors.orange)
        centre(5, string.rep("\x04", math.min(W-4,14)), colors.black, colors.orange)
    elseif phase == "betting" then
        local nr = count_ready()
        local nc = count_connected()
        if countdown > 0 then
            fill(1, 4, W, 4, colors.orange)
            centre(4, "  Spinning in " .. countdown .. "s  ", colors.black, colors.orange)
            fill(1, 5, W, 5, colors.black)
            centre(5, nr .. " / " .. nc .. " players ready", colors.white, colors.black)
        elseif nc == 0 then
            centre(4, "Waiting for players...", colors.gray, colors.black)
        elseif nr == 0 then
            centre(4, "  Bets open  (" .. nc .. " player" .. (nc~=1 and "s" or "") .. ")  ", colors.lime, colors.black)
        else
            centre(4, nr .. " / " .. nc .. " ready", colors.white, colors.black)
            centre(5, nr < 2 and "Need 2+ to start" or "Countdown paused", colors.gray, colors.black)
        end
    end

    -- Row 6: player dots
    if H >= 6 then
        fill(1, 6, W, 6, colors.black)
        mp(2, 6, "P:", colors.gray, colors.black)
        local px = 5
        local any = false
        for pid_i = 1, MAX_PLAYERS do
            local p = players[pid_i]
            if p and p.connected then
                any = true
                local col = p.ready and colors.lime or colors.orange
                local tag = "P"..pid_i.." "
                if px + #tag > W then break end
                mp(px, 6, tag, col, colors.black)
                px = px + #tag + 1
            end
        end
        if not any then
            mp(5, 6, "(none connected)", colors.gray, colors.black)
        end
    end

    -- Row 7: history
    if H >= 7 then
        fill(1, 7, W, H, colors.black)
        if #history > 0 then
            mp(2, 7, ":", colors.gray, colors.black)
            local hx = 4
            for i = #history, math.max(1, #history-7), -1 do
                local n   = history[i]
                local lbl = string.format(" %d ", n)
                if hx + #lbl - 1 <= W then
                    fill(hx, 7, hx+#lbl-1, 7, num_bg(n))
                    mp(hx, 7, lbl, colors.white, num_bg(n))
                    hx = hx + #lbl + 1
                end
            end
        end
    end
end

-- ── spin ──────────────────────────────────────────────────────────────────────
local function do_spin()
    cancel_countdown()
    phase = "spinning"
    bcast({type="phase", phase="spinning"})
    render()

    local result      = math.random(0, 36)
    local t_idx       = wheel_pos(result)
    local s_idx       = math.random(#WHEEL)
    local dist        = (t_idx - s_idx) % #WHEEL
    local total_steps = 2 * #WHEEL + dist

    for step = 1, total_steps do
        local pos = ((s_idx + step - 1) % #WHEEL) + 1
        local t   = step / total_steps
        draw_strip(pos, nil)
        sleep(0.025 + t * t * 0.30)
    end

    draw_strip(t_idx, result); sleep(0.5)
    for _ = 1, 3 do
        fill(1, 3, W, 3, colors.black); sleep(0.15)
        draw_strip(t_idx, result);       sleep(0.15)
    end

    last_num = result
    history[#history+1] = result
    if #history > 10 then table.remove(history, 1) end

    phase = "result"
    bcast({type="result", number=result})
    render()
    sleep(6)
end

local function open_betting()
    phase = "betting"
    cancel_countdown()
    for _, p in pairs(players) do p.ready = false end
    bcast({type="phase", phase="betting"})
    render()
end

-- ── check countdown state ─────────────────────────────────────────────────────
local function check_ready()
    if phase ~= "betting" then return end
    local nr = count_ready()
    if nr >= 2 and all_ready() then
        do_spin(); open_betting()
    elseif nr >= 2 and not spin_tmr then
        start_countdown(); render()
    elseif nr < 2 and spin_tmr then
        cancel_countdown(); render()
    else
        render()
    end
end

-- ── message handler ───────────────────────────────────────────────────────────
local function handle_msg(msg)
    if not msg then return end
    if msg.type == "hello" and msg.player then
        local pid = msg.player
        if pid >= 1 and pid <= MAX_PLAYERS then
            players[pid] = {
                name      = (msg.name and msg.name ~= "") and msg.name or ("P"..pid),
                ready     = false,
                connected = true,
            }
            send_p(pid, {type="ack", player=pid, phase=phase})
            render()
        end
    elseif msg.type == "ready" and msg.player then
        local p = players[msg.player]
        if p and p.connected and phase == "betting" then
            p.ready = true
            check_ready()
        end
    elseif msg.type == "unready" and msg.player then
        local p = players[msg.player]
        if p and phase == "betting" then
            p.ready = false
            check_ready()
        end
    elseif msg.type == "bye" and msg.player then
        local p = players[msg.player]
        if p then
            p.connected = false
            if phase == "betting" then check_ready() else render() end
        end
    end
end

-- ── main loop ─────────────────────────────────────────────────────────────────
bcast({type="dealer_ready"})
open_betting()

while true do
    local ev = {os.pullEvent()}
    if ev[1] == "modem_message" then
        local msg = textutils.unserialize(ev[5] or "")
        if msg and (not msg.target or msg.target == 0) then
            handle_msg(msg)
        end
    elseif ev[1] == "timer" then
        if ev[2] == spin_tmr then
            spin_tmr = nil; tick_tmr = nil; countdown = 0
            do_spin()
            open_betting()
        elseif ev[2] == tick_tmr then
            tick_tmr = nil
            if countdown > 0 then
                countdown = countdown - 1
                if countdown > 0 then tick_tmr = os.startTimer(1) end
            end
            render()
        end
    end
end
