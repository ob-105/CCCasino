-- roulette/dealer.lua
-- Roulette croupier / wheel computer.
-- Hardware: monitor (any size, 2+ wide recommended), wireless modem
-- Channels: listens on 20 (DEALER_CH), broadcasts on 21 (BCAST_CH)
-- Run: dealer [max_players]   default 6
--
-- Operator workflow:
--   1. Press OPEN BETTING  -- players can now place bets
--   2. Wait for all players to press READY on their terminals
--      (or press FORCE SPIN at any time to spin immediately)
--   3. Wheel spins automatically once everyone is ready
--   4. Results shown for 6 seconds, then back to waiting

local MAX_PLAYERS = tonumber(arg and arg[1]) or 6
local DEALER_CH   = 20
local BCAST_CH    = 21

math.randomseed(os.epoch("utc"))

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the roulette dealer computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local modem = peripheral.find("modem")
assert(modem, "Attach a wireless modem to the roulette dealer computer")
modem.open(DEALER_CH); modem.open(BCAST_CH)

-- ── roulette constants ────────────────────────────────────────────────────────
local WHEEL = {0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26}
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do RED_SET[n]=true end

local function num_bg(n)
    if n == 0       then return colors.green end
    if RED_SET[n]   then return colors.red   end
    return colors.gray
end
local function wheel_pos(n)
    for i, v in ipairs(WHEEL) do if v == n then return i end end
    return 1
end

-- ── state ─────────────────────────────────────────────────────────────────────
-- phase: "waiting" | "betting" | "spinning" | "result"
local phase   = "waiting"
local players = {}   -- [pid] = {name, ready, connected}
local history = {}   -- last 10 results
local last_num = nil

local function bcast(msg)   modem.transmit(BCAST_CH, DEALER_CH, textutils.serialize(msg)) end
local function send_p(pid, msg) msg.target = pid; bcast(msg) end

local function count_connected()
    local n = 0
    for _, p in pairs(players) do if p.connected then n = n+1 end end
    return n
end
local function all_ready()
    if count_connected() == 0 then return false end
    for _, p in pairs(players) do
        if p.connected and not p.ready then return false end
    end
    return true
end

-- ── drawing ───────────────────────────────────────────────────────────────────
local function fill(x1,y1,x2,y2,bg)
    mon.setBackgroundColor(bg)
    local row = string.rep(" ",x2-x1+1)
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

