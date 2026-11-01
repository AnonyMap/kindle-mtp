USB file transfer (MTP) for KOReader on Kindle
==============================================
Lets your computer copy books over USB while KOReader stays open, from the
file browser (any view, including mosaic/bookshelf) or inside a book.

Version:  Tools > USB file transfer (MTP) > About, or the file mtp/VERSION
Project:  https://github.com/AnonyMap/kindle-mtp
Built for: Kindle 10th gen (2019), firmware 5.16.x, kernel 4.1.15-lab126.
Confirmed: FW 5.16.8 with Bazzite Linux (KDE), file manager and Calibre.

Nothing is permanent: if anything gets stuck, rebooting the Kindle restores
stock USB.

INSTALL
  1. Exit KOReader so the Kindle appears as a USB drive on your computer.
  2. Copy this "usbmtp.koplugin" folder into  koreader/plugins/  on the
     Kindle, replacing any older copy. (From GitHub's "Download ZIP", copy
     only this folder, not the whole kindle-mtp-main folder.)
  3. Eject, unplug, start KOReader from KUAL.
  4. Check: Tools > USB file transfer (MTP) > About shows the new version.

START IT (any of these)
  - Menu: Tools (wrench) > USB file transfer (MTP) > Start USB file transfer
  - Plug in: turn on "Ask to start when plugged into a computer" in that
    menu. Plugging into a computer then offers to start, on any screen.
    Wall chargers are ignored.
  - Gesture: Settings > Taps and gestures > Gesture manager > pick a
    gesture > General > "Toggle USB file transfer (MTP)".

WHILE SHARING
  A dialog shows the status with two buttons:
    Stop - ends sharing. Then unplug.
    Hide - keep reading or browsing. A notification tells you when the
           computer connects. Reopen the dialog from the menu or gesture.
  Linux: "Kindle (MTP)" appears in Dolphin's / GNOME Files' sidebar.
  Mac: use OpenMTP; quit Photos and Image Capture first.
  Windows: should appear in Explorer (untested).

CALIBRE
  Calibre sees it as an MTP device and sends EPUBs to "documents".
  1. Only one program can use an MTP device at a time. On KDE, kiod6 grabs
     the Kindle in the background even with no Dolphin window open, and
     Calibre then fails silently until you replug. To fix it once:
       quit Calibre > run "killall kiod6" > start Calibre > replug.
     To fix it for good, install the udev rule from the project's
     tools/69-zz-kindle-mtp-calibre.rules (instructions inside the file).
     Dolphin then stops showing the Kindle; Calibre always gets it.
  2. Answer Yes to "Manage the Kindle (MTP)?".
  3. Once: right-click the device icon > Configure this device > Ignored
     folders: untick "koreader" (much faster scans).
  4. Tap Stop on the Kindle when Calibre has finished.
  KOReader can then search your Calibre metadata: Tools > Calibre >
  Search settings > Manage libraries > Rescan disk for calibre libraries.

SAFETY RAILS (automatic)
  - Stops by itself when you unplug the cable, the Kindle sleeps, KOReader
    exits/restarts, KOReader crashes, or the MTP program dies.
  - Saves the open book's progress before sharing starts.
  - If the computer replaces or deletes the book you have open, that book
    is closed (sharing continues) so KOReader never reads a half-copied file.
  - Keeps the Kindle awake while sharing.
  - After a crash, offers to clean up on the next launch.
  Don't edit the "koreader" folder from the computer while sharing.

IF IT DOESN'T WORK
  - Menu > USB file transfer (MTP) > Status / diagnostics
  - Logs, in koreader/plugins/usbmtp.koplugin/mtp/ (read them after exiting
    KOReader): mtp.log and umtprd-last.log
  - Linux computer: run the project's tools/host-check.sh with the Kindle
    plugged in and MTP on; also
      journalctl -k -b | grep -iE "usb|1d6b" | tail -20
  - Something stuck: Menu > Reset USB, or reboot the Kindle.
  - Report problems at https://github.com/AnonyMap/kindle-mtp/issues
    with the version, the two logs, and host-check.sh output if relevant.

Includes uMTP-Responder by Viveris Technologies (GPLv3); license, source
and patch in mtp/umtprd-source/.
