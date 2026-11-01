#!/bin/sh
# kindle-mtp: share the Kindle's storage over MTP while KOReader keeps running.
# Usage (from KOReader's terminal or SSH):  sh /mnt/us/kindle-mtp/mtp-start.sh
# Stop with:                                 sh /mnt/us/kindle-mtp/mtp-stop.sh
#
# Env overrides:  KMTP_MODE=gffs  (skip configfs, use the legacy g_ffs gadget)
#                 FORCE=1         (skip the kernel-version check)
#                 KMTP_WATCH_PID=<pid>  (stop automatically if that process dies;
#                                        the KOReader plugin passes its own pid)

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

: >"${KMTP_LOG}" 2>/dev/null
log "=== kindle-mtp start ($(date)) ==="
log "kernel $(uname -r), volumd: $(volumd_state), USB: $(udc_state)"

# ---------- preflight (nothing has been changed yet) ----------
[ "$(id -u)" = "0" ] || die "must run as root"

if [ "$(uname -r)" != "${EXPECTED_KERNEL}" ] && [ "${FORCE:-0}" != "1" ]; then
    die "built for kernel ${EXPECTED_KERNEL}, this is $(uname -r). Set FORCE=1 to try anyway."
fi

[ -d "/sys/class/udc/${UDC_NAME}" ] || die "USB controller ${UDC_NAME} not found"
[ -f "${KMTP_SRC}/bin/umtprd" ] || die "missing ${KMTP_SRC}/bin/umtprd"
[ -f "${MODDIR}/function/usb_f_fs.ko" ] || die "missing usb_f_fs.ko"

if [ -f "${KMTP_STATE}" ] || daemon_pid >/dev/null; then
    die "MTP already active. Run mtp-stop.sh first."
fi

case "$(volumd_state)" in
    running)
        die "volumd is running, so the stock system is managing USB. Start KOReader from KUAL (koreader.sh), or just exit KOReader and use stock USB."
        ;;
esac

if mod_loaded g_ether || mod_loaded g_ffs; then
    die "another USB gadget is loaded (USBNetwork?). Turn it off first."
fi

if gms_exporting; then
    die "the stock USB drive mode is exporting storage right now. Eject on the computer and unplug first."
fi

# ---------- stage binaries on tmpfs ----------
mkdir -p "${KMTP_RUN}" || die "cannot create ${KMTP_RUN}"
: >"${KMTP_DLOG}"
cp -f "${KMTP_SRC}/bin/umtprd" "${KMTP_RUN}/umtprd" || die "cannot copy umtprd"
cp -f "${KMTP_SRC}/conf/umtprd.conf" "${KMTP_RUN}/umtprd.conf" || die "cannot copy config"
chmod 755 "${KMTP_RUN}/umtprd"
state_set STARTED "$(date +%s)"

# From here on, any failure must roll back.
fail() {
    log "ERROR: $*"
    [ -f "${KMTP_DLOG}" ] && { log "--- umtprd output ---"; tail -n 15 "${KMTP_DLOG}" | while read -r l; do log "  ${l}"; done; }
    cp -f "${KMTP_DLOG}" "${KMTP_SRC}/umtprd-last.log" 2>/dev/null
    log "rolling back..."
    if teardown; then
        log "rolled back; stock USB restored"
    else
        log "rolled back, but stock USB was not restored. Reboot the Kindle."
    fi
    exit 1
}

# ---------- release the controller from the stock driver ----------
if mod_loaded g_mass_storage; then
    state_set GMS_WAS_LOADED yes
    save_gms_params
    log "unloading g_mass_storage"
    rmmod g_mass_storage || fail "could not unload g_mass_storage (in use?)"
else
    state_set GMS_WAS_LOADED no
fi

