-- Tests for usbmtp_updater.lua against fake GitHub releases.
-- Uses KOReader's real ffi/archiver (on the system libarchive) and ffi/sha2, so
-- unpacking and checksums are exercised for real. Needs a koreader-base checkout:
--   KOREADER_BASE=/path/to/koreader-base luajit tests/updater_test.lua <repo>
local REPO = assert(arg[1], "usage: updater_test.lua <repo root>")
local KBASE = assert(os.getenv("KOREADER_BASE"), "set KOREADER_BASE")
local W = "/tmp/kmtp-test/updater"

package.path = KBASE .. "/?.lua;" .. REPO .. "/usbmtp.koplugin/?.lua;/usr/share/lua/5.1/?.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath
local ffi = require("ffi")
ffi.loadlib = function(name, ver) return ffi.load("lib" .. name .. ".so." .. ver) end
ffi.libc = ffi.libc or "gnu" -- set by KOReader's ffi setup on the device
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
package.preload["json"] = function() local dk = require("dkjson"); return { decode = function(s) return dk.decode(s) end } end
package.preload["util"] = function() return { makePath = function(d) os.execute("mkdir -p '" .. d .. "'") return true end } end
package.preload["ffi/util"] = function() return { purgeDir = function(d) os.execute("rm -rf '" .. d .. "'") return true end } end

local Updater = require("usbmtp_updater")

local function sh(cmd) assert(os.execute(cmd) == 0, cmd) end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function exists(p) return require("lfs").attributes(p) ~= nil end

local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1 else fail = fail + 1 end print((c and "PASS " or "FAIL ") .. m) end

-- Fake GitHub: URL -> local file
local served = {}
Updater.download = function(url, path)
    local src = served[url]
    if not src then return nil, "HTTP 404" end
    sh(string.format("cp '%s' '%s'", src, path))
    return true
end

