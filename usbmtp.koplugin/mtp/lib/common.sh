# Shared helpers for kindle-mtp. Sourced by mtp-start.sh, mtp-stop.sh, mtp-status.sh.
# Target: Kindle 10th gen (KT4), FW 5.16.x, kernel 4.1.15-lab126. Runs as root.

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"

KMTP_SRC="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
KMTP_RUN="/var/tmp/kmtp"            # binaries run from tmpfs, never from the shared storage
KMTP_STATE="${KMTP_RUN}/state"
KMTP_PIDFILE="${KMTP_RUN}/umtprd.pid"
KMTP_WATCHER_PIDFILE="${KMTP_RUN}/watcher.pid"
KMTP_DLOG="${KMTP_RUN}/umtprd.log"  # daemon output
KMTP_LOG="${KMTP_SRC}/mtp.log"      # script log, readable from the computer afterwards

EXPECTED_KERNEL="4.1.15-lab126"
UDC_NAME="ci_hdrc.0"
MODDIR="/lib/modules/$(uname -r)/kernel/drivers/usb/gadget"
CFGFS="/sys/kernel/config"
GADGET="${CFGFS}/usb_gadget/kmtp"
FFS_MNT="/dev/ffs-mtp"

log() {
    echo "$*"
    echo "$(date '+%H:%M:%S') $*" >>"${KMTP_LOG}" 2>/dev/null
}

die() {
    log "ERROR: $*"
    exit 1
}

state_get() {
    # state_get KEY -> value (empty if unset)
    [ -f "${KMTP_STATE}" ] || return 0
    sed -n "s/^${1}=//p" "${KMTP_STATE}" | tail -n 1
}

state_set() {
    mkdir -p "${KMTP_RUN}"
    echo "${1}=${2}" >>"${KMTP_STATE}"
}

mod_loaded() {
    grep -q "^${1} " /proc/modules
}

load_mod() {
    # load_mod NAME RELPATH [params...]
    _name="$1"; _rel="$2"; shift 2
    mod_loaded "${_name}" && return 0
    if modprobe "${_name}" "$@" 2>/dev/null; then
        return 0
    fi
    insmod "${MODDIR}/${_rel}" "$@"
}

volumd_state() {
    # Prints: absent | stopped | running
    _pid="$(pidof volumd 2>/dev/null | awk '{print $1}')"
    if [ -z "${_pid}" ]; then
        echo absent
        return
    fi
    _st="$(awk '{print $3}' "/proc/${_pid}/stat" 2>/dev/null)"
    if [ "${_st}" = "T" ] || [ "${_st}" = "t" ]; then
        echo stopped
    else
        echo running
    fi
}

daemon_pid() {
    [ -f "${KMTP_PIDFILE}" ] || return 1
    _p="$(cat "${KMTP_PIDFILE}")"
    [ -n "${_p}" ] && kill -0 "${_p}" 2>/dev/null || return 1
    # A zombie still answers kill -0; treat it as dead.
    [ "$(awk '{print $3}' "/proc/${_p}/stat" 2>/dev/null)" = "Z" ] && return 1
    echo "${_p}"
}

udc_state() {
    cat "/sys/class/udc/${UDC_NAME}/state" 2>/dev/null || echo unknown
}

# Save g_mass_storage's current module parameters so we can reload it exactly as volumd left it.
save_gms_params() {
    _params=""
    for _f in /sys/module/g_mass_storage/parameters/*; do
        [ -r "${_f}" ] || continue
        _k="${_f##*/}"
        _v="$(cat "${_f}" 2>/dev/null)"
        # Skip empty / NULL / all-comma (empty array) values
        case "${_v}" in
            "" | "(null)") continue ;;
        esac
        [ -z "$(echo "${_v}" | tr -d ',')" ] && continue
        # Values with spaces can't round-trip through insmod safely; record and skip.
        case "${_v}" in
            *" "*) log "note: not restoring ${_k} (contains spaces): ${_v}"; continue ;;
        esac
        _params="${_params} ${_k}=${_v}"
    done
    state_set GMS_PARAMS "${_params# }"
    log "saved g_mass_storage params: ${_params:- (none)}"
}

# Is the stock USB drive mode actively exporting storage right now?
# Direct path first; only walk /sys/devices (slow on this CPU) if that finds no LUNs.
gms_exporting() {
    _found=0
    for _f in /sys/class/udc/${UDC_NAME}/device/gadget/lun*/file; do
        [ -r "${_f}" ] || continue
        _found=1
        [ -n "$(cat "${_f}" 2>/dev/null)" ] && return 0
    done
    [ ${_found} -eq 1 ] && return 1
    for _f in $(find /sys/devices -path '*/gadget/lun*/file' 2>/dev/null); do
        [ -n "$(cat "${_f}" 2>/dev/null)" ] && return 0
    done
    return 1
}

stop_watcher() {
    # The crash watcher calls mtp-stop.sh itself; don't kill our own caller.
    _w="$(cat "${KMTP_WATCHER_PIDFILE}" 2>/dev/null)"
    if [ -n "${_w}" ] && [ "${_w}" != "${PPID}" ] && kill -0 "${_w}" 2>/dev/null; then
        kill -TERM "${_w}" 2>/dev/null
    fi
    rm -f "${KMTP_WATCHER_PIDFILE}"
}

