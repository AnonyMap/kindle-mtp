--[[
usbmtp_drive: the "USB drive" mode's files.

The drive is a disk image in KOReader's folder (never in documents/, and never
inside the plugin, which updates replace). The computer sees it as a plain USB
stick called TO KINDLE, which every OS can write to with no extra app; the
Kindle's own storage stays mounted here the whole time, so KOReader keeps
running. After the computer ejects it, import() copies what's on it into
documents/ and wipe() empties it for next time.

  Drive.creator(path, mb)   -> step function: each call writes a bit more;
                               returns a fraction, true when done, or nil, err
  Drive.pending(path)       -> number of files waiting on the drive (or nil, err)
  Drive.import(path, opts)  -> result | nil, err
        result = { added = {us paths}, same = n, empty = n, skipped = n,
                   failed = { {name=, err=} }, forced = bool }
        nil, err, Drive.DIRTY when the computer didn't eject it (opts.allow_dirty
        imports anyway, but then never replaces a book already on the Kindle)
        opts.before_replace(us_path)  called before an existing file is overwritten
        opts.progress(i, n, name)     before each file
        opts.free_space(dir)          bytes available (default: util.diskUsage)
  Drive.wipe(path)          -> true | nil, err
]]

local Fat = require("usbmtp_fat")
local lfs = require("libs/libkoreader-lfs")

local Drive = {
    IMAGE = "/mnt/base-us/koreader/usbmtp-drive.img", -- base-us: the kernel must not go through Amazon's FUSE layer
    BOOKS = "/mnt/base-us/documents",
    MB = 1024 * 1024,
}

-- KOReader knows files by their /mnt/us path.
function Drive.usPath(p)
    return (p:gsub("^/mnt/base%-us/", "/mnt/us/"))
end

local function mkdirs(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local path = ""
    for part in dir:gmatch("[^/]+") do
        path = path .. "/" .. part
        if lfs.attributes(path, "mode") ~= "directory" then
            local ok, err = lfs.mkdir(path)
            if not ok and lfs.attributes(path, "mode") ~= "directory" then return nil, err end
        end
    end
    return true
end

local function defaultFreeSpace(dir)
    local ok, util = pcall(require, "util")
    if not ok or not util.diskUsage then return nil end
    local u = util.diskUsage(dir)
    return u and u.available
end

function Drive.size(path)
    return lfs.attributes(path, "size")
end

-- Writing the image's zeros is the slow part (vfat on this kernel can't create a
-- large file any other way), so it's done a few MB per call.
function Drive.creator(path, mb, free_space)
    local total = mb * Drive.MB
    local tmp = path .. ".part"
    local f, written, zero
    return function()
        if not f then
            local dir = path:match("^(.*)/[^/]+$")
            local ok, err = mkdirs(dir)
            if not ok then return nil, err end
            local avail = (free_space or defaultFreeSpace)(dir)
            if avail and avail < total + 32 * Drive.MB then
                return nil, string.format("not enough space on the Kindle (%d MB needed, %d MB free)",
                                          mb + 32, math.floor(avail / Drive.MB))
            end
            f, err = io.open(tmp, "wb")
            if not f then return nil, err end
            written, zero = 0, string.rep("\0", Drive.MB)
        end
        for _ = 1, 4 do
            if written >= total then break end
            if not f:write(zero) then
                f:close(); os.remove(tmp)
                return nil, "write failed (Kindle full?)"
            end
            written = written + Drive.MB
        end
        if written < total then return written / total end
        local ok = f:close()
        f = nil
        local err
        if ok then ok, err = Fat.format(tmp) end
        if ok then ok, err = os.rename(tmp, path) end
        if not ok then
            os.remove(tmp)
            return nil, err or "write failed (Kindle full?)"
        end
        return true
    end
end

function Drive.pending(path)
    local vol, err = Fat.open(path)
    if not vol then return nil, err end
    local list
    list, err = vol:list()
    vol:close()
    if not list then return nil, err end
    return #list
end

local function sameContent(a, b, size)
    local fa, fb = io.open(a, "rb"), io.open(b, "rb")
    local same = fa and fb and true or false
    while same and size > 0 do
        local n = math.min(size, Drive.MB)
        local x, y = fa:read(n), fb:read(n)
        same = x ~= nil and x == y
        size = size - n
    end
    if fa then fa:close() end
    if fb then fb:close() end
    return same
