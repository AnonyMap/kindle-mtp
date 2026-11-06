-- usbmtp_fat against real tools: our images must pass fsck.fat and take files
-- from mtools (which writes long names the way operating systems do); and we
-- must read back what mtools / mkfs.fat wrote, byte for byte.
--   luajit tests/fat_test.lua      (needs mtools and dosfstools)
local REPO = (arg[0]:match("^(.*)/tests/[^/]+$")) or "."
package.path = REPO .. "/usbmtp.koplugin/?.lua;" .. package.path
local Fat = require("usbmtp_fat")

local pass, fail = 0, 0
local function check(cond, what)
    if cond then pass = pass + 1; print("PASS " .. what)
    else fail = fail + 1; print("FAIL " .. what) end
end
local W = os.tmpname() .. ".fat"
local function sh(cmd)
    local p = io.popen("export LANG=C.UTF-8 MTOOLS_SKIP_CHECK=1; " .. cmd .. " 2>&1; echo \"rc=$?\"")
    local out = p:read("*a"); p:close()
    return out:match("rc=0%s*$") ~= nil, out
end
local function must(cmd) local ok, out = sh(cmd); assert(ok, cmd .. "\n" .. out); return out end
local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
must("rm -rf '" .. W .. "' && mkdir -p '" .. W .. "/src/Sci-Fi/Asimov'")

-- Source files: long Unicode names, nested folders, several sizes.
local function mkfile(rel, size, seed)
    local t, x = {}, seed
    for i = 1, size do x = (x * 1103515245 + 12345) % 2147483648; t[i] = string.char(x % 256) end
    local f = assert(io.open(W .. "/src/" .. rel, "wb")); f:write(table.concat(t)); f:close()
end
mkfile("Dune – Frank Herbert.epub", 3 * 1024 * 1024 + 17, 1)        -- multi-cluster, en dash
mkfile("Sci-Fi/Asimov/Foundation (1951) a very long title indeed to pass seventy-two characters.epub", 70000, 2)
mkfile("short.txt", 12, 3)
mkfile("empty.pdf", 0, 4)
mkfile("日本語の本.epub", 5000, 5)                                   -- CJK
mkfile("._Dune.epub", 100, 7)                                       -- macOS AppleDouble junk
local wanted = { "Dune – Frank Herbert.epub",
    "Sci-Fi/Asimov/Foundation (1951) a very long title indeed to pass seventy-two characters.epub",
    "short.txt", "empty.pdf", "日本語の本.epub" }

local function byPath(list) local m = {}; for _, f in ipairs(list or {}) do m[f.path] = f end; return m end
local function readBack(img, label)
    local vol, err = Fat.open(img)
    check(vol, label .. ": opens (" .. tostring(err) .. ")")
    if not vol then return end
    local list, lerr = vol:list()
    check(list, label .. ": lists (" .. tostring(lerr) .. ")")
    local m = byPath(list)
    local all = true
    for _, rel in ipairs(wanted) do
        local f = m[rel]
        local dest = W .. "/out"
        local ok = f and vol:extract(f, dest)
        if not (ok and read(dest) == read(W .. "/src/" .. rel)) then
            all = false; print("    mismatch: " .. rel .. (f and "" or " (not listed)"))
        end
    end
    check(all, label .. ": every file comes back byte for byte, names intact")
    check(not m["._Dune.epub"] and not m[".Trashes/junk"], label .. ": dot-files and .Trashes skipped")
    vol:close()
    return list
end
local function mcopyAll(target)
    must("mmd -i " .. target .. " ::Sci-Fi ::Sci-Fi/Asimov ::.Trashes")
    for _, rel in ipairs(wanted) do
        must(string.format("mcopy -i %s '%s/src/%s' '::%s'", target, W, rel, rel))
    end
    must(string.format("mcopy -i %s '%s/src/._Dune.epub' '::._Dune.epub'", target, W))
    must(string.format("mcopy -i %s '%s/src/short.txt' '::.Trashes/junk'", target, W))
