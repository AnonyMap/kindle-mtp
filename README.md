# usbmtp

A [KOReader](https://github.com/koreader/koreader) plugin that lets a computer copy books to a
jailbroken Kindle over USB **while KOReader keeps running**, using MTP. That includes from inside
a book.

Normally KOReader on Kindle has no USB file transfer. Its launcher pauses Amazon's `volumd`
daemon for as long as KOReader runs, because stock USB mass storage would unmount the partition
KOReader itself lives on (`/mnt/us`). MTP avoids that: files are copied through the mounted
filesystem, so nothing gets unmounted.

> **Status: v0.6, early but working.** Confirmed on a Kindle 10th gen (FW 5.16.8) with Bazzite
> Linux (KDE): copying books from the file manager, and sending books from Calibre (Flatpak
> 9.17). Everything else is covered by the simulated-Kindle test suite (see [Tests](#tests)) but
> not yet confirmed on hardware; see [Not yet tested on hardware](#not-yet-tested-on-hardware).

> [!IMPORTANT]
> **This plugin was written by AI.** I'm sceptical of AI-made software myself, so you should know
> before you install it. Details in [How this was made](#how-this-was-made).

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
- **On plug-in:** set *When plugged into a computer* to **ask first** or **start automatically**
  (default: do nothing). Works on any screen. Wall chargers are ignored: only a computer that
  actually connects counts.
- **Gesture:** Gesture manager → *General* → **Toggle USB file transfer (MTP)**

While sharing, a dialog offers **Stop** or **Hide** (keep reading). With Hide, a small **ᴍᴛᴘ**
appears in the reader's status bar while sharing is on; you can turn it off in the menu. Sharing
stops by itself when you unplug, when the Kindle sleeps, or when KOReader exits.

After Stop, it lists the books that arrived, e.g. "2 new file(s) on the Kindle: …". The list
covers files that appeared in `documents/` during the session, and leaves out KOReader's own
`.sdr` metadata.

On the computer:
- **Linux:** shows up as "Kindle (MTP)" in Dolphin / GNOME Files.
- **macOS:** use [OpenMTP](https://openmtp.ganeshrvel.com/). Quit Photos and Image Capture first.
- **Windows:** should work in Explorer (untested).

Don't edit the `koreader` folder from the computer while sharing.

## Updating

From v0.5 on, the plugin updates itself from this repo's
[GitHub Releases](https://github.com/AnonyMap/usbmtp/releases) over Wi-Fi:
**Tools → USB file transfer (MTP) → Check for updates**.

It shows the release notes and asks before installing. KOReader then needs a restart. It only
checks when you tap that menu entry, never automatically.

Before installing, it refuses anything that:
- isn't the latest published release;
- fails its `SHA256SUMS` checksum;
- contains files outside `usbmtp.koplugin/`;
- has a version inside the zip that doesn't match the release tag.

The new copy is unpacked next to the old one and swapped in with two renames. If that fails,
the old copy is put back. It won't update while a transfer is running.

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
- Hide and keep reading during a transfer;
- stock USB working normally after exiting KOReader;
- **Check for updates** against the real GitHub (new in v0.5; tested against fake releases);
- Windows and macOS hosts.

Reports are welcome.

## Repository layout

| Path | What it is |
|---|---|
| `usbmtp.koplugin/` | The plugin. This is the only folder that goes on the Kindle |
| `usbmtp.koplugin/mtp/` | Start, stop, status and watcher scripts, umtprd and its config, version file |
| `usbmtp.koplugin/mtp/umtprd-source/` | uMTP-Responder source, license (GPLv3) and our patch |
| `usbmtp.koplugin/usbmtp_updater.lua` | The self-updater (GitHub Releases) |
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
   - **On GitHub:** Releases → **Draft a new release** → new tag `v<VERSION>` (e.g. `v0.6`) →
     write notes → **Publish**.
   - **From git:**
     ```sh
     git tag v0.6 && git push origin v0.6
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
  out);
- the three plug-in modes, including migrating the old setting;
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
# include the updater tests (needs a koreader-base checkout, zip, lua-dkjson, lua-filesystem, libarchive13):
sudo KOREADER_BASE=/path/to/koreader-base sh tests/run.sh
```

## How this was made

This plugin was developed with an AI model, Anthropic's Claude, over a single long conversation.
I didn't write the code myself. My part was directing it, deciding what to build, and testing it
on my own Kindle. I'm sceptical of AI-made software, so here's what that means in practice.

**How it was checked:**
- Claims about how the Kindle, Linux kernel, KOReader, uMTP-Responder and Calibre behave were
  checked against their source code, not assumed.
- A separate AI review went through the code looking for bugs. It was given only the code and a
  short description, not the development conversation or its conclusions. It found two serious
  bugs, both since fixed:
  - a kernel use-after-free in the stop order;
  - USB buffers too small for long filenames.
- The [test suite](#tests) runs the real scripts and plugin code against a simulated Kindle. It
  includes a test proven to fail on the buggy stop order.

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
