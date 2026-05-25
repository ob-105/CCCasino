-- lib/autoupdate.lua
-- Boot-time self-updater. Call M.check(files) near the top of any game script.
-- files = list of {"/repo/path.lua", "/casino/local/path.lua"} pairs to update.
-- Silently no-ops on any network failure so the game still starts offline.

local BASE      = "https://raw.githubusercontent.com/ob-105/CCCasino/main"
local LOCAL_VER = "/casino/version.txt"

local function fetch(url)
    local ok, r = pcall(http.get, url)
    if not ok or not r then return nil end
    local s = r.readAll(); r.close()
    return s
end

local M = {}

function M.check(files)
    local remote_str = fetch(BASE .. "/version.txt")
    if not remote_str then return end
    local remote = tonumber(remote_str:match("%d+"))
    if not remote then return end

    local local_ver = 0
    if fs.exists(LOCAL_VER) then
        local f = fs.open(LOCAL_VER, "r")
        local_ver = tonumber(f.readAll():match("%d+")) or 0
        f.close()
    end
    if remote <= local_ver then return end

    print("Update v" .. remote .. " found — updating...")
    local ok_all = true
    for _, pair in ipairs(files) do
        local data = fetch(BASE .. pair[1])
        if data then
            local dir = fs.getDir(pair[2])
            if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
            local f = fs.open(pair[2], "w"); f.write(data); f.close()
        else
            ok_all = false
        end
    end
    if ok_all then
        local f = fs.open(LOCAL_VER, "w"); f.write(tostring(remote)); f.close()
        print("Done. Rebooting...")
        sleep(1.5)
        os.reboot()
    else
        print("Some files failed to download; skipping update.")
    end
end

return M