end

-- Why an import didn't happen, for the caller to act on.
Drive.DIRTY = "dirty"

function Drive.import(path, opts)
    opts = opts or {}
    local vol, err = Fat.open(path)
    if not vol then return nil, err end
    -- Not ejected: the computer may not have written everything yet (a file can
    -- have its final size and no data). Only on request, and then never over an
    -- existing book.
    local forced = false
    if vol:dirty() then
        if not opts.allow_dirty then
            vol:close()
            return nil, "the computer still had the drive open (it wasn't ejected)", Drive.DIRTY
        end
        forced = true
    end
    local list, skipped = vol:list()
    if not list then vol:close(); return nil, skipped end

    -- People coming from the stock USB mode may well drop a "documents" folder on
    -- it. That can make two files land on the same name (vfat ignores case), so the
    -- later one gets " (2)".
    local plan, taken, need = {}, {}, 0
    for i, file in ipairs(list) do
        local rel = file.path:gsub("^[Dd][Oo][Cc][Uu][Mm][Ee][Nn][Tt][Ss]/", "")
        local dest = Drive.BOOKS .. "/" .. rel
        local n = 1
        while taken[dest:lower()] do
            n = n + 1
            local stem, ext = rel:match("^(.*)(%.[^./]+)$")
            dest = Drive.BOOKS .. "/" .. (stem and (stem .. " (" .. n .. ")" .. ext) or (rel .. " (" .. n .. ")"))
        end
        taken[dest:lower()] = true
        plan[#plan + 1] = { file = file, dest = dest, index = i }
        local existing = lfs.attributes(dest)
        if not (existing and existing.size == file.size) then need = need + file.size end
    end
    local avail = (opts.free_space or defaultFreeSpace)(Drive.BOOKS)
    if avail and need > 0 and avail < need + 8 * Drive.MB then
        vol:close()
        return nil, string.format("not enough space on the Kindle for the %d MB on the drive (%d MB free)",
                                  math.ceil(need / Drive.MB), math.floor(avail / Drive.MB))
    end

    -- One file: "added", "same" (already there, identical), "empty", or nil, err.
    local function importOne(p)
        if p.file.size == 0 then return "empty" end -- e.g. what an interrupted copy leaves
        local dir = p.dest:match("^(.*)/[^/]+$")
        local ok, e = mkdirs(dir)
        if not ok then return nil, e end
        local existing = lfs.attributes(p.dest)
        if existing and existing.mode ~= "file" then return nil, "a folder of that name is in the way" end
        -- Hidden temp name in the same folder (short: long names must still fit), then
        -- rename: never a half-written book.
        local tmp = dir .. "/.usbmtp-part-" .. p.index
        ok, e = vol:extract(p.file, tmp)
        if not ok then return nil, e end
        if existing and existing.size == p.file.size and sameContent(tmp, p.dest, p.file.size) then
            os.remove(tmp) -- e.g. imported before, by a run that stopped part-way
            return "same"
        end
        if existing and forced then
            os.remove(tmp)
            return nil, "not replacing the copy on the Kindle (the drive wasn't ejected)"
        end
        if existing and opts.before_replace then opts.before_replace(Drive.usPath(p.dest)) end
        ok, e = os.rename(tmp, p.dest)
        if not ok then os.remove(tmp); return nil, e end
        return "added"
    end

    local result = { added = {}, same = 0, empty = 0, skipped = skipped or 0, failed = {}, forced = forced }
    for i, p in ipairs(plan) do
        if opts.progress then opts.progress(i, #plan, p.file.path) end
        local status, e = importOne(p)
        if status == "added" then
            result.added[#result.added + 1] = Drive.usPath(p.dest)
        elseif status == "same" then
            result.same = result.same + 1
        elseif status == "empty" then
            result.empty = result.empty + 1
        else
            result.failed[#result.failed + 1] = { name = p.file.path, err = tostring(e) }
        end
    end
    vol:close()
    table.sort(result.added)
    return result
end

-- Remove the drive (and a half-created one).
function Drive.erase(path)
    os.remove(path .. ".part")
    return os.remove(path)
end

function Drive.wipe(path)
    return Fat.format(path)
end

return Drive
