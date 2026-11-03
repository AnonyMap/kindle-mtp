# Shared helpers for usbmtp. Sourced by mtp-start.sh, mtp-stop.sh, mtp-status.sh.
# Target: Kindle 10th gen (KT4), FW 5.16.x, kernel 4.1.15-lab126. Runs as root.

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"

KMTP_SRC="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"
KMTP_RUN="/var/tmp/kmtp"            # binaries run from tmpfs, never from the shared storage
KMTP_STATE="${KMTP_RUN}/state"
KMTP_PIDFILE="${KMTP_RUN}/umtprd.pid"
KMTP_WATCHER_PIDFILE="${KMTP_RUN}/watcher.pid"
KMTP_DLOG="${KMTP_RUN}/umtprd.log"  # daemon output
KMTP_LOG="${KMTP_SRC}/mtp.log"      # script log, readable from the computer afterwards
KMTP_MARK="${KMTP_RUN}/session-start" # files newer than this arrived during the session
KMTP_RECEIVED="${KMTP_SRC}/received.txt" # what arrived in the last session (for the plugin)
BOOKS_DIR="/mnt/base-us/documents"

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

# Running, and not a zombie (a dead child not yet reaped still answers kill -0).
pid_alive() {
    kill -0 "$1" 2>/dev/null || return 1
    [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != "Z" ]
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
        # A double quote can't be passed through the kernel's parameter parser.
        case "${_v}" in
            *'"'*) log "note: not restoring ${_k} (contains a double quote): ${_v}"; continue ;;
        esac
        state_set GMS_PARAM "${_k}=${_v}"   # one per line, so values may contain spaces
        _params="${_params} ${_k}=${_v}"
    done
    log "saved g_mass_storage params: ${_params:- (none)}"
}

# Reload g_mass_storage with the parameters save_gms_params recorded.
# Values with spaces are passed as name="value", the form the kernel's
# module-parameter parser understands. Never file=: it would export a partition
# on load while the Kindle still has it mounted, and the state we found had
# nothing exported anyway (preflight refuses to start otherwise; volumd sets the
# backing file itself when it shares the storage).
reload_saved_gms() {
    set --
    if grep -q '^GMS_PARAM=' "${KMTP_STATE}" 2>/dev/null; then
        while IFS= read -r _l; do
            case "${_l}" in
                GMS_PARAM=*)
                    _kv="${_l#GMS_PARAM=}"
                    _k="${_kv%%=*}"
                    _v="${_kv#*=}"
                    [ "${_k}" = file ] && { log "not passing file=${_v} (the storage is still mounted here)"; continue; }
                    case "${_v}" in
                        *" "*) set -- "$@" "${_k}=\"${_v}\"" ;;
                        *) set -- "$@" "${_k}=${_v}" ;;
                    esac
                    ;;
            esac
        done <"${KMTP_STATE}"
    else
        # State written by v0.5 or earlier: one space-separated line.
        set -f
        for _kv in $(state_get GMS_PARAMS); do
            case "${_kv}" in
                file=*) log "not passing ${_kv} (the storage is still mounted here)" ;;
                *) set -- "$@" "${_kv}" ;;
            esac
        done
        set +f
    fi
    log "reloading g_mass_storage $*"
    reload_gms "$@"
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

# After the daemon has stopped: record files that arrived in documents/ during the
# session, as /mnt/us paths (what KOReader uses). Skips KOReader's own .sdr
# metadata and dot-files. Writes nothing if there was no session marker.
list_received() {
    [ -f "${KMTP_MARK}" ] || return 0
    [ -d "${BOOKS_DIR}" ] || return 0
    find "${BOOKS_DIR}" -type f -newer "${KMTP_MARK}" 2>/dev/null |
        grep -v -e '\.sdr/' -e '/\.' |
        sed 's#^/mnt/base-us/#/mnt/us/#' >"${KMTP_RECEIVED}.tmp"
    mv -f "${KMTP_RECEIVED}.tmp" "${KMTP_RECEIVED}"
    _n="$(wc -l <"${KMTP_RECEIVED}" | tr -d ' ')"
    log "received ${_n} new file(s) in documents/"
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
        while pid_alive "${_p}" && [ ${_i} -lt 20 ]; do
            usleep 250000 2>/dev/null || sleep 1
            _i=$((_i + 1))
        done
        if pid_alive "${_p}"; then
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
    # reload_gms [params...]  -> 0 if g_mass_storage is loaded (and exporting nothing) afterwards
    if insmod "${MODDIR}/legacy/g_mass_storage.ko" "$@" 2>/dev/null; then
        gms_unexport
        return
    fi
    [ $# -gt 0 ] && log "warning: reload with saved params failed, retrying with defaults"
    modprobe g_mass_storage 2>/dev/null || insmod "${MODDIR}/legacy/g_mass_storage.ko" 2>/dev/null || return 1
    gms_unexport
}

# Safety net: the stock driver must come back exactly as we found it, loaded and
# exporting nothing. The storage is still mounted here, so if the reloaded driver
# exported it anyway, the computer and the Kindle would both write the same FAT
# filesystem and corrupt it. Runs right after loading, before a computer has had
# time to enumerate the gadget; the direct sysfs path first, since the full
# /sys/devices walk is slow on this CPU. Returns 1 unless nothing is exported.
gms_unexport() {
    gms_exporting || return 0
    log "warning: the reloaded stock USB driver exported the storage while the Kindle has it mounted; ejecting it"
    for _f in /sys/class/udc/${UDC_NAME}/device/gadget/lun*/file; do
        [ -e "${_f}" ] && echo "" >"${_f}" 2>/dev/null
    done
    gms_exporting || return 0
    for _f in $(find /sys/devices -path '*/gadget/lun*/file' 2>/dev/null); do
        echo "" >"${_f}" 2>/dev/null
    done
    gms_exporting || return 0
    if rmmod g_mass_storage 2>/dev/null; then
        log "ERROR: could not eject the storage from the stock USB driver, so it was unloaded again. Unplug the cable and reboot the Kindle."
    else
        log "ERROR: the stock USB driver is sharing the storage while the Kindle has it mounted, and could not be stopped. Eject it on the computer, unplug the cable and reboot the Kindle."
    fi
    return 1
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
        if ! reload_saved_gms || ! mod_loaded g_mass_storage; then
            # (gms_unexport has already logged it if the driver is up but exporting)
            log "ERROR: could not reload the stock USB driver. Reboot the Kindle to restore stock USB."
            _restore_ok=1
        fi
    fi
    # Also on a retry where the driver is already back: it must not be exporting the
    # storage. (Unless volumd runs again and is managing USB itself.)
    if [ ${_restore_ok} -eq 0 ] && [ "$(volumd_state)" != running ] && ! gms_unexport; then
        _restore_ok=1
    fi

    [ ${_restore_ok} -eq 0 ] && rm -f "${KMTP_STATE}"
    log "USB controller state: $(udc_state)"
    return ${_restore_ok}
}
