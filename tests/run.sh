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
cleanup() {
    for f in ${CREATED}; do rm -rf "$f"; done
    rm -rf "${BASE}" /var/tmp/kmtp /dev/ffs-mtp
}
trap cleanup EXIT

rm -rf "${BASE}"; mkdir -p "${H}/realbin"
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

echo "== shell scripts (BusyBox: ${BB})"
fresh_plugin; o="$(ns : sh "${H}/scenarios/scripts-cycle.sh")"
expect "start/stop cycle (configfs)" "$o" "MTP is ON (mode: configfs" "MTP is OFF. Safe to unplug." "^g_mass_storage 1000" "MTP is not active. Nothing to do."
expect_not "teardown order safe for Linux 4.1 FunctionFS" "$o" "ORDER-VIOLATION"
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
printf '%s\n' "$o" | grep -E "^FAIL" | sed 's/^/    /'
expect "plugin scenarios" "$o" " 0 failed"
printf '%s\n' "$o" | grep -E "passed, [0-9]+ failed" | sed 's/^/    /'

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
