--[[--
Self-updater for usbmtp.koplugin, from GitHub Releases.

Only installs a release that:
  * is the repo's latest (non-draft, non-prerelease) GitHub Release, over HTTPS;
  * ships a "usbmtp.koplugin-v<version>.zip" asset and a "SHA256SUMS" asset;
  * matches its SHA256SUMS entry (catches truncated/corrupt downloads);
  * contains nothing outside "usbmtp.koplugin/", has _meta.lua, main.lua and
    mtp/VERSION, and that VERSION equals the release tag.
The new copy is staged next to the current one and swapped in with two renames;
if the swap fails, the current copy is put back.

Network and archive access go through small functions that tests replace.
]]

local Updater = {
    REPO = "AnonyMap/usbmtp",
    ASSET_PATTERN = "^usbmtp%.koplugin%-v?([%d%.]+)%.zip$",
    SUMS_NAME = "SHA256SUMS",
    PLUGIN_DIRNAME = "usbmtp.koplugin",
}

---------------------------------------------------------------------------
-- Pluggable I/O (replaced in tests)
---------------------------------------------------------------------------

-- Download url to path. Returns true, or nil and an error string.
function Updater.download(url, path, accept)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local tmp = path .. ".part"
    os.remove(tmp)
    local f, ferr = io.open(tmp, "wb")
    if not f then return nil, ferr end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT or 15, socketutil.FILE_TOTAL_TIMEOUT or 180)
    local code, headers, status = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = socketutil.file_sink(f),
        redirect = true, -- release assets redirect to GitHub's download host
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT,
            ["Accept"] = accept or "application/octet-stream",
        },
    })
    socketutil:reset_timeout()
    pcall(function() f:close() end)
    if not headers or tonumber(code) ~= 200 then
        os.remove(tmp)
        return nil, status or ("HTTP " .. tostring(code))
    end
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then return nil, rerr end
    return true
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

local function makePath(dir)
    return require("util").makePath(dir)
end

local function purgeDir(dir)
    if require("libs/libkoreader-lfs").attributes(dir, "mode") == "directory" then
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

local function exists(path)
    return require("libs/libkoreader-lfs").attributes(path, "mode") ~= nil
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

---------------------------------------------------------------------------
-- Check
---------------------------------------------------------------------------

--- Look up the latest release.
-- @return info table, or nil + error. info.newer is true if it's newer than current_version.
function Updater.check(current_version, work_dir)
    makePath(work_dir)
    local json_path = work_dir .. "/latest.json"
    local ok, err = Updater.download(
        string.format("https://api.github.com/repos/%s/releases/latest", Updater.REPO),
        json_path, "application/vnd.github+json")
    if not ok then
        return nil, "Could not reach GitHub: " .. tostring(err)
    end
    local okj, rel = pcall(Updater.decodeJSON, readFile(json_path) or "")
    os.remove(json_path)
    if not okj or type(rel) ~= "table" or type(rel.tag_name) ~= "string" then
        return nil, "GitHub sent an unexpected reply (no published release yet?)"
    end

    local info = {
        tag = rel.tag_name,
        version = rel.tag_name:gsub("^v", ""),
        notes = type(rel.body) == "string" and rel.body or "",
        page = rel.html_url,
    }
    for _, a in ipairs(type(rel.assets) == "table" and rel.assets or {}) do
        if type(a) == "table" and type(a.name) == "string" then
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
        return nil, "Release " .. info.tag .. " is missing its plugin zip or SHA256SUMS"
    end
    if info.newer and Updater.compareVersions(info.zip_version, info.version) ~= 0 then
        return nil, "Release " .. info.tag .. " has a zip for a different version (" .. info.zip_name .. ")"
    end
    return info
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------

--- Download, verify, stage and swap in a release found by check().
-- @param plugin_root absolute path of the installed usbmtp.koplugin folder
-- @return true, or nil + error. The installed copy is untouched on any error before the swap.
function Updater.install(info, plugin_root, work_dir)
    makePath(work_dir)
    local zip_path = work_dir .. "/" .. info.zip_name
    local sums_path = work_dir .. "/" .. Updater.SUMS_NAME

    local function cleanup()
        os.remove(zip_path)
        os.remove(sums_path)
    end

    local ok, err = Updater.download(info.zip_url, zip_path)
    if not ok then cleanup(); return nil, "Download failed: " .. tostring(err) end
    ok, err = Updater.download(info.sums_url, sums_path, "text/plain, */*")
    if not ok then cleanup(); return nil, "Download failed: " .. tostring(err) end

    -- 1. Checksum
    local expected
    for line in (readFile(sums_path) or ""):gmatch("[^\r\n]+") do
        local hash, name = line:match("^(%x+)%s+%*?(.-)%s*$")
        if name == info.zip_name then expected = hash:lower() end
    end
    if not expected then cleanup(); return nil, "SHA256SUMS has no entry for " .. info.zip_name end
    local actual = Updater.sha256File(zip_path)
    if actual ~= expected then
        cleanup()
        return nil, "Checksum mismatch (download corrupted?). Nothing was changed."
    end

    -- 2. Inspect the archive before writing anything
    local reader, aerr = Updater.openArchive(zip_path)
    if not reader then cleanup(); return nil, "Cannot open the zip: " .. tostring(aerr) end
    local prefix = Updater.PLUGIN_DIRNAME .. "/"
    local files, seen = {}, {}
    for entry in reader:iterate() do
        local p = entry.path
        if p:find("..", 1, true) or p:sub(1, 1) == "/" or p:sub(1, #prefix) ~= prefix then
            reader:close(); cleanup()
            return nil, "Unexpected path in the zip: " .. p
        end
        if entry.mode == "file" then
            files[#files + 1] = p
            seen[p:sub(#prefix + 1)] = true
        elseif entry.mode ~= "directory" then
            reader:close(); cleanup()
            return nil, "Unexpected entry type in the zip: " .. p
        end
    end
    for _, need in ipairs{ "_meta.lua", "main.lua", "mtp/VERSION", "mtp/mtp-start.sh", "mtp/mtp-stop.sh" } do
        if not seen[need] then
            reader:close(); cleanup()
            return nil, "The zip is missing " .. need
        end
    end
    local zip_version = trim(reader:extractToMemory(prefix .. "mtp/VERSION"))
    if Updater.compareVersions(zip_version, info.version) ~= 0 then
        reader:close(); cleanup()
        return nil, string.format("The zip says version %s, but the release is %s", zip_version, info.version)
    end

    -- 3. Stage next to the installed copy ("*.koplugin.new" isn't loaded by KOReader)
    local parent = plugin_root:match("^(.*)/[^/]+$")
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
    if not (exists(staged .. "/_meta.lua") and exists(staged .. "/main.lua")) then
        purgeDir(staged)
        return nil, "Unpacking failed"
    end

    -- 4. Swap: installed -> .old, staged -> installed. Undo on failure.
    purgeDir(old)
    local r1, e1 = os.rename(plugin_root, old)
    if not r1 then
        purgeDir(staged)
        return nil, "Could not move the current version aside: " .. tostring(e1)
    end
    local r2, e2 = os.rename(staged, plugin_root)
    if not r2 then
        os.rename(old, plugin_root)
        purgeDir(staged)
        return nil, "Could not put the new version in place (kept the current one): " .. tostring(e2)
    end
    purgeDir(old)
    return true, parent
end

return Updater
