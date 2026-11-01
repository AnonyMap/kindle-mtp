#!/bin/sh
# kindle-mtp: stop MTP sharing and restore the stock USB driver.
# Usage:  sh /mnt/us/kindle-mtp/mtp-stop.sh

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

log "=== kindle-mtp stop ($(date)) ==="
[ "$(id -u)" = "0" ] || die "must run as root"

if [ ! -f "${KMTP_STATE}" ] && ! daemon_pid >/dev/null && [ ! -d "${GADGET}" ] && ! mod_loaded g_ffs; then
    log "MTP is not active. Nothing to do."
    exit 0
fi

if [ ! -f "${KMTP_STATE}" ]; then
    log "warning: no saved state (crash or manual cleanup?). Cleaning up what's left."
    log "If stock USB misbehaves afterwards, reboot the Kindle."
fi

cp -f "${KMTP_DLOG}" "${KMTP_SRC}/umtprd-last.log" 2>/dev/null
if ! teardown; then
    sync
    log "MTP is off, but stock USB was not restored. Reboot the Kindle."
    exit 1
fi
rm -rf "${KMTP_RUN}"
sync
log "MTP is OFF. Safe to unplug."
