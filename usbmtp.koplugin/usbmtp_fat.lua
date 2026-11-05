--[[
usbmtp_fat: just enough FAT16 for the "USB drive" mode.

The computer gets a disk image (not the Kindle's own storage, which stays mounted
here), writes books into it, and ejects it; then this module reads the image to
copy them into documents/, and wipes it for next time. No loop devices or extra
binaries needed on the Kindle.

  Fat.format(path [, label])     -> true | nil, err   (MBR + one FAT16 partition, size = file size)
  local vol = Fat.open(path)     -> vol | nil, err    (only that layout)
  vol:list()                     -> { {path=, size=, cluster=}, ... }, skipped | nil, err
  vol:dirty()                    -> true if the computer still had it mounted (not ejected)
  vol:extract(file, dest)        -> true | nil, err
  vol:close()

The reader is strict: a cluster chain shorter than the file size, or running off
the volume, is an error rather than a truncated book. A dirty volume can hold
files whose size is right but whose data never arrived, which nothing here can
detect, so callers check dirty() first. The image is untrusted input.
]]

local bit = require("bit")

local Fat = {}

local SECTOR = 512
local PART_START = 2048 -- in sectors (1 MiB), where every partitioning tool puts it
Fat.LABEL = "TO KINDLE"
Fat.MIN_SIZE = 16 * 1024 * 1024
Fat.MAX_SIZE = 2047 * 1024 * 1024 -- FAT16 with 32 KiB clusters

