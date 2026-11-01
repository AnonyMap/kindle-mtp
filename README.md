# kindle-mtp

A [KOReader](https://github.com/koreader/koreader) plugin that lets a computer copy books to a
jailbroken Kindle over USB **while KOReader keeps running**, using MTP. That includes from inside
a book.

Normally KOReader on Kindle has no USB file transfer. Its launcher pauses Amazon's `volumd`
daemon for as long as KOReader runs, because stock USB mass storage would unmount the partition
KOReader itself lives on (`/mnt/us`). MTP avoids that: files are copied through the mounted
filesystem, so nothing gets unmounted.

> **Status: early, working.** On a Kindle 10th gen (FW 5.16.8) with Bazzite Linux: connecting,
> copying an EPUB and unplugging all work. The rest is covered by the simulated-Kindle test suite
> (see [Tests](#tests)).

## Supported devices

| Device | Firmware | Kernel | Status |
|---|---|---|---|
| Kindle 10th gen (2019, "KT4") | 5.16.8 | 4.1.15-lab126 | **Works** (basic copy confirmed) |
| Other Kindles | | | Refused by a kernel-version check. Most likely to work: other older (non-MTP) Kindles whose kernel ships `usb_f_fs.ko` |

Newer Kindles (Scribe, 11th/12th gen) already use MTP from Amazon. For those, see
[kindlemtp.koplugin](https://github.com/danihrndzld/kindlemtp.koplugin), which drives Amazon's
own MTP responder.

## Install

1. Exit KOReader so the Kindle shows up as a USB drive.
2. Copy `usbmtp.koplugin/` into `koreader/plugins/` on the Kindle.
3. Eject, unplug, and start KOReader **from KUAL**. The plugin needs KOReader's normal launcher.

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
   - **Permanent:** install [`tools/69-zz-kindle-mtp-calibre.rules`](tools/69-zz-kindle-mtp-calibre.rules).
     It hides this device from the desktop's device handling so Calibre always gets it; the file
     manager stops showing it. Instructions are inside the file.
   
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

The Flathub (Flatpak) build of Calibre has the USB access this needs.

## How it works

`usbmtp.koplugin/mtp/` holds standalone shell scripts that do all the system work. The Lua
plugin is just the UI and safety checks around them.

**`mtp-start.sh`**
1. Checks that it's safe to start; nothing is changed until all checks pass.
2. Saves the stock `g_mass_storage` module's parameters, then unloads it.
3. Builds a configfs USB gadget with a FunctionFS function (falls back to the legacy `g_ffs`
   module if configfs isn't available).
4. Starts [uMTP-Responder](https://github.com/viveris/uMTP-Responder) from `/var/tmp`, serving
   `/mnt/base-us` (the real vfat partition under Amazon's `fsp` FUSE layer).
5. Binds the gadget to the `ci_hdrc.0` USB controller.

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

- **Which version is on the Kindle?** Menu → USB file transfer (MTP) → **About (vX.Y)**, or
  `usbmtp.koplugin/mtp/VERSION`. When installing from GitHub, make sure the `usbmtp.koplugin`
  folder you copy replaces the old one in `koreader/plugins/`.

- Run **Status / diagnostics** from the plugin menu.
- Logs are in `koreader/plugins/usbmtp.koplugin/mtp/`: `mtp.log` (the scripts) and
  `umtprd-last.log` (the MTP program).
- On Linux, check the host side with:
  ```sh
  journalctl -k -b | grep -iE "usb|1d6b" | tail -20
  ```

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
- the Linux 4.1 FunctionFS teardown order (the fake flags the use-after-free ordering).

```sh
sudo sh tests/run.sh
```

## License

The plugin and scripts are MIT (see `LICENSE`). The bundled `umtprd` binary is uMTP-Responder
by Viveris Technologies, licensed **GPLv3**. Its license, full source and our patch are in
`usbmtp.koplugin/mtp/umtprd-source/`. The plugin runs it as a separate program.
