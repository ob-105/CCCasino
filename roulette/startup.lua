-- roulette/startup.lua
-- European roulette (single zero, 0-36).
-- Hardware: monitor (any side, 51+ chars wide recommended), disk drive (any side)
-- Run: startup  (no arguments)
--
-- Tap a chip size, then tap cells on the betting board to place bets.
-- SPIN deducts all placed bets and pays out winnings.
-- CLEAR removes all pending bets without spinning.

local wallet = dofile("/casino/lib/wallet.lua")

math.randomseed(os.epoch("utc"))

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the roulette computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local drv = wallet.find_drive()

-- ── wallet ────────────────────────────────────────────────────────────────────
local wd, wd_err = nil, nil
local chips = 0

local function refresh_wallet()
    wd, wd_err = nil, nil; chips = 0
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

-- ── roulette constants ────────────────────────────────────────────────────────
local RED_SET = {}
for _, n in ipairs({1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36}) do
    RED_SET[n] = true
end
local function num_color(n)
    if n == 0    then return colors.green end
    if RED_SET[n] then return colors.red   end
    return colors.gray
end
local function num_fg(n)
    return (n == 0 or RED_SET[n]) and colors.white or colors.white
end

-- Row of a number in the standard 3-row board layout:
--   row 1 (top)   = numbers where n%3 == 0  (3,6,9,...,36)
--   row 2 (mid)   = numbers where n%3 == 2  (2,5,8,...,35)
--   row 3 (bot)   = numbers where n%3 == 1  (1,4,7,...,34)
local function num_row(n)
    local r = n % 3
    if r == 0 then return 1 end
    if r == 2 then return 2 end
    return 3
end
local function num_col(n) return math.ceil(n / 3) end  -- 1..12

-- ── bet state ─────────────────────────────────────────────────────────────────
local sbets = {}  -- sbets[n] = chips on straight-up number n (0-36)
local obets = {
    red=0, black=0, odd=0, even=0,
    low=0, high=0,           -- 1-18, 19-36
    d1=0, d2=0, d3=0,        -- 1st / 2nd / 3rd dozen
    c1=0, c2=0, c3=0,        -- column 1 (bot) / 2 (mid) / 3 (top)
}

local CHIP_OPTS = { 1, 5, 10, 25, 50, 100 }
local chip_val  = 10

local last_result = nil   -- most recent spin result (0-36)
local last_payout = nil   -- most recent net payout (positive = win)

local function total_bets()
    local t = 0
    for _, v in pairs(sbets)  do t = t + v end
    for _, v in pairs(obets)  do t = t + v end
    return t
end

local function clear_bets()
    sbets = {}
    for k in pairs(obets) do obets[k] = 0 end
end

-- ── payout calculation ────────────────────────────────────────────────────────
local function calc_payout(result)
    local total_bet = total_bets()
    local win = 0

    -- straight-up bets: 35:1
    for n, amt in pairs(sbets) do
        if n == result then win = win + amt * 36 end  -- stake back + 35 profit
    end

    -- outside bets (1:1): only win if result not 0
    if result > 0 then
        local function even_money(amt, cond)
            if cond and amt > 0 then win = win + amt * 2 end
        end
        even_money(obets.red,   RED_SET[result] == true)
        even_money(obets.black, not RED_SET[result])
        even_money(obets.odd,   result % 2 == 1)
        even_money(obets.even,  result % 2 == 0)
        even_money(obets.low,   result >= 1  and result <= 18)
        even_money(obets.high,  result >= 19 and result <= 36)

        -- dozens (2:1)
        local function dozen(amt, lo, hi)
            if result >= lo and result <= hi and amt > 0 then win = win + amt * 3 end
        end
        dozen(obets.d1, 1, 12)
        dozen(obets.d2, 13, 24)
        dozen(obets.d3, 25, 36)

        -- columns (2:1)
        local col = result % 3
        if col == 1 and obets.c1 > 0 then win = win + obets.c1 * 3 end
        if col == 2 and obets.c2 > 0 then win = win + obets.c2 * 3 end
        if col == 0 and obets.c3 > 0 then win = win + obets.c3 * 3 end
    end

    return total_bet, win
end

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

