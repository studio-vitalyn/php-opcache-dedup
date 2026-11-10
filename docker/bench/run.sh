#!/bin/sh
# A/B benchmark: N WordPress sites, one PHP-FPM master, one pool and one Unix
# user per site, opcache.validate_permission=1. Every PHP file of every site
# is compiled through its own pool (concurrently), then OPcache memory is read
# from opcache_get_status(). Run once with opcache.enable_dedup=0, once with 1.
#
# usage: docker/bench/run.sh [series] [sites] [identical_percent]
set -eu

series=${1:-8.4}
sites=${2:-80}
identical=${3:-80}
parallel=${PARALLEL:-8}
# Must be large enough for the dedup=0 run, or both runs hit the ceiling
memory=${MEMORY:-8192}
interned=${INTERNED:-256}
# GDB=1 attaches gdb to every worker and writes backtraces of crashes to
# $BUILD/gdb (core dumps are not reliable in containers)
flavor=${FLAVOR:-release}
gdb=${GDB:-0}

here=$(cd "$(dirname "$0")" && pwd)
root="$BUILD/bench"
inst="$BUILD/$series-$flavor/inst"
results="$BUILD/results/bench-$series-$sites"
mkdir -p "$root/run" "$root/pool.d" "$results"

"$REPO/docker/build.sh" "$series" "$flavor"
"$here/sites.sh" "$sites" "$identical"

fpm_stop() {
	if [ -f "$root/run/fpm.pid" ]; then
		kill "$(cat "$root/run/fpm.pid")" 2>/dev/null || true
		while [ -f "$root/run/fpm.pid" ]; do sleep 0.2; done
	fi
}

fcgi() {
	# fcgi <site> <script>
	SCRIPT_FILENAME="$root/sites/$1/$2" REQUEST_METHOD=GET \
		cgi-fcgi -bind -connect "$root/run/$1.sock" | sed '1,/^\r\{0,1\}$/d'
}

for dedup in 0 1; do
	fpm_stop
	rm -f "$root"/pool.d/*.conf "$root/fpm.log"

	{
		case "$series" in
			8.2|8.3|8.4) echo "zend_extension=opcache" ;;
		esac
		cat <<-INI
		opcache.enable=1
		opcache.enable_dedup=$dedup
		opcache.memory_consumption=$memory
		opcache.interned_strings_buffer=$interned
		opcache.max_accelerated_files=1000000
		opcache.validate_permission=1
		opcache.validate_timestamps=0
		opcache.jit=disable
		opcache.protect_memory=${PROTECT:-0}
		opcache.jit_buffer_size=0
		opcache.log_verbosity_level=2
		opcache.error_log=$root/fpm.log
		memory_limit=1G
		max_execution_time=0
		INI
	} > "$root/php.ini"

	cat > "$root/php-fpm.conf" <<-CONF
	[global]
	pid = $root/run/fpm.pid
	error_log = $root/fpm.log
	daemonize = yes
	process.max = 0
	include = $root/pool.d/*.conf
	CONF

	for site in $(cat "$root/sites.list"); do
		cat > "$root/pool.d/$site.conf" <<-POOL
		[$site]
		user = $site
		group = $site
		listen = $root/run/$site.sock
		listen.mode = 0600
		$( if [ "$gdb" = 1 ]; then printf "pm = static\npm.max_children = 1\nprocess.dumpable = yes\ncatch_workers_output = yes"; else printf "pm = ondemand\npm.max_children = 2\npm.process_idle_timeout = 300s"; fi )
		POOL
	done

	"$inst/sbin/php-fpm" -c "$root/php.ini" -y "$root/php-fpm.conf" -R
	while [ ! -S "$root/run/$(head -1 "$root/sites.list").sock" ]; do sleep 0.2; done
	if [ "$gdb" = 1 ]; then
		mkdir -p "$BUILD/gdb"
		sleep 1
		for pid in $(pgrep -f "php-fpm: pool"); do
			gdb -p "$pid" -batch -q -ex "handle SIGPIPE nostop noprint" -ex continue -ex "bt full" \
				> "$BUILD/gdb/dedup$dedup-$pid.txt" 2>&1 &
		done
		sleep 2
	fi

	start=$(date +%s.%N)
	xargs -P "$parallel" -I{} sh -c "SCRIPT_FILENAME=$root/sites/{}/__warm.php REQUEST_METHOD=GET cgi-fcgi -bind -connect $root/run/{}.sock | tail -1; echo" \
		< "$root/sites.list" | grep '^{' > "$results/warm-$dedup.jsonl"
	end=$(date +%s.%N)
	echo "$start $end" > "$results/wall-$dedup.txt"

	: > "$results/smoke-$dedup.txt"
	for site in $(cat "$root/sites.list"); do
		echo "$site $(fcgi "$site" __smoke.php)" >> "$results/smoke-$dedup.txt"
	done

	fcgi "$(head -1 "$root/sites.list")" __status.php > "$results/status-$dedup.json"
	grep -c 'Not enough free shared space\|restart' "$root/fpm.log" > "$results/oom-$dedup.txt" || true
	grep -ciE 'wrong size|error|fatal' "$root/fpm.log" > "$results/errors-$dedup.txt" || true
	cp "$root/fpm.log" "$results/fpm-$dedup.log"
done
fpm_stop

"$inst/bin/php" "$here/report.php" "$results" "$series" "$sites" "$identical" | tee "$results/report.md"
