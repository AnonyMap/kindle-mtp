#!/bin/sh
# Simulated-Kindle test suite for usbmtp.koplugin.
#
# Runs the real shell scripts and the real plugin Lua against a fake Kindle:
# fake /sys (USB controller, g_mass_storage params, configfs), fake /proc,
# stand-ins for insmod/rmmod/modprobe/mount/umount, and a fake umtprd.
# Everything happens inside a private mount namespace, so the host is untouched
# apart from a few empty placeholder files it removes again at the end.
#
# Needs: Linux, root, unshare (util-linux), luajit. Optional: busybox
# (then the scripts run under BusyBox ash + applets, like on the Kindle).
#   sudo sh tests/run.sh          # BusyBox if available
#   sudo BB=0 sh tests/run.sh     # force the host's /bin/sh and coreutils
#   sudo PLUGIN_LOG=/tmp/p.log sh tests/run.sh   # keep the plugin scenarios' full output
set -u

REPO="$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)"
BASE=/tmp/kmtp-test
H="${BASE}/harness"
PLUG="${BASE}/plugin"

[ "$(id -u)" = 0 ] || { echo "run as root (needs mount namespaces)"; exit 1; }
command -v unshare >/dev/null || { echo "missing unshare"; exit 1; }
command -v luajit >/dev/null || { echo "missing luajit"; exit 1; }
if [ -z "${BB:-}" ]; then
    if command -v busybox >/dev/null && busybox sh -c 'type uname' 2>/dev/null | grep -q /; then BB=1; else BB=0; fi
fi
export BB

# Placeholders so the stand-ins can be bind-mounted over them.
CREATED=""
for f in /usr/sbin/insmod /usr/sbin/rmmod /usr/sbin/modprobe /usr/bin/usleep; do
    [ -e "$f" ] || { touch "$f" && CREATED="${CREATED} $f"; }
done
[ -d /lib/modules ] || { mkdir -p /lib/modules && CREATED="${CREATED} /lib/modules"; }
[ -d /mnt/base-us ] || { mkdir -p /mnt/base-us && CREATED="${CREATED} /mnt/base-us"; }
cleanup() {
    for f in ${CREATED}; do rm -rf "$f"; done
    rm -rf "${BASE}" /var/tmp/kmtp /dev/ffs-mtp
}
trap cleanup EXIT

rm -rf "${BASE}"; mkdir -p "${H}/realbin"
# Everything below must leave the repo untouched (checked at the end).
STAMP="$(mktemp)"
cp -r "${REPO}/tests/." "${H}/"
for b in mkdir rmdir mount umount; do cp "$(command -v $b)" "${H}/realbin/"; done
chmod +x "${H}"/stubs/* "${H}"/*.sh

fresh_plugin() {
    rm -rf "${PLUG}" /var/tmp/kmtp; mkdir -p "${PLUG}"
    cp -r "${REPO}/usbmtp.koplugin" "${PLUG}/"
    cp "${H}/stubs/fake-umtprd" "${PLUG}/usbmtp.koplugin/mtp/bin/umtprd"
    rm -f "${PLUG}"/usbmtp.koplugin/mtp/*.log
}

PASS=0; FAIL=0
ns() { # ns "setup snippet" command...
    _snip="$1"; shift
    timeout 300 unshare -m --propagation private sh "${H}/setup_ns.sh" "${_snip}" "$@" 2>&1 |
        grep -v "^mount: /lib\|dmesg"
}
expect() { # expect NAME OUTPUT pattern...
    _name="$1"; _out="$2"; shift 2
    for _p in "$@"; do
        if ! printf '%s\n' "${_out}" | grep -q -- "${_p}"; then
            echo "FAIL ${_name}: missing '${_p}'"
            printf '%s\n' "${_out}" | sed 's/^/    /' | tail -n 25
            FAIL=$((FAIL + 1)); return
        fi
    done
    echo "PASS ${_name}"; PASS=$((PASS + 1))
}

expect_not() { # expect_not NAME OUTPUT pattern
    if printf '%s\n' "$2" | grep -q -- "$3"; then
        echo "FAIL $1: found '$3'"; printf '%s\n' "$2" | grep -- "$3" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
    else
        echo "PASS $1"; PASS=$((PASS + 1))
    fi
}

echo "== static checks"
if command -v luacheck >/dev/null; then
    # Catches e.g. a local function used before its definition (it becomes a nil global).
    o="$(luacheck --no-color --std luajit --globals G_reader_settings --no-unused-args --no-max-line-length --codes \
        "${REPO}/usbmtp.koplugin/main.lua" "${REPO}/usbmtp.koplugin/usbmtp_updater.lua" "${REPO}/usbmtp.koplugin/_meta.lua" 2>&1)"
    expect "luacheck (no undefined globals or other warnings)" "$o" "0 warnings / 0 errors"
else
    echo "SKIP luacheck (not installed)"
fi

echo "== shell scripts (BusyBox: ${BB})"
fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-cycle.sh")"
expect "start/stop cycle (configfs)" "$o" "MTP is ON (mode: configfs" "MTP is OFF. Safe to unplug." "^g_mass_storage 1000" "MTP is not active. Nothing to do."
expect_not "teardown order safe for Linux 4.1 FunctionFS" "$o" "ORDER-VIOLATION"
expect "stock driver restored with exact settings (incl. a value with spaces)" "$o" 'insmod <.*/g_mass_storage.ko> .*<iProduct="Amazon Kindle">' '<removable=Y>'

