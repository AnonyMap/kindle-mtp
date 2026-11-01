#!/bin/sh
# Run on the computer (Linux) while the Kindle is plugged in with MTP on.
# Read-only: shows what Calibre's MTP detection will see.
#   sh host-check.sh

VID=1d6b; PID=0100
echo "=== USB device ${VID}:${PID} ==="
DEV=""
for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "$VID" ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ] && DEV="$d"
done
if [ -z "$DEV" ]; then
    echo "NOT FOUND. Is MTP started on the Kindle and the cable plugged in?"
    echo "All USB devices:"
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] && echo "  $(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"
    done
    exit 1
fi
BUS=$(cat "$DEV/busnum"); NUM=$(cat "$DEV/devnum")
echo "sysfs:        $DEV  (bus $BUS, dev $NUM)"
echo "product:      $(cat "$DEV/manufacturer" 2>/dev/null) / $(cat "$DEV/product" 2>/dev/null)"
echo "serial:       $(cat "$DEV/serial" 2>/dev/null)"
echo "bcdDevice:    $(cat "$DEV/bcdDevice" 2>/dev/null)   bDeviceClass: $(cat "$DEV/bDeviceClass" 2>/dev/null)"

echo
echo "=== Interfaces (Calibre needs one named exactly MTP) ==="
for i in "$DEV"/"$(basename "$DEV")":*; do
    [ -d "$i" ] || continue
    echo "$(basename "$i"): class=$(cat "$i/bInterfaceClass" 2>/dev/null) endpoints=$(cat "$i/bNumEndpoints" 2>/dev/null) name='$(cat "$i/interface" 2>/dev/null)' driver=$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)"
done

NODE=$(printf '/dev/bus/usb/%03d/%03d' "$BUS" "$NUM")
echo
echo "=== Device node $NODE (libmtp must be able to open it) ==="
ls -l "$NODE"
command -v getfacl >/dev/null && getfacl -p "$NODE" 2>/dev/null | grep -v '^#'
if [ -r "$NODE" ] && [ -w "$NODE" ]; then echo "you CAN read+write it"; else echo "you can NOT read+write it  <-- libmtp probe will fail"; fi

echo
echo "=== udev ==="
udevadm info -q property -n "$NODE" 2>/dev/null | grep -E "ID_MTP_DEVICE|ID_MEDIA_PLAYER|ID_GPHOTO2|TAGS|ID_MODEL=|ID_SERIAL="

echo
echo "=== Programs that may be holding the device (only one MTP client at a time) ==="
for p in kiod6 kiod5 kioworker gvfs-mtp-volume-monitor gvfsd-mtp gvfs-gphoto2-volume-monitor gvfsd-gphoto2 calibre-parallel calibre; do
    pgrep -a -x "$p" 2>/dev/null
done
command -v fuser >/dev/null && fuser -v "$NODE" 2>&1 | tail -n +2

echo
echo "=== Calibre ==="
if command -v flatpak >/dev/null && flatpak info com.calibre_ebook.calibre >/dev/null 2>&1; then
    echo "Flatpak: $(flatpak info com.calibre_ebook.calibre | grep -i '^ *version' | head -1)"
    flatpak info --show-permissions com.calibre_ebook.calibre 2>/dev/null | grep -i devices
fi
command -v calibre >/dev/null && echo "native: $(calibre --version 2>/dev/null)"
