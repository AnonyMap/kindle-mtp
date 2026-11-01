local function note(s) print("  ["..s.."]") end
local tasks, shown = {}, {}
local UIManager = {}
function UIManager:scheduleIn(_, f) tasks[#tasks+1] = f end
function UIManager:nextTick(f) tasks[#tasks+1] = f end
function UIManager:unschedule(f) for i=#tasks,1,-1 do if tasks[i]==f then table.remove(tasks,i) end end end
function UIManager:show(w) shown[#shown+1]=w; note("show "..w.kind.." "..((w.text or w.title or ""):gsub("\n+"," | "):sub(1,140))) end
function UIManager:close(w) for i=#shown,1,-1 do if shown[i]==w then table.remove(shown,i) end end end
function UIManager:forceRePaint() end
function UIManager:flushSettings() end
local function runTasks(n) for _=1,(n or 1) do local t = tasks; tasks = {}; for _,f in ipairs(t) do f() end end end
local function widget(kind) return { new = function(_, o) o = o or {}; o.kind = kind; return o end } end
local settings = {}
G_reader_settings = { isTrue=function(_,k) return settings[k]==true end,
  flipNilOrFalse=function(_,k) settings[k] = not settings[k] end, saveSetting=function(_,k,v) settings[k]=v end }
local notes = {}
local exited = 0
local Device = { isKindle=function() return true end, exit=function() exited = exited + 1 end }
package.preload["device"] = function() return Device end
package.preload["ui/widget/confirmbox"] = function() return widget("ConfirmBox") end
package.preload["ui/widget/infomessage"] = function() return widget("InfoMessage") end
package.preload["ui/widget/textviewer"] = function() return widget("TextViewer") end
package.preload["ui/widget/notification"] = function() return { SOURCE_ALWAYS_SHOW=0x8000,
  notify=function(_, t) notes[#notes+1]=t; note("notify "..t) end } end
package.preload["dispatcher"] = function() return { registerAction=function() end } end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["logger"] = function() local n=function() end; return {info=n,warn=n,dbg=n,err=n} end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["libs/libkoreader-lfs"] = function() return {
  attributes=function(p, what)
    local f=io.open(p,"r"); if not f then return nil end; f:close()
    if what=="mode" then return "file" end
    local s=io.popen("stat -c '%s %Y' '"..p.."'"):read("*l"); local sz, mt = s:match("(%d+) (%d+)")
    return { mode="file", size=tonumber(sz), modification=tonumber(mt) } end,
  currentdir=function() return "/" end } end
package.preload["ui/widget/container/widgetcontainer"] = function()
  local WC = {}; function WC:extend(o) o = o or {}; setmetatable(o,{__index=self}); o.__index=o
    function o:new(i) i = i or {}; setmetatable(i, self); if i.init then i:init() end; return i end; return o end
  return WC end
-- Fake FileManager / ReaderUI
local refreshed = 0
package.loaded["apps/filemanager/filemanager"] = { instance = { onRefresh=function() refreshed = refreshed+1 end } }
local saved, homed = 0, 0
local ReaderUI = { instance = nil }
package.loaded["apps/reader/readerui"] = ReaderUI
local BOOK = "/tmp/kmtp-test/fake/book.epub"
local function openBook()
  os.execute("echo epubdata > "..BOOK)
  ReaderUI.instance = { document = { file = BOOK }, saveSettings=function() saved = saved+1 end,
    onHome=function() homed = homed+1; ReaderUI.instance = nil end }
end

local Plugin = dofile("/tmp/kmtp-test/plugin/usbmtp.koplugin/main.lua")
Plugin.path = "/tmp/kmtp-test/plugin/usbmtp.koplugin"
local menu_items = {}
local function mkui(doc) return { menu = { registerToMainMenu=function(_, p) p:addToMainMenu(menu_items) end }, document=doc } end
local function udc(s) local f=io.open("/sys/class/udc/ci_hdrc.0/state","w"); f:write(s.."\n"); f:close() end
local function fakeProcStat(state)
  local pid = io.open("/var/tmp/kmtp/umtprd.pid"):read("*l")
  os.execute("mkdir -p /proc/"..pid); local f=io.open("/proc/"..pid.."/stat","w"); f:write(pid.." (umtprd) "..state.." 1 1\n"); f:close() end
local function modules() local f=io.open("/proc/modules"); local s=f:read("*a"); f:close(); return (s:gsub(" [^\n]*",""):gsub("\n"," ")) end
local function top() return shown[#shown] end
local pass, fail = 0, 0
local function check(c, m) if c then pass=pass+1 else fail=fail+1 end; print((c and "PASS " or "FAIL ")..m) end
local function startNow() menu_items.usbmtp.sub_item_table[1].callback(); fakeProcStat("S") end
local Ctl = Plugin._controller

print("== A. start from inside a book")
openBook(); udc("not attached")
local rp = Plugin:new{ ui = mkui(ReaderUI.instance.document) }
startNow()
check(saved == 1, "book's settings saved before sharing")
check(top().kind=="ConfirmBox" and top().dismissable==false and top().ok_text=="Hide" and top().cancel_text=="Stop", "dialog with Hide + Stop")
check(modules():find("usb_f_fs") ~= nil, "MTP gadget up")

print("== B. Hide, then computer connects")
local d = top(); UIManager:close(d); d.ok_callback()
check(Ctl.hidden and Ctl.dialog == nil, "dialog hidden, still active")
check(notes[#notes]:find("still on"), "told how to stop later")
udc("configured"); runTasks()
check(notes[#notes]:find("Computer connected"), "connection shown as notification while hidden")
check(Ctl.dialog == nil and not (top() and top().kind=="ConfirmBox"), "dialog not forced back while hidden")

print("== C. computer overwrites the open book")
os.execute("echo 'newer version of the book' >> "..BOOK); runTasks(); runTasks()
check(homed == 1 and ReaderUI.instance == nil, "book closed back to file browser")
check(top().kind=="InfoMessage" and top().text:find("changed from the computer"), "explained why")
check(Ctl.active, "transfer keeps running")

print("== D. book opened during transfer, then deleted while dialog showing")
openBook()
local rp2 = Plugin:new{ ui = mkui(ReaderUI.instance.document) }
rp2:onReaderReady(); runTasks()       -- hidden -> stays hidden
check(Ctl.dialog == nil, "opening a book while hidden doesn't nag")
menu_items.usbmtp.sub_item_table[1].callback()   -- "Show transfer / Stop"
check(top().kind=="ConfirmBox" and Ctl.dialog ~= nil, "menu re-shows dialog")
os.remove(BOOK); runTasks(); runTasks()
check(homed == 2, "deleted book closed")
check(Ctl.dialog ~= nil, "dialog restored on top of file browser")
check(shown[#shown].kind=="InfoMessage" and shown[#shown].text:find("deleted"), "explained deletion")

print("== E. unplug from inside a book auto-stops")
openBook(); Ctl:rememberOpenBook(); udc("not attached"); runTasks(); runTasks()
check(not Ctl.active and modules():find("g_mass_storage"), "stopped, stock driver back")
check(ReaderUI.instance ~= nil, "book left open")

print("== F. KOReader exits while sharing (from a book)")
startNow(); Device.exit(Device)
check(exited == 1 and not Ctl.active and modules():find("g_mass_storage") and not modules():find("usb_f_fs"), "stopped on exit, then real exit ran")

print("== G. prompt on plug-in from inside a book")
settings.usbmtp_prompt_on_plug = true; udc("not attached"); rp2:onCharging(); runTasks(2); udc("configured"); runTasks()
check(top().kind=="ConfirmBox" and top().text:find("Computer detected"), "offered from inside the book")
top().ok_callback(); fakeProcStat("S")
check(Ctl.active, "started from the prompt")
Ctl:stop()

print("== H. charger is ignored")
udc("powered"); local n = #shown; rp2:onCharging(); runTasks(20)
check(#shown == n, "no prompt")

print("== I. daemon death / sleep / start failure")
startNow(); fakeProcStat("Z"); runTasks()
check(top().text:find("stopped unexpectedly") and not Ctl.active, "daemon death handled")
startNow(); rp2:onSuspend(); check(not Ctl.active, "stopped on sleep")
rp2:onResume(); runTasks(); check(top().text:find("went to sleep"), "told after wake")
os.execute("touch /tmp/kmtp-test/fake/umtprd_fail"); Ctl:start()
check(top().text:find("Could not start") and top().text:find("umtprd exited"), "start failure explained")
check(modules():find("g_mass_storage"), "rolled back")
os.remove("/tmp/kmtp-test/fake/umtprd_fail")

print("== J. crash recovery")
os.execute("mkdir -p /var/tmp/kmtp && echo STARTED=1 > /var/tmp/kmtp/state")
local P2 = dofile("/tmp/kmtp-test/plugin/usbmtp.koplugin/main.lua"); P2.path = Plugin.path
P2:new{ ui = mkui(nil) }; runTasks()
check(top().text:find("left running"), "offers cleanup")
top().ok_callback(); check(top().text:find("Safe to unplug"), "cleanup ran")

print("== K. stock driver can't be restored after a failed start")
os.execute("touch /tmp/kmtp-test/fake/umtprd_fail /tmp/kmtp-test/fake/fail_insmod_g_mass_storage")
Ctl:start()
check(top().text:find("umtprd exited during startup") and top().text:find("could not be restored"), "says the real cause AND that a reboot is needed")
os.remove("/tmp/kmtp-test/fake/umtprd_fail")
print("== L. retry after restore failure keeps working")
local P3 = dofile("/tmp/kmtp-test/plugin/usbmtp.koplugin/main.lua"); P3.path = Plugin.path
P3:new{ ui = mkui(nil) }; runTasks()
check(top().text:find("left running"), "state kept, so cleanup is offered again")
os.remove("/tmp/kmtp-test/fake/fail_insmod_g_mass_storage")
top().ok_callback()
check(top().text:find("Safe to unplug") and modules():find("g_mass_storage"), "retry restored stock USB")
print(string.format("\n%d passed, %d failed", pass, fail))
