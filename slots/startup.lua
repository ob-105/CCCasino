-- slots/startup.lua
-- Three-reel slot machine.
-- Hardware: monitor (any side), disk drive (any side)
-- Run: startup  (no arguments)

local wallet = dofile("/casino/lib/wallet.lua")

math.randomseed(os.epoch("utc"))

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the slots computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local drv = wallet.find_drive()

-- ── wallet ────────────────────────────────────────────────────────────────────
local wd, wd_err = nil, nil
local chips = 0

local function refresh_wallet()
    wd, wd_err = nil, nil
    chips = 0
    if drv and disk.isPresent(drv) then
        wd, wd_err = wallet.load(drv)
        if wd then chips = wd.balance end
    end
end

local function flush_wallet()
    if not wd then return end
    wd.balance = chips
    local ok, err = wallet.save(wd, drv)
    if not ok then wd_err = err end
end

refresh_wallet()

-- ── symbols ───────────────────────────────────────────────────────────────────
-- weight controls frequency (higher = more common)
local SYMS = {
    { key="7",   disp=" 7 ", col=colors.yellow, weight=3  },
    { key="BAR", disp="BAR", col=colors.white,  weight=5  },
    { key="BEL", disp="BEL", col=colors.orange, weight=5  },
    { key="CHR", disp="CHR", col=colors.red,    weight=6  },
    { key="LEM", disp="LEM", col=colors.lime,   weight=6  },
}

