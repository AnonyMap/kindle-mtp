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
-- served[url] = local file path, or { code = 404 } for an HTTP error. Unknown URL = no network.
local served = {}
Updater.download = function(url, path)
    local src = served[url]
    if src == nil then return nil, "timeout" end
    if type(src) == "table" then return nil, "HTTP " .. src.code, src.code end
    sh(string.format("cp '%s' '%s'", src, path))
    return true
end
Updater.sync = function() end

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
check(not exists(ROOT .. ".new") and exists(ROOT .. ".old/mtp/VERSION"), "previous version kept as .old until the new one loads")
Updater.cleanupAfterUpdate(ROOT)
check(no_leftovers(), "cleanupAfterUpdate removes the backup")
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
served[API] = { code = 404 } -- what GitHub really answers when there are no releases
info, err = Updater.check("0.4", WORK)
check(not info and err:find("No release has been published"), "no release: " .. tostring(err))
served[API] = { code = 403 }
info, err = Updater.check("0.4", WORK)
check(not info and err:find("rate limit"), "rate limited: " .. tostring(err))
served[API] = nil
info, err = Updater.check("0.4", WORK)
check(not info and err:find("Could not reach GitHub") and err:find("Wi%-Fi"), "offline: " .. tostring(err))
write(W .. "/srv/latest.json", '{"message":"weird"}'); served[API] = W .. "/srv/latest.json"
info, err = Updater.check("0.4", WORK)
check(not info and err:find("doesn't understand"), "unexpected reply: " .. tostring(err))
release("v1.0-rc1", {})
info, err = Updater.check("0.4", WORK)
check(not info and err:find("plain version number"), "non-numeric tag: " .. tostring(err))

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
check(not ok and ierr:find("Kept the current version"), "reports: " .. tostring(ierr))
check(installed_version() == "0.4" and not exists(ROOT .. ".new"), "original copy restored")

print("== swap fails halfway AND the undo fails: says where the old copy is")
fresh_install("0.4")
info = Updater.check("0.4", WORK)
calls = 0
os.rename = function(a, b)
    calls = calls + 1
    if calls >= 2 then return nil, "simulated failure" end
    return real_rename(a, b)
end
ok, ierr = Updater.install(info, ROOT, WORK)
os.rename = real_rename
check(not ok and ierr:find("previous version is now at") and ierr:find("usbmtp.koplugin.old", 1, true), "tells the user the folder to rename back")
check(exists(ROOT .. ".old/mtp/VERSION"), "previous version still intact at .old")

local GOOD = { { "usbmtp.koplugin-v0.5.zip", "https://dl/usbmtp.koplugin-v0.5.zip" }, { "SHA256SUMS", "https://dl/SHA256SUMS" } }
local function try_broken(label, tweak, expect_pat)
    fresh_install("0.4")
    build_zip("0.5", "usbmtp.koplugin-v0.5.zip", tweak)
    release("v0.5", GOOD)
    local i = Updater.check("0.4", WORK)
    local okk, e = Updater.install(i, ROOT, WORK)
    check(not okk and tostring(e):find(expect_pat), label .. ": " .. tostring(e))
    check(installed_version() == "0.4" and not exists(ROOT .. ".new"), label .. ": installed copy untouched")
end

print("== broken releases are refused")
try_broken("missing the updater itself", function(b) os.remove(b .. "/usbmtp.koplugin/usbmtp_updater.lua") end, "missing usbmtp_updater.lua")
try_broken("missing the MTP program", function(b) os.remove(b .. "/usbmtp.koplugin/mtp/bin/umtprd") end, "missing mtp/bin/umtprd")
try_broken("missing common.sh", function(b) os.remove(b .. "/usbmtp.koplugin/mtp/lib/common.sh") end, "missing mtp/lib/common.sh")
try_broken("main.lua doesn't compile", function(b) write(b .. "/usbmtp.koplugin/main.lua", "local x = = 1\n") end, "broken file")
try_broken("empty MTP program", function(b) write(b .. "/usbmtp.koplugin/mtp/bin/umtprd", "") end, "missing or empty")

