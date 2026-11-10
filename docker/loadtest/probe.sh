#!/bin/bash
# Error reporting check: the same probe (identical files, so deduplicated)
# is deployed on every site; every site is called in turn, once to dump
# __FILE__/__LINE__/__CLASS__/... and traces, then once per kind of error.
# Each new line of the PHP error log is attributed to the request that wrote
# it. Run with dedup off and on, the outputs must be identical and every path
# must belong to the calling site.
#
# usage: docker/loadtest/probe.sh [series]
set -uo pipefail

series=${1:-8.4}
here=$(cd "$(dirname "$0")" && pwd)
lt="$BUILD/lt"
inst="$BUILD/$series-bench/inst"
out="$BUILD/results/probe"
rm -rf "$out"
mkdir -p "$out"

while read -r site; do
	id -u "$site" > /dev/null 2>&1 || useradd -M -U -s /usr/sbin/nologin "$site"
	mkdir -p "$lt/sites/$site/probe"
	cp "$here"/probe/*.php "$lt/sites/$site/probe/"
	chown -R "$site:$site" "$lt/sites/$site/probe"
	chmod 751 "$lt/sites/$site/probe"
	chmod 640 "$lt/sites/$site/probe/"*.php
done < "$lt/sites.list"

for dedup in 0 1; do
	"$here/stop.sh" > /dev/null
	sed -i "s/^opcache.enable_dedup=.*/opcache.enable_dedup=$dedup/" "$lt/php.ini"
	: > "$lt/logs/php-errors.log"
	chmod 666 "$lt/logs/php-errors.log"
	"$inst/sbin/php-fpm" -c "$lt/php.ini" -y "$lt/php-fpm.conf" -R
	nginx -c "$lt/nginx.conf"
	for _ in $(seq 1 50); do [ -S "$lt/run/zstatus.sock" ] && break; sleep 0.2; done

	log="$out/dedup$dedup.txt"
	: > "$log"
	while read -r site; do
		for url in "probe/index.php" "probe/fail.php?kind=warning" "probe/fail.php?kind=notice" \
			"probe/fail.php?kind=exception" "probe/fail.php?kind=error" "probe/fail.php?kind=division"; do
			before=$(stat -c %s "$lt/logs/php-errors.log")
			body=$(curl -s -w ' [HTTP %{http_code}]' "http://127.0.0.1:8080/$site/$url")
			sleep 0.05
			echo "### $site $url" >> "$log"
			echo "$body" >> "$log"
			# Log lines written by this request, without their timestamp
			tail -c +"$((before + 1))" "$lt/logs/php-errors.log" | sed -E 's/^\[[^]]*\] //' >> "$log"
		done
	done < "$lt/sites.list"

	SCRIPT_FILENAME="$lt/status/status.php" REQUEST_METHOD=GET \
		cgi-fcgi -bind -connect "$lt/run/zstatus.sock" | sed '1,/^\r\{0,1\}$/d' > "$out/opcache$dedup.json"
	grep -c SIGSEGV "$lt/logs/fpm.log" > "$out/segfaults$dedup.txt"
done
"$here/stop.sh" > /dev/null

"$inst/bin/php" "$here/probe-check.php" "$out"
