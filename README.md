# usbmtp

A [KOReader](https://github.com/koreader/koreader) plugin for jailbroken Kindles. It lets you copy
books from a computer over USB **while KOReader stays open**, even with a book open.

Normally that isn't possible: while KOReader runs, the Kindle's USB drive mode is switched off,
so you have to exit KOReader every time you want to add a book. This plugin connects the Kindle
to the computer in one of two ways, without exiting:

- **MTP**: the computer browses the Kindle's folders, like a phone. Built into Windows and Linux.
- **USB drive**: the computer sees an empty drive called **TO KINDLE**. Drop books on it and eject
  it, and the Kindle adds them to its library. Works on any computer, including a Mac, with
  nothing to install.

> This plugin was coded with AI by someone who isn't a developer. All of the code is open here
> for anyone to use and audit.

## Which Kindles

| Kindle | Released | Status |
|---|---|---|
| Kindle (10th generation) | 2019 | **Works.** Tested on firmware 5.16.8 |
| Kindle Paperwhite (10th generation, "PW4") | 2018 | Should work, not tested yet. Same kernel as the Kindle 10th gen¹ |
| Kindle Oasis (10th generation, "Oasis 3") | 2019 | Should work, not tested yet. Same kernel¹ |
| Kindle Oasis (9th generation, "Oasis 2") | 2017 | Unknown. Kernel not confirmed. The plugin checks the kernel and refuses to start if it doesn't match |
| Older Kindles (Paperwhite 3 and earlier, Voyage, Oasis 1, Kindle 8th gen and earlier) | 2016 and before | Not supported. Older kernel (3.0.35); the plugin refuses to start |
| Kindles that show up as an **MTP device** on their own (Kindle Scribe since firmware 5.16.3, and other recent models) | | Use [kindlemtp.koplugin](https://github.com/danihrndzld/kindlemtp.koplugin) instead. It uses Amazon's own MTP |

¹ Owners report kernel `4.1.15-lab126` for the Paperwhite 4
([report](https://github.com/zampierilucas/kindle-hid-passthrough/issues/167)) and the Oasis 3
([report](https://github.com/zampierilucas/kindle-hid-passthrough/issues/314)), the same as the
Kindle 10th gen this was built on.

**Quick check:** exit KOReader and plug the Kindle into a computer.
- If it shows up as a **USB drive**, this plugin is for you (if your model is in the table).
- If it shows up as an **MTP device**, use kindlemtp.

Either plugin refuses to start on the wrong Kindle, so trying the wrong one does no harm.

You also need:
- **A jailbroken Kindle with KOReader installed.** The [Kindle Modding wiki](https://kindlemodding.org/)
  has the current jailbreaks and which firmware each supports. Not every firmware can be jailbroken.
- **A USB cable that carries data**, not just power.

If you try it on a model marked "not tested yet", please open an issue saying whether it worked.

## Install

1. Download `usbmtp.koplugin-vX.Y.zip` from [Releases](https://github.com/AnonyMap/usbmtp/releases)
   and unzip it. You get a folder called `usbmtp.koplugin`.
2. Exit KOReader, plug the Kindle into the computer, and copy that folder into
   `koreader/plugins/` on the Kindle. If an older `usbmtp.koplugin` is there, replace it.
3. Eject and unplug the Kindle, then start KOReader **from KUAL** as usual.
4. Check it's there: Tools (wrench icon) → **USB file transfer** → **About**.

After this, the plugin can update itself over Wi-Fi (see [Updating](#updating)).

## Use

Start it from **Tools → USB file transfer → Start USB file transfer**. You can also:
- **Start it when plugged in:** in the same menu, set *When plugged into a computer* to **ask
  first** or **start automatically**. Wall chargers are ignored.
- **Use a gesture:** Settings → Taps and gestures → Gesture manager → *General* → **Toggle USB
  file transfer**.

While it's on, a window shows the status:
- **Stop** ends it. Then you can unplug.
- **Hide** lets you keep reading. Reopen the window from the menu or gesture.

When it stops, any new books get an **Open** button.

It also stops by itself if you unplug the cable, the Kindle goes to sleep, KOReader closes, or no
computer connects within 10 minutes.

**Connection** in the same menu picks between **MTP** (the default) and **USB drive**. It's
remembered, so you only set it once per computer you use.

### Windows

Use **MTP** (the default):
1. Start USB file transfer on the Kindle, then plug it in.
2. The Kindle appears in File Explorer under *This PC*. Copy books into its `documents` folder.
3. Tap **Stop** on the Kindle, then unplug.

MTP on Windows hasn't been tested yet. If it doesn't show up, use **USB drive** instead (see the
Mac steps below; on Windows, eject the drive by right-clicking **TO KINDLE** → **Eject**).

### Mac

macOS can't use MTP devices without an extra app, so use **USB drive**:
1. On the Kindle: Tools → USB file transfer → **Connection** → **USB drive**. You only do this once.
2. Plug the Kindle into the Mac and tap **Start USB file transfer**. The first time, the Kindle
   takes a moment to prepare the drive.
3. A drive called **TO KINDLE** appears in Finder. Drag your books onto it. Folders are kept.
4. **Eject TO KINDLE** in Finder (the ⏏ button next to it). The Kindle adds the books to its
   library, empties the drive, and offers to open them.

**Always eject before unplugging.** If you don't, the Kindle leaves the books on the drive and
asks you to start again and eject. That way a half-copied book never replaces a good one.

The drive only adds books. It can't show you or delete what's already on the Kindle. For that,
use an MTP app such as [OpenMTP](https://openmtp.ganeshrvel.com/) with the **MTP** connection.
Quit Photos and Image Capture first, because macOS's photo import grabs MTP devices.

### Linux

Use **MTP** (the default):
1. Start USB file transfer on the Kindle, then plug it in.
2. "Kindle (MTP)" appears in your file manager (Dolphin, GNOME Files and others). Copy books
   into `documents`.
3. Tap **Stop** on the Kindle, then unplug.

**USB drive** works on Linux too. Eject TO KINDLE from the file manager when you're done.

### Calibre

Calibre talks to the Kindle over **MTP**. It sends EPUBs to the `documents` folder, which suits
KOReader.

1. Start USB file transfer and plug in. Calibre asks **"Manage the Kindle (MTP)?"**. Choose
   **Yes**.
2. Recommended, once: right-click Calibre's device icon → **Configure this device** → under
   **Ignored folders**, untick `koreader`. That makes Calibre's scan much faster.
3. Send books as usual, then tap **Stop** on the Kindle.

**Calibre doesn't see the Kindle on Linux?** Only one program can use an MTP device at a time,
and KDE's `kiod6` grabs it in the background. Quit Calibre, run `killall kiod6`, start Calibre,
and replug. To fix it for good, install
[`tools/69-zz-usbmtp-calibre.rules`](tools/69-zz-usbmtp-calibre.rules) (instructions inside).
After that, Calibre always gets the Kindle, and the file manager stops showing it.

KOReader's own Calibre plugin can then search your books by series, tags and author: Tools →
Calibre → Search settings → Manage libraries → **Rescan disk for calibre libraries**.

On a Mac, use Calibre with the USB drive: *Connect/share → Connect to folder*, pick TO KINDLE,
send the books, then eject.

## How it works

**Why KOReader can't do this on its own.** A stock Kindle shares its storage as a USB drive by
handing the whole partition to the computer, which means unmounting it on the Kindle. KOReader
lives on that partition, so its launcher pauses Amazon's USB service for as long as KOReader
runs.

The plugin gets around that without ever unmounting the Kindle's storage:

- **MTP mode** swaps the Kindle's USB driver for its own. A small bundled program,
  [uMTP-Responder](https://github.com/viveris/uMTP-Responder), copies files in and out of the
  Kindle's storage while it stays mounted.
- **USB drive mode** shares a separate 256 MB disk image (`koreader/usbmtp-drive.img`) instead of
  the Kindle's storage. When the computer ejects it, the Kindle reads the image and copies the
  books into `documents/`.

The details:
- Shell scripts in `usbmtp.koplugin/mtp/` do the system work, and the Lua plugin is the
  interface and safety checks around them.
- Before changing anything, the start script checks that it's safe to start, and saves the
  stock USB driver's settings. If any step fails, everything is rolled back.
- Stop restores the stock driver exactly as it was, and checks it isn't sharing the Kindle's
  storage while it's still mounted.
- A small watcher stops the transfer if KOReader crashes. Rebooting the Kindle always restores
  stock USB.
- In USB drive mode, the Kindle formats and reads the image itself (`usbmtp_fat.lua`), so it
  needs nothing beyond the Kindle's own kernel modules. It only imports a drive the computer
  ejected properly, and only empties it once every book made it across.

The scripts also run without the plugin, from KOReader's terminal or SSH:

```sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-start.sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-status.sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-stop.sh
```

## Updating

**Tools → USB file transfer → Check for updates** looks for a newer release on this page over
Wi-Fi. It shows the release notes and asks before installing. Then restart KOReader.

It only runs when you tap it, never on its own. It refuses a download that doesn't match its
checksum or is missing files. The previous version is kept until the new one has loaded
successfully, so a bad update can be undone by renaming `usbmtp.koplugin.old` back.

## Limits and concerns

- **It runs as root and swaps kernel modules** while KOReader runs. Nothing is written to the
  Kindle's system partitions, and a reboot always restores stock USB. Still, it's worth reading
  [How it works](#how-it-works), or the code, before trusting it.
- **Tested on one Kindle so far** (the Kindle 10th gen, with Linux and Calibre). Not yet
  confirmed on real hardware:
  - Windows and macOS;
  - USB drive mode on any computer, including whether ejecting is noticed;
  - large files (50 MB+);
  - the plug-in prompt;
  - updating over Wi-Fi.
  
  An automated test suite covers all of it against a simulated Kindle on every change.
- **USB drive mode** uses 256 MB of the Kindle's storage once it has been set up.
  Tools → USB file transfer → Connection → **Erase the USB drive** frees it.
- **Don't edit the `koreader` folder from the computer** while connected over MTP.

## Troubleshooting

- **The computer doesn't see the Kindle:**
  - check the plugin says it's on;
  - try another cable (some only charge);
  - on a Mac, use **USB drive**.
- **Something on the Kindle seems stuck:** Tools → USB file transfer → **Reset USB (after a crash)**, or reboot
  the Kindle.
- **Details:** **Status / diagnostics** in the plugin's menu shows the current state and recent
  log lines. The full logs are `mtp.log` and `umtprd-last.log` in
  `koreader/plugins/usbmtp.koplugin/mtp/`.
- **Linux:** [`tools/host-check.sh`](tools/host-check.sh) shows whether the computer sees the
  Kindle and which program is holding it.

When reporting a problem, [open an issue](https://github.com/AnonyMap/usbmtp/issues) with your
Kindle model, the plugin version (from **About**), and the two log files.

## For developers

| Path | What it is |
|---|---|
| `usbmtp.koplugin/` | The plugin, the only folder that goes on the Kindle |
| `usbmtp.koplugin/mtp/` | Start, stop, status and watcher scripts; the umtprd binary and its config |
| `usbmtp.koplugin/mtp/umtprd-source/` | uMTP-Responder source, license (GPLv3) and our one patch |
| `usbmtp.koplugin/usbmtp_drive.lua`, `usbmtp_fat.lua` | USB drive mode |
| `usbmtp.koplugin/usbmtp_updater.lua` | The self-updater |
| `tools/` | umtprd build script, release script, Linux diagnostics, Calibre udev rule |
| `tests/` | The test suite |

- **Tests:** `sudo sh tests/run.sh` runs the real scripts and plugin code against a simulated
  Kindle in a private mount namespace. `.github/actions-test-deps.sh` installs what the full
  suite needs (including a koreader-base checkout for the updater tests). GitHub runs it on every
  push and pull request.
- **The umtprd binary** is a reproducible static ARMv7 build of uMTP-Responder v1.10.1 with one
  patch (a hang on exit after a failed USB init): `sh tools/build-umtprd.sh`.
- **Releasing:** bump `usbmtp.koplugin/mtp/VERSION` and merge. Then publish a GitHub release with
  the tag `v<VERSION>`. The Release workflow tests, builds and attaches the zip and its checksums.
  If that fails, re-run it from **Actions → Release → Run workflow**.

## License

The plugin and scripts are MIT (see `LICENSE`). The bundled `umtprd` binary is uMTP-Responder by
Viveris Technologies, licensed GPLv3. Its license, full source and our patch are in
`usbmtp.koplugin/mtp/umtprd-source/`.
