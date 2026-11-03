--[[--
USB file transfer (MTP) for Kindle.

Swaps the Kindle's stock USB mass-storage gadget for an MTP gadget (FunctionFS +
uMTP-Responder) so a computer can copy books while KOReader keeps running.
All the system work is done by the bundled, separately tested shell scripts in ./mtp;
this file is the UI and the safety rails around them.

Works from the file browser (any view: list, mosaic/bookshelf, history...) and from
inside a book. One session is shared by every plugin instance, so it survives
opening and closing books.

@module koplugin.usbmtp
]]

local Device = require("device")

if not Device:isKindle() then
    return { disabled = true }
end

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local PluginShare = require("pluginshare")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
-- Distinct module name: package.loaded is shared by every plugin, so a generic
-- name like "updater" could collide with another plugin's module.
local Updater = require("usbmtp_updater")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ffi = require("ffi")
require("ffi/posix_h")
local KOREADER_PID = ffi.C.getpid()

local STATE_FILE = "/var/tmp/kmtp/state"
local PID_FILE = "/var/tmp/kmtp/umtprd.pid"
local UDC_STATE = "/sys/class/udc/ci_hdrc.0/state"
local POLL_SECS = 2
local NO_HOST_TIMEOUT = 600 -- seconds without a computer before giving up (keeps the Kindle from never sleeping)
local REPLUG_QUIET_SECS = 30 -- after a Stop, the computer re-enumerating the Kindle isn't a new plug-in
local MAX_OPEN_BUTTONS = 5

