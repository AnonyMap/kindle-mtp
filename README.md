# usbmtp

A [KOReader](https://github.com/koreader/koreader) plugin that lets a computer copy books to a
jailbroken Kindle over USB **while KOReader keeps running**, using MTP. That includes from inside
a book.

Normally KOReader on Kindle has no USB file transfer. Its launcher pauses Amazon's `volumd`
daemon for as long as KOReader runs, because stock USB mass storage would unmount the partition
KOReader itself lives on (`/mnt/us`). MTP avoids that: files are copied through the mounted
filesystem, so nothing gets unmounted.

> **Status: v0.4, early but working.** Confirmed on a Kindle 10th gen (FW 5.16.8) with Bazzite
> Linux (KDE): copying books from the file manager, and sending books from Calibre (Flatpak
> 9.17). Everything else is covered by the simulated-Kindle test suite (see [Tests](#tests)) but
> not yet confirmed on hardware; see [Not yet tested on hardware](#not-yet-tested-on-hardware).

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
4. Check the version: Tools → **USB file transfer (MTP)** → **About (vX.Y)**.

## Use

- **Menu:** Tools (wrench) → **USB file transfer (MTP)** → **Start USB file transfer**
- **On plug-in:** enable *Ask to start when plugged into a computer*. Plugging into a computer
  then offers to start, on any screen. Wall chargers are ignored.
- **Gesture:** Gesture manager → *General* → **Toggle USB file transfer (MTP)**

While sharing, a dialog offers **Stop** or **Hide** (keep reading). It stops by itself when you
unplug, when the Kindle sleeps, or when KOReader exits.

On the computer:
- **Linux:** shows up as "Kindle (MTP)" in Dolphin / GNOME Files.
- **macOS:** use [OpenMTP](https://openmtp.ganeshrvel.com/). Quit Photos and Image Capture first.
- **Windows:** should work in Explorer (untested).

Don't edit the `koreader` folder from the computer while sharing.

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

- **Which version is on the Kindle?** Tools → USB file transfer (MTP) → **About (vX.Y)**, or the
  file `usbmtp.koplugin/mtp/VERSION`. If it isn't the version you expect, KOReader is still
  loading an old copy; see [Install](#install).
- **Calibre doesn't see the Kindle**, but the file manager does: another program is holding the
  MTP device. On KDE that's `kiod6`. See step 2 of [Using with Calibre](#using-with-calibre).
- **The computer doesn't see the Kindle at all:**
  - check that the plugin says "USB file transfer is on";
  - check that the cable carries data, not just power;
  - on a Mac, use an MTP app (OpenMTP).
- **Kindle side:** run **Status / diagnostics** from the plugin menu. Logs are in
  `koreader/plugins/usbmtp.koplugin/mtp/`: `mtp.log` (the scripts) and `umtprd-last.log` (the
  MTP program). Read them after exiting KOReader, or over SSH.
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
- Hide and keep reading during a transfer;
- stock USB working normally after exiting KOReader;
- Windows and macOS hosts.

Reports are welcome.

## Repository layout

| Path | What it is |
|---|---|
| `usbmtp.koplugin/` | The plugin. This is the only folder that goes on the Kindle |
| `usbmtp.koplugin/mtp/` | Start, stop, status and watcher scripts, umtprd and its config, version file |
| `usbmtp.koplugin/mtp/umtprd-source/` | uMTP-Responder source, license (GPLv3) and our patch |
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

## Tests

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
- the Linux 4.1 FunctionFS teardown order (the fake flags the use-after-free ordering).

```sh
sudo sh tests/run.sh
```

## License

The plugin and scripts are MIT (see `LICENSE`). The bundled `umtprd` binary is uMTP-Responder
by Viveris Technologies, licensed **GPLv3**. Its license, full source and our patch are in
`usbmtp.koplugin/mtp/umtprd-source/`. The plugin runs it as a separate program.
