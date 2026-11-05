USB file transfer for KOReader on Kindle
=======================================
Lets your computer copy books over USB while KOReader stays open, from the
file browser (any view, including mosaic/bookshelf) or inside a book.
Two ways: MTP (Linux, Windows), or a plain USB drive any computer can use
with no extra app (a Mac included).

Version:  Tools > USB file transfer > About, or the file mtp/VERSION
Project:  https://github.com/AnonyMap/usbmtp
Built for: Kindle 10th gen (2019), firmware 5.16.x, kernel 4.1.15-lab126.
Confirmed: FW 5.16.8 with Bazzite Linux (KDE), file manager and Calibre.

Nothing is permanent: if anything gets stuck, rebooting the Kindle restores
stock USB.

WRITTEN BY AI: this plugin was developed with an AI model (Anthropic's
Claude). Its author directed and tested it but didn't write the code. It
has been tested on one Kindle. It runs as root and swaps USB kernel modules
while KOReader runs. Read the project README ("How this was made") before
trusting it.

WHICH PLUGIN? With KOReader closed, does your Kindle show up on a computer
as a USB drive? Then this is the right plugin (currently Kindle 10th gen
only; see Built for). If it shows up as an MTP device
(newer Kindles: Scribe, Colorsoft, recent Paperwhites), use kindlemtp.koplugin
(github.com/danihrndzld/kindlemtp.koplugin) instead. Quick check in a
terminal: if /usr/bin/mtp.sh exists, use kindlemtp.

INSTALL
  1. Exit KOReader so the Kindle appears as a USB drive on your computer.
  2. Copy this "usbmtp.koplugin" folder into  koreader/plugins/  on the
     Kindle, replacing any older copy. (From GitHub's "Download ZIP", copy
     the usbmtp.koplugin folder from inside usbmtp-main.)
  3. Eject, unplug, start KOReader from KUAL.
  4. Check: Tools > USB file transfer > About shows the new version.

UPDATING (v0.5 and later)
  Tools > USB file transfer > Check for updates (needs Wi-Fi).
  It shows the release notes and asks first. It only checks when you tap it.
  It refuses a download that fails its checksum, is incomplete, contains
  anything outside this plugin's folder, or has broken code, and it keeps
  the current version if anything goes wrong. Stop any transfer first.
  After updating, restart KOReader (USB transfer waits until you do). The
  previous version is kept as usbmtp.koplugin.old until the new one loads.

START IT (any of these)
  - Menu: Tools (wrench) > USB file transfer > Start USB file transfer
  - Plug in: in that menu, set "When plugged into a computer" to "ask
    first" or "start automatically" (default: do nothing). Works on any
    screen. Wall chargers are ignored, and so is charging that resumes
    with the cable still in (full battery topping up, or just after Stop).
  - Gesture: Settings > Taps and gestures > Gesture manager > pick a
    gesture > General > "Toggle USB file transfer".
  Connection (same menu): MTP, or USB drive (see below). The plug-in
  prompt also offers the other one, for that time only.

WHILE SHARING
  A dialog shows the status with two buttons:
    Stop - ends sharing. Then unplug.
    Hide - keep reading or browsing. A notification tells you when the
           computer connects, and "ᴍᴛᴘ" shows in the reader's status bar
           (can be turned off in the menu). Reopen the dialog from the
           menu or gesture.
  After Stop, each book that arrived gets an Open button (first five).
  If the Kindle sleeps during a transfer, sharing stops; if the cable is
  still in when it wakes, you're offered Start again.
  With MTP:
  Linux: "Kindle (MTP)" appears in Dolphin's / GNOME Files' sidebar.
  Mac: macOS has no MTP support; use the USB drive connection, or the
       OpenMTP app (quit Photos and Image Capture first).
  Windows: should appear in Explorer (untested).

USB DRIVE (Mac, Windows, any computer, no app)
  Set Connection > USB drive, then start as usual.
  1. A drive called TO KINDLE appears on the computer (empty).
  2. Copy books onto it. Folders are kept.
  3. Eject it on the computer.
  4. The Kindle copies them into documents/, empties the drive, and
     offers to open them.
  The drive is a file, koreader/usbmtp-drive.img (256 MB by default;
  Connection > USB drive size), so the Kindle's own storage is never
  shared: the computer can only add books, not see or delete them.
  First start creates it (takes a while). It keeps using that space;
  Connection > Erase the USB drive frees it.
  Anything that can't be copied stays on the drive and is listed.
  Eject before unplugging or tapping Stop: if the computer still has the
  drive open, nothing is added (the last book may be incomplete); you get
  Start again (to eject it properly) or Add anyway (never replaces a book
  already on the Kindle).
  Calibre: use "Connect to folder" on the TO KINDLE drive (or use MTP).

CALIBRE
  Calibre sees it as an MTP device and sends EPUBs to "documents".
  1. Only one program can use an MTP device at a time. On KDE, kiod6 grabs
     the Kindle in the background even with no Dolphin window open, and
     Calibre then fails silently until you replug. To fix it once:
       quit Calibre > run "killall kiod6" > start Calibre > replug.
     To fix it for good, install the udev rule from the project's
     tools/69-zz-usbmtp-calibre.rules (instructions inside the file).
     Dolphin then stops showing the Kindle; Calibre always gets it.
  2. Answer Yes to "Manage the Kindle (MTP)?".
  3. Once: right-click the device icon > Configure this device > Ignored
     folders: untick "koreader" (much faster scans).
  4. Tap Stop on the Kindle when Calibre has finished.
  KOReader can then search your Calibre metadata: Tools > Calibre >
  Search settings > Manage libraries > Rescan disk for calibre libraries.

SAFETY RAILS (automatic)
  - Stops by itself when you unplug the cable, the Kindle sleeps, KOReader
    exits/restarts, KOReader crashes, or the MTP program dies, and if no
    computer connects within 10 minutes.
  - Saves the open book's progress before sharing starts.
  - If the computer replaces or deletes the book you have open, that book
    is closed (sharing continues) so KOReader never reads a half-copied file.
  - Keeps the Kindle awake while sharing.
  - After a crash, offers to clean up on the next launch.
  Don't edit the "koreader" folder from the computer while sharing.

IF IT DOESN'T WORK
  - Menu > USB file transfer > Status / diagnostics (state, the end
    of both logs, and what arrived last time)
  - Logs, in koreader/plugins/usbmtp.koplugin/mtp/ (read them after exiting
    KOReader): mtp.log and umtprd-last.log
  - Linux computer: run the project's tools/host-check.sh with the Kindle
    plugged in and MTP on; also
      journalctl -k -b | grep -iE "usb|1d6b" | tail -20
  - Something stuck: Menu > Reset USB, or reboot the Kindle.
  - Report problems at https://github.com/AnonyMap/usbmtp/issues
    with the version, the two logs, and host-check.sh output if relevant.

Includes uMTP-Responder by Viveris Technologies (GPLv3); license, source
and patch in mtp/umtprd-source/.
