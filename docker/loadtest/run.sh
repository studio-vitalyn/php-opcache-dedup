#!/bin/bash
# One load test run: fresh PHP-FPM master (cold OPcache) with one pool per
# site, nginx in front, h2load replaying the request mix, and a sampler
# recording CPU, memory and OPcache metrics every second.
#
# usage: docker/loadtest/run.sh <dedup 0|1> <requests> <label> [series]
set -euo pipefail

dedup=$1
requests=$2
label=$3
series=${4:-8.4}
here=$(cd "$(dirname "$0")" && pwd)
lt="$BUILD/lt"
inst="$BUILD/$series-bench/inst"
out="$BUILD/results/loadtest/$label"
concurrency=${CONCURRENCY:-32}
rm -rf "$out"
mkdir -p "$out" "$lt/run" "$lt/logs"

# Users live in the container image, files in the volume: recreate them in
# order so that they get the same uids after the container is recreated
while read -r site; do
	id -u "$site" > /dev/null 2>&1 || useradd -M -U -s /usr/sbin/nologin "$site"
done < "$lt/sites.list"

"$here/mariadb.sh" start

fpm_stop() {
	if [ -f "$lt/run/fpm.pid" ]; then
		kill -QUIT "$(cat "$lt/run/fpm.pid")" 2>/dev/null || true
		for _ in $(seq 1 100); do [ -f "$lt/run/fpm.pid" ] || break; sleep 0.2; done
	fi
	pkill -f 'php-fpm: ' 2>/dev/null || true
	rm -f "$lt/run/fpm.pid"
}
nginx_stop() {
	[ -f "$lt/run/nginx.pid" ] && kill "$(cat "$lt/run/nginx.pid")" 2>/dev/null || true
	sleep 0.5
}
fpm_stop
nginx_stop

{
	case "$series" in
		8.2|8.3|8.4) echo "zend_extension=opcache" ;;
	esac
	cat <<-INI
	opcache.enable=1
	opcache.enable_dedup=$dedup
	opcache.memory_consumption=${MEMORY:-8192}
	opcache.interned_strings_buffer=${INTERNED:-256}
	opcache.max_accelerated_files=1000000
	opcache.validate_permission=1
	opcache.validate_timestamps=1
	opcache.revalidate_freq=2
	opcache.jit=disable
	opcache.log_verbosity_level=2
	opcache.error_log=$lt/logs/opcache.log
	memory_limit=256M
	max_execution_time=60
	display_errors=0
	log_errors=1
	error_log=$lt/logs/php-errors.log
	mysqli.default_socket=/run/mysqld/mysqld.sock
	INI
} > "$lt/php.ini"

{
	cat <<-CONF
	[global]
	pid = $lt/run/fpm.pid
	error_log = $lt/logs/fpm.log
	daemonize = yes
	process.max = 0
	rlimit_files = 65536

	[zstatus]
	user = www-data
	group = www-data
	listen = $lt/run/zstatus.sock
	pm = static
	pm.max_children = 1
	CONF
	while read -r site; do
		cat <<-POOL

		[$site]
		user = $site
		group = $site
		listen = $lt/run/$site.sock
		listen.owner = www-data
		listen.group = www-data
		listen.mode = 0660
		pm = ondemand
		pm.max_children = ${CHILDREN:-3}
		pm.process_idle_timeout = 10s
		POOL
	done < "$lt/sites.list"
} > "$lt/php-fpm.conf"

cat > "$lt/nginx.conf" <<-NGINX
	user www-data;
	worker_processes 2;
	pid $lt/run/nginx.pid;
	error_log $lt/logs/nginx-error.log warn;
	events { worker_connections 4096; }
	http {
		access_log off;
		keepalive_requests 1000000;
		fastcgi_buffers 32 16k;
		server {
			listen 127.0.0.1:8080 default_server;
			root $lt/sites;
			index index.php;
			location ~ "^/(?<site>site[0-9]{3})/.*\.php\$" {
				include /etc/nginx/fastcgi_params;
				fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
				# Keep the port, WordPress compares it with the site URL
				fastcgi_param HTTP_HOST \$http_host;
				fastcgi_pass unix:$lt/run/\$site.sock;
			}
			location ~ "^/(?<site>site[0-9]{3})(/|\$)" {
				try_files \$uri \$uri/ /\$site/index.php?\$args;
			}
		}
	}
NGINX

: > "$lt/logs/fpm.log"
: > "$lt/logs/php-errors.log"
# Written by the workers, which run as the site users
chmod 666 "$lt/logs/php-errors.log"
: > "$lt/logs/opcache.log"
: > "$lt/logs/nginx-error.log"
"$inst/sbin/php-fpm" -c "$lt/php.ini" -y "$lt/php-fpm.conf" -R
nginx -c "$lt/nginx.conf"
for _ in $(seq 1 50); do [ -S "$lt/run/zstatus.sock" ] && break; sleep 0.2; done

"$here/sample.sh" "$out/metrics.csv" &
sampler=$!

start=$(date +%s.%N)
h2load --h1 -n "$requests" -c "$concurrency" -t 4 -i "$lt/uris.txt" \
	--log-file="$out/requests.tsv" > "$out/h2load.txt" 2>&1 || true
end=$(date +%s.%N)

sleep 3
kill "$sampler" 2>/dev/null || true
wait "$sampler" 2>/dev/null || true

SCRIPT_FILENAME="$lt/status/status.php" REQUEST_METHOD=GET \
	cgi-fcgi -bind -connect "$lt/run/zstatus.sock" | sed '1,/^\r\{0,1\}$/d' > "$out/opcache.json"
fpm_stop
nginx_stop

cp "$lt/logs/fpm.log" "$lt/logs/php-errors.log" "$lt/logs/opcache.log" "$lt/logs/nginx-error.log" "$out/"
cat > "$out/run.json" <<-JSON
	{"dedup": $dedup, "requests": $requests, "concurrency": $concurrency, "series": "$series",
	 "sites": $(wc -l < "$lt/sites.list"), "start": $start, "end": $end,
	 "segfaults": $(grep -c SIGSEGV "$out/fpm.log" || true),
	 "php_errors": $(grep -c 'PHP Fatal' "$out/php-errors.log" || true)}
JSON
grep -E 'finished in|requests:|status codes|time for request' "$out/h2load.txt" || true
