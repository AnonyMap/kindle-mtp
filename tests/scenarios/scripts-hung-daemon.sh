P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp
sed -i "s/trap '.*' TERM/trap '' TERM/" $P/bin/umtprd
sh $P/mtp-start.sh >/dev/null; t0=$(date +%s); sh $P/mtp-stop.sh; echo "stop took $(( $(date +%s)-t0 ))s"
echo "-- leftover umtprd procs: $(ps -eo pid,args 2>/dev/null | grep -c '[f]ake umtprd')"