local btns = {}
local function abtn(x1,y1,x2,y2,id,label,bg,fg)
    fill(x1,y1,x2,y2,bg)
    mp(x1+math.floor((x2-x1+1-#label)/2), y1+math.floor((y2-y1)/2), label, fg, bg)
    btns[#btns+1] = {x1=x1,y1=y1,x2=x2,y2=y2,id=id}
end

-- Draw the wheel strip: 7 visible numbers centred on wheel position `center`.
-- `highlight` = the winning number to glow gold (nil = no highlight).
local STRIP_CELLS = 7
local CELL_W      = 5   -- " 32  " format

local function draw_strip(center, highlight)
    local total_w = STRIP_CELLS * CELL_W + (STRIP_CELLS-1)
    local sx = math.floor((W - total_w) / 2) + 1
    local sy = 3
    fill(1, sy, W, sy, colors.black)
    for i = 1, STRIP_CELLS do
        local offset = i - math.ceil(STRIP_CELLS/2)
        local idx = ((center + offset - 1) % #WHEEL) + 1
        local n   = WHEEL[idx]
        local mid = (i == math.ceil(STRIP_CELLS/2))
        local bg  = mid and colors.yellow or num_bg(n)
        local fg  = mid and colors.black  or colors.white
        -- highlight glow when result settled
        if highlight == n and mid then bg = colors.lime; fg = colors.black end
        local lbl = string.format("%2d", n) .. "   "
        lbl = lbl:sub(1, CELL_W)
        local cx = sx + (i-1) * (CELL_W+1)
        fill(cx, sy, cx+CELL_W-1, sy, bg)
        mp(cx, sy, lbl, fg, bg)
        if i < STRIP_CELLS then
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.gray)
            mon.setCursorPos(cx+CELL_W, sy); mon.write("|")
        end
    end
    -- arrows
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white)
    mon.setCursorPos(sx-2, sy); mon.write("\x11\x11")
    mon.setCursorPos(sx + total_w + 1, sy); mon.write("\x10\x10")
end

-- Full screen render (called outside of spin animation).
local function render()
    mon.setBackgroundColor(colors.black); mon.clear()
    btns = {}

    -- ── header ─────────────────────────────────────────────────────────────────
    fill(1,1,W,1,colors.green)
    local title = "\x04\x04\x04  ROULETTE  \x04\x04\x04"
    centre(1, title, colors.black, colors.green)

    -- ── wheel strip ────────────────────────────────────────────────────────────
    if last_num ~= nil then
        draw_strip(wheel_pos(last_num), last_num)
    else
        fill(1,3,W,3,colors.black)
        centre(3, "  \x1b  Waiting for next round  \x1a  ", colors.gray, colors.black)
    end

    -- ── phase banner ───────────────────────────────────────────────────────────
    local ph_text = {
        waiting  = "  Waiting  ",
        betting  = " BETS OPEN ",
        spinning = " SPINNING! ",
        result   = "  RESULT   ",
    }
    local ph_col = {
        waiting  = colors.gray,
        betting  = colors.lime,
        spinning = colors.orange,
        result   = colors.yellow,
    }
    fill(1,4,W,4,colors.black)
    centre(4, ph_text[phase] or phase, colors.black, ph_col[phase] or colors.white)

    -- ── last result ────────────────────────────────────────────────────────────
    fill(1,5,W,5,colors.black)
    if phase == "result" and last_num ~= nil then
        local rb = last_num==0 and "Green" or (RED_SET[last_num] and "Red" or "Black")
        centre(5, "  " .. last_num .. "  (" .. rb .. ")  ", colors.white, num_bg(last_num))
    end

    -- ── history ─────────────────────────────────────────────────────────────────
    fill(1,6,W,6,colors.black)
    if #history > 0 then
        mp(2,6,"Last: ",colors.gray,colors.black)
        local hx = 9
        for i = math.max(1,#history-8), #history do
            local n = history[i]
            local lbl = string.format("%2d", n) .. " "
            fill(hx, 6, hx+#lbl-1, 6, num_bg(n))
            mp(hx, 6, lbl, colors.white, num_bg(n))
            hx = hx + #lbl + 1
        end
    end

    -- ── player list ─────────────────────────────────────────────────────────────
    local py = 8
    mp(2, py-1, "Players:", colors.gray, colors.black)
    local shown = 0
    for pid = 1, MAX_PLAYERS do
        local p = players[pid]
        if p and p.connected then
            shown = shown + 1
            local row = py + shown - 1
            if row <= H-3 then
                fill(1, row, W, row, colors.black)
                local dot_col = p.ready and colors.lime or colors.orange
                local dot     = p.ready and "\x07" or "\x07"
                mp(2,  row, "P"..pid.." "..p.name, colors.white,  colors.black)
                mp(W-7, row, p.ready and "READY  " or "betting", dot_col, colors.black)
            end
        end
    end
    if shown == 0 then
        mp(2, py, "(no players connected)", colors.gray, colors.black)
    end

    -- ── action buttons ──────────────────────────────────────────────────────────
    local by = H-1
    if phase == "waiting" or phase == "result" then
        abtn(2, by, W-1, by+1, "open", "OPEN BETTING", colors.green, colors.black)
    elseif phase == "betting" then
        local hw = math.floor((W-3)/2)
        abtn(2,    by, 1+hw, by+1, "force", "FORCE SPIN",   colors.red,    colors.white)
        abtn(3+hw, by, W-1,  by+1, "close", "CLOSE BETS",   colors.orange, colors.black)
    end
end

-- ── spin animation ────────────────────────────────────────────────────────────
local function do_spin()
    phase = "spinning"
    bcast({type="phase", phase="spinning"})
    render()

    local result     = math.random(0, 36)
    local t_idx      = wheel_pos(result)
    local s_idx      = math.random(#WHEEL)
    local dist       = (t_idx - s_idx) % #WHEEL
    local total_steps = 2 * #WHEEL + dist   -- ~2 full rotations + land

    for step = 1, total_steps do
        local pos = ((s_idx + step - 1) % #WHEEL) + 1
        local t   = step / total_steps
        draw_strip(pos, nil)
        sleep(0.025 + t * t * 0.30)   -- quadratic ease-out: starts fast, ends slow
    end

    -- Hold on final position with glow
    draw_strip(t_idx, result)
    sleep(0.5)

    -- Flash the winning cell three times
    for i = 1, 3 do
        fill(1,3,W,3,colors.black); sleep(0.15)
        draw_strip(t_idx, result);  sleep(0.15)
    end

    last_num = result
    history[#history+1] = result
    if #history > 10 then table.remove(history, 1) end

    phase = "result"
    bcast({type="result", number=result})
    render()
    sleep(6)

    phase = "waiting"
    for _, p in pairs(players) do p.ready = false end
    render()
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
        if p and p.connected then
            p.ready = true
            render()
            if phase == "betting" and all_ready() then
                do_spin()
            end
        end
    elseif msg.type == "unready" and msg.player then
        local p = players[msg.player]
        if p and phase == "betting" then p.ready = false; render() end
    elseif msg.type == "bye" and msg.player then
        local p = players[msg.player]
        if p then p.connected = false; render() end
    end
end

-- ── touch handler ─────────────────────────────────────────────────────────────
local function handle_touch(x, y)
    for _, b in ipairs(btns) do
        if x>=b.x1 and x<=b.x2 and y>=b.y1 and y<=b.y2 then
            if b.id == "open" then
                phase = "betting"
                for _, p in pairs(players) do p.ready = false end
                bcast({type="phase", phase="betting"})
                render()
            elseif b.id == "force" or b.id == "close" then
                do_spin()
            end
            return
        end
    end
end

-- ── main loop ─────────────────────────────────────────────────────────────────
render()
bcast({type="dealer_ready"})

while true do
    local ev = {os.pullEvent()}
    if ev[1] == "monitor_touch" then
        handle_touch(ev[3], ev[4])
    elseif ev[1] == "modem_message" then
        local msg = textutils.unserialize(ev[5] or "")
        if msg and (not msg.target or msg.target == 0) then
            handle_msg(msg)
        end
    end
end
