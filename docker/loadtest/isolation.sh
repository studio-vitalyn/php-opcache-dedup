#!/bin/bash
# Cross-tenant isolation checks under PHP-FPM: two sites, two Unix users, one
# master. Run with dedup off and on, and with and without opcache.restrict_api;
# the dedup runs must behave exactly like the native ones.
#
#  1. identical code on both sites is shared, then each site edits its own
#     copy in turn: a site must only ever see its own version
#  2. the OPcache API (status, invalidate, reset) from one site: native
#     exposure without restrict_api, refused with it, identical with dedup
#  3. reading the other site's file through a symlink or its absolute path,
#     before and after the other site cached it: refused (validate_permission)
#
# usage: docker/loadtest/isolation.sh [series]
set -uo pipefail

series=${1:-8.4}
here=$(cd "$(dirname "$0")" && pwd)
lt="$BUILD/lt"
inst="$BUILD/$series-bench/inst"
out="$BUILD/results/isolation"
A=site001
B=site002
rm -rf "$out"
mkdir -p "$out"

"$here/mariadb.sh" start > /dev/null
while read -r site; do
	id -u "$site" > /dev/null 2>&1 || useradd -M -U -s /usr/sbin/nologin "$site"
done < "$lt/sites.list"

deploy() {
	# deploy <site> <marker>
	local d="$lt/sites/$1/probe"
	mkdir -p "$d"
	cp "$here"/isolation/*.php "$d/"
	sed -i "s/MARKER/$2/" "$d/lib.php"
	ln -sfn "$lt/sites/$([ "$1" = $A ] && echo $B || echo $A)/probe/secret.php" "$d/other.php"
	chown -h "$1:$1" "$d" "$d"/*
	chmod 751 "$d"
	chmod 640 "$d"/*.php
}
edit() {
	# edit <site> <marker> : the site changes its own copy (newer mtime)
	sed -i "s/return '[^']*';/return '$2';/" "$lt/sites/$1/probe/lib.php"
	touch -d '+10 seconds' "$lt/sites/$1/probe/lib.php"
}
get() {
	# get <site> <uri>
	curl -s -w ' [%{http_code}]' "http://127.0.0.1:8080/$1/probe/$2"
	echo
}
status() {
	SCRIPT_FILENAME="$lt/status/status.php" REQUEST_METHOD=GET \
		cgi-fcgi -bind -connect "$lt/run/zstatus.sock" | sed '1,/^\r\{0,1\}$/d' | grep -o '"dedup_hits":[0-9]*'
}

for restrict in off on; do
for dedup in 0 1; do
	name="dedup$dedup-restrict_api-$restrict"
	"$here/stop.sh" > /dev/null
	deploy $A v1
	deploy $B v1
	sed -i "s/^opcache.enable_dedup=.*/opcache.enable_dedup=$dedup/; /^opcache.restrict_api/d; /^opcache.file_update_protection/d" "$lt/php.ini"
	# files are edited and requested within the same second
	sed -i '/^opcache.revalidate_freq/d' "$lt/php.ini"
	printf 'opcache.file_update_protection=0\nopcache.revalidate_freq=0\n' >> "$lt/php.ini"
	# a path no tenant controls (here, the status pool's): only an
	# administrator's scripts may call the API
	[ $restrict = on ] && echo "opcache.restrict_api=$lt/status" >> "$lt/php.ini"
	: > "$lt/logs/php-errors.log"; chmod 666 "$lt/logs/php-errors.log"
	"$inst/sbin/php-fpm" -c "$lt/php.ini" -y "$lt/php-fpm.conf" -R
	nginx -c "$lt/nginx.conf"
	for _ in $(seq 1 50); do [ -S "$lt/run/zstatus.sock" ] && break; sleep 0.2; done
	{
		echo "## 1. shared code, then each site edits its own copy"
		echo "B first:      $(get $B run.php)"
		h0=$(status)
		echo "A (shares):   $(get $A run.php)"
		echo "dedup hits before/after A: $h0 -> $(status)"
		edit $B v2
		echo "B edited v2:  $(get $B run.php)"
		echo "A unchanged:  $(get $A run.php)"
		edit $A v3
		echo "A edited v3:  $(get $A run.php)"
		echo "B unchanged:  $(get $B run.php)"
		echo "## 2. OPcache API from A (restrict_api $restrict)"
		echo "A api:        $(get $A "api.php?other=$lt/sites/$B/probe/lib.php")"
		echo "B after:      $(get $B run.php)"
		echo "dedup hits after A's reset: $(status)"
		echo "## 3. A reads B's secret.php (640 $B)"
		echo "A before B cached it:"
		get $A "viasym.php?path=$lt/sites/$B/probe/secret.php" | sed 's/^/   /'
		echo "B caches it:  $(get $B secret.php | head -c 60)"
		echo "A after B cached it:"
		get $A "viasym.php?path=$lt/sites/$B/probe/secret.php" | sed 's/^/   /'
		echo "## log lines:"
		sed -E 's/^\[[^]]*\] //' "$lt/logs/php-errors.log" | sort | uniq -c | sed 's/^/   /'
	} > "$out/$name.txt" 2>&1
	echo "== $name"
	cat "$out/$name.txt"
done
done
"$here/stop.sh" > /dev/null

echo
echo "== dedup=1 vs dedup=0, dedup counters aside"
fail=0
for restrict in off on; do
	if diff <(sed -E 's/dedup hits.*//; s/dedup=\{[^}]*\}/dedup=X/' "$out/dedup0-restrict_api-$restrict.txt") \
	        <(sed -E 's/dedup hits.*//; s/dedup=\{[^}]*\}/dedup=X/' "$out/dedup1-restrict_api-$restrict.txt") > "$out/diff-$restrict.txt"; then
		echo "restrict_api $restrict: identical"
	else
		echo "restrict_api $restrict: DIFFERENT"; cat "$out/diff-$restrict.txt"; fail=1
	fi
done
grep -q "A unchanged:  v1 $A $A" "$out/dedup1-restrict_api-off.txt" || { echo "❌ A saw B's edit"; fail=1; }
grep -q "B unchanged:  v2 $B $B" "$out/dedup1-restrict_api-off.txt" || { echo "❌ B saw A's edit"; fail=1; }
grep -q "READ" "$out/dedup1-restrict_api-off.txt" && { echo "❌ A read B's file"; fail=1; }
grep -q '"status":"refused","invalidate_other":"refused","reset":"refused"' "$out/dedup1-restrict_api-on.txt" || { echo "❌ API not refused with restrict_api"; fail=1; }
read -r h_before h_after < <(sed -nE 's/.*before.after A: "dedup_hits":([0-9]+) -> "dedup_hits":([0-9]+).*/\1 \2/p' "$out/dedup1-restrict_api-off.txt" | head -1)
[ "${h_after:-0}" -gt "${h_before:-0}" ] || { echo "❌ the identical code was not shared: the check did not exercise sharing"; fail=1; }
# without restrict_api, A's opcache_reset() restarted the cache: the table was cleared with it
r=$(sed -nE "s/.*after A's reset: \"dedup_hits\":([0-9]+).*/\1/p" "$out/dedup1-restrict_api-off.txt" | head -1)
[ "${r:-99}" -lt "${h_after:-0}" ] || { echo "❌ dedup counters not cleared by the restart"; fail=1; }
[ $fail = 0 ] && echo "✅ isolation holds, dedup behaves like native"
exit $fail