# ---------- build the MTP gadget ----------
setup_configfs() {
    load_mod libcomposite libcomposite.ko || return 1
    if ! mod_loaded usb_f_fs; then
        load_mod usb_f_fs function/usb_f_fs.ko || return 1
        state_set LOADED_USB_F_FS yes
    fi
    if ! grep -q " ${CFGFS} configfs" /proc/mounts; then
        mkdir -p "${CFGFS}" 2>/dev/null
        mount -t configfs none "${CFGFS}" || return 1
        state_set MOUNTED_CONFIGFS yes
    fi
    [ -d "${CFGFS}/usb_gadget" ] || { log "configfs has no usb_gadget directory"; return 1; }

    mkdir "${GADGET}" || return 1
    echo 0x1d6b >"${GADGET}/idVendor"
    echo 0x0100 >"${GADGET}/idProduct"
    echo 0x0200 >"${GADGET}/bcdUSB"
    mkdir "${GADGET}/strings/0x409" || return 1
    echo "KMTP0001" >"${GADGET}/strings/0x409/serialnumber"
    echo "KOReader" >"${GADGET}/strings/0x409/manufacturer"
    echo "Kindle (MTP)" >"${GADGET}/strings/0x409/product"
    mkdir "${GADGET}/functions/ffs.mtp" || return 1
    mkdir "${GADGET}/configs/c.1" || return 1
    mkdir "${GADGET}/configs/c.1/strings/0x409" || return 1
    echo "MTP" >"${GADGET}/configs/c.1/strings/0x409/configuration"
    echo 500 >"${GADGET}/configs/c.1/MaxPower"
    ln -s "${GADGET}/functions/ffs.mtp" "${GADGET}/configs/c.1/" || return 1

    mkdir -p "${FFS_MNT}"
    mount -t functionfs mtp "${FFS_MNT}" || return 1
    return 0
}

setup_gffs() {
    if ! mod_loaded usb_f_fs; then
        load_mod usb_f_fs function/usb_f_fs.ko || return 1
        state_set LOADED_USB_F_FS yes
    fi
    load_mod g_ffs legacy/g_ffs.ko functions=mtp idVendor=0x1d6b idProduct=0x0100 iManufacturer=KOReader iProduct=Kindle-MTP iSerialNumber=KMTP0001 || return 1
    mkdir -p "${FFS_MNT}"
    mount -t functionfs mtp "${FFS_MNT}" || return 1
    return 0
}

MODE="${KMTP_MODE:-configfs}"
if [ "${MODE}" = "configfs" ]; then
    log "setting up configfs MTP gadget"
    if ! setup_configfs; then
        log "configfs setup failed, cleaning up and trying legacy g_ffs"
        teardown_gadget || fail "could not clean up the half-built configfs gadget"
        MODE="gffs"
    fi
fi
if [ "${MODE}" = "gffs" ]; then
    log "setting up g_ffs MTP gadget"
    setup_gffs || fail "g_ffs setup failed"
fi
state_set MODE "${MODE}"

# ---------- start the responder ----------
log "starting umtprd"
cd "${KMTP_RUN}" || fail "cannot cd ${KMTP_RUN}"
# An ignored SIGHUP survives exec, so the daemon outlives the caller's terminal
# without needing nohup (not every BusyBox build has it).
trap '' HUP
./umtprd -conf ./umtprd.conf >"${KMTP_DLOG}" 2>&1 </dev/null &
echo $! >"${KMTP_PIDFILE}"
cd / || true

# umtprd writes its USB descriptors to ep0; the data endpoints appear once that worked.
i=0
while [ ! -e "${FFS_MNT}/ep1" ] && [ ${i} -lt 40 ]; do
    daemon_pid >/dev/null || fail "umtprd exited during startup"
    usleep 250000 2>/dev/null || sleep 1
    i=$((i + 1))
done
[ -e "${FFS_MNT}/ep1" ] || fail "umtprd never set up its USB endpoints"

if [ "${MODE}" = "configfs" ]; then
    log "binding gadget to ${UDC_NAME}"
    echo "${UDC_NAME}" >"${GADGET}/UDC" || fail "could not bind gadget to ${UDC_NAME}"
fi

usleep 500000 2>/dev/null || sleep 1
daemon_pid >/dev/null || fail "umtprd died after binding"

# Crash safety: if the caller (KOReader) dies without stopping us, stop ourselves.
if [ -n "${KMTP_WATCH_PID:-}" ]; then
    sh "${KMTP_SRC}/mtp-watch.sh" "${KMTP_WATCH_PID}" >/dev/null 2>&1 </dev/null &
    echo $! >"${KMTP_WATCHER_PIDFILE}"
    log "watching process ${KMTP_WATCH_PID}"
fi

log "MTP is ON (mode: ${MODE}, USB: $(udc_state))"
log "Plug in the cable if it isn't already. Keep the Kindle awake while copying."
log "When finished: sh ${KMTP_SRC}/mtp-stop.sh  (then unplug)"
