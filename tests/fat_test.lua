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

print("== drives formatted by someone else")
for _, case in ipairs({
    { "FAT32, no partition table", "mkfs.fat -F 32 -s 1 -C '%s' 66000", "" },
    { "FAT16, no partition table", "mkfs.fat -F 16 -C '%s' 32768", "" },
    { "FAT12, no partition table", "mkfs.fat -F 12 -C '%s' 12000", "" },
}) do
    local img = W .. "/other.img"
    os.remove(img)
    must(string.format(case[2], img))
    mcopyAll(img .. case[3])
    readBack(img, case[1])
    os.remove(img)
end

print("== a name outside Unicode's basic plane (emoji), as macOS/Windows/Linux write it")
do -- mtools can't write one, so write "Emoji XY.cbz" and turn X,Y into the UTF-16 pair for U+1F4DA
    local img = W .. "/emoji.img"
    must("mkfs.fat -F 16 -C '" .. img .. "' 32768")
    mkfile("e.cbz", 10, 8)
    must(string.format("mcopy -i '%s' '%s/src/e.cbz' '::Emoji XY.cbz'", img, W))
    local data = read(img)
    local i = data:find("X\0Y\0", 1, true)
    local h = io.open(img, "r+b"); h:seek("set", i - 1); h:write("\61\216\218\220"); h:close()
    local vol = Fat.open(img)
    local l = vol and vol:list()
    check(l and l[1] and l[1].path == "Emoji 📚.cbz", "decoded: " .. tostring(l and l[1] and l[1].path))
    vol:close()
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