-- Touch zones built during render
local zones = {}
local function add_zone(x1, y1, x2, y2, kind, key)
    zones[#zones+1] = { x1=x1, y1=y1, x2=x2, y2=y2, kind=kind, key=key }
end

-- Draw a single number cell (3 wide x 1 tall).
-- Shows bet indicator if chips are on this number.
local CELL_W = 3
local function draw_num_cell(x, y, n, highlight)
    local bg  = highlight and colors.yellow or num_color(n)
    local fg  = highlight and colors.black  or num_fg(n)
    local bet = sbets[n] or 0
    local lbl
    if bet > 0 then
        lbl = (bet >= 100 and tostring(bet):sub(1,3)) or
              (bet >= 10  and tostring(bet).." ")      or
              (" "..tostring(bet).." ")
    else
        lbl = (n < 10 and " "..n.." ") or (tostring(n).." ")
    end
    -- clamp to 3 chars
    lbl = lbl:sub(1, CELL_W)
    if #lbl < CELL_W then lbl = lbl .. string.rep(" ", CELL_W - #lbl) end
    mp(x, y, lbl, fg, bg)
    add_zone(x, y, x + CELL_W - 1, y, "straight", n)
end

-- Draw an outside-bet cell (variable width x 1 tall).
local function draw_obet(x, y, w, id, label, bg, fg)
    local amt = obets[id] or 0
    local disp = amt > 0 and (label:sub(1, w-2) .. " *") or label
    disp = disp:sub(1, w)
    if #disp < w then disp = disp .. string.rep(" ", w - #disp) end
    local abg = amt > 0 and colors.yellow or bg
    local afg = amt > 0 and colors.black  or fg
    mp(x, y, disp, afg, abg)
    add_zone(x, y, x + w - 1, y, "outside", id)
end

-- ── full render ───────────────────────────────────────────────────────────────
-- Board layout (rows relative to board_y):
--   board_y + 0 :  0 cell | row-3 numbers | C3 col-bet
--   board_y + 1 :  0 cell | row-2 numbers | C2 col-bet
--   board_y + 2 :  0 cell | row-1 numbers | C1 col-bet
--   board_y + 3 :  [  1st 12  ][  2nd 12  ][  3rd 12  ]
--   board_y + 4 :  [1-18][EVN][RED][BLK][ODD][19-36]
local BOARD_X = 2   -- left edge of the 0 cell
local ZERO_W  = 4   -- width of the "0" cell (spans 3 rows)
local NUM_X   = BOARD_X + ZERO_W  -- where number columns start

local function render(highlight_result)
    mon.setBackgroundColor(colors.black); mon.clear()
    zones = {}

    -- header
    fill(1, 1, W, 1, colors.green)
    centre(1, " ROULETTE ", colors.black, colors.green)

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

    -- chip selector
    fill(1, 3, W, 3, colors.black)
    mp(2, 3, "CHIP:", colors.lightGray, colors.black)
    local cx = 8
    for _, cv in ipairs(CHIP_OPTS) do
        local lbl = tostring(cv)
        local bw  = #lbl + 2
        local bg  = cv == chip_val and colors.orange or colors.gray
        local fg  = cv == chip_val and colors.black  or colors.white
        fill(cx, 3, cx+bw-1, 3, bg)
        mp(cx + math.floor((bw - #lbl)/2), 3, lbl, fg, bg)
        add_zone(cx, 3, cx+bw-1, 3, "chip", cv)
        cx = cx + bw + 1
    end

    -- ── betting board ──────────────────────────────────────────────────────────
    local board_y = 5

    -- 0 cell (spans 3 rows)
    local zero_bg = (highlight_result == 0) and colors.lime or colors.green
    fill(BOARD_X, board_y, BOARD_X + ZERO_W - 1, board_y + 2, zero_bg)
    local zbet = sbets[0] or 0
    local zlbl = zbet > 0 and tostring(zbet) or "0"
    mp(BOARD_X + math.floor((ZERO_W - #zlbl)/2), board_y + 1,
       zlbl, colors.white, zero_bg)
    add_zone(BOARD_X, board_y, BOARD_X + ZERO_W - 1, board_y + 2, "straight", 0)

    -- number grid (rows 1-3, cols 1-12)
    for n = 1, 36 do
        local col = num_col(n)
        local row = num_row(n)
        local nx  = NUM_X + (col - 1) * CELL_W
        local ny  = board_y + (row - 1)
        local hl  = (highlight_result == n)
        draw_num_cell(nx, ny, n, hl)
    end

    -- column bet cells (right of rows)
    local col_x = NUM_X + 12 * CELL_W + 1
    local col_labels = { c3=" C3", c2=" C2", c1=" C1" }
    for i, key in ipairs({"c3", "c2", "c1"}) do
        local bx = col_x; local by = board_y + (i-1)
        local amt = obets[key] or 0
        local bg  = amt > 0 and colors.yellow or colors.gray
        local fg  = amt > 0 and colors.black  or colors.white
        mp(bx, by, col_labels[key], fg, bg)
        add_zone(bx, by, bx + 2, by, "outside", key)
    end

    -- dozens (1 row below numbers)
    local doz_y = board_y + 3
    local doz_w = math.floor(12 * CELL_W / 3)  -- 12 cells per dozen
    local doz_start = NUM_X
    local dozens = { {key="d1",lbl=" 1st 12 "}, {key="d2",lbl=" 2nd 12 "}, {key="d3",lbl=" 3rd 12 "} }
    for i, d in ipairs(dozens) do
        draw_obet(doz_start + (i-1)*doz_w, doz_y, doz_w, d.key, d.lbl, colors.gray, colors.white)
    end

    -- even-money outside bets (row below dozens)
    local out_y = board_y + 4
    local out_w = math.floor(12 * CELL_W / 6)  -- 6 cells share the same width
    local outs = {
        {key="low",   lbl="1-18 "}, {key="even",lbl="EVEN "},
        {key="red",   lbl="RED  "}, {key="black",lbl="BLK  "},
        {key="odd",   lbl="ODD  "}, {key="high", lbl="19-36"},
    }
    for i, o in ipairs(outs) do
        local bx  = NUM_X + (i-1)*out_w
        local rbg = (o.key=="red")   and colors.red  or
                    (o.key=="black") and colors.gray  or colors.gray
        draw_obet(bx, out_y, out_w, o.key, o.lbl, rbg, colors.white)
    end

    -- ── action buttons ─────────────────────────────────────────────────────────
    local act_y = board_y + 6
    local total = total_bets()
    local hw    = math.floor((W - 3) / 2)

    if total > 0 and chips >= total then
        fill(2, act_y, 1+hw, act_y+1, colors.green)
        mp(2 + math.floor((hw - 8)/2), act_y, "SPIN", colors.black, colors.green)
        mp(2 + math.floor((hw - 8)/2), act_y+1, "bet:"..total, colors.black, colors.green)
        add_zone(2, act_y, 1+hw, act_y+1, "action", "spin")
    elseif total > chips then
        fill(2, act_y, 1+hw, act_y+1, colors.red)
        centre(act_y, "Not enough chips", colors.white, colors.red)
        add_zone(2, act_y, 1+hw, act_y+1, "action", "spin")
    else
        fill(2, act_y, 1+hw, act_y+1, colors.gray)
        centre(act_y, "Place bets to spin", colors.lightGray, colors.gray)
    end

    fill(3+hw, act_y, W-1, act_y+1, colors.orange)
    mp(3+hw + math.floor((W-2-hw - 5)/2), act_y, "CLEAR", colors.black, colors.orange)
    mp(3+hw + math.floor((W-2-hw - 8)/2), act_y+1, "all bets", colors.black, colors.orange)
    add_zone(3+hw, act_y, W-1, act_y+1, "action", "clear")

    -- ── result area ────────────────────────────────────────────────────────────
    local res_y = act_y + 3
    if last_result ~= nil then
        fill(1, res_y, W, res_y+1, colors.black)
        local res_bg = num_color(last_result)
        local res_str = "  Result: " .. last_result .. "  "
        if RED_SET[last_result] then
            res_str = res_str .. "(Red)"
        elseif last_result == 0 then
            res_str = res_str .. "(Green)"
        else
            res_str = res_str .. "(Black)"
        end
        centre(res_y, res_str, colors.white, res_bg)

        if last_payout ~= nil then
            if last_payout > 0 then
                centre(res_y+1, "  WIN! +" .. last_payout .. " chips  ", colors.black, colors.lime)
            else
                centre(res_y+1, "  No win this spin  ", colors.gray, colors.black)
            end
        end
    end

    -- leave table
    fill(1, H, math.floor(W/3), H, colors.purple)
    mp(2, H, "LEAVE TABLE", colors.white, colors.purple)
    add_zone(1, H, math.floor(W/3), H, "action", "leave")
end

-- ── spin animation ────────────────────────────────────────────────────────────
local function do_spin()
    local total = total_bets()
    if total == 0 or chips < total then return end

    chips = chips - total

    -- animate: show spinning counter
    local candidates = {}
    for i = 0, 36 do candidates[#candidates+1] = i end
    local result = math.random(0, 36)

    for pass = 1, 20 do
        local fake = candidates[math.random(#candidates)]
        render(fake)
        sleep(0.04 + pass * 0.006)
    end

    -- final result
    local _, win = calc_payout(result)
    chips       = chips + win
    last_result = result
    last_payout = win - total   -- net gain/loss

    clear_bets()
    flush_wallet()
    render(result)
end

-- ── touch handler ─────────────────────────────────────────────────────────────
local function handle_touch(x, y)
    for _, z in ipairs(zones) do
        if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then
            if z.kind == "chip" then
                chip_val = z.key
                render()
            elseif z.kind == "straight" then
                sbets[z.key] = (sbets[z.key] or 0) + chip_val
                render()
            elseif z.kind == "outside" then
                obets[z.key] = (obets[z.key] or 0) + chip_val
                render()
            elseif z.kind == "action" then
                if z.key == "spin" then
                    do_spin()
                elseif z.key == "clear" then
                    clear_bets(); render()
                elseif z.key == "leave" then
                    flush_wallet()
                    fill(1, 1, W, H, colors.purple)
                    centre(math.floor(H/2),
                           "Saved " .. chips .. "c to disk.  Goodbye!",
                           colors.white, colors.purple)
                    sleep(2)
                    error("player left")
                end
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
        clear_bets()
        last_result = nil; last_payout = nil
        render()
    end
end
