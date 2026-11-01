P=/tmp/kmtp-test/plugin/usbmtp.koplugin/mtp
sleep 60 & KO=$!
KMTP_WATCH_PID=$KO sh $P/mtp-start.sh | grep "MTP is ON"
echo "watcher pid file: $(cat /var/tmp/kmtp/watcher.pid 2>/dev/null)"
kill $KO; wait $KO 2>/dev/null
sleep 4
grep "watcher:" $P/mtp.log
echo "-- state: $(ls /var/tmp/kmtp/state 2>/dev/null || echo gone)"
echo "-- modules: $(cut -d' ' -f1 /proc/modules | tr '\n' ' ')"
