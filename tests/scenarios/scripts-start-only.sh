P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp; F=/tmp/kmtp-test/fake
sh $P/mtp-start.sh; echo "start exit=$?"
echo "-- modules: $(cut -d' ' -f1 /proc/modules | tr '\n' ' ')"
echo "-- mounts:  $(cut -d' ' -f2,3 /proc/mounts | tr '\n' ';')"
echo "-- gadget:  $(ls /sys/kernel/config/usb_gadget 2>/dev/null)  state file: $(ls /var/tmp/kmtp/state 2>/dev/null)"
echo "-- calls:   $(tr '\n' '|' < $F/calls 2>/dev/null)"
sh $P/mtp-stop.sh >/dev/null 2>&1
