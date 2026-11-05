-- Install a freshly built release (dist/) with the real updater, the way a Kindle
-- would, and fail if it's refused. Used by the Release workflow before publishing.
--   luajit tests/check_release_zip.lua <dist dir> <koreader-base checkout>
local DIST = assert(arg[1], "usage: check_release_zip.lua <dist> <koreader-base>")
local KBASE = assert(arg[2], "usage: check_release_zip.lua <dist> <koreader-base>")
local REPO = (arg[0]:match("^(.*)/tests/[^/]+$")) or "."
local W = os.tmpname() .. ".d"

package.path = KBASE .. "/?.lua;" .. REPO .. "/usbmtp.koplugin/?.lua;/usr/share/lua/5.1/?.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
local ffi = require("ffi")
ffi.loadlib = function(name, ver) return ffi.load("lib" .. name .. ".so." .. ver) end
ffi.libc = ffi.libc or "gnu"
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
package.preload["util"] = function() return { makePath = function(d) os.execute("mkdir -p '" .. d .. "'") return true end } end
package.preload["ffi/util"] = function() return { purgeDir = function(d) os.execute("rm -rf '" .. d .. "'") return true end } end

local Updater = require("usbmtp_updater")
Updater.sync = function() end

-- os.execute: 0 in Lua 5.1 mode, true/"exit"/0 in a LuaJIT built with 5.2 compat
local function ran(a, _, c) if type(a) == "number" then return a == 0 end; return a == true and (c == nil or c == 0) end
local function sh(cmd) assert(ran(os.execute(cmd)), cmd) end
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end

local version = read(REPO .. "/usbmtp.koplugin/mtp/VERSION"):gsub("%s", "")
local zip = "usbmtp.koplugin-v" .. version .. ".zip"
local served = { ["https://dl/" .. zip] = DIST .. "/" .. zip, ["https://dl/SHA256SUMS"] = DIST .. "/SHA256SUMS" }
Updater.download = function(url, path)
    assert(served[url], "unexpected URL " .. url)
    sh(string.format("cp '%s' '%s'", served[url], path))
    return true
end

-- An "installed" older copy to update over.
sh("rm -rf '" .. W .. "' && mkdir -p '" .. W .. "/plugins'")
sh(string.format("cp -r '%s/usbmtp.koplugin' '%s/plugins/'", REPO, W))
local f = assert(io.open(W .. "/plugins/usbmtp.koplugin/mtp/VERSION", "w")); f:write("0.0\n"); f:close()

local info = { tag = "v" .. version, version = version, zip_name = zip,
               zip_url = "https://dl/" .. zip, sums_url = "https://dl/SHA256SUMS", newer = true }
local ok, err = Updater.install(info, W .. "/plugins/usbmtp.koplugin", W .. "/work")
local installed = ok and read(W .. "/plugins/usbmtp.koplugin/mtp/VERSION"):gsub("%s", "")
sh("rm -rf '" .. W .. "'")
if not ok then
    io.stderr:write("The updater would REFUSE this release: " .. tostring(err) .. "\n")
    os.exit(1)
end
assert(installed == version, "installed version " .. tostring(installed) .. " ~= " .. version)
print("OK: the updater accepts " .. zip .. " (installs v" .. version .. ")")
