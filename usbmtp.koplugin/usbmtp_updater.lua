--[[--
Self-updater for usbmtp.koplugin, from GitHub Releases.

Only installs a release that:
  * is the repo's latest (non-draft, non-prerelease) GitHub Release, fetched over
    HTTPS with GitHub's certificate and hostname verified (see tlsParams), with a
    plain numeric version tag (v0.6, v1.2.3), and assets on this repo's GitHub
    release download URLs;
  * ships "usbmtp.koplugin-v<version>.zip" and "SHA256SUMS" assets;
  * matches its SHA256SUMS entry (catches truncated/corrupt downloads);
  * reads cleanly, contains only regular files and folders under
    "usbmtp.koplugin/", includes every file the plugin needs (REQUIRED), and
    its mtp/VERSION equals the release tag;
  * has Lua files that all compile.
The new copy is staged next to the current one and swapped in with two renames.
The previous copy is kept as "usbmtp.koplugin.old" (KOReader doesn't load it)
until the new version has loaded once; see cleanupAfterUpdate().

Network, hashing and archive access go through small functions tests replace.
]]

local Updater = {
    REPO = "AnonyMap/usbmtp",
    VERSION_PATTERN = "^v?(%d+[%.%d]*)$",
    ASSET_PATTERN = "^usbmtp%.koplugin%-v(%d+[%.%d]*)%.zip$",
    SUMS_NAME = "SHA256SUMS",
    PLUGIN_DIRNAME = "usbmtp.koplugin",
    -- Everything the plugin needs to load and run. A release missing any of these is refused.
    REQUIRED = {
        "_meta.lua", "main.lua", "usbmtp_updater.lua", "usbmtp_fat.lua", "usbmtp_drive.lua",
        "mtp/VERSION", "mtp/mtp-start.sh", "mtp/mtp-stop.sh", "mtp/mtp-status.sh",
        "mtp/mtp-watch.sh", "mtp/lib/common.sh", "mtp/conf/umtprd.conf", "mtp/bin/umtprd",
    },
    ZIP_TOTAL_TIMEOUT = 300, -- seconds; ~0.5 MB must still finish on slow Wi-Fi
}

---------------------------------------------------------------------------
-- Pluggable I/O (replaced in tests)
---------------------------------------------------------------------------

--- TLS settings that make sure we're really talking to GitHub, or nil + why not.
-- This downloads code that runs as root, so an unverified connection (anyone on
-- the same Wi-Fi could answer instead of GitHub) is not acceptable. LuaSec's own
-- default is no verification at all. KOReader patches in certificate and hostname
-- checks, but older builds don't have them, and the patched default quietly falls
-- back to none if it finds no CA bundle. So: ask for verification explicitly, and
-- refuse where the hostname check is missing.
function Updater.tlsParams()
    local ok, ssl = pcall(require, "ssl")
    if not ok or type(ssl) ~= "table" or type(ssl.checkhostname) ~= "function" then
        return nil, "This version of KOReader can't verify that it's really talking to GitHub, so updating over Wi-Fi isn't safe. Update KOReader, or install the new version by hand from GitHub."
    end
    local ca = type(ssl.get_system_ca) == "function" and ssl.get_system_ca() or nil
    if not ca and require("libs/libkoreader-lfs").attributes("data/ca-bundle.crt", "mode") == "file" then
        ca = "data/ca-bundle.crt" -- (KOReader's own bundle, relative to its folder)
    end
    if not ca then
        return nil, "KOReader has no certificate bundle, so GitHub can't be verified. Install the new version by hand from GitHub."
    end
    return { verify = "peer", cafile = ca }
end

--- One HTTP request, as socket.http.request(table) (replaced in tests).
function Updater.httpRequest(req)
    return require("socket.http").request(req)
end

local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--- Download url to path, over verified HTTPS only.
-- Redirects (release assets go to GitHub's download host) are followed here
-- rather than by LuaSocket, which rebuilds the request for the new host without
-- our TLS settings.
-- @return true, or nil + error string + HTTP status code (number) if the server answered.
function Updater.download(url, path, accept, total_timeout)
    local tls, terr = Updater.tlsParams()
    if not tls then return nil, terr end
    local socket = require("socket")
    local socketutil = require("socketutil")
    local tmp = path .. ".part"
    for _ = 1, 5 do
        if type(url) ~= "string" or not url:match("^https://") then
            os.remove(tmp)
            return nil, "refusing a non-HTTPS address"
        end
        os.remove(tmp)
        local f, ferr = io.open(tmp, "wb")
        if not f then return nil, ferr end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15,
                               total_timeout or socketutil.FILE_TOTAL_TIMEOUT or 60)
        local code, headers, status = socket.skip(1, Updater.httpRequest{
            url = url,
            method = "GET",
            sink = socketutil.file_sink(f),
            redirect = false,
            verify = tls.verify,
            cafile = tls.cafile,
            headers = {
                ["User-Agent"] = socketutil.USER_AGENT,
                ["Accept"] = accept or "application/octet-stream",
            },
        })
        socketutil:reset_timeout()
        pcall(function() f:close() end)
        local n = tonumber(code)
        if n and REDIRECT[n] and type(headers) == "table" and type(headers.location) == "string" then
            url = require("socket.url").absolute(url, headers.location)
        elseif not headers or n ~= 200 then
            os.remove(tmp)
            if n then return nil, status or ("HTTP " .. n), n end
            return nil, tostring(code or status or "network error")
        else
            os.remove(path)
            local ok, rerr = os.rename(tmp, path)
            if not ok then return nil, rerr end
            return true
        end
    end
    os.remove(tmp)
    return nil, "too many redirects"
end

function Updater.decodeJSON(s)
    return require("json").decode(s)
end

function Updater.sha256File(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return require("ffi/sha2").sha256(data)
end

function Updater.openArchive(path)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil, reader.err or "cannot open archive" end
    return reader
end

function Updater.sync()
    os.execute("sync")
end

local function makePath(dir)
    return require("util").makePath(dir)
end

local function lfs() return require("libs/libkoreader-lfs") end

local function exists(path)
    return lfs().attributes(path, "mode") ~= nil
end

local function purgeDir(dir)
    if lfs().attributes(dir, "mode") == "directory" then
        require("ffi/util").purgeDir(dir)
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function trim(s) return (s or ""):match("^%s*(.-)%s*$") end

-- "0.4" < "0.10" < "1.0"; returns -1, 0 or 1
function Updater.compareVersions(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v):gsub("^v", ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    return 0
end

-- A zip entry path is acceptable if it's relative, uses "/" only, and no
-- component is "." or "..". ("a..b.txt" is fine.)
function Updater.safeEntryPath(p)
    if p == "" or p:sub(1, 1) == "/" or p:find("\\", 1, true) or p:find("%z") then return false end
    for part in (p:gsub("/+$", "")):gmatch("[^/]+") do
        if part == ".." or part == "." then return false end
    end
    return not p:find("//", 1, true)
end

-- Trim release notes to about n bytes without splitting a UTF-8 character.
function Updater.shortNotes(s, n)
    s = (s or ""):gsub("\r", "")
    if #s <= n then return s end
    s = s:sub(1, n)
    s = s:gsub("[\192-\255][\128-\191]*$", "") -- drop a cut-off multi-byte sequence
    return s .. "…"
end

local function describeHttpFailure(err, code)
    if code == 404 then
        return "No release has been published on GitHub yet."
    elseif code == 403 or code == 429 then
        return "GitHub is limiting requests right now (rate limit). Try again in an hour."
    elseif code then
        return "GitHub replied with an error (HTTP " .. code .. "). Try again later."
    end
    return "Could not reach GitHub (" .. tostring(err) .. "). Check the Wi-Fi connection."
end

---------------------------------------------------------------------------
-- Check
---------------------------------------------------------------------------

--- Look up the latest release.
-- @return info table, or nil + error. info.newer is true if it's newer than current_version.
function Updater.check(current_version, work_dir)
    local tls_ok, tls_err = Updater.tlsParams()
    if not tls_ok then return nil, tls_err end
    makePath(work_dir)
    local json_path = work_dir .. "/latest.json"
    local ok, err, code = Updater.download(
        string.format("https://api.github.com/repos/%s/releases/latest", Updater.REPO),
        json_path, "application/vnd.github+json")
    if not ok then
        return nil, describeHttpFailure(err, code)
    end
    local okj, rel = pcall(Updater.decodeJSON, readFile(json_path) or "")
    os.remove(json_path)
    if not okj or type(rel) ~= "table" or type(rel.tag_name) ~= "string" then
        return nil, "GitHub sent a reply the updater doesn't understand. Try again later."
    end
    local version = rel.tag_name:match(Updater.VERSION_PATTERN)
    if not version then
        return nil, "The latest release (" .. rel.tag_name .. ") doesn't have a plain version number, so it can't be installed automatically."
    end

    local info = {
        tag = rel.tag_name,
        version = version,
        notes = type(rel.body) == "string" and rel.body or "",
        page = rel.html_url,
    }
    -- Assets only from this repo's own release downloads.
    local asset_prefix = "https://github.com/" .. Updater.REPO .. "/releases/download/"
    for _, a in ipairs(type(rel.assets) == "table" and rel.assets or {}) do
        if type(a) == "table" and type(a.name) == "string" and type(a.browser_download_url) == "string"
                and a.browser_download_url:sub(1, #asset_prefix) == asset_prefix then
            local v = a.name:match(Updater.ASSET_PATTERN)
            if v then
                info.zip_name, info.zip_url, info.zip_version = a.name, a.browser_download_url, v
            elseif a.name == Updater.SUMS_NAME then
                info.sums_url = a.browser_download_url
            end
        end
    end
    info.newer = Updater.compareVersions(info.version, current_version) > 0
    if info.newer and not (info.zip_url and info.sums_url) then
        return nil, "Release " .. info.tag .. " is missing its plugin zip or SHA256SUMS. Try again later."
    end
    if info.newer and Updater.compareVersions(info.zip_version, info.version) ~= 0 then
        return nil, "Release " .. info.tag .. " has a zip for a different version (" .. info.zip_name .. ")."
    end
    return info
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------

--- Download, verify, stage and swap in a release found by check().
-- @param plugin_root absolute path of the installed usbmtp.koplugin folder
-- @return true, or nil + error. Before the swap, any error leaves the installed copy untouched.
function Updater.install(info, plugin_root, work_dir)
    makePath(work_dir)
    local zip_path = work_dir .. "/" .. info.zip_name
    local sums_path = work_dir .. "/" .. Updater.SUMS_NAME

    local function cleanup()
        os.remove(zip_path)
        os.remove(sums_path)
    end

    local ok, err, code = Updater.download(info.zip_url, zip_path, nil, Updater.ZIP_TOTAL_TIMEOUT)
    if not ok then cleanup(); return nil, "Download failed: " .. describeHttpFailure(err, code) end
    ok, err, code = Updater.download(info.sums_url, sums_path, "text/plain, */*")
    if not ok then cleanup(); return nil, "Download failed: " .. describeHttpFailure(err, code) end

    -- 1. Checksum
    local expected
    for line in (readFile(sums_path) or ""):gmatch("[^\r\n]+") do
        local hash, name = line:match("^(%x+)%s+%*?(.-)%s*$")
        if name == info.zip_name then expected = hash:lower() end
    end
    if not expected then cleanup(); return nil, "SHA256SUMS has no entry for " .. info.zip_name end
    if Updater.sha256File(zip_path) ~= expected then
        cleanup()
        return nil, "Checksum mismatch (download corrupted?). Nothing was changed."
    end

    -- 2. Inspect the whole archive before writing anything
    local reader, aerr = Updater.openArchive(zip_path)
    if not reader then cleanup(); return nil, "Cannot open the zip: " .. tostring(aerr) end
    local prefix = Updater.PLUGIN_DIRNAME .. "/"
    local files, seen = {}, {}
    local function fail(msg)
        reader:close(); cleanup()
        return nil, msg
    end
    for entry in reader:iterate() do
        local p = entry.path
        if not Updater.safeEntryPath(p) or p:sub(1, #prefix) ~= prefix then
            return fail("Unexpected path in the zip: " .. p)
        end
        if entry.mode == "file" then
            files[#files + 1] = p
            seen[p:sub(#prefix + 1)] = true
        elseif entry.mode ~= "directory" then
            return fail("Unexpected entry type in the zip (" .. tostring(entry.mode) .. "): " .. p)
        end
    end
    if reader.err then
        return fail("The zip is damaged: " .. tostring(reader.err))
    end
    for _, need in ipairs(Updater.REQUIRED) do
        if not seen[need] then return fail("The zip is missing " .. need) end
    end
    local zip_version = trim(reader:extractToMemory(prefix .. "mtp/VERSION"))
    if Updater.compareVersions(zip_version, info.version) ~= 0 then
        return fail(string.format("The zip says version %s, but the release is %s", zip_version, info.version))
    end

    -- 3. Stage next to the installed copy ("*.koplugin.new" isn't loaded by KOReader)
    local staged = plugin_root .. ".new"
    local old = plugin_root .. ".old"
    purgeDir(staged)
    for _, p in ipairs(files) do
        local dest = staged .. "/" .. p:sub(#prefix + 1)
        makePath(dest:match("^(.*)/[^/]+$"))
        if not reader:extractToPath(p, dest) then
            local why = reader.err
            reader:close(); cleanup(); purgeDir(staged)
            return nil, "Could not unpack " .. p .. ": " .. tostring(why)
        end
    end
    reader:close()
    cleanup()

    -- 4. Check what landed on disk: every required file present and non-empty, all Lua compiles.
    for _, need in ipairs(Updater.REQUIRED) do
        local size = lfs().attributes(staged .. "/" .. need, "size")
        if not size or size == 0 then
            purgeDir(staged)
            return nil, "Unpacking failed (" .. need .. " is missing or empty). Nothing was changed."
        end
    end
    for _, p in ipairs(files) do
        if p:match("%.lua$") then
            local chunk, lerr = loadfile(staged .. "/" .. p:sub(#prefix + 1))
            if not chunk then
                purgeDir(staged)
                return nil, "The new version has a broken file (" .. tostring(lerr) .. "). Nothing was changed."
            end
        end
    end
    Updater.sync()

    -- 5. Swap: installed -> .old, staged -> installed. Undo on failure.
    purgeDir(old)
    if exists(old) then
        purgeDir(staged)
        return nil, "An old backup folder is in the way: " .. old .. "\nDelete it, then try again. Nothing was changed."
    end
    local r1, e1 = os.rename(plugin_root, old)
    if not r1 then
        purgeDir(staged)
        return nil, "Could not move the current version aside: " .. tostring(e1) .. ". Nothing was changed."
    end
    local r2, e2 = os.rename(staged, plugin_root)
    if not r2 then
        local undone = os.rename(old, plugin_root)
        Updater.sync()
        if not undone then
            return nil, "The update failed halfway (" .. tostring(e2) .. ").\nYour previous version is now at:\n" .. old ..
                        "\nRename that folder back to " .. Updater.PLUGIN_DIRNAME .. " (on a computer, or over SSH) to restore it."
        end
        purgeDir(staged)
        return nil, "Could not put the new version in place (" .. tostring(e2) .. "). Kept the current version."
    end
    Updater.sync()
    return true
end

--- Call from the plugin once it has loaded: the new version works, so the
-- backup of the previous one (and any half-staged copy) can go.
function Updater.cleanupAfterUpdate(plugin_root)
    purgeDir(plugin_root .. ".old")
    purgeDir(plugin_root .. ".new")
end

return Updater