V="$(tr -d ' \n' < "${REPO}/usbmtp.koplugin/mtp/VERSION")"
expect "version stamped and shown" "$o" "version in umtprd.conf: firmware_version \"usbmtp ${V}\"" "^version: *${V}" "USB serial: *G000AB12CD34EF56"
expect "reports the Kindle's own serial" "$o" 'serial in umtprd.conf: serial "G000AB12CD34EF56"' "serial in gadget: G000AB12CD34EF56"
fresh_plugin; o="$(ns : sh -c "sh ${PLUG}/usbmtp.koplugin/mtp/mtp-start.sh >/dev/null; sed -i '/^GMS_PARAM=/d' /var/tmp/kmtp/state; echo 'GMS_PARAMS=idVendor=6473 removable=Y' >> /var/tmp/kmtp/state; sh ${PLUG}/usbmtp.koplugin/mtp/mtp-stop.sh; cat /tmp/kmtp-test/fake/argv")"
expect "restores state saved by v0.5 (old one-line format)" "$o" "MTP is OFF" 'insmod <.*/g_mass_storage.ko> <idVendor=6473> <removable=Y>'
# The stock driver must never come back exporting the storage the Kindle still has mounted.
LUN=/sys/devices/soc0/ci_hdrc.0/gadget/lun0/file
gms_case() { # gms_case "setup snippet": start, stop twice, report
    fresh_plugin
    ns "$1" sh -c "M=${PLUG}/usbmtp.koplugin/mtp; sh \$M/mtp-start.sh >/dev/null
        sh \$M/mtp-stop.sh; echo \"stop1 exit=\$? lun=[\$(cat ${LUN})] gms=\$(grep -c '^g_mass_storage ' /proc/modules) state=\$(test -f /var/tmp/kmtp/state && echo kept || echo gone)\"
        sh \$M/mtp-stop.sh; echo \"stop2 exit=\$? lun=[\$(cat ${LUN})]\"; cat /tmp/kmtp-test/fake/argv"
}
o="$(gms_case 'echo /dev/mmcblk0p4 > /sys/module/g_mass_storage/parameters/file')"
expect "a saved file= is never passed back to the stock driver" "$o" "not passing file=/dev/mmcblk0p4" "stop1 exit=0 lun=\[\] gms=1 state=gone"
expect_not "  (no file= in the reload)" "$o" "g_mass_storage.ko>.*<file="
o="$(gms_case 'touch $F/gms_exports_on_load')"
expect "driver exports on load anyway: ejected at once" "$o" "ejecting it" "stop1 exit=0 lun=\[\] gms=1"
o="$(gms_case 'touch $F/gms_exports_on_load $F/gms_eject_fails')"
expect "eject fails: driver unloaded again, never 'Safe to unplug'" "$o" "so it was unloaded again" "stop1 exit=1 lun=\[\] gms=0 state=kept" "stop2 exit=1"
expect_not "  (no 'Safe to unplug')" "$o" "Safe to unplug"
o="$(gms_case 'touch $F/gms_exports_on_load $F/gms_eject_fails $F/gms_rmmod_fails')"
expect "eject and unload both fail: reported, and a retry doesn't claim success" "$o" "could not be stopped" "stop1 exit=1 lun=\[/dev/mmcblk0p4\] gms=1 state=kept" "stop2 exit=1"
expect_not "  (no 'Safe to unplug')" "$o" "Safe to unplug"
# USB drive mode: the stock driver shares a disk image instead of running MTP.
IMG=/mnt/base-us/koreader/usbmtp-drive.img
drive_case() { # drive_case "setup snippet" [image]
    fresh_plugin
    ns "mkdir -p /mnt/base-us/koreader; truncate -s 1M ${IMG}; $1" sh -c "M=${PLUG}/usbmtp.koplugin/mtp
        KMTP_DRIVE=${2:-${IMG}} sh \$M/mtp-start.sh; echo \"start exit=\$? lun=[\$(cat ${LUN})] umtprd=\$(pidof fake-umtprd umtprd | wc -w)\"
        sh \$M/mtp-status.sh | grep -E '^(mode|drive)'
        sh \$M/mtp-stop.sh; echo \"stop exit=\$? lun=[\$(cat ${LUN})] gms=\$(grep -c '^g_mass_storage ' /proc/modules) state=\$(test -f /var/tmp/kmtp/state && echo kept || echo gone)\"
        cat /tmp/kmtp-test/fake/argv"
}
o="$(drive_case :)"
expect "drive mode: shares the image under its own USB identity, no MTP daemon" "$o" "USB drive is ON" \
    "start exit=0 lun=\[${IMG}\] umtprd=0" "<file=${IMG}> <removable=1>" "<idVendor=0x1d6b> <idProduct=0x0104>" '<iProduct="Kindle drive">' \
    "^mode: *drive" "drive shared: *yes"
