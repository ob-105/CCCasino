-- install.lua
-- CCCasino installer: downloads all game files from GitHub onto this computer.
--
-- How to get this file onto a CC:Tweaked computer:
--   wget https://raw.githubusercontent.com/ob-105/CCCasino/main/install.lua install
--   install
--
-- Requires HTTP to be enabled in your ComputerCraft config.

local BASE = "https://raw.githubusercontent.com/ob-105/CCCasino/main"

-- ── helpers ───────────────────────────────────────────────────────────────────
local function dl(src, dst)
    io.write("  " .. dst .. " ... ")
    local resp, err = http.get(BASE .. src)
    if not resp then
        print("FAIL (" .. (err or "?") .. ")")
        return false
    end
    local data = resp.readAll(); resp.close()
    local dir = fs.getDir(dst)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(dst, "w"); f.write(data); f.close()
    print("ok")
    return true
end

local function write_startup(content)
    local f = fs.open("/startup.lua", "w")
    f.write(content .. "\n")
    f.close()
    print("  /startup.lua written")
end

-- ── computer types ────────────────────────────────────────────────────────────
-- Each entry: name, files to download, startup line (or ask=true for extra input)
local TYPES = {
    {
        name  = "Cashier Terminal",
        files = { {"/cashier/startup.lua", "/casino/cashier/startup.lua"} },
        boot  = 'shell.run("/casino/cashier/startup.lua")',
    },
    {
        name  = "Poker Dealer",
        files = { {"/poker/dealer.lua", "/casino/poker/dealer.lua"} },
        boot  = 'shell.run("/casino/poker/dealer.lua")',
    },
    {
        name  = "Poker Player",
        files = { {"/poker/player.lua", "/casino/poker/player.lua"} },
        ask   = "player number (1-4)",
        boot  = nil,   -- filled in after asking
    },
    {
        name  = "Slots Machine",
        files = { {"/slots/startup.lua", "/casino/slots/startup.lua"} },
        boot  = 'shell.run("/casino/slots/startup.lua")',
    },
    {
        name  = "Roulette Table",
        files = { {"/roulette/table.lua", "/casino/roulette/table.lua"} },
        boot  = 'shell.run("/casino/roulette/table.lua")',
    },
}

-- ── UI ────────────────────────────────────────────────────────────────────────
local function hr() print(("="):rep(40)) end

term.clear(); term.setCursorPos(1,1)
hr()
print("     CCCasino Installer")
hr()
print("")
print("Select this computer's role:")
print("")
for i, t in ipairs(TYPES) do
    print(("  %d. %s"):format(i, t.name))
end
print("")
io.write("Choice [1-" .. #TYPES .. "]: ")
local choice = tonumber(io.read())
if not choice or not TYPES[choice] then
    print("Invalid choice. Exiting.")
    return
end

local ct = TYPES[choice]

-- extra input for types that need it
if ct.ask then
    io.write("Enter " .. ct.ask .. ": ")
    local extra = io.read():match("^%s*(.-)%s*$")  -- trim
    if not extra or extra == "" then
        print("No input given. Exiting.")
        return
    end
    if ct.name == "Poker Player" then
        local n = tonumber(extra)
        if not n or n < 1 or n > 4 then
            print("Player number must be 1-4. Exiting.")
            return
        end
        ct.boot = ('shell.run("/casino/poker/player.lua", "%d")'):format(n)
    end
end

-- ── download ──────────────────────────────────────────────────────────────────
print("")
print("Installing: " .. ct.name)
hr()

local ok = true

-- common libraries (needed on every casino computer)
print("Common files:")
ok = dl("/lib/autoupdate.lua", "/casino/lib/autoupdate.lua") and ok
ok = dl("/lib/wallet.lua",     "/casino/lib/wallet.lua")     and ok

-- computer-specific files
print("Game files:")
for _, pair in ipairs(ct.files) do
    ok = dl(pair[1], pair[2]) and ok
end

if not ok then
    print("")
    print("One or more downloads failed.")
    print("Check that HTTP is enabled in your CC config")
    print("(set http.enabled=true in computercraft.cfg)")
    return
end

-- startup script
print("Startup:")
write_startup(ct.boot)

-- ── done ──────────────────────────────────────────────────────────────────────
hr()
print("Installation complete!")
print("")
print("IMPORTANT:")
print("  Open /casino/lib/wallet.lua and change")
print("  SECRET to a unique string.  Use the SAME")
print("  secret on every casino computer, or disks")
print("  from one machine will be rejected by another.")
print("")
print("Type 'reboot' to start.")
hr()
