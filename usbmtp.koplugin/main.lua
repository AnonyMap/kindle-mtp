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

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local PluginShare = require("pluginshare")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local STATE_FILE = "/var/tmp/kmtp/state"
local PID_FILE = "/var/tmp/kmtp/umtprd.pid"
local UDC_STATE = "/sys/class/udc/ci_hdrc.0/state"
local POLL_SECS = 2

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
}

function Ctl:runScript(script)
    local cmd = string.format("sh '%s/%s' >/dev/null 2>&1", self.mtp_dir, script)
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
        if line:find("=== kindle-mtp ", 1, true) then
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

function Ctl:rememberOpenBook()
    local r = openReader()
    if r then
        self.book = { file = r.document.file, stamp = bookStamp(r.document.file) }
    else
        self.book = nil
    end
end

function Ctl:start()
    if self.active then
        self:showDialog()
        return
    end
    if fileExists(STATE_FILE) then
        self:offerStaleCleanup()
        return
    end

    -- Get everything KOReader holds in memory onto disk before the computer looks.
    local r = openReader()
    if r then r:saveSettings() end
    UIManager:flushSettings()

    local busy = showBusy(_("Starting USB file transfer…"))
    local ok = self:runScript("mtp-start.sh")
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
    self.lost_polls = 0
    self.hidden = false
    self:rememberOpenBook()
    self:keepAwake(true)
    self:showDialog()
    self:schedulePoll()
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

    if quiet then return end

    local FileManager = package.loaded["apps/filemanager/filemanager"]
    if FileManager and FileManager.instance then
        -- MTP deletions can take ~1s to show through Amazon's fsp layer
        UIManager:scheduleIn(1, function()
            if FileManager.instance then FileManager.instance:onRefresh() end
        end)
    end

    local text
    if ok then
        text = (reason and (reason .. "\n\n") or "") .. _("USB file transfer stopped. Safe to unplug.")
    else
        local err, not_restored = self:lastRunResult()
        text = _("Problem while stopping USB file transfer.") .. "\n\n" .. (err or "") .. "\n\n" ..
               (not_restored and _("Stock USB was not restored. Reboot the Kindle before using USB.")
                              or _("If USB misbehaves, reboot the Kindle."))
    end
    UIManager:show(InfoMessage:new{ text = text, timeout = ok and 4 or nil })
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
    if st == "configured" then
        self.lost_polls = 0
        if not self.connected then
            self.connected = true
            if self.dialog then
                self:showDialog()
            else
                notify(_("Computer connected over USB."))
            end
        end
    elseif self.connected then
        self.lost_polls = self.lost_polls + 1
        if self.lost_polls >= 2 then
            self:stop(_("The cable was unplugged."))
            return
        end
    end

    self:checkOpenBook()
    self:schedulePoll()
end

---------------------------------------------------------------------------
-- Optional prompt when plugged into a computer (from any screen).
-- With the stock driver loaded, a computer configures the USB gadget within a
-- few seconds; a wall charger never does. That's how we tell them apart.
---------------------------------------------------------------------------

function Ctl:onCharging()
    if not G_reader_settings:isTrue("usbmtp_prompt_on_plug") then return end
    if self.active or self._probing then return end
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
            UIManager:show(ConfirmBox:new{
                text = _("Computer detected.\n\nStart USB file transfer (MTP)?"),
                ok_text = _("Start"),
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
end

function Ctl:onSuspend()
    if self.active then
        self:stop(nil, true)
        self.stopped_by_sleep = true
    end
end

function Ctl:onResume()
    if self.stopped_by_sleep then
        self.stopped_by_sleep = false
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new{ text = _("USB file transfer was stopped because the Kindle went to sleep."), timeout = 5 })
        end)
    end
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
    end
    Ctl:hookExit()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

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

function UsbMtp:onReaderReady()
    -- A book opened while sharing: re-show the dialog unless the user hid it,
    -- since the new reader screen is drawn on top of it.
    if Ctl.active then
        Ctl:rememberOpenBook()
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
                text = _("Ask to start when plugged into a computer"),
                help_text = _("When the cable is connected to a computer (not a wall charger), offer to start USB file transfer. Works on any screen, including inside a book."),
                checked_func = function() return G_reader_settings:isTrue("usbmtp_prompt_on_plug") end,
                callback = function() G_reader_settings:flipNilOrFalse("usbmtp_prompt_on_plug") end,
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
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _([[USB file transfer (MTP) lets your computer copy books while KOReader stays open, from the file browser or inside a book.

Linux: the Kindle shows up as "Kindle (MTP)" in your file manager.
Mac: install OpenMTP; quit Photos/Image Capture first.

Tap Hide to keep reading during a transfer. It stops by itself when you unplug, when the Kindle sleeps, or when KOReader exits. If the computer replaces or deletes the book you have open, that book is closed safely.

Don't edit the "koreader" folder from the computer.

Uses uMTP-Responder (GPLv3) by Viveris Technologies.]]),
                    })
                end,
            },
        },
    }
end

-- Exposed for tests
UsbMtp._controller = Ctl

return UsbMtp