stop_daemon() {
    _p="$(daemon_pid)"
    if [ -n "${_p}" ]; then
        log "stopping umtprd (pid ${_p})"
        kill -TERM "${_p}" 2>/dev/null
        _i=0
        while kill -0 "${_p}" 2>/dev/null && [ ${_i} -lt 20 ]; do
            usleep 250000 2>/dev/null || sleep 1
            _i=$((_i + 1))
        done
        if kill -0 "${_p}" 2>/dev/null; then
            log "umtprd did not exit, sending SIGKILL"
            kill -KILL "${_p}" 2>/dev/null
            usleep 300000 2>/dev/null || sleep 1
        fi
    fi
    # Catch strays (e.g. after a crash, pidfile lost)
    killall umtprd 2>/dev/null && { usleep 300000 2>/dev/null || sleep 1; }
    rm -f "${KMTP_PIDFILE}"
}

# Remove our MTP gadget (either flavour). Does not touch the stock driver.
# Order matters on Linux 4.1: FunctionFS must be unmounted BEFORE its configfs
# function instance is removed, or the unmount writes into freed kernel memory
# (f_fs.c _ffs_free_dev doesn't clear ffs_data->private_data). Returns 1 on failure.
teardown_gadget() {
    _gadget_ok=0
    stop_watcher

    # 1. Detach from the host first, so it sees a clean disconnect.
    if [ -d "${GADGET}" ]; then
        log "unbinding gadget"
        echo "" >"${GADGET}/UDC" 2>/dev/null
    fi

    # 2. Stop the daemon (closes the endpoint files), and flush its writes.
    stop_daemon
    sync

    # 3. Unmount FunctionFS while the function instance still exists.
    if grep -q " ${FFS_MNT} functionfs" /proc/mounts; then
        log "unmounting FunctionFS"
        if ! umount "${FFS_MNT}" 2>/dev/null; then
            log "ERROR: could not unmount ${FFS_MNT}; leaving the gadget in place (reboot to clear)"
            return 1
        fi
    fi
    rmdir "${FFS_MNT}" 2>/dev/null

    # 4. Now the configfs gadget can go.
    if [ -d "${GADGET}" ]; then
        log "removing configfs gadget"
        rm -f "${GADGET}/configs/c.1/ffs.mtp" 2>/dev/null
        rmdir "${GADGET}/configs/c.1/strings/0x409" 2>/dev/null
        rmdir "${GADGET}/configs/c.1" 2>/dev/null
        rmdir "${GADGET}/functions/ffs.mtp" 2>/dev/null
        rmdir "${GADGET}/strings/0x409" 2>/dev/null
        if ! rmdir "${GADGET}" 2>/dev/null; then
            log "ERROR: could not remove ${GADGET}"
            _gadget_ok=1
        fi
    fi

    if mod_loaded g_ffs; then
        log "unloading g_ffs"
        rmmod g_ffs 2>/dev/null || { log "ERROR: could not unload g_ffs"; _gadget_ok=1; }
    fi
    if [ "$(state_get LOADED_USB_F_FS)" = "yes" ] && mod_loaded usb_f_fs; then
        rmmod usb_f_fs 2>/dev/null || log "note: left usb_f_fs loaded"
    fi

    if [ "$(state_get MOUNTED_CONFIGFS)" = "yes" ] && grep -q " ${CFGFS} configfs" /proc/mounts; then
        umount "${CFGFS}" 2>/dev/null || log "note: left configfs mounted"
    fi
    return ${_gadget_ok}
}

reload_gms() {
    # reload_gms [params...]  -> 0 if g_mass_storage is loaded afterwards
    # shellcheck disable=SC2068
    insmod "${MODDIR}/legacy/g_mass_storage.ko" $@ 2>/dev/null && return 0
    [ $# -gt 0 ] && log "warning: reload with saved params failed, retrying with defaults"
    modprobe g_mass_storage 2>/dev/null || insmod "${MODDIR}/legacy/g_mass_storage.ko" 2>/dev/null
}

# Undo everything start did, in reverse order. Safe to run repeatedly and after partial starts.
# Returns 1 if anything couldn't be undone; the state file is then kept so a retry
# (Reset / next stop) still knows how to put the stock driver back.
teardown() {
    _restore_ok=0
    if ! teardown_gadget; then
        log "ERROR: MTP gadget not fully removed, so the stock USB driver was not restored. Reboot the Kindle."
        log "USB controller state: $(udc_state)"
        return 1
    fi

    # Put the stock USB driver back the way we found it.
    if [ "$(state_get GMS_WAS_LOADED)" = "yes" ] && ! mod_loaded g_mass_storage; then
        _gp="$(state_get GMS_PARAMS)"
        log "reloading g_mass_storage ${_gp}"
        set -f   # saved params are word-split on purpose, but never globbed
        # shellcheck disable=SC2086
        reload_gms ${_gp}
        set +f
        if ! mod_loaded g_mass_storage; then
            log "ERROR: could not reload the stock USB driver. Reboot the Kindle to restore stock USB."
            _restore_ok=1
        fi
    fi

    [ ${_restore_ok} -eq 0 ] && rm -f "${KMTP_STATE}"
    log "USB controller state: $(udc_state)"
    return ${_restore_ok}
}
