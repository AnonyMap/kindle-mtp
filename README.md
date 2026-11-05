# usbmtp

A [KOReader](https://github.com/koreader/koreader) plugin that lets a computer copy books to a
jailbroken Kindle over USB **while KOReader keeps running**, using MTP, or as a plain USB drive
that any computer can use with no extra app (a Mac included). That includes from inside a book.

Normally KOReader on Kindle has no USB file transfer. Its launcher pauses Amazon's `volumd`
daemon for as long as KOReader runs, because stock USB mass storage would unmount the partition
KOReader itself lives on (`/mnt/us`). MTP avoids that: files are copied through the mounted
filesystem, so nothing gets unmounted. The USB drive mode avoids it differently: the computer
gets a separate disk image, never the storage the Kindle has mounted.

> **Status: v0.8, early but working.** Confirmed on a Kindle 10th gen (FW 5.16.8) with Bazzite
> Linux (KDE): copying books from the file manager, and sending books from Calibre (Flatpak
> 9.17). Everything else is covered by the simulated-Kindle test suite (see [Tests](#tests)) but
> not yet confirmed on hardware; see [Not yet tested on hardware](#not-yet-tested-on-hardware).

> [!IMPORTANT]
> **This plugin was written by AI.** I'm sceptical of AI-made software myself, so you should know
> before you install it. Details in [How this was made](#how-this-was-made).

## On a Mac

macOS can't talk to MTP devices on its own, so use the plugin's **USB drive** connection instead.
It needs nothing installed on the Mac.

1. [Install the plugin](#install) on the Kindle, then start KOReader.
2. On the Kindle: Tools (wrench) → **USB file transfer** → **Connection** → **USB drive**.
   (Once. It's remembered.)
3. Plug the Kindle into the Mac and tap **Start USB file transfer**. The first time, the Kindle
   takes a moment to prepare the drive.
4. A drive called **TO KINDLE** appears in Finder. Drag your books onto it.
5. **Eject TO KINDLE** in Finder (the ⏏ button next to it). The Kindle then adds the books to
   its library and offers to open them.

Always eject before unplugging. If you don't, the Kindle leaves the books on the drive and asks
you to start again and eject. That way a half-copied book never replaces a good one.

The drive only adds books: it can't show or delete what's already on the Kindle. For that, use an
MTP app such as [OpenMTP](https://openmtp.ganeshrvel.com/) with the **MTP** connection (quit
Photos and Image Capture first). More in [USB drive mode](#usb-drive-mode-mac-windows-no-app).

## Supported devices

| Device | Firmware | Kernel | Status |
|---|---|---|---|
| Kindle 10th gen (2019, "KT4") | 5.16.8 | 4.1.15-lab126 | **Works** (file manager and Calibre confirmed) |
| Other Kindles | | | Refused by a kernel-version check. Most likely to work: other older (non-MTP) Kindles whose kernel ships `usb_f_fs.ko` |

## usbmtp vs. kindlemtp: which one do I need?

[kindlemtp.koplugin](https://github.com/danihrndzld/kindlemtp.koplugin) solves the same problem
for a different set of Kindles. You need exactly one of them, and which one depends on how your
Kindle connects to a computer on **stock firmware**, with KOReader closed:

| If, with KOReader closed, your Kindle shows up as… | Your Kindle | Use |
|---|---|---|
| a **USB drive** (a drive letter, or a mounted disk) | Older models without Amazon's MTP software. Currently only the Kindle 10th gen (2019) is supported; others are refused by a kernel check (see [Supported devices](#supported-devices)) | **usbmtp** (this plugin) |
| an **MTP device** that needs an MTP app on a Mac (e.g. "Kindle Scribe") | Models where Amazon switched USB to MTP (Scribe, Colorsoft, recent Paperwhites; firmware 5.16+) | **kindlemtp** |

To check from KOReader's terminal or SSH: `ls /usr/bin/mtp.sh`. If the file exists, use
kindlemtp; if not, use usbmtp.

How they differ under the hood:

| | usbmtp (this plugin) | kindlemtp |
|---|---|---|
| MTP program | Brings its own (uMTP-Responder, bundled) | Remote-controls Amazon's built-in `tizen-mtp` |
| USB setup | Swaps the stock mass-storage gadget for its own FunctionFS gadget, and restores it afterwards | Uses Amazon's existing MTP gadget |
| Needs | Kernel FunctionFS modules (present on the Kindle 10th gen) | Amazon's `mtp.sh` and `tizen-mtp` (firmware 5.16+ on MTP models) |
| Storage it serves | `/mnt/base-us` (FAT32) | `/mnt/base-us` (ext4 on those models) |

Each one refuses to start on the other's devices, so installing the wrong one does no harm; it
just won't start. kindlemtp's README says older Kindles don't need it because their mass storage
"works without this plugin". That's true only after exiting KOReader. While KOReader runs, mass
storage is switched off, and usbmtp exists to fill that gap.

## Install

1. Exit KOReader so the Kindle shows up as a USB drive.
2. Copy the `usbmtp.koplugin` folder into `koreader/plugins/` on the Kindle. If you have an older
   version, replace the old folder.
   - If you used GitHub's **Download ZIP**, it unpacks to `usbmtp-main/`. Copy the
     `usbmtp.koplugin` folder from **inside** it, not the outer folder. KOReader only loads
     folders whose names end in `.koplugin`, so it ignores `usbmtp-main/`.
3. Eject, unplug, and start KOReader **from KUAL**. The plugin needs KOReader's normal launcher.
4. Check the version: Tools → **USB file transfer** → **About (vX.Y)** (called *USB file transfer (MTP)* before v0.8).

## Use

- **Menu:** Tools (wrench) → **USB file transfer** → **Start USB file transfer**
- **On plug-in:** set *When plugged into a computer* to **ask first** or **start automatically**
  (default: do nothing). Works on any screen. Wall chargers are ignored: only a computer that
  actually connects counts. So is charging resuming with the cable still in (when a full
  battery tops up, or right after you tap Stop): only a cable that was actually unplugged and
  plugged back in counts as a new plug-in.
- **Gesture:** Gesture manager → *General* → **Toggle USB file transfer**

**Connection** in the same menu picks how the computer sees the Kindle: **MTP** (default) or
**USB drive** (see [below](#usb-drive-mode-mac-windows-no-app)).

While sharing, a dialog offers **Stop** or **Hide** (keep reading). With Hide, a small **ᴍᴛᴘ**
appears in the reader's status bar while sharing is on; you can turn it off in the menu. Sharing
stops by itself when you unplug, when the Kindle sleeps, or when KOReader exits or crashes. It
also stops if no computer connects within 10 minutes, so the Kindle can sleep again.

After Stop, the books that arrived each get an **Open** button (the first five; the rest are in
the file browser). That covers books that appeared in `documents/` during the session, in any
format KOReader opens. Other new files (Calibre's `metadata.calibre`, say) are only counted, and
KOReader's own `.sdr` metadata is left out.

If the Kindle goes to sleep during a transfer, sharing stops. When it wakes with the cable still
in, the message offers **Start again**.

On the computer, with MTP:
- **Linux:** shows up as "Kindle (MTP)" in Dolphin / GNOME Files.
- **macOS:** macOS has no MTP support of its own. Use the **USB drive** connection instead, or an
  MTP app such as [OpenMTP](https://openmtp.ganeshrvel.com/) (quit Photos and Image Capture
  first: macOS's camera service grabs MTP devices).
- **Windows:** should work in Explorer (untested).

Don't edit the `koreader` folder from the computer while sharing.

## USB drive mode (Mac, Windows, no app)

Every computer can write to a USB stick without extra software, so this mode makes the Kindle
look like one. Set **Connection → USB drive**, then start as usual:

1. A drive called **TO KINDLE** appears on the computer. It starts empty.
2. Copy books onto it (folders are kept; a `documents` folder dropped on it is merged).
3. **Eject it** on the computer (Finder's eject button, *Safely Remove* on Windows).
4. The Kindle notices, stops sharing, copies the books into `documents/`, empties the drive,
   and offers to open them.

What it is: a 256 MB disk image, `koreader/usbmtp-drive.img`, formatted FAT16. The Kindle's own storage stays mounted the whole time, so
KOReader keeps running, and the computer can't see or delete the books already on the Kindle.
It's one-way, for adding books. Use MTP to manage what's there.

Details:
- The first start creates the image, which takes a little while (writing 256 MB). It then stays,
  using its full size on the Kindle; **Erase the USB drive** frees the space.
- A file that's already on the Kindle with identical contents is skipped. A newer copy of the
  book you have open closes it first.
- If something can't be copied (no space, a folder with that name in the way, a file cut short),
  it stays on the drive and the message says which and why. The drive is only emptied when
  everything made it. Empty files (what an interrupted copy leaves) and hidden files are skipped
  and counted. Two files that would land on the same name get "(2)".
- **Not ejected?** If you unplug, tap **Stop** or the Kindle sleeps while the computer still has
  the drive open, nothing is added, because a file can have its full size on the drive with its
  contents never written. The books stay on the drive. Tap **Start again**, then eject it on the
  computer. The Kindle can tell from the marks Windows, macOS and Linux leave on a FAT drive while
  it's in use.
- If KOReader exits before the drive is ejected, the books wait on it and are added after the
  next session.
- Calibre doesn't recognise it as a Kindle. Use *Connect/share → Connect to folder* on the
  TO KINDLE drive, or use MTP with Calibre.
- If the computer offers to reformat the drive, don't. If it was reformatted anyway, the Kindle
  says it can't read it, and **Erase the USB drive** fixes that. (The Kindle only reads the drive
  the way it formatted it: FAT16, 256 MB.)

## Updating

From v0.5 on, the plugin updates itself from this repo's
[GitHub Releases](https://github.com/AnonyMap/usbmtp/releases) over Wi-Fi:
**Tools → USB file transfer → Check for updates** (*USB file transfer (MTP)* before v0.8).

- **When it runs:** only when you tap that menu entry, never automatically. It won't update
  while any transfer is running, including one started over SSH or left over from a crash.
- **What you see:** it shows the release notes and asks before installing. Afterwards it puts
  Wi-Fi back how your KOReader Wi-Fi setting says.
- **Restarting:** after an update, KOReader needs a restart. Until then, USB file transfer is
  unavailable, so the old code never runs the new scripts.

Before changing anything, it refuses a release that:
- isn't the latest published release, or doesn't have a plain version number (`v0.7`);
- fails its `SHA256SUMS` checksum, or can't be read completely;
- contains anything other than plain files and folders under `usbmtp.koplugin/` (no `../`, no
  absolute paths, no symlinks);
- is missing any file the plugin needs to load and run;
- has a version inside the zip that doesn't match the release tag;
- has Lua code that doesn't compile.

**The swap:**
- The new copy is unpacked next to the old one, synced to flash, and swapped in with two
  renames.
- If the second rename fails, the old copy is put back. If even that fails, the message says
  exactly which folder to rename back.
- The previous version stays as `usbmtp.koplugin.old`, which KOReader ignores. It's deleted the
  first time the new version loads successfully. If a new version ever failed to load, renaming
  that folder back restores the old one.

v0.4 and earlier have no updater, so install v0.5 by hand once (see [Install](#install)).

## Using with Calibre

Calibre's built-in MTP driver picks the Kindle up as a generic MTP device. That suits KOReader:
Calibre sends **EPUB** by default (not the Kindle formats it would pick for a stock Kindle), and
it puts books in the Kindle's `documents` folder.

1. On the Kindle, start USB file transfer and plug in.
2. Make sure your desktop isn't holding the device. Only one program can use an MTP device at a
   time.
   - KDE's `kiod6` claims the device in the background as soon as it's plugged in or browsed once,
     even with no Dolphin window open.
   - When that happens, Calibre fails to open it **silently** and won't retry until you replug.
   
   Two fixes:
   - **One-off:** quit Calibre, run `killall kiod6` (GNOME: eject it in Files), start Calibre,
     then replug the Kindle.
   - **Permanent:** install [`tools/69-zz-usbmtp-calibre.rules`](tools/69-zz-usbmtp-calibre.rules).
     It hides this device from the desktop's device handling so Calibre always gets it; the file
     manager stops showing it. Instructions are inside the file.
     (Installed it under its earlier name, `69-zz-kindle-mtp-calibre.rules`? That file is
     identical and keeps working; no need to change anything.)
   
   To see who holds the device, run [`tools/host-check.sh`](tools/host-check.sh): look for
   `driver=usbfs`, then the process list.
3. Calibre asks **"Manage the Kindle (MTP)?"**. Choose **Yes**.
4. Recommended, once: right-click Calibre's device icon → **Configure this device**.
   - Under **Ignored folders**, untick `koreader`. KOReader's own files are thousands of small
     files that slow Calibre's scan.
   - Check that the send-to folder is `documents`.
   
   Calibre remembers these settings for this Kindle, because the plugin reports the Kindle's
   real serial number.
5. Send books as usual. Tap **Stop** on the Kindle when Calibre has finished.

Calibre also writes its `metadata.calibre` index to the device. KOReader's Calibre plugin can then
search and browse your books by series, tags and author: **Tools → Calibre → Search settings →
Manage libraries → Rescan disk for calibre libraries**.

The Flathub (Flatpak) build of Calibre has the USB access this needs. It was confirmed working on
Bazzite KDE with Calibre 9.17.

## How it works

`usbmtp.koplugin/mtp/` holds standalone shell scripts that do all the system work. The Lua
plugin is just the UI and safety checks around them.

**`mtp-start.sh`**
1. Checks that it's safe to start; nothing is changed until all checks pass.
2. Copies umtprd and its config to `/var/tmp`. It stamps in the Kindle's own serial number (from
   `/proc/usid`, as stock USB mode does) and the plugin version.
3. Saves the stock `g_mass_storage` module's parameters, then unloads it.
4. Builds a configfs USB gadget with a FunctionFS function (falls back to the legacy `g_ffs`
   module if configfs isn't available).
5. Starts [uMTP-Responder](https://github.com/viveris/uMTP-Responder) from `/var/tmp`, serving
   `/mnt/base-us` (the real vfat partition under Amazon's `fsp` FUSE layer).
6. Binds the gadget to the `ci_hdrc.0` USB controller.

If any step fails, it rolls back automatically.

**`mtp-stop.sh`** reverses all of this and reloads the stock driver with its original
parameters. It works in a kernel-safe order:
1. Unbind the gadget from the USB controller.
2. Stop the daemon.
3. Unmount FunctionFS.
4. Only then remove the configfs function.

On Linux 4.1, removing the function while FunctionFS is still mounted is a use-after-free in
`f_fs.c`. If anything can't be undone, the script reports it and keeps its saved state, so a
retry can still restore stock USB.

**USB drive mode** (`KMTP_DRIVE=<image> mtp-start.sh`) skips umtprd: after the same checks and
saving the stock driver's settings, it loads `g_mass_storage` again, backed by the image
(`removable=1`) and with its own USB identity (`1d6b:0104`, "Kindle drive"), so the computer
can't mistake it for the Kindle's storage. When the computer ejects it, the kernel closes the
image and empties the LUN's `file` attribute, which is what the plugin watches for. Stop unloads
it and restores the stock driver as usual. The plugin formats and reads the FAT image itself
(`usbmtp_fat.lua`: just the FAT16 layout it creates, with long names), so nothing beyond the
stock kernel modules is needed on the Kindle.

**`mtp-watch.sh`** is started by the plugin's start call. If KOReader dies without stopping
MTP, it stops MTP within about a second.

**Plugin safety checks**
- Watches the USB controller state, so it can stop on unplug.
- Watches the daemon, so it can stop if it dies.
- Watches the open book and closes it if the computer replaces or deletes it.
- Keeps the Kindle awake while sharing.
- Wraps `Device.exit`, so sharing always stops when KOReader exits; a crash watcher covers
  crashes.
- Offers to clean up after a crash.

Nothing is permanent: rebooting the Kindle always restores stock USB.

The scripts also work without the plugin, from KOReader's terminal or SSH:

```sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-start.sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-status.sh
sh /mnt/us/koreader/plugins/usbmtp.koplugin/mtp/mtp-stop.sh
```

## Troubleshooting

- **Which version is on the Kindle?** Tools → USB file transfer → **About (vX.Y)**, or the
  file `usbmtp.koplugin/mtp/VERSION`. If it isn't the version you expect, KOReader is still
  loading an old copy; see [Install](#install).
- **Calibre doesn't see the Kindle**, but the file manager does: another program is holding the
  MTP device. On KDE that's `kiod6`. See step 2 of [Using with Calibre](#using-with-calibre).
- **The computer doesn't see the Kindle at all:**
  - check that the plugin says "USB file transfer is on";
  - check that the cable carries data, not just power;
  - on a Mac, use the **USB drive** connection, or an MTP app (OpenMTP).
- **Kindle side:** run **Status / diagnostics** from the plugin menu. It shows:
  - the current state;
  - the end of both logs;
  - what arrived in the last session.
  
  The full logs are in `koreader/plugins/usbmtp.koplugin/mtp/`: `mtp.log` (the scripts) and
  `umtprd-last.log` (the MTP program).
- **Computer side (Linux):** run [`tools/host-check.sh`](tools/host-check.sh) with the Kindle
  plugged in and MTP on. It shows:
  - whether the device is visible;
  - whether your user can open it;
  - what udev decided about it;
  - which programs hold it.
  
  The kernel log helps too:
  ```sh
  journalctl -k -b | grep -iE "usb|1d6b" | tail -20
  ```
- **Anything stuck:** reboot the Kindle. That always restores stock USB.

When reporting a problem, open an issue with the plugin version, the two log files, and the
`host-check.sh` output if it's a detection problem.

## Not yet tested on hardware

These pass in the simulated-Kindle suite but haven't been confirmed on a real device yet:
- file names longer than 72 characters (fixed in v0.3; before that they failed to list);
- large files (50 MB+), with the 8 KiB USB buffers on the i.MX6;
- automatic stop when the cable is pulled without tapping Stop;
- the "ask to start when plugged in" prompt, and wall chargers correctly not triggering it;
- the plug-in prompt staying quiet when a full battery starts charging again (new in v0.7;
  depends on when the Kindle's power daemon reports charging, which the suite can only guess);
- **Open** after Stop, and **Start again** after the Kindle wakes up (new in v0.7);
- Hide and keep reading during a transfer;
- stock USB working normally after exiting KOReader;
- **Check for updates** against the real GitHub (new in v0.5; tested against fake releases);
- **USB drive mode** (new in v0.8) on any real computer: macOS and Windows mounting the image,
  ejecting it being noticed (it relies on the computer sending the standard "eject" SCSI command,
  which Finder and Windows' Safely Remove normally do), and the speed of creating the image;
- Windows and macOS hosts.

Reports are welcome.

## Repository layout

| Path | What it is |
|---|---|
| `usbmtp.koplugin/` | The plugin. This is the only folder that goes on the Kindle |
| `usbmtp.koplugin/mtp/` | Start, stop, status and watcher scripts, umtprd and its config, version file |
| `usbmtp.koplugin/mtp/umtprd-source/` | uMTP-Responder source, license (GPLv3) and our patch |
| `usbmtp.koplugin/usbmtp_updater.lua` | The self-updater (GitHub Releases) |
| `usbmtp.koplugin/usbmtp_drive.lua`, `usbmtp_fat.lua` | USB drive mode: the image, importing from it, and a small FAT formatter/reader |
| `tools/make-release.sh` | Builds the release zip and `SHA256SUMS` into `dist/` |
| `.github/workflows/release.yml` | Publishes a release when a `v*` tag is pushed |
| `tools/build-umtprd.sh` | Reproducible rebuild of the umtprd binary |
| `tools/host-check.sh` | Linux host diagnostics |
| `tools/69-zz-usbmtp-calibre.rules` | Optional udev rule so KDE/GNOME don't block Calibre |
| `tests/` | Simulated-Kindle test suite |

## Building the MTP binary

`usbmtp.koplugin/mtp/bin/umtprd` is a static ARMv7 build of uMTP-Responder v1.10.1 (commit
`85a26f4`), with one patch from `usbmtp.koplugin/mtp/umtprd-source/`. The patch fixes a hang on
exit after a failed USB init. Builds are reproducible:

```sh
sh tools/build-umtprd.sh   # needs gcc-arm-linux-gnueabi; see the script for Bazzite/Fedora
```

## Releasing

1. Bump `usbmtp.koplugin/mtp/VERSION`, run the tests, and merge to `main`.
2. Make the release, either way:
   - **On GitHub:** Releases → **Draft a new release** → new tag `v<VERSION>` (e.g. `v0.7`) →
     write notes → **Publish**.
   - **From git:**
     ```sh
     git tag v0.7 && git push origin v0.7
     ```
3. The **Release** workflow runs on the new tag:
   - checks that the tag matches `VERSION`;
   - builds `usbmtp.koplugin-v<VERSION>.zip` and `SHA256SUMS` with `tools/make-release.sh`
     (reproducible: same code, same zip);
   - attaches them to the release, creating the release if you pushed only a tag. Your release
     notes are kept.
   
   The plugin's **Check for updates** then offers it. The notes you wrote are what it shows.

If a release ends up without its two files (for example, the workflow failed), go to
**Actions → Release → Run workflow**, enter the tag, and run it again. The plugin refuses a
release that's missing them, so nothing breaks in the meantime.

## Tests

The **Tests** workflow runs the whole suite on every push and pull request. The **Release**
workflow runs it again, then installs the freshly built zip with the real updater
(`tests/check_release_zip.lua`) before publishing. A release that fails either step is never
published.

`tests/run.sh` runs the real scripts and the real plugin code against a fake Kindle, inside a
private mount namespace. The fake Kindle provides:
- a fake `/sys` and `/proc`;
- stand-ins for `insmod`, `mount` and the other system tools;
- a fake daemon.

If BusyBox is installed, the scripts run under BusyBox ash, as on the device. The suite covers:
- normal start and stop;
- every refusal case;
- rollback after each kind of failure;
- the g_ffs fallback;
- crash recovery;
- a hung daemon;
- a failed driver restore;
- the plugin's behaviour in books, on unplug, sleep, exit and charger vs. computer;
- the crash watcher;
- the serial number and version stamping;
- the Linux 4.1 FunctionFS teardown order (the fake flags the use-after-free ordering);
- the update flow in the plugin;
- the list of received books (new files only; old books, `.sdr` metadata and dot-files left
  out), and opening them from the Stop message;
- the stock driver never exporting the storage the Kindle still has mounted, even if its saved
  settings would, and Stop failing (never "Safe to unplug") if that can't be undone;
- charging events that aren't plug-ins (battery top-up, re-enumeration after Stop) being
  ignored;
- the three plug-in modes, including migrating the old setting;
- USB drive mode, end to end: creating the image, sharing it under its own USB identity,
  noticing the eject, importing (folders, Mac junk skipped, already-there files, a newer copy of
  the open book, a file that can't be copied), a drive that wasn't ejected, leftovers after an
  exit, sleep, a drive the computer reformatted, and erasing;
- the FAT code against real tools: our images pass `fsck.fat` and take files from mtools, which
  read back byte for byte (long Unicode names, fragmented files); a file cut short is refused,
  and a drive reformatted by `mkfs.fat` or deliberately malformed is reported, never misread;
- the status-bar marker coming and going with the session;
- a luacheck pass, which catches e.g. a function used before it's defined;
- the updater itself, using KOReader's real unzip and checksum code against fake GitHub
  releases:
  - a good update;
  - an up-to-date check;
  - a corrupted download;
  - files outside the plugin folder;
  - a version mismatch;
  - missing files;
  - no release yet, and being offline;
  - a swap that fails halfway and has to roll back.

```sh
sudo sh tests/run.sh
# the FAT tests need mtools and dosfstools; the updater tests need a koreader-base checkout,
# zip, lua-dkjson, lua-filesystem and libarchive13:
sudo KOREADER_BASE=/path/to/koreader-base sh tests/run.sh
# (.github/actions-test-deps.sh installs everything and fetches the pinned koreader-base ffi/)
```

## How this was made

This plugin was developed with an AI model, Anthropic's Claude, over a single long conversation.
I didn't write the code myself. My part was directing it, deciding what to build, and testing it
on my own Kindle. I'm sceptical of AI-made software, so here's what that means in practice.

**How it was checked:**
- Claims about how the Kindle, Linux kernel, KOReader, uMTP-Responder and Calibre behave were
  checked against their source code, not assumed.
- Four separate AI reviews went through the code looking for bugs, each given only the code and
  a short description, not the development conversation or its conclusions. All the serious
  findings have been fixed:
  - **First review:**
    - a kernel use-after-free in the stop order;
    - USB buffers too small for long filenames.
  - **Second review:** the updater would install a broken release (missing files, or code that
    doesn't compile), leaving a plugin that couldn't load or update itself. It also found smaller
    issues too, mostly edge cases in updating, sleep and unplugging.
  - **Third review (v0.7):** if the stock USB driver came back sharing the storage and couldn't
    be stopped, Stop could still say "Safe to unplug" while the computer had the storage mounted.
    Now the driver is never given its saved backing-file setting, and anything left exporting
    makes Stop fail loudly. It also found gaps in telling a real plug-in from charging that
    resumes with the cable still in.
  - **Fourth review (v0.8, USB drive mode):** a drive the computer hadn't ejected would have been
    imported anyway, so a half-written copy could replace a good book before the drive was
    wiped; now such a drive isn't imported until it's been ejected properly. It
    also found that a deliberately malformed drive could make the FAT reader run out of memory
    (its counts are now clamped to the image's real size), and several smaller import edge
    cases. After it, drive mode was cut back to essentials (one fixed size, FAT16 only, no
    "add anyway"), about a fifth less code.
- The [test suite](#tests) runs the real scripts and plugin code against a simulated Kindle, and
  runs on GitHub for every change. It includes tests that were checked to fail on each of those
  bugs.

**What that doesn't give you:**
- It has been used on one Kindle, by one person. Many things are still
  [untested on real hardware](#not-yet-tested-on-hardware).
- I can't promise I'll understand and fix every bug myself.
- It can download and install new versions of itself from this repo's GitHub Releases, but only
  when you tap **Check for updates** and confirm.
- It runs as root and swaps the Kindle's USB kernel modules while KOReader is running. A reboot
  always restores stock USB, and nothing is written to the Kindle's system partitions. Still, it
  is the kind of software where you should read the code, or at least the
  [How it works](#how-it-works) section, before trusting it.

This is a personal project, shared as-is in case it helps someone with the same Kindle. If I
end up being its only user, that's fine with me. Bug reports and fixes are welcome.

## License

The plugin and scripts are MIT (see `LICENSE`). The bundled `umtprd` binary is uMTP-Responder
by Viveris Technologies, licensed **GPLv3**. Its license, full source and our patch are in
`usbmtp.koplugin/mtp/umtprd-source/`. The plugin runs it as a separate program.
