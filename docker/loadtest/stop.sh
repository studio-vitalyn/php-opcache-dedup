#!/bin/bash
# Stops any load test in progress and everything it started.
lt="$BUILD/lt"
pkill -f 'loadtest/night\.sh'
pkill -f 'loadtest/run\.sh'
pkill -f 'loadtest/sample\.sh'
pkill -x h2load
pkill -QUIT -f 'php-fpm: master'
[ -f "$lt/run/nginx.pid" ] && kill "$(cat "$lt/run/nginx.pid")" 2>/dev/null
for _ in $(seq 1 30); do
	pgrep -f 'php-fpm: ' > /dev/null || break
	sleep 1
done
pkill -9 -f 'php-fpm: '
pkill -9 -x nginx
rm -f "$lt"/run/*.sock "$lt"/run/*.pid
echo "fpm=$(pgrep -fc 'php-fpm: ') nginx=$(pgrep -xc nginx) h2load=$(pgrep -xc h2load) runs=$(pgrep -fc 'loadtest/run\.sh')"
