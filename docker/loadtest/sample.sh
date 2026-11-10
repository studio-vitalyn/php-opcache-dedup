#!/bin/bash
# Samples once per second, until killed:
#   CPU ticks of PHP-FPM (master + reaped children + live workers) and MariaDB,
#   PSS/RSS of PHP-FPM processes, worker count, and OPcache status (every 5 s).
#
# usage: sample.sh <output.csv>
set -uo pipefail

out=$1
lt="$BUILD/lt"
echo "t,fpm_ticks,db_ticks,fpm_pss_kb,fpm_rss_kb,workers,shm_used,shm_interned,scripts,dedup_hits,dedup_saved" > "$out"

opcache_status() {
	SCRIPT_FILENAME="$lt/status/status.php" REQUEST_METHOD=GET \
		cgi-fcgi -bind -connect "$lt/run/zstatus.sock" 2>/dev/null | sed '1,/^\r\{0,1\}$/d'
}

i=0
status='{}'
while :; do
	master=$(cat "$lt/run/fpm.pid" 2>/dev/null) || master=
	pids=$(pgrep -f 'php-fpm: pool' | tr '\n' ' ')
	fpm_ticks=0
	if [ -n "$master" ] && [ -r "/proc/$master/stat" ]; then
		# utime stime cutime cstime: cutime/cstime include exited workers
		fpm_ticks=$(awk '{ print $14 + $15 + $16 + $17 }' "/proc/$master/stat")
	fi
	pss=0; rss=0; workers=0
	for pid in $pids; do
		[ -r "/proc/$pid/stat" ] || continue
		read -r t < <(awk '{ print $14 + $15 }' "/proc/$pid/stat" 2>/dev/null) || continue
		fpm_ticks=$((fpm_ticks + t))
		read -r p r < <(awk '/^Pss:/ { p = $2 } /^Rss:/ { r = $2 } END { print p + 0, r + 0 }' "/proc/$pid/smaps_rollup" 2>/dev/null) || continue
		pss=$((pss + p)); rss=$((rss + r)); workers=$((workers + 1))
	done
	db_ticks=$(awk '{ print $14 + $15 }' "/proc/$(pgrep -x mariadbd | head -1)/stat" 2>/dev/null || echo 0)
	if [ $((i % 5)) -eq 0 ]; then
		status=$(opcache_status)
		[ -n "$status" ] || status='{}'
	fi
	php_fields=$(echo "$status" | sed -E 's/.*"used":([0-9]+).*"interned":([0-9]+),"scripts":([0-9]+).*"dedup_hits":([0-9]+),"dedup_saved":([0-9]+).*/\1,\2,\3,\4,\5/')
	case "$php_fields" in *[!0-9,]*|'') php_fields=",,,," ;; esac
	echo "$(date +%s.%N),$fpm_ticks,$db_ticks,$pss,$rss,$workers,$php_fields" >> "$out"
	i=$((i + 1))
	sleep 1
done
