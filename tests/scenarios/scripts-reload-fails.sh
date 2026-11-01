P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp
sh $P/mtp-start.sh >/dev/null; touch /tmp/kmtp-test/fake/fail_insmod_g_mass_storage; sh $P/mtp-stop.sh
