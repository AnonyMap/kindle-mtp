local function note(s) print("  ["..s.."]") end
local tasks, shown = {}, {}
local UIManager = {}
function UIManager:scheduleIn(_, f) tasks[#tasks+1] = f end
function UIManager:nextTick(f) tasks[#tasks+1] = f end
function UIManager:unschedule(f) for i=#tasks,1,-1 do if tasks[i]==f then table.remove(tasks,i) end end end
function UIManager:show(w) shown[#shown+1]=w; note("show "..w.kind.." "..((w.text or w.title or ""):gsub("\n+"," | "):sub(1,140))) end
function UIManager:close(w) for i=#shown,1,-1 do if shown[i]==w then table.remove(shown,i) end end end
function UIManager:forceRePaint() end
function UIManager:askForRestart(msg) UIManager.restart_msg = msg end
function UIManager:restartKOReader() UIManager.restarted = true end
function UIManager:flushSettings() local R = package.loaded["apps/reader/readerui"]; if R and R.instance then R.instance:saveSettings() end end
function UIManager:getTopmostVisibleWidget() return shown[#shown] end
local function runTasks(n) for _=1,(n or 1) do local t = tasks; tasks = {}; for _,f in ipairs(t) do f() end end end
local function widget(kind) return { new = function(_, o) o = o or {}; o.kind = kind; return o end } end
local settings = {}
G_reader_settings = { isTrue=function(_,k) return settings[k]==true end,
  flipNilOrFalse=function(_,k) settings[k] = not settings[k] end, saveSetting=function(_,k,v) settings[k]=v end,
  readSetting=function(_,k) return settings[k] end,
  nilOrTrue=function(_,k) return settings[k] == nil or settings[k] == true end,
  flipNilOrTrue=function(_,k) if settings[k] == nil or settings[k] == true then settings[k] = false else settings[k] = nil end end }
local broadcasts = {}
function UIManager:broadcastEvent(ev) broadcasts[#broadcasts+1] = ev.name end
local notes = {}
local exited = 0
local Device = { isKindle=function() return true end, exit=function() exited = exited + 1 end }
package.preload["device"] = function() return Device end
package.preload["ui/widget/confirmbox"] = function() return widget("ConfirmBox") end
package.preload["ui/widget/infomessage"] = function() return widget("InfoMessage") end
package.preload["ui/widget/textviewer"] = function() return widget("TextViewer") end
package.preload["ui/widget/notification"] = function() return { SOURCE_ALWAYS_SHOW=0x8000,
  notify=function(_, t) notes[#notes+1]=t; note("notify "..t) end } end
package.preload["ui/event"] = function() return { new=function(_, name) return { name=name } end } end
package.preload["ffi/posix_h"] = function() require("ffi").cdef("int getpid(void);"); return true end
package.preload["dispatcher"] = function() return { registerAction=function() end } end
package.preload["datastorage"] = function() return { getDataDir=function() return "/tmp/kmtp-test/fake/koreader" end } end
local wifi_off_calls = 0
package.preload["ui/network/manager"] = function() return { runWhenOnline=function(_, cb) cb() end,
  afterWifiAction=function() wifi_off_calls = wifi_off_calls + 1 end } end
package.preload["ffi/util"] = function() return { template=function(fmt, ...) local a = {...}; return (fmt:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end } end
-- Stand-in updater: scripted results, records calls
local FakeUpdater = { calls = {} }
function FakeUpdater.check(cur) FakeUpdater.calls[#FakeUpdater.calls+1] = "check "..cur; return FakeUpdater.next_check, FakeUpdater.next_err end
function FakeUpdater.install(info, root) FakeUpdater.calls[#FakeUpdater.calls+1] = "install "..info.version.." "..root; return FakeUpdater.next_install, FakeUpdater.next_install_err end
package.preload["usbmtp_updater"] = function()
  -- Real helpers, scripted network/install.
  local real = dofile("/tmp/kmtp-test/plugin/usbmtp.koplugin/usbmtp_updater.lua")
  FakeUpdater.shortNotes = real.shortNotes
  FakeUpdater.cleanupAfterUpdate = function() end
  return FakeUpdater
end
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
  local r
  r = { kind="ReaderUI", document = { file = BOOK }, saveSettings=function() saved = saved+1 end,
    handleEvent=function() end,
    onHome=function() homed = homed+1; UIManager:close(r); ReaderUI.instance = nil end }
  ReaderUI.instance = r
  table.insert(shown, 1, r)   -- the reader sits at the bottom of the window stack
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
local V = (io.open("/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp/VERSION"):read("*l"):gsub("%s", ""))
local NEXT = (function() local a, b = V:match("^(%d+)%.(%d+)"); return a .. "." .. (tonumber(b) + 1) end)()
local function esc(x) return (x:gsub("%p", "%%%0")) end

print("== A. start from inside a book")
openBook(); udc("not attached")
local rp = Plugin:new{ ui = mkui(ReaderUI.instance.document) }
startNow()
check(saved == 1, "book's settings saved exactly once before sharing")
check(top().flush_events_on_show == true, "taps made during start are flushed")
check(top().kind=="ConfirmBox" and top().dismissable==false and top().ok_text=="Hide" and top().cancel_text=="Stop", "dialog with Hide + Stop")
check(modules():find("usb_f_fs") ~= nil, "MTP gadget up")

local wp = io.open("/var/tmp/kmtp/watcher.pid"); check(wp ~= nil, "crash watcher started with KOReader's pid"); if wp then wp:close() end

local about
for _, it in ipairs(menu_items.usbmtp.sub_item_table) do
  if it.text_func and it.text_func():find("^About") then about = it end
end
check(about and about.text_func() == "About (v" .. V .. ")", "About shows the installed version")

print("== B. Hide, then computer connects")
local d = top(); UIManager:close(d); d.ok_callback()
check(Ctl.hidden and Ctl.dialog == nil, "dialog hidden, still active")
check(notes[#notes]:find("still on"), "told how to stop later")
udc("configured"); runTasks()
check(notes[#notes]:find("Computer connected"), "connection shown as notification while hidden")
check(Ctl.dialog == nil and not (top() and top().kind=="ConfirmBox"), "dialog not forced back while hidden")

print("== C. computer overwrites the open book (with a dictionary popup open)")
local popup = { kind="DictQuickLookup", text="popup" }; UIManager:show(popup)
os.execute("echo 'newer version of the book' >> "..BOOK); runTasks(); runTasks()
check(homed == 1 and ReaderUI.instance == nil, "book closed back to file browser")
local still = false; for _, w in ipairs(shown) do if w == popup then still = true end end
check(not still, "popup above the reader closed before the book")
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

print("== E0. computer goes to sleep / re-enumerates: keep going")
udc("suspended"); runTasks(); runTasks(); runTasks()
udc("addressed"); runTasks(); runTasks()
check(Ctl.active, "suspended/addressed states don't count as unplug")
udc("configured"); runTasks()

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
print("== M. check for updates")
local function menuItem(label)
  for _, it in ipairs(menu_items.usbmtp.sub_item_table) do
    local t = it.text or (it.text_func and it.text_func())
    if t == label then return it end
  end
end
local upd = menuItem("Check for updates")
check(upd ~= nil, "menu has Check for updates")
-- Scenarios J/L reloaded the plugin module; the menu now belongs to the newest copy.
local CtlM = P3._controller
startNow(); FakeUpdater.calls = {}
upd.callback()
check(#FakeUpdater.calls == 0 and top().text:find("Stop the USB file transfer first"), "refuses while a transfer is running")
CtlM:stop()
os.execute("mkdir -p /var/tmp/kmtp && echo STARTED=1 > /var/tmp/kmtp/state")
upd.callback()
check(top().text:find("Stop the USB file transfer first"), "refuses while a session it didn't start is running")
os.remove("/var/tmp/kmtp/state")
FakeUpdater.next_check = { newer = false, version = V }
local w0 = wifi_off_calls
upd.callback()
check(top().text:find("You have the latest version %(v" .. esc(V) .. "%)"), "says up to date")
check(wifi_off_calls == w0 + 1, "hands Wi-Fi back (user's after-Wi-Fi setting)")
FakeUpdater.next_check, FakeUpdater.next_err = nil, "Could not reach GitHub: timeout"
upd.callback()
check(top().text:find("Could not reach GitHub"), "shows network errors")
FakeUpdater.next_check = { newer = true, version = NEXT, notes = "Faster stop." }
upd.callback()
check(top().kind == "ConfirmBox" and top().text:find("Version " .. esc(NEXT) .. " is available %(you have " .. esc(V) .. "%)") and top().text:find("Faster stop."), "offers the update with notes")
check(top().flush_events_on_show == true, "taps made while checking can't press Install")
FakeUpdater.next_install, FakeUpdater.next_install_err = nil, "Checksum mismatch (download corrupted?). Nothing was changed."
top().ok_callback()
check(top().text:find("Update failed.") and top().text:find("Checksum mismatch"), "explains a failed install")
check(not CtlM.update_pending, "a failed install doesn't lock anything")
upd.callback()
FakeUpdater.next_install = true
top().ok_callback()
check(FakeUpdater.calls[#FakeUpdater.calls]:find("^install " .. esc(NEXT) .. " .*/usbmtp.koplugin$"), "installs into the plugin folder")
check(top().kind == "ConfirmBox" and top().text:find("Updated to v" .. esc(NEXT)) and top().flush_events_on_show, "offers a restart (taps flushed)")
top().cancel_callback = top().cancel_callback or function() end
UIManager:close(top()) -- "Later"
menuItem("Start USB file transfer").callback()
check(not CtlM.active and top().text:find("Restart KOReader to finish updating"), "Start waits for the restart (old code + new scripts never mix)")
upd.callback()
check(top().text:find("Updated to v"), "Check for updates offers the restart again instead of re-downloading")
top().ok_callback()
check(UIManager.restarted, "Restart now restarts KOReader")
CtlM.update_pending = nil

print("== N. what happens when plugged into a computer")
CtlM = P3._controller
CtlM.active = false
settings.usbmtp_on_plug = nil; settings.usbmtp_prompt_on_plug = true
local plugItem
for _, it in ipairs(menu_items.usbmtp.sub_item_table) do
  if it.text_func and it.text_func():find("^When plugged into a computer") then plugItem = it end
end
check(plugItem and plugItem.text_func():find("ask first"), "old 'ask' setting carries over")
settings.usbmtp_on_plug = "auto"; udc("not attached")
P3:new{ ui = mkui(nil) }  -- an instance to receive the event
CtlM:onCharging(); runTasks(2); udc("configured"); runTasks()
check(CtlM.active and top().kind == "ConfirmBox" and top().cancel_text == "Stop", "auto: starts with no prompt")
fakeProcStat("S"); CtlM:stop()
settings.usbmtp_on_plug = "off"; udc("not attached"); local n0 = #shown
CtlM:onCharging(); runTasks(2); udc("configured"); runTasks(20)
check(not CtlM.active and #shown == n0, "off: does nothing")
settings.usbmtp_on_plug = nil; settings.usbmtp_prompt_on_plug = nil

print("== O. new books are listed after Stop")
os.execute("mkdir -p /mnt/base-us/documents/Old.sdr && echo old > /mnt/base-us/documents/Old.epub && touch -d '2 days ago' /mnt/base-us/documents/Old.epub")
local O = menuItem("Start USB file transfer"); O.callback(); fakeProcStat("S")
os.execute("sleep 1; mkdir -p '/mnt/base-us/documents/Sci-Fi' && echo new > '/mnt/base-us/documents/Sci-Fi/Dune - Frank Herbert.epub'"
  .. " && echo meta > /mnt/base-us/documents/Old.sdr/metadata.epub.lua && echo x > /mnt/base-us/documents/.hidden")
local d = top(); UIManager:close(d); d.cancel_callback()
check(top().text:find("1 new file%(s%) on the Kindle") and top().text:find("Dune %- Frank Herbert.epub"), "lists the new book")
check(not top().text:find("Old.epub") and not top().text:find("metadata") and not top().text:find("hidden"), "skips old books, .sdr metadata and dot-files")
check(top().timeout == nil, "list stays up until dismissed")
local rf = io.open("/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp/received.txt"):read("*a")
check(rf:find("^/mnt/us/documents/Sci%-Fi/Dune"), "paths given as /mnt/us (what KOReader uses)")
O.callback(); fakeProcStat("S"); d = top(); UIManager:close(d); d.cancel_callback()
check(top().text:find("Safe to unplug") and not top().text:find("new file") and top().timeout == 4, "nothing new: plain message that times out")

print("== P. status-bar marker while sharing")
local footer_items = {}
local footer = { addAdditionalFooterContent=function(_, f) footer_items[#footer_items+1] = f end,
  removeAdditionalFooterContent=function(_, f) for i=#footer_items,1,-1 do if footer_items[i]==f then table.remove(footer_items,i) end end end }
openBook()
local readerP = P3:new{ ui = { menu = { registerToMainMenu=function() end }, document = ReaderUI.instance.document, view = { footer = footer } } }
readerP:onReaderReady()
check(#footer_items == 0, "no marker when not sharing")
O.callback(); fakeProcStat("S")
check(#footer_items == 1 and footer_items[1]() == "ᴍᴛᴘ", "marker shown while sharing")
d = top(); UIManager:close(d); d.cancel_callback()
check(#footer_items == 0, "marker removed after Stop (footer settings restored)")
settings.usbmtp_footer = false
O.callback(); fakeProcStat("S")
check(#footer_items == 0, "opt-out respected")
CtlM:stop(); settings.usbmtp_footer = nil
readerP:onCloseWidget()
check(CtlM.reader_plugin == nil, "reader closing clears its reference")

print("== Q. cable in but no computer ever connected, then unplugged")
O.callback(); fakeProcStat("S")
udc("powered"); runTasks()          -- a cable (charger, or a Mac with no MTP app)
check(CtlM.active, "keeps waiting while the cable is in")
udc("not attached"); runTasks(); runTasks()
check(not CtlM.active and top().text:find("cable was unplugged"), "stops when it's pulled, so the Kindle can sleep")

print("== R. nothing connects for 10 minutes")
O.callback(); fakeProcStat("S")
CtlM.started_at = os.time() - 601; runTasks()
check(not CtlM.active and top().text:find("No computer connected within 10 minutes"), "gives up after 10 minutes")

print("== S. stopping during sleep fails: reported on wake")
O.callback(); fakeProcStat("S")
os.execute("touch /tmp/kmtp-test/fake/fail_insmod_g_mass_storage")
local readerS = P3:new{ ui = mkui(nil) }
readerS:onSuspend()
os.remove("/tmp/kmtp-test/fake/fail_insmod_g_mass_storage")
readerS:onResume(); runTasks()
check(top().text:find("went to sleep") and top().text:find("Stock USB was not restored"), "tells the user stock USB needs a reboot")
check(top().timeout == nil, "and that message stays up")
P3._controller:stop() -- clean up (retries the restore)

print(string.format("\n%d passed, %d failed", pass, fail))
