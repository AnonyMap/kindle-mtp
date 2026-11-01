P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp
sh $P/mtp-start.sh >/dev/null; echo "started: $(sh $P/mtp-status.sh | grep umtprd:)"
kill -9 "$(cat /var/tmp/kmtp/umtprd.pid)"; sleep 1
echo "after crash: $(sh $P/mtp-status.sh | grep umtprd:)"
echo "-- start again:"; sh $P/mtp-start.sh; echo "exit=$?"
echo "-- stop:"; sh $P/mtp-stop.sh
echo "-- modules: $(cut -d' ' -f1 /proc/modules | tr '\n' ' ') mounts: $(cut -d' ' -f2 /proc/mounts | tr '\n' ' ')"