-- Little-endian helpers (offsets are 0-based, like the specs)
local function u8(s, o) return s:byte(o + 1) end
local function u16(s, o) local a, b = s:byte(o + 1, o + 2); return a + b * 256 end
local function u32(s, o)
    local a, b, c, d = s:byte(o + 1, o + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function readAt(f, offset, len)
    if not f:seek("set", offset) then return nil end
    local s = f:read(len)
    if not s or #s ~= len then return nil end
    return s
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

-- FAT16 geometry for a volume of `total` sectors: the smallest cluster size that
-- keeps the cluster count in FAT16's range.
local function layout16(total)
    local reserved, root_sec = 4, 32 -- 512 root directory entries
    for _, spc in ipairs({ 1, 2, 4, 8, 16, 32, 64 }) do
        local fatsz = math.ceil(((total - reserved - root_sec) / spc + 2) * 2 / SECTOR)
        local clusters = math.floor((total - reserved - 2 * fatsz - root_sec) / spc)
        if clusters <= 65524 then
            if clusters < 4085 then return nil end
            return { spc = spc, reserved = reserved, fatsz = fatsz, root_sec = root_sec }
        end
    end
end

local function label11(label)
    label = (label or Fat.LABEL):upper():gsub("[^%w %-_]", "_"):sub(1, 11)
    return label .. string.rep(" ", 11 - #label)
end

-- Writes a fresh, empty filesystem over the start of an existing file (the data
-- area is left alone: the FAT says it's all free). Also how the drive is wiped.
function Fat.format(path, label)
    local f, err = io.open(path, "r+b")
    if not f then return nil, err end
    local size = f:seek("end")
    if not size or size < Fat.MIN_SIZE or size > Fat.MAX_SIZE + PART_START * SECTOR then
        f:close()
        return nil, "unsupported image size " .. tostring(size)
    end
    local total = math.floor(size / SECTOR) - PART_START
    local L = layout16(total)
    if not L then f:close(); return nil, "image too small" end
    local lbl = label11(label)

    -- MBR: one FAT16 (LBA) partition from 1 MiB to the end.
    local mbr = string.rep("\0", 446)
        .. "\0" .. "\254\255\255" .. "\14" .. "\254\255\255" .. le32(PART_START) .. le32(total)
        .. string.rep("\0", 48) .. "\85\170"

    local volid = os.time() % 4294967296
    local boot = "\235\60\144" .. "USBMTP  " .. le16(SECTOR) .. string.char(L.spc) .. le16(L.reserved)
        .. "\2" .. le16(512) .. le16(total < 65536 and total or 0) .. "\248" .. le16(L.fatsz)
        .. le16(63) .. le16(255) .. le32(PART_START) .. le32(total >= 65536 and total or 0)
        .. "\128\0\41" .. le32(volid) .. lbl .. "FAT16   "
    boot = boot .. string.rep("\0", 510 - #boot) .. "\85\170"

    local ok = true
    local function put(offset, data)
        if ok then ok = f:seek("set", offset) and f:write(data) and true or false end
    end
    local base = PART_START * SECTOR
    put(0, mbr)
    put(base, boot .. string.rep("\0", (L.reserved - 1) * SECTOR))
    local fat_bytes = L.fatsz * SECTOR
    for i = 0, 1 do
        local off = base + (L.reserved + i * L.fatsz) * SECTOR
        put(off, "\248\255\255\255")
        local done, zero = 4, string.rep("\0", 65536)
        while done < fat_bytes do
            local n = math.min(#zero, fat_bytes - done)
            put(off + done, n == #zero and zero or zero:sub(1, n))
            done = done + n
        end
    end
    -- Root directory: just the volume label (what Finder/Explorer show as the name).
    local label_entry = lbl .. "\8" .. string.rep("\0", 20)
    put(base + (L.reserved + 2 * L.fatsz) * SECTOR, label_entry .. string.rep("\0", L.root_sec * SECTOR - 32))
    ok = ok and f:flush() and true or false
    f:close()
    if not ok then return nil, "write failed" end
    return true
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local Vol = {}
Vol.__index = Vol

-- Only what Fat.format makes is read: an MBR with a FAT16 partition. A drive the
-- computer reformatted (FAT32, exFAT, ...) is reported, and erasing it fixes it.
-- Every count from the image is untrusted and clamped to what the file holds.
function Fat.open(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local function bad(msg) f:close(); return nil, msg end
    local mbr = readAt(f, 0, 512)
    if not mbr or u16(mbr, 510) ~= 0xAA55 then return bad("no filesystem found") end
    local base = u32(mbr, 446 + 8) * SECTOR
    local boot = base > 0 and readAt(f, base, 512)
    local reformatted = "the drive isn't the way the Kindle formatted it (was it reformatted on the computer?)"
    if not boot or u16(boot, 510) ~= 0xAA55 or u16(boot, 11) ~= SECTOR or u8(boot, 16) ~= 2
            or u16(boot, 22) == 0 or u16(boot, 14) == 0 then
        return bad(reformatted)
    end
    local v = setmetatable({ f = f, base = base, boot = boot }, Vol)
    v.spc = u8(boot, 13)
    if v.spc == 0 or bit.band(v.spc, v.spc - 1) ~= 0 then return bad(reformatted) end
    v.csize = SECTOR * v.spc
    local reserved, fatsz = u16(boot, 14), u16(boot, 22)
    local rootsec = math.ceil(u16(boot, 17) * 32 / SECTOR)
    local totsec = u16(boot, 19) ~= 0 and u16(boot, 19) or u32(boot, 32)
    v.root_off = base + (reserved + 2 * fatsz) * SECTOR
    v.root_len = rootsec * SECTOR
    v.data_off = v.root_off + v.root_len
    v.clusters = math.floor((totsec - reserved - 2 * fatsz - rootsec) / v.spc)
    if v.clusters < 4085 or v.clusters > 65524 then return bad(reformatted) end -- not FAT16
    v.clusters = math.min(v.clusters, fatsz * SECTOR / 2 - 2,
                          math.floor(((f:seek("end") or 0) - v.data_off) / v.csize))
    if v.clusters < 1 then return bad("the drive is damaged") end
    v.fat = readAt(f, base + reserved * SECTOR, fatsz * SECTOR)
    if not v.fat then return bad("the drive is damaged") end
    return v
end

-- Still marked in use by the computer that had it (not ejected): Windows and
-- macOS clear the "clean" bit in FAT entry 1 while it's mounted, Linux sets bit 0
-- of the boot sector's state byte.
function Vol:dirty()
    return bit.band(u16(self.fat, 2), 0x8000) == 0 or bit.band(u8(self.boot, 37), 1) ~= 0
end

function Vol:close()
    if self.f then self.f:close() end
    self.f = nil
end

-- Up to `limit` clusters of the chain starting at `first` (nil if it's broken
-- before that). The limit also bounds a chain that loops back on itself.
function Vol:chain(first, limit)
    local out = {}
    local c = first
    while #out < limit do
        if c < 2 or c >= self.clusters + 2 then return nil end
        out[#out + 1] = c
        c = u16(self.fat, 2 * c)
        if c >= 0xFFF8 then break end -- end of chain
    end
    return out
end

function Vol:clusterOffset(c)
    return self.data_off + (c - 2) * self.csize
end

-- Raw bytes of a directory: the fixed root, or a cluster chain.
function Vol:dirData(cluster)
    if not cluster then return readAt(self.f, self.root_off, self.root_len) end
    -- (More than 2 MiB of directory entries is not a real folder.)
    local ch = self:chain(cluster, math.max(1, math.floor(2 * 1024 * 1024 / self.csize)))
    if not ch then return nil end
    local parts = {}
    for _, c in ipairs(ch) do
        local s = readAt(self.f, self:clusterOffset(c), self.csize)
        if not s then return nil end
        parts[#parts + 1] = s
    end
    return table.concat(parts)
end

local function utf16ToUtf8(units)
    local out, i = {}, 1
    while i <= #units do
        local u = units[i]
        if u >= 0xD800 and u <= 0xDBFF and units[i + 1] and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF then
            u = 0x10000 + (u - 0xD800) * 1024 + (units[i + 1] - 0xDC00)
            i = i + 1
        elseif u >= 0xD800 and u <= 0xDFFF then
            u = 0x5F -- lone surrogate: "_"
        end
        if u < 0x80 then out[#out + 1] = string.char(u)
        elseif u < 0x800 then out[#out + 1] = string.char(0xC0 + math.floor(u / 64), 0x80 + u % 64)
        elseif u < 0x10000 then
            out[#out + 1] = string.char(0xE0 + math.floor(u / 4096), 0x80 + math.floor(u / 64) % 64, 0x80 + u % 64)
        else
            out[#out + 1] = string.char(0xF0 + math.floor(u / 262144), 0x80 + math.floor(u / 4096) % 64,
                                        0x80 + math.floor(u / 64) % 64, 0x80 + u % 64)
        end
        i = i + 1
    end
    return table.concat(out)
end

local function shortChecksum(e)
    local sum = 0
    for i = 1, 11 do
        sum = (bit.band(sum, 1) * 128 + math.floor(sum / 2) + e:byte(i)) % 256
    end
    return sum
end

local function shortName(e)
    local function clean(s, lower)
        s = s:gsub(" +$", ""):gsub("[\128-\255]", "_")
        return lower and s:lower() or s
    end
    local nt = u8(e, 12)
    local b = e:sub(1, 8)
    if b:byte(1) == 0x05 then b = "_" .. b:sub(2) end
    local base = clean(b, bit.band(nt, 0x08) ~= 0)
    local ext = clean(e:sub(9, 11), bit.band(nt, 0x10) ~= 0)
    return ext ~= "" and (base .. "." .. ext) or base
end

-- Entries of one directory: { name=, dir=, cluster=, size=, attr= }
function Vol:entries(cluster)
    local data = self:dirData(cluster)
    if not data then return nil end
    local out = {}
    local lfn, lfn_n, lfn_sum = nil, 0, 0
    for off = 0, #data - 32, 32 do
        local e = data:sub(off + 1, off + 32)
        local b0 = e:byte(1)
        if b0 == 0 then break end
        local attr = e:byte(12)
        if b0 == 0xE5 then
            lfn = nil
        elseif attr == 0x0F then
            local seq = bit.band(b0, 0x1F)
            if bit.band(b0, 0x40) ~= 0 then
                lfn, lfn_n, lfn_sum = {}, seq, e:byte(14)
            end
            if lfn and seq >= 1 and seq <= 20 and e:byte(14) == lfn_sum then
                local units = {}
                for _, o in ipairs({ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 }) do
                    units[#units + 1] = u16(e, o)
                end
                lfn[seq] = units
            else
                lfn = nil
            end
        elseif bit.band(attr, 0x08) ~= 0 then
            lfn = nil -- volume label
        else
            local name
            if lfn and shortChecksum(e) == lfn_sum then
                local units, complete = {}, true
                for i = 1, lfn_n do
                    if not lfn[i] then complete = false; break end
                    for _, u in ipairs(lfn[i]) do
                        if u == 0 or u == 0xFFFF then break end
                        units[#units + 1] = u
                    end
                end
                if complete then name = utf16ToUtf8(units) end
            end
            name = name or shortName(e)
            lfn = nil
            if name ~= "." and name ~= ".." then
                out[#out + 1] = { name = name, attr = attr, dir = bit.band(attr, 0x10) ~= 0,
                                  cluster = u16(e, 26), size = u32(e, 28) }
            end
        end
    end
    return out
end

-- Things computers leave on a drive that aren't the user's files.
local SKIP_TOP = { ["system volume information"] = true, ["$recycle.bin"] = true, ["recycler"] = true }

local JUNK = { ["thumbs.db"] = true, ["desktop.ini"] = true }

-- "junk": things computers leave behind (silently ignored); "skip": a user file we
-- won't copy (hidden/system attribute or an unusable name), which gets reported.
local function classify(e, top)
    local lname = e.name:lower()
    if e.name:sub(1, 1) == "." then return "junk" end -- .Trashes, .fseventsd, ._AppleDouble, ...
    if (top and SKIP_TOP[lname]) or JUNK[lname] then return "junk" end
    if e.name:find("[%z\1-\31/\\]") then return "skip" end
    if bit.band(e.attr, 0x06) ~= 0 then return "skip" end -- hidden / system
    return nil
end

-- Every user file on the drive, depth-first, with "/"-separated paths, and how
-- many user files were skipped.
function Vol:list()
    local files, count, skipped = {}, 0, 0
    local function walk(cluster, prefix, depth)
        if depth > 16 then return nil, "folders nested too deep" end
        local ents = self:entries(cluster)
        if not ents then return nil, "a folder on the drive can't be read" end
        for _, e in ipairs(ents) do
            count = count + 1
            if count > 20000 then return nil, "too many files" end
            local class = classify(e, depth == 0)
            if class == "skip" then skipped = skipped + 1 end
            if not class then
                local p = prefix .. e.name
                if e.dir then
                    if e.cluster < 2 then return nil, "a folder on the drive is damaged" end
                    local ok, err = walk(e.cluster, p .. "/", depth + 1)
                    if not ok then return nil, err end
                else
                    files[#files + 1] = { path = p, size = e.size, cluster = e.cluster }
                end
            end
        end
        return true
    end
    local ok, err = walk(nil, "", 0)
    if not ok then return nil, err end
    return files, skipped
end

-- Copy one file out to `dest` (written as-is; the caller picks a temp name).
function Vol:extract(file, dest)
    local out, err = io.open(dest, "wb")
    if not out then return nil, err end
    local function fail(msg) out:close(); os.remove(dest); return nil, msg end
    if file.size > 0 then
        local need = math.ceil(file.size / self.csize)
        local ch = self:chain(file.cluster, need)
        if not ch or #ch < need then
            return fail("incomplete on the drive (was it ejected before unplugging?)")
        end
        local left = file.size
        local i = 1
        while left > 0 do
            -- Merge consecutive clusters into one read, up to 1 MiB.
            local first, n = ch[i], 1
            while ch[i + n] == first + n and n * self.csize < 1048576 do n = n + 1 end
            local len = math.min(n * self.csize, left)
            local data = readAt(self.f, self:clusterOffset(first), len)
            if not data then return fail("read error") end
            if not out:write(data) then return fail("write error (Kindle full?)") end
            left = left - len
            i = i + n
        end
    end
    if not out:close() then os.remove(dest); return nil, "write error (Kindle full?)" end
    return true
end

return Fat