local function readFirstLine(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    return line
end

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function udcState()
    return readFirstLine(UDC_STATE) or "unknown"
end

local function daemonAlive()
    local pid = tonumber(readFirstLine(PID_FILE) or "")
    if not pid then return false end
    local stat = readFirstLine("/proc/" .. pid .. "/stat")
    if not stat then return false end
    local st = stat:match("^%d+ %b() (%a)") -- 3rd field: process state, Z = zombie
    return st ~= nil and st ~= "Z"
end

local function notify(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

-- The currently open book, if any (nil in the file browser)
local function openReader()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local r = ReaderUI and ReaderUI.instance
    if r and r.document and r.document.file then return r end
end

local function bookStamp(file)
    local a = lfs.attributes(file)
    if not a then return nil end
    return string.format("%s:%s", tostring(a.size), tostring(a.modification))
end

---------------------------------------------------------------------------
-- Controller: one per KOReader process
---------------------------------------------------------------------------

local Ctl = {
    mtp_dir = nil,
    active = false,       -- a session we started in this run
    dialog = nil,         -- the transfer dialog, when visible
    hidden = false,       -- user chose to keep reading/browsing
    connected = false,    -- host has configured the gadget at least once
    lost_polls = 0,
    book = nil,           -- { file = ..., stamp = ... } for the open book
    stopped_by_sleep = false,
    prev_pause_auto_suspend = nil,
    stale_checked = false,
    exit_hooked = false,
    plug_armed = nil,     -- the cable has been out since the last plug-in we acted on
    stopped_at = nil,
}

function Ctl:runScript(script, env)
    local cmd = string.format("%ssh '%s/%s' >/dev/null 2>&1", env or "", self.mtp_dir, script)
    logger.info("usbmtp: running", cmd)
    local rc = os.execute(cmd)
    logger.info("usbmtp:", script, "returned", rc)
    return rc == 0
end

-- What the most recent script run said: its first "ERROR: ..." line (the cause),
-- and whether the stock USB driver failed to come back.
function Ctl:lastRunResult()
    local f = io.open(self.mtp_dir .. "/mtp.log", "r")
    if not f then return nil, false end
    local err, not_restored
    for line in f:lines() do
        if line:find("=== usbmtp ", 1, true) then
            err, not_restored = nil, false -- a new run starts here
        else
            local e = line:match("ERROR: (.*)$")
            if e and not err then err = e end
            if line:find("not restored", 1, true) or line:find("could not reload the stock USB", 1, true) then
                not_restored = true
            end
        end
    end
    f:close()
    return err, not_restored
end

local function showBusy(text)
    local msg = InfoMessage:new{ text = text, dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

function Ctl:keepAwake(on)
    if on then
        self.prev_pause_auto_suspend = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1 >/dev/null 2>&1")
    else
        PluginShare.pause_auto_suspend = self.prev_pause_auto_suspend
        if not PluginShare.keepalive then -- don't undo the KeepAlive plugin's choice
            os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0 >/dev/null 2>&1")
        end
    end
end

-- Stop MTP on any exit/restart, whatever screen we're on.
function Ctl:hookExit()
    if self.exit_hooked then return end
    self.exit_hooked = true
    local orig_exit = Device.exit
    Device.exit = function(...)
        if Ctl.active then
            logger.info("usbmtp: KOReader exiting, stopping MTP")
            Ctl:stop(nil, true)
        end
        return orig_exit(...)
    end
end

function Ctl:rememberOpenBook(file)
    if not file then
        local r = openReader()
        file = r and r.document.file
    end
    self.book = file and { file = file, stamp = bookStamp(file) } or nil
end

function Ctl:start()
    if self.active then
        self:showDialog()
        return
    end
    if self.update_pending then
        UIManager:show(InfoMessage:new{
            text = T(_("Restart KOReader to finish updating to v%1 first."), self.update_pending),
        })
        return
    end
    if fileExists(STATE_FILE) then
        self:offerStaleCleanup()
        return
    end

    -- Get everything KOReader holds in memory onto disk before the computer looks.
    -- (FlushSettings also makes an open ReaderUI save the book's settings.)
    UIManager:flushSettings()

    local busy = showBusy(_("Starting USB file transfer…"))
    -- The scripts' crash watcher stops MTP if this process dies without doing it.
    local ok = self:runScript("mtp-start.sh", string.format("KMTP_WATCH_PID=%d ", KOREADER_PID))
    UIManager:close(busy)

    if not ok then
        local err, not_restored = self:lastRunResult()
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not start USB file transfer.") .. "\n\n" ..
                   (err or _("Unknown error.")) .. "\n\n" ..
                   (not_restored and _("Stock USB could not be restored. Reboot the Kindle before using USB.")
                                  or _("Stock USB has been restored.")) ..
                   "\n" .. _("Details are in the plugin's mtp/mtp.log."),
        })
        return
    end

    self.active = true
    self.connected = false
    self.cable_seen = false
    self.started_at = os.time()
    self.lost_polls = 0
    self.hidden = false
    self:rememberOpenBook()
    self:keepAwake(true)
    self:updateFooter()
    self:showDialog()
    self:schedulePoll()
end

-- Files that arrived during the last session (written by mtp-stop.sh).
function Ctl:receivedFiles()
    local f = io.open(self.mtp_dir .. "/received.txt", "r")
    if not f then return {} end
    local list = {}
    for line in f:lines() do
        if line ~= "" then list[#list + 1] = line end
    end
    f:close()
    table.sort(list)
    return list
end

local function baseName(path)
    return path:match("([^/]+)$") or path
end

-- Split what arrived into books KOReader can open and anything else (Calibre's
-- metadata files, covers, ...).
local function splitBooks(list)
    local ok, DocumentRegistry = pcall(require, "document/documentregistry")
    local books, others = {}, 0
    for _, f in ipairs(list) do
        if not ok or DocumentRegistry:hasProvider(f) then
            books[#books + 1] = f
        else
            others = others + 1
        end
    end
    return books, others
end

-- The books themselves are listed as Open buttons (see showResult), so the text
-- only names the ones that didn't get a button.
local function receivedSummary(books, others)
    local lines = {}
    if #books > 0 then
        lines[1] = T(_("%1 new book(s) on the Kindle."), #books)
        if #books > MAX_OPEN_BUTTONS then
            lines[#lines + 1] = T(_("The first %1 are below; find the rest in the file browser."), MAX_OPEN_BUTTONS)
        end
    end
    if others > 0 then
        lines[#lines + 1] = #books > 0 and T(_("Plus %1 other file(s)."), others)
                                        or T(_("%1 new file(s) on the Kindle, none of them books."), others)
    end
    return #lines > 0 and table.concat(lines, "\n") or nil
end

-- Open a book from wherever we are (file browser or another book).
local function openFile(file)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    local ok, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    if ui and ok and filemanagerutil.openFile then
        filemanagerutil.openFile(ui, file, nil, true)
    else -- older KOReader
        (ReaderUI or require("apps/reader/readerui")):showReader(file)
    end
end

-- The message after a session ends, with buttons to open the books that just
-- arrived and, if the cable is still in, to start sharing again.
-- opts: restart (offer "Start again"), timeout (only used when there are no buttons)
function Ctl:showResult(text, books, opts)
    opts = opts or {}
    local rows, dlg = {}, nil
    local function close()
        if dlg then UIManager:close(dlg) end
        dlg = nil
    end
    if opts.restart then
        rows[#rows + 1] = {{ text = _("Start again"), callback = function() close(); self:start() end }}
    end
    for i = 1, math.min(#books, MAX_OPEN_BUTTONS) do
        local file = books[i]
        rows[#rows + 1] = {{ text = T(_("Open %1"), baseName(file)), callback = function() close(); openFile(file) end }}
    end
    if #rows == 0 then
        UIManager:show(InfoMessage:new{ text = text, timeout = opts.timeout })
        return
    end
    rows[#rows + 1] = {{ text = _("Close"), callback = close }}
    dlg = ButtonDialog:new{ title = text, buttons = rows }
    -- Like ConfirmBox's flush_events_on_show: taps made while stopping mustn't press a button.
    if Device.input and Device.input.inhibitInputUntil then Device.input:inhibitInputUntil(true) end
    UIManager:show(dlg)
end

-- quiet: no popups (exit / sleep)
function Ctl:stop(reason, quiet)
    self:unschedulePoll()
    self:closeDialog()

    local busy = not quiet and showBusy(_("Stopping USB file transfer…"))
    local ok = self:runScript("mtp-stop.sh")
    if busy then UIManager:close(busy) end

    if self.active then self:keepAwake(false) end
    self.active = false
    self.connected = false
    self.hidden = false
    self.book = nil
    self.stopped_at = os.time()
    -- Cable still in: only pulling it makes the next Charging event a plug-in.
    self.plug_armed = udcState() == "not attached"
    self:updateFooter()

    if quiet then return ok end

    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager.instance then
        -- MTP deletions can take ~1s to show through Amazon's fsp layer
        UIManager:scheduleIn(1, function()
            if FileManager.instance then FileManager.instance:onRefresh() end
        end)
    end

    local text, summary
    local books = {}
    if ok then
        local others
        books, others = splitBooks(self:receivedFiles())
        summary = receivedSummary(books, others)
        text = (reason and (reason .. "\n\n") or "") .. _("USB file transfer stopped. Safe to unplug.") ..
               (summary and ("\n\n" .. summary) or "")
    else
        local err, not_restored = self:lastRunResult()
        text = _("Problem while stopping USB file transfer.") .. "\n\n" .. (err or "") .. "\n\n" ..
               (not_restored and _("Stock USB was not restored. Reboot the Kindle before using USB.")
                              or _("If USB misbehaves, reboot the Kindle."))
    end
    -- Leave news of new files up until dismissed; a plain "stopped" can time out.
    self:showResult(text, books, { timeout = (ok and not summary) and 4 or nil })
    return ok
end

function Ctl:offerStaleCleanup()
    UIManager:show(ConfirmBox:new{
        text = _("A USB file transfer was left running (KOReader probably closed unexpectedly).\n\nStop it and restore normal USB?"),
        ok_text = _("Stop it"),
        ok_callback = function() self:stop() end,
    })
end

---------------------------------------------------------------------------
-- Transfer dialog: Stop, or Hide to keep reading/browsing
---------------------------------------------------------------------------

function Ctl:dialogText()
    local state
    if self.connected then
        state = _("Connected. Your computer can see the Kindle's files.")
    else
        state = _("Waiting for the computer…\nLook for \"Kindle (MTP)\" in your file manager (Mac: use OpenMTP).")
    end
    return _("USB file transfer is on.") .. "\n\n" .. state .. "\n\n" ..
           _("Hide it to keep reading. It stops by itself when you unplug the cable.\nDon't change the open book or the \"koreader\" folder from the computer.")
end

function Ctl:showDialog()
    self:closeDialog()
    self.hidden = false
    self.dialog = ConfirmBox:new{
        text = self:dialogText(),
        dismissable = false,
        flush_events_on_show = true, -- drop taps made while start was blocking
        cancel_text = _("Stop"),
        cancel_callback = function()
            self.dialog = nil
            self:stop()
        end,
        ok_text = _("Hide"),
        ok_callback = function()
            self.dialog = nil
            self.hidden = true
            notify(_("USB transfer still on. Menu > Tools > USB file transfer to stop."))
        end,
    }
    UIManager:show(self.dialog)
end

function Ctl:closeDialog()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

---------------------------------------------------------------------------
-- Watchdog: connection status, unplug, daemon death, open book changed
---------------------------------------------------------------------------

function Ctl:schedulePoll()
    self._poll = self._poll or function() self:poll() end
    UIManager:scheduleIn(POLL_SECS, self._poll)
end

function Ctl:unschedulePoll()
    if self._poll then UIManager:unschedule(self._poll) end
end

-- If the computer replaced or deleted the book that's open, close it before
-- KOReader tries to read a half-copied or missing file.
function Ctl:checkOpenBook()
    local r = openReader()
    if not r then
        self.book = nil
        return
    end
    local file = r.document.file
    if not self.book or self.book.file ~= file then
        -- A book opened during the transfer: start watching it.
        self.book = { file = file, stamp = bookStamp(file) }
        return
    end
    local now = bookStamp(file)
    if now == self.book.stamp then return end

    logger.warn("usbmtp: open book changed on disk:", file, self.book.stamp, "->", now)
    local was_shown = self.dialog ~= nil
    self:closeDialog()
    self.book = nil
    -- Close menus/popups sitting on the reader first: they hold references to
    -- the document and would crash on the next tap once it's closed.
    r:handleEvent(Event:new("CloseReaderMenu"))
    r:handleEvent(Event:new("CloseConfigMenu"))
    if r.highlight and r.highlight.onClose then r.highlight:onClose() end
    for _ = 1, 10 do
        local top = UIManager:getTopmostVisibleWidget()
        if not top or top == r then break end
        UIManager:close(top)
    end
    r:onHome() -- close the book, back to the file browser at its folder
    UIManager:nextTick(function()
        if was_shown then self:showDialog() end
        UIManager:show(InfoMessage:new{
            text = now and _("The open book was changed from the computer, so it was closed. Open it again when the copy has finished.")
                       or _("The open book was deleted from the computer, so it was closed."),
        })
    end)
end

function Ctl:poll()
    if not self.active then return end

    if not daemonAlive() then
        logger.warn("usbmtp: umtprd died")
        self:stop(_("The MTP program stopped unexpectedly."))
        return
    end

    local st = udcState()
    if st ~= "not attached" then
        self.lost_polls = 0
    end
    if st == "configured" then
        if not self.connected then
            self.connected = true
            if self.dialog then
                self:showDialog()
            else
                notify(_("Computer connected over USB."))
            end
        end
    elseif (self.connected or self.cable_seen) and st == "not attached" then
        -- Only VBUS loss means unplugged. "suspended" (computer asleep) and the
        -- default/addressed states seen while a host re-enumerates are not.
        -- Also applies when a cable was in but no computer ever connected
        -- (e.g. a Mac with no MTP app), so the Kindle can sleep again.
        self.lost_polls = self.lost_polls + 1
        if self.lost_polls >= 2 then
            self:stop(_("The cable was unplugged."))
            return
        end
    end
    if st ~= "not attached" and st ~= "unknown" then
        self.cable_seen = true
    end
    if not self.connected and os.time() - (self.started_at or os.time()) > NO_HOST_TIMEOUT then
        self:stop(T(_("No computer connected within %1 minutes."), math.floor(NO_HOST_TIMEOUT / 60)))
        return
    end

    self:checkOpenBook()
    self:schedulePoll()
end

---------------------------------------------------------------------------
-- Optional prompt when plugged into a computer (from any screen).
-- With the stock driver loaded, a computer configures the USB gadget within a
-- few seconds; a wall charger never does. That's how we tell them apart.
---------------------------------------------------------------------------

-- What to do when plugged into a computer: "ask", "auto" or "off".
-- (v0.5 and earlier stored a boolean "usbmtp_prompt_on_plug": true means "ask".)
local function onPlugMode()
    local m = G_reader_settings:readSetting("usbmtp_on_plug")
    if m == "ask" or m == "auto" or m == "off" then return m end
    return G_reader_settings:isTrue("usbmtp_prompt_on_plug") and "ask" or "off"
end

-- Charging events aren't plug-in events. Charging also stops when the battery is
-- full and resumes later with the cable still in, and our own Stop makes the
-- computer re-enumerate the Kindle. Neither may pop up the prompt mid-book or
-- restart sharing behind the user's back, so a Charging event only counts when
-- the cable was seen out since the last plug-in (plug_armed). If that was missed,
-- it still counts unless the computer is already connected (nothing was
-- re-plugged) or we only just stopped.
function Ctl:onCharging()
    local mode = onPlugMode()
    if mode == "off" then return end
    if self.active or self._probing then return end
    local st = udcState()
    if st == "not attached" then self.plug_armed = true end -- the cable is only just in
    if not self.plug_armed and (st == "configured"
            or (self.stopped_at and os.time() - self.stopped_at < REPLUG_QUIET_SECS)) then
        logger.info("usbmtp: charging event with the cable already in; not a plug-in (USB:", st, ")")
        return
    end
    self.plug_armed = false
    self._probing = true
    local tries = 0
    self._probe = function()
        tries = tries + 1
        if self.active then
            self._probing = false
            return
        end
        if udcState() == "configured" then
            self._probing = false
            if mode == "auto" then
                self:start()
                return
            end
            UIManager:show(ConfirmBox:new{
                text = _("Computer detected.\n\nStart USB file transfer (MTP)?"),
                ok_text = _("Start"),
                flush_events_on_show = true,
                ok_callback = function() self:start() end,
            })
        elseif tries < 16 then
            UIManager:scheduleIn(0.5, self._probe)
        else
            self._probing = false -- probably a charger
        end
    end
    UIManager:scheduleIn(1, self._probe)
end

function Ctl:onNotCharging()
    if self._probe then UIManager:unschedule(self._probe) end
    self._probing = false
    -- Cable pulled, or battery full? Watch the USB port for a few seconds.
    if self._unplug_check then UIManager:unschedule(self._unplug_check) end
    local tries = 0
    self._unplug_check = function()
        tries = tries + 1
        if udcState() == "not attached" then
            self.plug_armed = true
        elseif tries < 5 then
            UIManager:scheduleIn(1, self._unplug_check)
        end
    end
    self._unplug_check()
end

function Ctl:onSuspend()
    if self.active then
        self.sleep_stop_ok = self:stop(nil, true)
        self.stopped_by_sleep = true
    end
end

function Ctl:onResume()
    if self.stopped_by_sleep then
        self.stopped_by_sleep = false
        local ok = self.sleep_stop_ok
        UIManager:scheduleIn(1, function()
            local FileManager = package.loaded["apps/filemanager/filemanager"]
            if FileManager and FileManager.instance then FileManager.instance:onRefresh() end
            local text = _("USB file transfer was stopped because the Kindle went to sleep.\n\nIf a file was being copied at that moment, copy it again.")
            local books, summary = {}, nil
            local st = udcState()
            local cable_in = ok and st ~= "not attached" and st ~= "unknown"
            if ok then
                local others
                books, others = splitBooks(self:receivedFiles())
                summary = receivedSummary(books, others)
                if summary then text = text .. "\n\n" .. summary end
            else
                local err, not_restored = self:lastRunResult()
                text = text .. "\n\n" .. _("Stopping didn't go cleanly:") .. " " .. (err or "") .. "\n" ..
                       (not_restored and _("Stock USB was not restored. Reboot the Kindle before using USB.")
                                      or _("If USB misbehaves, reboot the Kindle."))
            end
            self:showResult(text, books, { restart = cable_in, timeout = (ok and not summary) and 8 or nil })
        end)
    end
end

---------------------------------------------------------------------------
-- Status-bar marker in the reader while sharing (opt-out). Registered only while
-- a session is on: adding footer content flips a persistent footer setting, and
-- removing the last item flips it back, so the user's footer is left as it was.
---------------------------------------------------------------------------

local FOOTER_TEXT = "ᴍᴛᴘ" -- small caps, like the SSH plugin's marker

function Ctl:updateFooter()
    local p = self.reader_plugin
    local footer = p and p.ui and p.ui.view and p.ui.view.footer
    if not footer then return end
    local want = self.active and G_reader_settings:nilOrTrue("usbmtp_footer")
    if want and not p.footer_added then
        footer:addAdditionalFooterContent(p.footer_func)
        p.footer_added = true
    elseif not want and p.footer_added then
        footer:removeAdditionalFooterContent(p.footer_func)
        p.footer_added = false
        UIManager:broadcastEvent(Event:new("UpdateFooter", true))
    end
    UIManager:broadcastEvent(Event:new("RefreshAdditionalContent"))
end

---------------------------------------------------------------------------
-- Plugin instances (one in the file browser, one per open book): thin wrappers
---------------------------------------------------------------------------

local UsbMtp = WidgetContainer:extend{
    name = "usbmtp",
    is_doc_only = false,
}

function UsbMtp:init()
    if not Ctl.mtp_dir then
        local root = self.path
        if root:sub(1, 1) ~= "/" then
            root = lfs.currentdir() .. "/" .. root
        end
        Ctl.mtp_dir = root .. "/mtp"
        Ctl.version = readFirstLine(Ctl.mtp_dir .. "/VERSION") or "?"
        -- We loaded, so any update that just happened worked: drop the backup.
        pcall(Updater.cleanupAfterUpdate, root)
        -- Started with the cable in: wait for it to come out before acting on a
        -- Charging event (it may just be the battery topping up).
        Ctl.plug_armed = udcState() == "not attached"
    end
    Ctl:hookExit()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    if self.ui.view and self.ui.view.footer then -- a reader, not the file browser
        self.footer_func = function() return Ctl.active and FOOTER_TEXT or nil end
        Ctl.reader_plugin = self
    end

    -- After a crash, a session may still be running with nobody owning it.
    if not Ctl.stale_checked then
        Ctl.stale_checked = true
        if not Ctl.active and fileExists(STATE_FILE) then
            UIManager:scheduleIn(1, function() Ctl:offerStaleCleanup() end)
        end
    end
end

-- Broadcast events: only one plugin instance exists at a time (file browser or
-- reader), so forwarding to the controller is enough.
function UsbMtp:onCharging() Ctl:onCharging() end
function UsbMtp:onNotCharging() Ctl:onNotCharging() end
function UsbMtp:onSuspend() Ctl:onSuspend() end
function UsbMtp:onResume() Ctl:onResume() end

function UsbMtp:onCloseWidget()
    if Ctl.reader_plugin == self then
        if self.footer_added and self.ui.view and self.ui.view.footer then
            self.ui.view.footer:removeAdditionalFooterContent(self.footer_func)
        end
        self.footer_added = false
        Ctl.reader_plugin = nil
    end
end

function UsbMtp:onReaderReady()
    Ctl.reader_plugin = self
    Ctl:updateFooter()
    -- A book opened while sharing: re-show the dialog unless the user hid it,
    -- since the new reader screen is drawn on top of it.
    if Ctl.active then
        -- ReaderUI.instance isn't set yet when ReaderReady fires; use our own ui.
        Ctl:rememberOpenBook(self.ui.document and self.ui.document.file)
        if not Ctl.hidden then
            UIManager:nextTick(function() Ctl:showDialog() end)
        end
    end
end

function UsbMtp:onDispatcherRegisterActions()
    Dispatcher:registerAction("usbmtp_toggle", {
        category = "none",
        event = "ToggleUsbMtp",
        title = _("Toggle USB file transfer (MTP)"),
        general = true,
    })
end

function UsbMtp:onToggleUsbMtp()
    if Ctl.active then
        Ctl:showDialog()
    else
        Ctl:start()
    end
    return true
end

---------------------------------------------------------------------------
-- Updates from GitHub Releases
---------------------------------------------------------------------------

local function updateWorkDir()
    return DataStorage:getDataDir() .. "/cache/usbmtp-update"
end

-- A session we didn't start (SSH/KUAL, or left over from a crash) also counts.
local function anySessionRunning()
    return Ctl.active or fileExists(STATE_FILE) or daemonAlive()
end

function UsbMtp:checkForUpdates()
    if Ctl.update_pending then
        self:offerRestart()
        return
    end
    if anySessionRunning() then
        UIManager:show(InfoMessage:new{ text = _("Stop the USB file transfer first, then check for updates.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local busy = showBusy(_("Checking GitHub for updates…"))
        local info, err = Updater.check(Ctl.version, updateWorkDir())
        UIManager:close(busy)
        if not info or not info.newer then
            NetworkMgr:afterWifiAction() -- turn Wi-Fi back off if we turned it on (user's setting)
        end
        if not info then
            UIManager:show(InfoMessage:new{ icon = "notice-warning", text = err })
            return
        end
        if not info.newer then
            UIManager:show(InfoMessage:new{
                text = T(_("You have the latest version (v%1)."), Ctl.version), timeout = 4,
            })
            return
        end
        local notes = Updater.shortNotes(info.notes, 700)
        UIManager:show(ConfirmBox:new{
            text = T(_("Version %1 is available (you have %2)."), info.version, Ctl.version) ..
                   (notes ~= "" and ("\n\n" .. notes) or "") ..
                   "\n\n" .. _("Install it? KOReader will need to restart."),
            ok_text = _("Install"),
            flush_events_on_show = true, -- taps made while checking mustn't press Install
            ok_callback = function() self:installUpdate(info) end,
            cancel_callback = function() NetworkMgr:afterWifiAction() end,
        })
    end)
end

function UsbMtp:installUpdate(info)
    if anySessionRunning() then
        UIManager:show(InfoMessage:new{ text = _("Stop the USB file transfer first.") })
        NetworkMgr:afterWifiAction()
        return
    end
    local root = Ctl.mtp_dir:match("^(.*)/mtp$")
    local busy = showBusy(T(_("Downloading and installing v%1…"), info.version))
    local ok, err = Updater.install(info, root, updateWorkDir())
    UIManager:close(busy)
    NetworkMgr:afterWifiAction()
    if not ok then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Update failed.") .. "\n\n" .. tostring(err),
        })
        return
    end
    -- The code running now is the old version, but the scripts on disk are new:
    -- don't let them mix. Starting a transfer waits for the restart.
    Ctl.update_pending = info.version
    self:offerRestart()
end

function UsbMtp:offerRestart()
    UIManager:show(ConfirmBox:new{
        text = T(_("Updated to v%1. Restart KOReader to finish the update.\n\nUntil then, USB file transfer is unavailable."), Ctl.update_pending),
        ok_text = _("Restart now"),
        cancel_text = _("Later"),
        flush_events_on_show = true,
        ok_callback = function() UIManager:restartKOReader() end,
    })
end

function UsbMtp:showStatus()
    local p = io.popen(string.format("sh '%s/mtp-status.sh' 2>&1", Ctl.mtp_dir), "r")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    UIManager:show(TextViewer:new{ title = _("USB file transfer status"), text = out })
end

function UsbMtp:addToMainMenu(menu_items)
    menu_items.usbmtp = {
        text = _("USB file transfer (MTP)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    return Ctl.active and _("Show transfer / Stop") or _("Start USB file transfer")
                end,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:onToggleUsbMtp()
                end,
            },
            {
                text_func = function()
                    local labels = { ask = _("ask first"), auto = _("start automatically"), off = _("do nothing") }
                    return T(_("When plugged into a computer: %1"), labels[onPlugMode()])
                end,
                help_text = _("Wall chargers are ignored: only a computer that actually connects counts. Works on any screen, including inside a book."),
                sub_item_table = {
                    {
                        text = _("Ask first"),
                        radio = true,
                        checked_func = function() return onPlugMode() == "ask" end,
                        callback = function() G_reader_settings:saveSetting("usbmtp_on_plug", "ask") end,
                    },
                    {
                        text = _("Start automatically"),
                        radio = true,
                        checked_func = function() return onPlugMode() == "auto" end,
                        callback = function() G_reader_settings:saveSetting("usbmtp_on_plug", "auto") end,
                    },
                    {
                        text = _("Do nothing"),
                        radio = true,
                        checked_func = function() return onPlugMode() == "off" end,
                        callback = function() G_reader_settings:saveSetting("usbmtp_on_plug", "off") end,
                    },
                },
            },
            {
                text = T(_("Show %1 in the reader's status bar while sharing"), FOOTER_TEXT),
                checked_func = function() return G_reader_settings:nilOrTrue("usbmtp_footer") end,
                callback = function()
                    G_reader_settings:flipNilOrTrue("usbmtp_footer")
                    Ctl:updateFooter()
                end,
            },
            {
                text = _("Check for updates"),
                help_text = _("Look for a newer release on GitHub over Wi-Fi, and install it if you want."),
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:checkForUpdates()
                end,
            },
            {
                text = _("Status / diagnostics"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
            {
                text = _("Reset USB (after a crash)"),
                enabled_func = function() return not Ctl.active end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Stop any leftover MTP session and restore the stock USB driver?"),
                        ok_text = _("Reset"),
                        ok_callback = function() Ctl:stop() end,
                    })
                end,
            },
            {
                text_func = function() return _("About") .. " (v" .. (Ctl.version or "?") .. ")" end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[USB file transfer (MTP) lets your computer copy books while KOReader stays open, from the file browser or inside a book.

Linux: the Kindle shows up as "Kindle (MTP)" in your file manager.
Mac: install OpenMTP; quit Photos/Image Capture first.

Tap Hide to keep reading during a transfer. It stops by itself when you unplug, when the Kindle sleeps, or when KOReader exits. If the computer replaces or deletes the book you have open, that book is closed safely.

Don't edit the "koreader" folder from the computer.

Uses uMTP-Responder (GPLv3) by Viveris Technologies.]]) .. "\n\n" .. _("Version") .. " " .. (Ctl.version or "?"),
                    })
                end,
            },
        },
    }
end

-- Exposed for tests
UsbMtp._controller = Ctl

return UsbMtp
