#!/bin/bash
# Starts (or stops) the MariaDB server used by the load test. Data lives in
# the build volume so the databases survive container restarts.
set -euo pipefail

datadir="$BUILD/mysql"
case "${1:-start}" in
	start)
		if mariadb -e 'SELECT 1' > /dev/null 2>&1; then
			exit 0
		fi
		if [ ! -d "$datadir/mysql" ]; then
			mkdir -p "$datadir"
			chown mysql:mysql "$datadir"
			mariadb-install-db --user=mysql --datadir="$datadir" > /dev/null
		fi
		mkdir -p /run/mysqld
		chown mysql:mysql /run/mysqld
		mariadbd-safe --user=mysql --datadir="$datadir" --skip-networking \
			--innodb-buffer-pool-size=1G --max-connections=500 \
			--innodb-flush-log-at-trx-commit=2 --log-error="$BUILD/lt/logs/mariadb.log" > /dev/null 2>&1 &
		for _ in $(seq 1 60); do
			if mariadb -e 'SELECT 1' > /dev/null 2>&1; then
				# Sites connect as their own Unix user, so not through unix_socket auth
				mariadb -e "CREATE USER IF NOT EXISTS 'wp'@'localhost' IDENTIFIED BY 'wp-bench'; GRANT ALL ON *.* TO 'wp'@'localhost'"
				exit 0
			fi
			sleep 1
		done
		echo "MariaDB did not start" >&2
		exit 1
		;;
	stop)
		mariadb-admin shutdown || true
		;;
esac