local POOL = {}
for _, s in ipairs(SYMS) do
    for _ = 1, s.weight do POOL[#POOL+1] = s end
end
local function rsym() return POOL[math.random(#POOL)] end

-- ── payouts ───────────────────────────────────────────────────────────────────
local THREE_MULT = { ["7"]=50, BAR=20, BEL=10, CHR=8, LEM=5 }

local function calc_win(s1, s2, s3, bet)
    local k1, k2, k3 = s1.key, s2.key, s3.key
    if k1 == k2 and k2 == k3 then
        return bet * (THREE_MULT[k1] or 3)
    end
    local sevens = (k1=="7" and 1 or 0) + (k2=="7" and 1 or 0) + (k3=="7" and 1 or 0)
    if sevens >= 2 then return bet * 5 end
    if k1==k2 or k2==k3 or k1==k3 then return bet * 2 end
    if k1=="CHR" or k2=="CHR" or k3=="CHR" then return bet end
    return 0
end

local PAYOUT_LINES = {
    " 7  7  7  \xd7 50  JACKPOT",
    " BAR BAR BAR  \xd7 20",
    " BEL BEL BEL  \xd7 10",
    " CHR CHR CHR  \xd7 8",
    " LEM LEM LEM  \xd7 5",
    " Two 7s       \xd7 5",
    " Any pair     \xd7 2",
    " Any cherry   \xd7 1",
}

-- ── state ─────────────────────────────────────────────────────────────────────
local BET_OPTS = { 1, 5, 10, 25, 50, 100, 500 }
local bet      = 10
local reels    = { SYMS[4], SYMS[1], SYMS[3] }  -- idle display
local last_win = nil   -- nil = first load, number = last result
local spinning = false
local btns     = {}

-- ── drawing helpers ───────────────────────────────────────────────────────────
local function fill(x1, y1, x2, y2, bg)
    mon.setBackgroundColor(bg)
    local row = string.rep(" ", x2 - x1 + 1)
    for y = y1, y2 do mon.setCursorPos(x1, y); mon.write(row) end
end
local function mp(x, y, s, fg, bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(x, y); mon.write(s)
end
local function centre(y, s, fg, bg)
    if bg then mon.setBackgroundColor(bg) end
    if fg then mon.setTextColor(fg) end
    mon.setCursorPos(math.floor((W - #s) / 2) + 1, y); mon.write(s)
end
local function abtn(x1, y1, x2, y2, id, label, bg, fg)
    fill(x1, y1, x2, y2, bg)
    local lx = x1 + math.floor((x2 - x1 + 1 - #label) / 2)
    local ly = y1 + math.floor((y2 - y1) / 2)
    mp(lx, ly, label, fg, bg)
    btns[#btns+1] = { x1=x1, y1=y1, x2=x2, y2=y2, id=id }
end

-- Draw a single reel cell (7 wide x 3 tall).
local function draw_reel(cx, cy, sym, stopped)
    local bg = stopped and colors.white or colors.lightGray
    mon.setBackgroundColor(bg)
    mon.setTextColor(colors.black)
    mon.setCursorPos(cx, cy);   mon.write("+-----+")
    mon.setCursorPos(cx, cy+1); mon.write("|     |")
    mon.setCursorPos(cx, cy+2); mon.write("+-----+")
    mon.setBackgroundColor(bg)
    mon.setTextColor(sym.col)
    mon.setCursorPos(cx+2, cy+1); mon.write(sym.disp)
end

-- ── render ────────────────────────────────────────────────────────────────────
local function render(disp_reels, stopped_flags)
    mon.setBackgroundColor(colors.black); mon.clear()
    btns = {}
    disp_reels   = disp_reels   or reels
    stopped_flags = stopped_flags or { true, true, true }

    -- header
    fill(1, 1, W, 1, colors.yellow)
    centre(1, " *** LUCKY SLOTS *** ", colors.black, colors.yellow)

    -- balance / disk status
    fill(1, 2, W, 2, colors.black)
    if wd then
        mp(2, 2, "Balance: "..chips.." chips", colors.white, colors.black)
        mp(W-8, 2, "[disk ok]", colors.lime, colors.black)
    elseif drv and disk.isPresent(drv) then
        mp(2, 2, "Chips: "..chips, colors.white, colors.black)
        mp(W-9, 2, "[bad disk]", colors.red, colors.black)
    else
        mp(2, 2, "!! NO DISK -- chips not saved !!", colors.orange, colors.black)
    end

    -- reels (3 cells of 7 wide with 2-char gaps, centred)
    local reel_total = 3 * 7 + 2 * 2   -- 25
    local rx = math.floor((W - reel_total) / 2) + 1
    local ry = 4
    for i = 1, 3 do
        draw_reel(rx + (i-1) * 9, ry, disp_reels[i], stopped_flags[i])
    end

    -- win / no-win result line
    local res_y = ry + 3
    fill(1, res_y, W, res_y, colors.black)
    if last_win ~= nil then
        if last_win > 0 then
            centre(res_y, "  WIN!  +" .. last_win .. " chips  ", colors.black, colors.lime)
        else
            centre(res_y, "  No win  ", colors.gray, colors.black)
        end
    end

    -- bet selector
    local by = res_y + 2
    fill(1, by, W, by, colors.black)
    mp(2, by, "BET:", colors.lightGray, colors.black)
    local bx = 7
    for _, b in ipairs(BET_OPTS) do
        local lbl = tostring(b)
        local bw  = #lbl + 2
        local bg  = b == bet and colors.orange or colors.gray
        local fg  = b == bet and colors.black  or colors.white
        abtn(bx, by, bx + bw - 1, by, "bet_"..b, lbl, bg, fg)
        bx = bx + bw + 1
    end

    -- spin button
    local sy = by + 2
    if spinning then
        fill(1, sy, W, sy+1, colors.black)
        centre(sy, "  SPINNING...  ", colors.yellow, colors.black)
    elseif chips >= bet then
        abtn(math.floor(W/2)-9, sy, math.floor(W/2)+9, sy+1,
             "spin", "   SPIN  " .. bet .. " chips   ", colors.green, colors.black)
    else
        fill(1, sy, W, sy+1, colors.black)
        centre(sy, "Not enough chips (need "..bet..")", colors.red, colors.black)
    end

    -- payout reference (shows if there's room)
    local py = sy + 3
    if py + #PAYOUT_LINES <= H - 1 then
        mp(2, py, "Payouts:", colors.gray, colors.black)
        for i, line in ipairs(PAYOUT_LINES) do
            mp(2, py + i, line, colors.lightGray, colors.black)
        end
    end

    -- leave table
    abtn(1, H, math.floor(W/3), H, "leave", "LEAVE TABLE", colors.purple, colors.white)
end

-- ── spin animation ────────────────────────────────────────────────────────────
local function do_spin()
    if chips < bet or spinning then return end
    spinning = true

    chips = chips - bet

    local result   = { rsym(), rsym(), rsym() }
    local display  = { rsym(), rsym(), rsym() }
    local stopped  = { false, false, false }
    local stop_tick = { 16, 22, 28 }

    for tick = 1, 30 do
        for i = 1, 3 do
            if tick >= stop_tick[i] then
                stopped[i] = true
                display[i] = result[i]
            else
                display[i] = rsym()
            end
        end
        render(display, stopped)
        -- gradually slow down
        sleep(0.04 + tick * 0.005)
    end

    local win = calc_win(result[1], result[2], result[3], bet)
    chips    = chips + win
    last_win = win
    reels    = result

    flush_wallet()
    spinning = false
    render()
end

-- ── touch handler ─────────────────────────────────────────────────────────────
local function handle_touch(x, y)
    for _, b in ipairs(btns) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            if b.id == "spin" and not spinning then
                do_spin()
            elseif b.id == "leave" then
                flush_wallet()
                fill(1, 1, W, H, colors.purple)
                centre(math.floor(H/2),
                       "Saved " .. chips .. "c to disk.  Goodbye!",
                       colors.white, colors.purple)
                sleep(2)
                error("player left")
            elseif b.id:sub(1, 4) == "bet_" then
                bet = tonumber(b.id:sub(5)) or bet
                render()
            end
            return
        end
    end
end

-- ── main loop ─────────────────────────────────────────────────────────────────
render()
while true do
    local ev = { os.pullEvent() }
    if ev[1] == "monitor_touch" then
        handle_touch(ev[3], ev[4])
    elseif ev[1] == "disk" or ev[1] == "disk_eject" then
        refresh_wallet()
        last_win = nil
        render()
    end
end
