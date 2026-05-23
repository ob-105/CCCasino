-- lib/wallet.lua
-- Casino floppy-disk wallet: cryptographic sign, verify, issue, update, wipe.
--
-- HOW IT WORKS:
--   Every wallet.dat on disk stores { player_id, player_name, balance, nonce,
--   issued, signature }.  The signature is a keyed hash of the balance and
--   player_id.  Without the SECRET below, an offline player cannot forge a
--   valid signature, so editing the file at home breaks verification.
--
-- SETUP:
--   1. Copy this file to /casino/lib/wallet.lua on every casino computer.
--   2. Change SECRET to a long random string — keep it the same on all
--      casino machines and never put it on a player disk.

local SECRET = "CHANGE_ME_to_a_long_unique_secret_key_abc123xyz789"

-- ── internal hash ────────────────────────────────────────────────────────────
-- Two interleaved polynomial hashes (djb2 + sdbm) combined into a 16-char
-- hex string.  Keyed with SECRET so the output is opaque without it.
local function hash(s)
    local a, b = 5381, 0
    for i = 1, #s do
        local c = string.byte(s, i)
        a = ((a * 33) + c) % 4294967296
        b = (c + (b * 65599)) % 4294967296
    end
    return string.format("%08x%08x", a, b)
end

local function sign(id, bal, nonce)
    return hash(SECRET .. id .. tostring(math.floor(bal)) .. tostring(nonce))
end

-- ── public API ───────────────────────────────────────────────────────────────
local M = {}

-- Returns the peripheral name of the first disk drive found, or nil.
function M.find_drive()
    local d = peripheral.find("drive")
    return d and peripheral.getName(d) or nil
end

-- load(drv?) → wallet_table | nil, err_string
-- Reads wallet.dat from the disk in `drv` and verifies its signature.
-- Returns the wallet table on success; nil + error string on failure.
function M.load(drv)
    drv = drv or M.find_drive()
    if not drv                        then return nil, "no drive attached"      end
    if not disk.isPresent(drv)        then return nil, "no disk"                end
    local path = disk.getMountPath(drv)
    if not path                       then return nil, "disk not mounted"        end
    local f = fs.open(path .. "/wallet.dat", "r")
    if not f                          then return nil, "not a casino disk"       end
    local raw = f.readAll(); f.close()
    local w = textutils.unserialize(raw)
    if type(w) ~= "table"
       or not w.player_id or w.balance == nil
       or not w.nonce     or not w.signature then
        return nil, "corrupt wallet"
    end
    if w.signature ~= sign(w.player_id, w.balance, w.nonce) then
        return nil, "tampered or foreign disk"
    end
    return w
end

-- save(w, drv?) → true | false, err_string
-- Increments the nonce, re-signs, and writes wallet back to disk.
function M.save(w, drv)
    drv = drv or M.find_drive()
    if not drv                 then return false, "no drive"       end
    if not disk.isPresent(drv) then return false, "no disk"        end
    local path = disk.getMountPath(drv)
    if not path                then return false, "not mounted"    end
    w.nonce     = (w.nonce or 0) + 1
    w.balance   = math.floor(w.balance)
    w.signature = sign(w.player_id, w.balance, w.nonce)
    local f = fs.open(path .. "/wallet.dat", "w")
    if not f                   then return false, "write failed"   end
    f.write(textutils.serialize(w)); f.close()
    return true
end

-- issue(drv, name, balance) → wallet_table | nil, err_string
-- Writes a brand-new signed wallet onto a disk.  Overwrites any existing
-- wallet.dat.  Sets the disk label to "<name>'s Chips".
function M.issue(drv, name, balance)
    drv = drv or M.find_drive()
    if not drv                 then return nil, "no drive"      end
    if not disk.isPresent(drv) then return nil, "no disk"       end
    local path = disk.getMountPath(drv)
    if not path                then return nil, "not mounted"   end
    math.randomseed(os.epoch("utc"))
    local uid = tostring(os.epoch("utc")) .. "_" .. tostring(math.random(100000, 999999))
    local w = {
        player_id   = uid,
        player_name = name,
        balance     = math.floor(balance),
        issued      = os.epoch("utc"),
        nonce       = 1,
    }
    w.signature = sign(w.player_id, w.balance, w.nonce)
    local f = fs.open(path .. "/wallet.dat", "w")
    if not f then return nil, "write failed" end
    f.write(textutils.serialize(w)); f.close()
    pcall(disk.setLabel, drv, name .. "'s Chips")
    return w
end

-- wipe(drv?) → true | false
-- Removes wallet.dat and clears the disk label (used at cash-out).
function M.wipe(drv)
    drv = drv or M.find_drive()
    if not drv or not disk.isPresent(drv) then return false end
    local path = disk.getMountPath(drv)
    if not path then return false end
    pcall(fs.delete, path .. "/wallet.dat")
    pcall(disk.setLabel, drv, "")
    return true
end

return M
