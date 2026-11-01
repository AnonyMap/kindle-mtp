#!/bin/sh
# kindle-mtp crash watcher: if the process that started MTP (KOReader) dies
# without stopping it, stop it ourselves, so the stock USB driver is back before
# the launcher resumes Amazon's volumd.
# Usage (started by mtp-start.sh):  sh mtp-watch.sh <pid-to-watch>

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

WATCH="$1"
[ -n "${WATCH}" ] || exit 0
trap '' HUP

while [ -f "${KMTP_STATE}" ] && kill -0 "${WATCH}" 2>/dev/null; do
    # A zombie still answers kill -0
    [ "$(awk '{print $3}' "/proc/${WATCH}/stat" 2>/dev/null)" = "Z" ] && break
    sleep 1
done

if [ -f "${KMTP_STATE}" ]; then
    log "watcher: process ${WATCH} is gone but MTP is still on; stopping it"
    sh "${KMTP_SRC}/mtp-stop.sh" >/dev/null 2>&1
fi
