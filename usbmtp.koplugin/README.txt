USB file transfer (MTP) for KOReader on Kindle - (version: see mtp/VERSION or Menu > About)
=========================================================================
Lets your computer copy books over USB while KOReader stays open,
from the file browser (any view, including mosaic/bookshelf) or inside a book.
Built for: Kindle 10th gen (2019), firmware 5.16.x, kernel 4.1.15-lab126.
Nothing is permanent: if anything gets stuck, rebooting the Kindle restores stock USB.

INSTALL
  1. Exit KOReader so the Kindle appears as a USB drive on your computer.
  2. Copy the "usbmtp.koplugin" folder into  koreader/plugins/  on the Kindle
     (replace the old one if you installed v0.1).
  3. Eject, unplug, start KOReader from KUAL.

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
  Bazzite: "Kindle (MTP)" appears in Dolphin's / Files' sidebar.
  Mac: use OpenMTP; quit Photos and Image Capture first.

CALIBRE
  Calibre sees it as an MTP device and sends EPUBs to "documents".
  - Close it in Dolphin first (KDE: "killall kiod6" if Calibre can't open it);
    only one program can use an MTP device at a time.
  - Answer Yes to "Manage the Kindle (MTP)?".
  - Once: right-click the device icon > Configure this device > Ignored
    folders: untick "koreader" (much faster scans).
  - KOReader can then search your Calibre metadata: Tools > Calibre >
    Search settings > Manage libraries > Rescan disk for calibre libraries.

SAFETY RAILS (automatic)
  - Stops by itself when you unplug the cable, the Kindle sleeps, KOReader
    exits/restarts, or the MTP program dies.
  - Saves the open book's progress before sharing starts.
  - If the computer replaces or deletes the book you have open, that book
    is closed (sharing continues) so KOReader never reads a half-copied file.
  - Keeps the Kindle awake while sharing.
  - After a crash, offers to clean up on the next launch.
  Don't edit the "koreader" folder from the computer while sharing.

IF IT DOESN'T WORK
  Menu > USB file transfer (MTP) > Status / diagnostics
  Then send me (from koreader/plugins/usbmtp.koplugin/mtp/ after exiting
  KOReader): mtp.log and umtprd-last.log
  On Bazzite also:  journalctl -k -b | grep -iE "usb|1d6b" | tail -20

Includes uMTP-Responder by Viveris Technologies (GPLv3); license and
source in mtp/umtprd-source/.
