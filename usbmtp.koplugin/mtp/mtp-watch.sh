#!/bin/sh
# usbmtp crash watcher: if the process that started MTP (KOReader) dies
# without stopping it, stop it ourselves. KOReader's launcher resumes Amazon's
# volumd right after KOReader exits, so volumd is paused again while we tear
# down, and resumed afterwards.
# Usage (started by mtp-start.sh):  sh mtp-watch.sh <pid-to-watch>

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

WATCH="$1"
[ -n "${WATCH}" ] || exit 0
trap '' HUP

while [ -f "${KMTP_STATE}" ] && pid_alive "${WATCH}"; do
    usleep 200000 2>/dev/null || sleep 1
done

if [ -f "${KMTP_STATE}" ]; then
    log "watcher: process ${WATCH} is gone but MTP is still on; stopping it"
    PAUSED_VOLUMD=""
    if [ "$(volumd_state)" = "running" ]; then
        PAUSED_VOLUMD="$(pidof volumd 2>/dev/null)"
        # shellcheck disable=SC2086
        [ -n "${PAUSED_VOLUMD}" ] && kill -STOP ${PAUSED_VOLUMD} 2>/dev/null && log "watcher: paused volumd during teardown"
    fi
    sh "${KMTP_SRC}/mtp-stop.sh" >/dev/null 2>&1
    if [ -n "${PAUSED_VOLUMD}" ]; then
        # shellcheck disable=SC2086
        kill -CONT ${PAUSED_VOLUMD} 2>/dev/null
        log "watcher: resumed volumd"
    fi
fi