print("== hostile paths, crafted with python's zipfile")
local function craft(entries)
    fresh_install("0.4")
    build_zip("0.5", "usbmtp.koplugin-v0.5.zip")
    local py = string.format([[import zipfile
z = zipfile.ZipFile('%s/srv/usbmtp.koplugin-v0.5.zip', 'a')
for n in %s: z.writestr(n, 'x')
z.close()]], W, entries)
    write(W .. "/craft.py", py)
    sh("python3 -I " .. W .. "/craft.py")
    sh(string.format("cd %s/srv && sha256sum usbmtp.koplugin-v0.5.zip > SHA256SUMS", W))
    release("v0.5", GOOD)
    local i = Updater.check("0.4", WORK)
    return Updater.install(i, ROOT, WORK)
end
ok, ierr = craft("['usbmtp.koplugin/../../escape.txt']")
check(not ok and ierr:find("Unexpected path"), "../ refused: " .. tostring(ierr))
ok, ierr = craft("['/tmp/absolute.txt']")
check(not ok and ierr:find("Unexpected path"), "absolute path refused: " .. tostring(ierr))
check(not exists("/tmp/absolute.txt") and not exists(W .. "/escape.txt"), "nothing written outside")
-- A real symlink entry (zip -r would store the target's content instead).
fresh_install("0.4")
build_zip("0.5", "usbmtp.koplugin-v0.5.zip")
write(W .. "/craft.py", string.format([[import zipfile
z = zipfile.ZipFile('%s/srv/usbmtp.koplugin-v0.5.zip', 'a')
zi = zipfile.ZipInfo('usbmtp.koplugin/link'); zi.create_system = 3; zi.external_attr = 0o120777 << 16
z.writestr(zi, '/etc/passwd'); z.close()]], W))
sh("python3 -I " .. W .. "/craft.py")
sh(string.format("cd %s/srv && sha256sum usbmtp.koplugin-v0.5.zip > SHA256SUMS", W))
release("v0.5", GOOD)
ok, ierr = Updater.install(Updater.check("0.4", WORK), ROOT, WORK)
check(not ok and ierr:find("entry type in the zip %(link%)"), "symlink refused: " .. tostring(ierr))
check(installed_version() == "0.4", "symlink: installed copy untouched")
ok, ierr = craft("['usbmtp.koplugin/notes..txt']")
check(ok, "a harmless 'notes..txt' is allowed: " .. tostring(ierr))
check(exists(ROOT .. "/notes..txt"), "and installed")

print("== helpers")
check(Updater.safeEntryPath("usbmtp.koplugin/a..b/c.lua") and not Updater.safeEntryPath("usbmtp.koplugin/../x")
      and not Updater.safeEntryPath("usbmtp.koplugin/./x") and not Updater.safeEntryPath("a\\b"), "safeEntryPath")
local cut = Updater.shortNotes(string.rep("a", 9) .. "é", 10) -- é is 2 bytes; the cut lands inside it
check(cut == string.rep("a", 9) .. "…", "notes cut at a UTF-8 boundary: " .. cut)

print("== release zip built by tools/make-release.sh installs cleanly")
fresh_install("0.3")
-- Build into the scratch dir, never the repo (the suite runs as root; a root-owned
-- dist/ broke the v0.6 release build).
sh(string.format("cd '%s' && DIST_DIR='%s/dist' sh tools/make-release.sh >/dev/null", REPO, W))
local v = (read(REPO .. "/usbmtp.koplugin/mtp/VERSION") or ""):gsub("%s", "")
local zname = "usbmtp.koplugin-v" .. v .. ".zip"
served["https://dl/" .. zname] = W .. "/dist/" .. zname
served["https://dl/SHA256SUMS"] = W .. "/dist/SHA256SUMS"
release("v" .. v, { { zname, "https://dl/" .. zname }, { "SHA256SUMS", "https://dl/SHA256SUMS" } })
info = Updater.check("0.3", WORK)
ok, ierr = Updater.install(info, ROOT, WORK)
check(ok and installed_version() == v, "real release asset installs: " .. tostring(ierr))

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
