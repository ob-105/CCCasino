-- cashier/startup.lua
-- Casino cashier terminal: issue and redeem floppy-disk chip wallets.
--
-- Hardware:
--   Monitor  — any side (touch-screen preferred)
--   Disk drive — any side
--
-- Usage:
--   Operator receives items from the player by hand, then uses this
--   terminal to issue or top-up a wallet, or to wipe a disk at cash-out.
--   Player names are typed on the computer keyboard; everything else is
--   driven by tapping the monitor.

pcall(function()
    local au = dofile("/casino/lib/autoupdate.lua")
    au.check({
        {"/lib/autoupdate.lua",    "/casino/lib/autoupdate.lua"},
        {"/lib/wallet.lua",        "/casino/lib/wallet.lua"},
        {"/cashier/startup.lua",   "/casino/cashier/startup.lua"},
    })
end)

local wallet = dofile("/casino/lib/wallet.lua")

local mon = peripheral.find("monitor")
assert(mon, "Attach a monitor to the cashier computer")
mon.setTextScale(0.5)
local W, H = mon.getSize()

local drv = wallet.find_drive()
assert(drv, "Attach a disk drive to the cashier computer")

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
    mon.setCursorPos(math.floor((W - #s) / 2) + 1, y)
    mon.write(s)
end

-- ── state ─────────────────────────────────────────────────────────────────────
-- mode:
--   "home"             — show disk status + action buttons
--   "new_name"         — typing player name for a new wallet
--   "new_amount"       — typing chip amount for a new wallet
--   "add_amount"       — typing chip amount to top-up existing wallet
--   "cashout_confirm"  — confirm wipe before handing back resources
local mode   = "home"
local input  = ""          -- current keyboard input buffer
local p_name = ""          -- confirmed player name for the current flow
local msg    = ""          -- status-bar message
local msg_col = colors.white

local btns = {}            -- populated by render(), read by handle_touch()

local function btn(x1, y1, x2, y2, id, label, bg, fg)
    fill(x1, y1, x2, y2, bg)
    local lx = x1 + math.floor((x2 - x1 + 1 - #label) / 2)
    local ly = y1 + math.floor((y2 - y1) / 2)
    mp(lx, ly, label, fg, bg)
    btns[#btns + 1] = { x1=x1, y1=y1, x2=x2, y2=y2, id=id }
end

local function set_msg(s, col)
    msg = s; msg_col = col or colors.white
end

-- ── render ────────────────────────────────────────────────────────────────────
local function render()
    mon.setBackgroundColor(colors.black); mon.clear()
    btns = {}

    -- header
    fill(1, 1, W, 1, colors.orange)
    centre(1, " CASINO CASHIER ", colors.black, colors.orange)

    local y = 3

    -- disk status block
    local w_data, w_err = wallet.load(drv)
    local disk_in = disk.isPresent(drv)

    if not disk_in then
        centre(y,   "[ No Disk ]",          colors.gray,      colors.black); y = y + 1
        centre(y,   "Insert a floppy disk", colors.lightGray, colors.black); y = y + 3
    elseif w_data then
        centre(y,   w_data.player_name .. "'s Wallet",   colors.lime,   colors.black); y = y + 1
        centre(y,   "Balance: " .. w_data.balance .. " chips", colors.yellow, colors.black); y = y + 3
    else
        centre(y,   "Disk present — no wallet",  colors.orange,    colors.black); y = y + 1
        centre(y,   w_err or "blank or foreign",  colors.lightGray, colors.black); y = y + 3
    end

    -- mode-specific UI
    if mode == "home" then
        if disk_in and w_data then
            local hw = math.floor((W - 3) / 2)
            btn(2, y, 1+hw,  y+1, "add",     "ADD CHIPS",  colors.blue,  colors.white)
            btn(3+hw, y, W-1, y+1, "cashout", "CASH OUT",   colors.red,   colors.white)
        elseif disk_in and not w_data then
            btn(2, y, W-1, y+1, "issue_new", "ISSUE NEW WALLET", colors.green, colors.black)
        end

    elseif mode == "new_name" then
        centre(y, "Player name (type on keyboard):", colors.white, colors.black); y = y + 1
        fill(2, y, W-1, y, colors.gray)
        mp(3, y, input .. "|", colors.white, colors.gray); y = y + 2
        centre(y, "Press ENTER when done", colors.lightGray, colors.black); y = y + 2
        btn(2, y, W-1, y, "cancel", "CANCEL", colors.red, colors.white)

    elseif mode == "new_amount" or mode == "add_amount" then
        local lbl = mode == "new_amount"
            and ("Issue chips to " .. p_name .. ":")
            or  ("Add chips to "   .. p_name .. ":")
        centre(y, lbl, colors.white, colors.black); y = y + 1
        fill(2, y, W-1, y, colors.gray)
        mp(3, y, input .. "|", colors.yellow, colors.gray); y = y + 2

        -- quick-amount touch buttons
        local amts = {100, 500, 1000, 5000}
        local bw   = math.floor(W / #amts)
        for i, a in ipairs(amts) do
            local x1 = 1 + (i - 1) * bw
            local x2 = i == #amts and W or i * bw
            btn(x1, y, x2, y, "q" .. a, "+" .. a, colors.gray, colors.white)
        end
        y = y + 2

        local hw = math.floor((W - 3) / 2)
        btn(2,    y, 1+hw, y+1, "confirm_amount", "CONFIRM",  colors.green,  colors.black)
        btn(3+hw, y, W-1,  y+1, "cancel",          "CANCEL",   colors.red,    colors.white)

    elseif mode == "cashout_confirm" then
        if w_data then
            centre(y, "CASH OUT — give the player:", colors.white,     colors.black); y = y + 1
            centre(y, w_data.balance .. " chips worth of resources",
                      colors.yellow, colors.black); y = y + 2
            centre(y, "Hand over resources FIRST, then confirm.", colors.lightGray, colors.black); y = y + 2
            local hw = math.floor((W - 3) / 2)
            btn(2,    y, 1+hw, y+1, "confirm_wipe", "CONFIRM WIPE", colors.red,    colors.white)
            btn(3+hw, y, W-1,  y+1, "cancel",        "CANCEL",       colors.orange, colors.black)
        else
            -- disk was removed while confirming
            mode = "home"
        end
    end

    -- status bar
    if msg ~= "" then
        fill(1, H, W, H, colors.black)
        centre(H, msg, msg_col, colors.black)
    end
end

-- ── commit helpers ────────────────────────────────────────────────────────────
local function do_issue(name, amount)
    local w2, err = wallet.issue(drv, name, amount)
    if w2 then
        set_msg("Issued " .. amount .. " chips to " .. name, colors.lime)
        mode = "home"; input = ""; p_name = ""
    else
        set_msg("Error: " .. (err or "?"), colors.red)
    end
end

local function do_add(amount)
    local wd = wallet.load(drv)
    if not wd then set_msg("Disk read failed", colors.red); return end
    wd.balance = wd.balance + amount
    local ok, err = wallet.save(wd, drv)
    if ok then
        set_msg("Added " .. amount .. " chips.  New balance: " .. wd.balance, colors.lime)
        mode = "home"; input = ""
    else
        set_msg("Save error: " .. (err or "?"), colors.red)
    end
end

local function do_confirm_amount()
    local n = tonumber(input)
    if not n or n <= 0 then
        set_msg("Enter a positive number", colors.red); return
    end
    if mode == "new_amount" then
        do_issue(p_name, n)
    elseif mode == "add_amount" then
        do_add(n)
    end
end

-- ── keyboard input ────────────────────────────────────────────────────────────
local function handle_key(k)
    if k == keys.backspace then
        input = input:sub(1, -2)
    elseif k == keys.enter then
        if mode == "new_name" then
            if #input > 0 then
                p_name = input; input = ""
                mode   = "new_amount"
                set_msg("Enter chip amount, then CONFIRM", colors.white)
            else
                set_msg("Name cannot be empty", colors.red)
            end
        elseif mode == "new_amount" or mode == "add_amount" then
            do_confirm_amount()
        end
    end
end

-- ── touch input ───────────────────────────────────────────────────────────────
local function handle_touch(x, y)
    for _, b in ipairs(btns) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
            local id = b.id

            if id == "issue_new" then
                mode = "new_name"; input = ""; p_name = ""
                set_msg("Type player name on keyboard, then ENTER", colors.white)

            elseif id == "add" then
                local wd = wallet.load(drv)
                if wd then
                    p_name = wd.player_name
                    mode   = "add_amount"; input = ""
                    set_msg("Enter chips to add, then CONFIRM", colors.white)
                else
                    set_msg("Cannot read disk", colors.red)
                end

            elseif id == "cashout" then
                mode = "cashout_confirm"
                set_msg("", colors.white)

            elseif id == "confirm_amount" then
                do_confirm_amount()

            elseif id == "confirm_wipe" then
                local wd  = wallet.load(drv)
                local bal = wd and wd.balance or 0
                if wallet.wipe(drv) then
                    set_msg("Disk wiped.  Give " .. bal .. " chips' worth of resources.", colors.lime)
                    mode = "home"
                else
                    set_msg("Wipe failed — is disk still inserted?", colors.red)
                end

            elseif id == "cancel" then
                mode = "home"; input = ""; p_name = ""
                set_msg("", colors.white)

            elseif id:sub(1, 1) == "q" then
                -- quick-amount button: set input to that amount
                local n = tonumber(id:sub(2))
                if n then
                    input = tostring(n)
                    set_msg("Press CONFIRM or ENTER to apply", colors.white)
                end
            end

            render(); return
        end
    end
end

-- ── main loop ─────────────────────────────────────────────────────────────────
render()
while true do
    local ev = { os.pullEvent() }
    local e  = ev[1]

    if e == "char" then
        if mode == "new_name" or mode == "new_amount" or mode == "add_amount" then
            input = input .. ev[2]; render()
        end
    elseif e == "key" then
        handle_key(ev[2]); render()
    elseif e == "monitor_touch" then
        handle_touch(ev[3], ev[4])
    elseif e == "disk" or e == "disk_eject" then
        -- disk inserted or removed: reset to home and refresh
        msg = ""; mode = "home"; input = ""; p_name = ""
        render()
    end
end
