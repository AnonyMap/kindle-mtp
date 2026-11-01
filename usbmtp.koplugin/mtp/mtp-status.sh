#!/bin/sh
# kindle-mtp: show what's going on. Read-only.
# Usage:  sh /mnt/us/kindle-mtp/mtp-status.sh

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

echo "version:       $(cat "${KMTP_SRC}/VERSION" 2>/dev/null)"
echo "USB serial:    $(sed -n 's/^serial "\(.*\)"/\1/p' "${KMTP_RUN}/umtprd.conf" 2>/dev/null)"
echo "volumd:        $(volumd_state)"
echo "USB state:     $(udc_state)"
_p="$(daemon_pid)"
if [ -n "${_p}" ]; then
    echo "umtprd:        running (pid ${_p})"
else
    echo "umtprd:        not running"
fi
echo "mode:          $(state_get MODE)"
echo "gadget dir:    $([ -d "${GADGET}" ] && echo present || echo absent)"
echo "gadget UDC:    $(cat "${GADGET}/UDC" 2>/dev/null)"
echo "FunctionFS:    $(grep -q " ${FFS_MNT} functionfs" /proc/mounts && echo mounted || echo not mounted)"
echo "modules:       $(grep -oE '^(g_mass_storage|g_ffs|g_ether|usb_f_fs|usb_f_mass_storage|libcomposite) ' /proc/modules | tr -d '\n')"
echo
echo "--- saved state ---"
cat "${KMTP_STATE}" 2>/dev/null || echo "(none)"
echo
echo "--- last 20 lines of umtprd output ---"
tail -n 20 "${KMTP_DLOG}" 2>/dev/null || echo "(none)"
