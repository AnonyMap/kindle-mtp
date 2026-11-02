P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp; F=/tmp/kmtp-test/fake
echo "########## START"; sh $P/mtp-start.sh; echo "exit=$?"
echo "serial in umtprd.conf: $(grep '^serial' /var/tmp/kmtp/umtprd.conf)"
echo "version in umtprd.conf: $(grep '^firmware_version' /var/tmp/kmtp/umtprd.conf)"
echo "serial in gadget: $(cat /sys/kernel/config/usb_gadget/kmtp/strings/0x409/serialnumber)"
echo "########## STATUS"; sh $P/mtp-status.sh
echo "gadget UDC file: $(cat /sys/kernel/config/usb_gadget/kmtp/UDC 2>&1)"
ls -R /sys/kernel/config/usb_gadget/kmtp | head -30
echo "########## STOP"; sh $P/mtp-stop.sh; echo "exit=$?"
echo "########## AFTER"; cat /proc/modules; echo "--mounts"; cat /proc/mounts; echo "--gadget"; ls /sys/kernel/config 2>&1; ls /var/tmp/kmtp 2>&1
echo "########## CALLS"; cat $F/calls
echo "########## ARGV"; cat $F/argv
echo "########## STOP AGAIN"; sh $P/mtp-stop.sh