local API = "https://api.github.com/repos/AnonyMap/usbmtp/releases/latest"
local function release(tag, assets, body)
    local list = {}
    for _, a in ipairs(assets) do
        list[#list + 1] = string.format('{"name":"%s","browser_download_url":"%s"}', a[1], a[2])
    end
    write(W .. "/srv/latest.json", string.format('{"tag_name":"%s","html_url":"https://example/r","body":%q,"assets":[%s]}',
        tag, body or "Release notes", table.concat(list, ",")))
    served[API] = W .. "/srv/latest.json"
end

-- Build a release zip from the repo's plugin, with a given VERSION and an optional tweak.
local function build_zip(version, name, tweak)
    sh("rm -rf " .. W .. "/build && mkdir -p " .. W .. "/build")
    sh(string.format("cp -r '%s/usbmtp.koplugin' %s/build/", REPO, W))
    sh("rm -f " .. W .. "/build/usbmtp.koplugin/mtp/*.log")
    write(W .. "/build/usbmtp.koplugin/mtp/VERSION", version .. "\n")
    write(W .. "/build/usbmtp.koplugin/NEW_IN_" .. version, "marker\n")
    if tweak then tweak(W .. "/build") end
    os.remove(W .. "/srv/" .. name) -- zip appends to an existing archive
    sh(string.format("cd %s/build && zip -q -r ../srv/%s . -x '*.log'", W, name))
    sh(string.format("cd %s/srv && sha256sum %s > SHA256SUMS", W, name))
    served["https://dl/" .. name] = W .. "/srv/" .. name
    served["https://dl/SHA256SUMS"] = W .. "/srv/SHA256SUMS"
end

local function fresh_install(version)
    sh("rm -rf " .. W .. "/plugins && mkdir -p " .. W .. "/plugins")
    sh(string.format("cp -r '%s/usbmtp.koplugin' %s/plugins/", REPO, W))
    write(W .. "/plugins/usbmtp.koplugin/mtp/VERSION", version .. "\n")
end
local ROOT = W .. "/plugins/usbmtp.koplugin"
local WORK = W .. "/work"
local function installed_version() return (read(ROOT .. "/mtp/VERSION") or ""):gsub("%s", "") end
local function no_leftovers() return not exists(ROOT .. ".new") and not exists(ROOT .. ".old") end

sh("rm -rf " .. W .. " && mkdir -p " .. W .. "/srv")

print("== version comparison")
check(Updater.compareVersions("0.10", "0.4") == 1 and Updater.compareVersions("v0.4", "0.4") == 0
      and Updater.compareVersions("0.4", "0.4.1") == -1, "0.10 > 0.4, v0.4 == 0.4, 0.4 < 0.4.1")

print("== update available, installs")
fresh_install("0.4")
build_zip("0.5", "usbmtp.koplugin-v0.5.zip")
release("v0.5", { { "usbmtp.koplugin-v0.5.zip", "https://dl/usbmtp.koplugin-v0.5.zip" }, { "SHA256SUMS", "https://dl/SHA256SUMS" } })
local info, err = Updater.check("0.4", WORK)
check(info and info.newer and info.version == "0.5" and info.notes == "Release notes", "finds v0.5 and its notes " .. tostring(err))
local ok, ierr = Updater.install(info, ROOT, WORK)
check(ok, "install succeeds " .. tostring(ierr))
check(installed_version() == "0.5" and exists(ROOT .. "/NEW_IN_0.5"), "new version is in place")
check(exists(ROOT .. "/mtp/bin/umtprd") and exists(ROOT .. "/usbmtp_updater.lua"), "binary and updater came along")
check(no_leftovers(), "no .new/.old folders left behind")
check(not exists(WORK .. "/usbmtp.koplugin-v0.5.zip"), "download cleaned up")

print("== already up to date")
info = Updater.check("0.5", WORK)
check(info and info.newer == false, "reports no update")

print("== corrupted download")
fresh_install("0.4")
write(W .. "/srv/SHA256SUMS", string.rep("0", 64) .. "  usbmtp.koplugin-v0.5.zip\n")
info = Updater.check("0.4", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(not ok and ierr:find("Checksum mismatch"), "refuses: " .. tostring(ierr))
check(installed_version() == "0.4" and no_leftovers(), "installed copy untouched")

print("== zip with files outside the plugin folder")
fresh_install("0.4")
build_zip("0.5", "usbmtp.koplugin-v0.5.zip", function(b) write(b .. "/evil.sh", "rm -rf /\n") end)
info = Updater.check("0.4", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(not ok and ierr:find("Unexpected path"), "refuses: " .. tostring(ierr))
check(installed_version() == "0.4" and no_leftovers(), "installed copy untouched")

print("== zip whose VERSION disagrees with the tag")
fresh_install("0.4")
build_zip("0.6", "usbmtp.koplugin-v0.5.zip")
info = Updater.check("0.4", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(not ok and ierr:find("says version 0.6"), "refuses: " .. tostring(ierr))
check(installed_version() == "0.4", "installed copy untouched")

print("== zip missing a required file")
fresh_install("0.4")
build_zip("0.5", "usbmtp.koplugin-v0.5.zip", function(b) os.remove(b .. "/usbmtp.koplugin/mtp/mtp-stop.sh") end)
info = Updater.check("0.4", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(not ok and ierr:find("missing mtp/mtp%-stop.sh"), "refuses: " .. tostring(ierr))

print("== release without assets / no release yet")
release("v0.5", {})
info, err = Updater.check("0.4", WORK)
check(not info and err:find("missing its plugin zip"), "explains: " .. tostring(err))
write(W .. "/srv/latest.json", '{"message":"Not Found"}')
info, err = Updater.check("0.4", WORK)
check(not info and err:find("no published release"), "explains: " .. tostring(err))
served[API] = nil
info, err = Updater.check("0.4", WORK)
check(not info and err:find("Could not reach GitHub"), "offline: " .. tostring(err))

print("== swap fails halfway: rolls back")
fresh_install("0.4")
build_zip("0.5", "usbmtp.koplugin-v0.5.zip")
release("v0.5", { { "usbmtp.koplugin-v0.5.zip", "https://dl/usbmtp.koplugin-v0.5.zip" }, { "SHA256SUMS", "https://dl/SHA256SUMS" } })
info = Updater.check("0.4", WORK)
local real_rename, calls = os.rename, 0
os.rename = function(a, b)
    calls = calls + 1
    if calls == 2 then return nil, "simulated failure" end -- staged -> installed fails
    return real_rename(a, b)
end
ok, ierr = Updater.install(info, ROOT, WORK)
os.rename = real_rename
check(not ok and ierr:find("kept the current one"), "reports: " .. tostring(ierr))
check(installed_version() == "0.4" and no_leftovers(), "original copy restored, nothing left over")

print("== release zip built by tools/make-release.sh installs cleanly")
fresh_install("0.3")
sh(string.format("cd '%s' && sh tools/make-release.sh >/dev/null", REPO))
local v = (read(REPO .. "/usbmtp.koplugin/mtp/VERSION") or ""):gsub("%s", "")
local zname = "usbmtp.koplugin-v" .. v .. ".zip"
served["https://dl/" .. zname] = REPO .. "/dist/" .. zname
served["https://dl/SHA256SUMS"] = REPO .. "/dist/SHA256SUMS"
release("v" .. v, { { zname, "https://dl/" .. zname }, { "SHA256SUMS", "https://dl/SHA256SUMS" } })
info = Updater.check("0.3", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(ok and installed_version() == v, "real release asset installs: " .. tostring(ierr))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
