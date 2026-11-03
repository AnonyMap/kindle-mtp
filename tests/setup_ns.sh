#!/bin/sh
# Runs INSIDE a private mount namespace. $1 = scenario setup snippet, rest = command
H=/tmp/kmtp-test/harness; F=/tmp/kmtp-test/fake; S=$H/stubs
rm -rf "$F"; mkdir -p "$F/proc/999"
echo "4.1.15-lab126" >"$F/kernel"
printf 'g_mass_storage 4203 0 - Live 0x0\nusb_f_mass_storage 51007 2 g_mass_storage, Live 0x0\nlibcomposite 49114 2 - Live 0x0\nconfigfs 26493 3 - Live 0x0\n' >"$F/proc/modules"
echo "fsp /mnt/us fuse.fsp rw 0 0" >"$F/proc/mounts"
echo "999 (volumd) T 1 1" >"$F/proc/999/stat"
printf 'G000AB12CD34EF56\n' >"$F/proc/usid"; echo 999 >"$F/volumd_pid"
# fake /sys
mount -t tmpfs none /sys
mkdir -p /sys/class/udc/ci_hdrc.0 /sys/module/g_mass_storage/parameters /sys/kernel/config /sys/devices/soc0/ci_hdrc.0/gadget/lun0
echo "not attached" >/sys/class/udc/ci_hdrc.0/state
: >/sys/devices/soc0/ci_hdrc.0/gadget/lun0/file
ln -s /sys/devices/soc0/ci_hdrc.0 /sys/class/udc/ci_hdrc.0/device   # the direct path the scripts try first
P=/sys/module/g_mass_storage/parameters
echo ""  >$P/file; echo "Y" >$P/removable; echo 1 >$P/luns; echo 6473 >$P/idVendor; echo 4 >$P/idProduct
echo "N" >$P/stall; echo "N" >$P/ro; echo "(null)" >$P/iSerialNumber; echo "," >$P/cdrom
echo "Amazon Kindle" >$P/iProduct
# fake modules dir
mount -t tmpfs none /lib/modules
mount -t tmpfs none /mnt/base-us && mkdir -p /mnt/base-us/documents
D=/lib/modules/4.1.15-lab126/kernel/drivers/usb/gadget
mkdir -p $D/function $D/legacy; touch $D/function/usb_f_fs.ko $D/legacy/g_ffs.ko $D/legacy/g_mass_storage.ko $D/libcomposite.ko
# scenario tweaks
eval "$1"; shift
# swap /proc and tools (must be last: after this, real mount is gone)
mount --bind "$F/proc" /proc
for t in insmod rmmod modprobe; do mount --bind $S/kmod /usr/sbin/$t; done
mount --bind $S/uname /usr/bin/uname
mount --bind $S/pidof /usr/sbin/killall5
mount --bind $S/killall /usr/bin/killall
mount --bind $S/mkdir /usr/bin/mkdir
mount --bind $S/rmdir /usr/bin/rmdir
if [ "${BB:-0}" = 1 ]; then
  BBX=$(command -v busybox)
  for a in sed grep tail tr cut find cp date cat sleep ls nohup head wc rm; do
    [ -e /usr/bin/$a ] && mount --bind "$BBX" /usr/bin/$a
  done
  mount --bind "$BBX" /usr/bin/mawk
  mount --bind "$BBX" /usr/bin/usleep
  mount --bind "$BBX" /usr/bin/dash
fi
$H/realbin/mount --bind $S/umount /usr/bin/umount
$H/realbin/mount --bind $S/mount /usr/bin/mount
"$@"
