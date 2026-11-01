#!/bin/sh
# kindle-mtp: stop MTP sharing and restore the stock USB driver.
# Usage:  sh /mnt/us/kindle-mtp/mtp-stop.sh

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

log "=== kindle-mtp stop ($(date)) ==="
[ "$(id -u)" = "0" ] || die "must run as root"

if [ ! -f "${KMTP_STATE}" ] && ! daemon_pid >/dev/null && [ ! -d "${GADGET}" ] && ! mod_loaded g_ffs; then
    if mod_loaded g_mass_storage || [ ! -f "${MODDIR}/legacy/g_mass_storage.ko" ]; then
        log "MTP is not active. Nothing to do."
        exit 0
    fi
    # Nothing of ours is left, but the stock driver is missing (e.g. state was lost).
    log "MTP is not active, but the stock USB driver isn't loaded; loading it with defaults"
    if reload_gms && mod_loaded g_mass_storage; then
        log "Stock USB driver loaded. Safe to unplug."
        exit 0
    fi
    log "ERROR: could not load the stock USB driver. Reboot the Kindle."
    exit 1
fi

HAD_STATE=no; [ -f "${KMTP_STATE}" ] && HAD_STATE=yes
if [ "${HAD_STATE}" = "no" ]; then
    log "warning: no saved state (crash or manual cleanup?). Cleaning up what's left."
    log "If stock USB misbehaves afterwards, reboot the Kindle."
fi

cp -f "${KMTP_DLOG}" "${KMTP_SRC}/umtprd-last.log" 2>/dev/null
if ! teardown; then
    sync
    log "MTP is off, but stock USB was not restored. Reboot the Kindle."
    exit 1
fi
if [ "${HAD_STATE}" = "no" ] && ! mod_loaded g_mass_storage; then
    log "stock USB driver missing and no saved settings; loading it with defaults"
    reload_gms || { log "ERROR: could not load the stock USB driver. Reboot the Kindle."; exit 1; }
fi
rm -rf "${KMTP_RUN}"
sync
log "MTP is OFF. Safe to unplug."