end

print("== our format")
for _, mb in ipairs({ 16, 256, 2048 }) do
    local img = W .. "/d" .. mb .. ".img"
    must(string.format("truncate -s %dM '%s'", mb, img))
    check(Fat.format(img), mb .. " MB: formats")
    must(string.format("dd if='%s' of='%s.part' bs=1M skip=1 2>/dev/null", img, img))
    local ok, out = sh(string.format("fsck.fat -n '%s.part'", img))
    check(ok, mb .. " MB: fsck.fat finds a clean filesystem")
    if not ok then print(out) end
    local _, lab = sh("mlabel -i " .. img .. "@@1M -s ::")
    check(lab:find("TO KINDLE"), mb .. " MB: named TO KINDLE")
    os.remove(img .. ".part")
    if mb == 256 then
        check(read(img):sub(447 + 4, 447 + 4) == "\14", "partition type FAT16 (LBA)")
        mcopyAll(img .. "@@1M")
        must(string.format("dd if='%s' of='%s.part' bs=1M skip=1 2>/dev/null", img, img))
        check(sh(string.format("fsck.fat -n '%s.part'", img)), "still clean after mtools wrote into it")
        os.remove(img .. ".part")
        readBack(img, "256 MB, written by mtools")

        -- Fragmented file: free a hole, then write a file bigger than it.
        must("mdel -i " .. img .. "@@1M ::short.txt")
        mkfile("frag.epub", 2 * 1024 * 1024, 9)
        must(string.format("mcopy -i %s@@1M '%s/src/frag.epub' ::frag.epub", img, W))
        local vol = Fat.open(img)
        local f = byPath(vol:list())["frag.epub"]
        check(f and vol:extract(f, W .. "/out") and read(W .. "/out") == read(W .. "/src/frag.epub"),
              "a fragmented file comes back intact")

        -- A file whose cluster chain is cut short (unplugged mid-copy): refused, not truncated.
        local d = byPath(vol:list())["Dune – Frank Herbert.epub"]
        local fat_off = vol.base + 4 * 512 -- reserved = 4 sectors
        vol:close()
        local h = io.open(img, "r+b"); h:seek("set", fat_off + 2 * d.cluster); h:write("\255\255"); h:close()
        vol = Fat.open(img)
        local ok2, err = vol:extract(byPath(vol:list())["Dune – Frank Herbert.epub"], W .. "/out")
        check(not ok2 and err:find("incomplete"), "a cut-short file is refused (" .. tostring(err) .. ")")
        check(io.open(W .. "/out") == nil, "and no partial copy is left behind")
        vol:close()

        -- Wiping = formatting again.
        check(Fat.format(img), "re-format")
        vol = Fat.open(img)
        local l = vol:list()
        check(l and #l == 0, "wiped: nothing listed")
        vol:close()
        local _, lab = sh("mlabel -i " .. img .. "@@1M -s ::")
        check(lab:find("TO KINDLE"), "label kept")
    end
    os.remove(img)
end

local function ourImage(name, mb)
    local img = W .. "/" .. name
    os.remove(img)
    must(string.format("truncate -s %dM '%s'", mb or 64, img))
    assert(Fat.format(img))
    return img
end

print("== a drive the computer reformatted is reported, never misread as empty")
for _, case in ipairs({
    { "as FAT32 in the same partition", "mkfs.fat -F 32 -s 1 --offset 2048 '%s' >/dev/null" },
    { "as FAT16 with no partition table", "mkfs.fat -F 16 '%s' >/dev/null" },
}) do
    local img = ourImage("re.img")
    must(string.format(case[2], img))
    local vol, err = Fat.open(img)
    check(not vol and err:find("reformatted"), case[1] .. " (" .. tostring(err) .. ")")
    os.remove(img)
end

print("== a name outside Unicode's basic plane (emoji), as macOS/Windows/Linux write it")
do -- mtools can't write one, so write "Emoji XY.cbz" and turn X,Y into the UTF-16 pair for U+1F4DA
    local img = ourImage("emoji.img")
    mkfile("e.cbz", 10, 8)
    must(string.format("mcopy -i '%s@@1M' '%s/src/e.cbz' '::Emoji XY.cbz'", img, W))
    local data = read(img)
    local i = data:find("X\0Y\0", 1, true)
    local h = io.open(img, "r+b"); h:seek("set", i - 1); h:write("\61\216\218\220"); h:close()
    local vol = Fat.open(img)
    local l = vol and vol:list()
    check(l and l[1] and l[1].path == "Emoji 📚.cbz", "decoded: " .. tostring(l and l[1] and l[1].path))
    vol:close()
    os.remove(img)
end

print("== not ejected (dirty)")
do
    local img = ourImage("dirty.img")
    local vol = Fat.open(img); check(not vol:dirty(), "freshly formatted: clean"); vol:close()
    local h = io.open(img, "r+b"); h:seek("set", 1024 * 1024 + 4 * 512 + 3); h:write("\127"); h:close()
    vol = Fat.open(img); check(vol:dirty(), "clean bit in FAT[1] cleared (Windows/macOS while mounted): dirty"); vol:close()
    h = io.open(img, "r+b"); h:seek("set", 1024 * 1024 + 4 * 512 + 3); h:write("\255"); h:seek("set", 1024 * 1024 + 37); h:write("\1"); h:close()
    vol = Fat.open(img); check(vol:dirty(), "Linux's in-use flag in the boot sector: dirty"); vol:close()
    os.remove(img)
end

print("== malformed drives (the image is untrusted input)")
do
    local img = ourImage("evil.img")
    must(string.format("mmd -i '%s@@1M' ::Loop", img))
    mkfile("x.epub", 70000, 12)
    must(string.format("mcopy -i '%s@@1M' '%s/src/x.epub' ::Loop/x.epub", img, W))
    local vol = Fat.open(img)
    local dir
    for _, e in ipairs(vol:entries(nil)) do if e.name == "Loop" then dir = e.cluster end end
    local fat_off = vol.base + 4 * 512
    vol:close()
    -- The folder's cluster points back to itself.
    local h = io.open(img, "r+b"); h:seek("set", fat_off + 2 * dir); h:write(string.char(dir % 256, math.floor(dir / 256))); h:close()
    local t0 = os.clock()
    vol = Fat.open(img)
    local ok = pcall(function() return vol:list() end)
    check(ok and os.clock() - t0 < 5, "a folder chain that loops ends quickly")
    vol:close()
    -- Far more sectors than FAT16 can have: refused.
    h = io.open(img, "r+b"); h:seek("set", 1024 * 1024 + 32); h:write("\0\0\240\0"); h:close() -- 15.7M sectors
    local v2, err = Fat.open(img)
    check(not v2 and err:find("reformatted"), "absurd sector count refused")
    -- A boot sector claiming more than the image file holds: clamped to the file.
    os.remove(img); img = ourImage("evil.img"); must("truncate -s 8M '" .. img .. "'")
    vol = Fat.open(img)
    check(vol and vol.clusters < 8 * 1024, "cluster count clamped to the 8 MB file, not the 64 MB claimed (" .. tostring(vol and vol.clusters) .. ")")
    if vol then vol:close() end
    os.remove(img)
end

print("== not FAT")
local img = W .. "/x.img"
must("truncate -s 32M '" .. img .. "'")
local h = io.open(img, "r+b"); h:write("\235\118\144EXFAT   " .. string.rep("\0", 499) .. "\85\170"); h:close()
local v, err = Fat.open(img)
check(not v and err and err:find("reformatted"), "exFAT (or anything else) is reported, not misread")
must("truncate -s 0 '" .. img .. "' && truncate -s 32M '" .. img .. "'")
v, err = Fat.open(img)
check(not v and err, "blank image is reported")
check(not Fat.format(W .. "/missing.img"), "format refuses a missing file")

must("rm -rf '" .. W .. "'")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