expect "drive mode: stop unloads it and restores the stock driver exactly" "$o" "unloading the USB drive" \
    "MTP is OFF. Safe to unplug." "stop exit=0 lun=\[\] gms=1 state=gone" '<iProduct="Amazon Kindle"> <idProduct=4> <idVendor=6473>'
o="$(drive_case : /mnt/us/koreader/usbmtp-drive.img)"
expect "drive mode: refuses an image on the /mnt/us FUSE view (nothing changed)" "$o" "must be under /mnt/base-us" "start exit=1 lun=\[\]"
expect_not "  (stock driver untouched)" "$o" "^rmmod <g_mass_storage>"
o="$(drive_case 'touch $F/fail_drive_insmod')"
expect "drive mode: driver won't load -> rolled back to stock" "$o" "could not load the USB drive driver" "rolled back; stock USB restored" "start exit=1 lun=\[\]"
fresh_plugin; o="$(ns "mkdir -p /mnt/base-us/koreader; truncate -s 1M ${IMG}" sh -c "M=${PLUG}/usbmtp.koplugin/mtp
    KMTP_DRIVE=${IMG} sh \$M/mtp-start.sh >/dev/null; rm -f /var/tmp/kmtp/state
    sh \$M/mtp-stop.sh; echo \"stop exit=\$? lun=[\$(cat ${LUN})] gms=\$(grep -c '^g_mass_storage ' /proc/modules)\"; tail -n 2 /tmp/kmtp-test/fake/argv")"
expect "drive mode, state lost: stop still replaces the drive with the stock driver" "$o" "still loaded with no saved state" \
    "stop exit=0 lun=\[\] gms=1" "^rmmod <g_mass_storage>"
o="$(drive_case 'touch $F/drive_rmmod_fails')"
expect "drive mode: can't unload at stop -> error, state kept" "$o" "could not unload the USB drive" "stop exit=1" "state=kept"
expect_not "  (no 'Safe to unplug')" "$o" "Safe to unplug"
fresh_plugin; o="$(ns 'echo "g_ether 1 0 - Live 0x0" >> $F/proc/modules; sed -i "/^g_mass_storage /d" $F/proc/modules' sh "${PLUG}/usbmtp.koplugin/mtp/mtp-stop.sh")"
expect "Reset leaves USBNetwork alone" "$o" "MTP is not active. Nothing to do."
fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-watcher.sh")"
expect "crash watcher stops MTP when KOReader dies" "$o" "MTP is ON" "watcher: process" "state: gone" "modules:.*g_mass_storage"

run_start() { fresh_plugin; ns "$1" sh "${H}/scenarios/scripts-start-only.sh"; }
o="$(run_start 'touch $F/umtprd_fail')"
expect "daemon fails -> rollback" "$o" "umtprd exited during startup" "rolled back; stock USB restored" "modules:.*g_mass_storage"
o="$(run_start 'echo "999 (volumd) S 1 1" > $F/proc/999/stat')"
expect "refuses when volumd runs" "$o" "volumd is running" "start exit=1"
o="$(run_start 'echo /dev/loop/0 > /sys/devices/soc0/ci_hdrc.0/gadget/lun0/file')"
expect "refuses while stock USB exports" "$o" "exporting storage right now"
o="$(run_start 'echo 4.9.77-lab126 > $F/kernel')"
expect "refuses on other kernels" "$o" "built for kernel 4.1.15-lab126"
o="$(run_start 'echo "g_ether 1 0 - Live 0x0" >> $F/proc/modules')"
expect "refuses with USBNetwork" "$o" "another USB gadget is loaded"
o="$(run_start 'touch $F/no_usb_gadget')"
expect "configfs missing -> g_ffs fallback" "$o" "trying legacy g_ffs" "MTP is ON (mode: gffs"
o="$(run_start 'touch $F/no_usb_gadget $F/fail_insmod_g_ffs')"
expect "both gadget paths fail -> rollback" "$o" "g_ffs setup failed" "rolled back; stock USB restored"

fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-crash.sh")"
expect "crash leftovers cleaned by stop" "$o" "MTP already active" "MTP is OFF. Safe to unplug."
fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-hung-daemon.sh")"
expect "hung daemon force-killed" "$o" "sending SIGKILL" "MTP is OFF" "leftover umtprd procs: 0"
fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-reload-fails.sh")"
expect "restore failure reported" "$o" "could not reload the stock USB driver" "stock USB was not restored"

echo "== plugin (Lua, with stand-in KOReader modules)"
fresh_plugin; o="$(ns : luajit "${H}/plugin_test.lua")"
[ -n "${PLUGIN_LOG:-}" ] && printf '%s\n' "$o" >"${PLUGIN_LOG}"  # full output, for debugging
printf '%s\n' "$o" | grep -E "^FAIL" | sed 's/^/    /'
expect "plugin scenarios" "$o" " 0 failed"
printf '%s\n' "$o" | grep -E "passed, [0-9]+ failed" | sed 's/^/    /'

echo "== updater (real KOReader archiver + sha2, fake GitHub)"
KBASE="${KOREADER_BASE:-}"
if [ -n "${KBASE}" ] && [ -f "${KBASE}/ffi/archiver.lua" ] && command -v zip >/dev/null \
   && [ -f /usr/share/lua/5.1/dkjson.lua ] && ls /usr/lib/*/libarchive.so.13 >/dev/null 2>&1; then
    o="$(KOREADER_BASE="${KBASE}" luajit "${REPO}/tests/updater_test.lua" "${REPO}" 2>&1)"
    printf '%s\n' "$o" | grep -E "^FAIL" | sed 's/^/    /'
    expect "updater scenarios" "$o" " 0 failed"
    printf '%s\n' "$o" | grep -E "passed, [0-9]+ failed" | sed 's/^/    /'
else
    echo "SKIP updater scenarios (set KOREADER_BASE to a koreader-base checkout; needs zip, lua-dkjson, lua-filesystem, libarchive13)"
fi

echo "== umtprd: our patches apply to the bundled source, and the name filter"
if command -v gcc >/dev/null && command -v patch >/dev/null; then
    U="$(mktemp -d)"
    SRC="${REPO}/usbmtp.koplugin/mtp/umtprd-source"
    o="$( (cd "$U" && tar xzf "$SRC"/uMTP-Responder-*.tar.gz && d="$(ls)" && cd "$d" &&
          for p in "$SRC"/*.patch; do patch -p1 -s <"$p" || echo "PATCH FAILED: $p"; done &&
          grep -c "usbmtp patch" src/mtp_operations/mtp_op_deleteobject.c src/mtp_operations/mtp_ops_helpers.c src/mtp_operations/mtp_op_getpartialobject.c &&
          gcc -Wall -I./inc -o "$U/names" "${REPO}/tests/umtprd_names_test.c" src/mtp_sanitize.c 2>&1 &&
          "$U/names") 2>&1)"
    rm -rf "$U"
    printf '%s\n' "$o" | grep -E "^FAIL|FAILED|error" | sed 's/^/    /'
    expect "patches apply in build order" "$o" "mtp_op_deleteobject.c:1" "mtp_ops_helpers.c:1" "mtp_op_getpartialobject.c:1"
    expect_not "  (no patch failed)" "$o" "PATCH FAILED"
    expect "name filter: .lua files, .sdr folders and hidden names are protected; books aren't" "$o" 'PASS protected."Dune.epub". = 0'
    expect_not "  (every name case right)" "$o" "^FAIL"
else
    echo "SKIP umtprd patch checks (needs gcc and patch)"
fi

echo "== FAT (USB drive mode) against mtools / dosfstools"
if command -v mcopy >/dev/null && command -v mkfs.fat >/dev/null && command -v fsck.fat >/dev/null; then
    o="$(luajit "${REPO}/tests/fat_test.lua" 2>&1)"
    printf '%s\n' "$o" | grep -E "^FAIL|mismatch" | sed 's/^/    /'
    expect "FAT format/read scenarios" "$o" " 0 failed"
    printf '%s\n' "$o" | grep -E "passed, [0-9]+ failed" | sed 's/^/    /'
else
    echo "SKIP FAT scenarios (needs mtools and dosfstools)"
fi

echo "== hygiene"
# The suite runs as root: anything it wrote into the repo would be root-owned and
# break later non-root steps (this broke the v0.6 release build).
o="$(find "${REPO}" -path "${REPO}/.git" -prune -o -newer "${STAMP}" -print 2>/dev/null)"
rm -f "${STAMP}"
if [ -z "${o}" ]; then echo "PASS tests leave the repo untouched"; PASS=$((PASS + 1))
else echo "FAIL tests wrote into the repo:"; printf '%s\n' "${o}" | sed 's/^/    /'; FAIL=$((FAIL + 1)); fi

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
