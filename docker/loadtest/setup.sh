#!/bin/bash
# Prepares the load test: a PHP build with the extensions WordPress needs,
# MariaDB, and N fully installed WordPress sites (WooCommerce, Yoast SEO,
# Contact Form 7 and Elementor active), one Unix user and one database each.
#
# usage: docker/loadtest/setup.sh [series] [sites] [identical_percent]
set -euo pipefail

series=${1:-8.4}
sites=${2:-80}
identical=${3:-80}
here=$(cd "$(dirname "$0")" && pwd)
lt="$BUILD/lt"
dl="$BUILD/downloads"
php="$BUILD/$series-bench/inst/bin/php"
mkdir -p "$lt"/{sites,run,logs,tpl,status}

"$REPO/docker/build.sh" "$series" bench

# Stacks (shared with the compile benchmark)
SITES_ONLY_DOWNLOAD=1 "$REPO/docker/bench/sites.sh" 0 0

"$here/mariadb.sh" start

if [ ! -s "$lt/wp-cli.phar" ]; then
	curl -fsSL -o "$lt/wp-cli.phar" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
fi
wp() {
	"$php" -d memory_limit=1G -d error_reporting=0 "$lt/wp-cli.phar" --allow-root "$@"
}

# One installed template per stack, cloned into every site of that stack.
# Site URLs all have the same length (http://127.0.0.1:8080/siteNNN), so the
# database dump can be rewritten with sed without breaking serialized data.
template() {
	local stack=$1 dir="$lt/tpl/$1" db="tpl_$1"
	[ -s "$lt/tpl/$stack.sql" ] && return
	rm -rf "$dir"
	cp -a "$dl/stack-$stack" "$dir"
	mariadb -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db"
	sed -e "s/SITE_DB/$db/" "$here/wp-config.php" > "$dir/wp-config.php"
	wp --path="$dir" core install --url="http://127.0.0.1:8080/site000" --title="Bench shop" \
		--admin_user=admin --admin_password=admin-bench-pw --admin_email=admin@example.com --skip-email
	wp --path="$dir" rewrite structure '/%postname%/'
	wp --path="$dir" plugin activate woocommerce wordpress-seo contact-form-7 elementor
	wp --path="$dir" option update woocommerce_coming_soon no || true
	wp --path="$dir" option update blog_public 1
	wp --path="$dir" eval-file "$here/content.php"
	# wp-cli derives some URLs from the template path
	wp --path="$dir" search-replace "http://127.0.0.1:8080/tpl/$stack" "http://127.0.0.1:8080/site000" --all-tables --quiet
	wp --path="$dir" option update home "http://127.0.0.1:8080/site000"
	wp --path="$dir" option update siteurl "http://127.0.0.1:8080/site000"
	mariadb-dump "$db" > "$lt/tpl/$stack.sql"
}
template current
template previous

same=$((sites * identical / 100))
: > "$lt/sites.list"
for i in $(seq 1 "$sites"); do
	site=$(printf 'site%03d' "$i")
	echo "$site" >> "$lt/sites.list"
	dir="$lt/sites/$site"
	if [ "$i" -le "$same" ]; then stack=current; else stack=previous; fi
	if [ ! "$dir/.ready-db" -nt "$lt/tpl/$stack.sql" ] && [ -f "$dir/.ready" ]; then
		mariadb -e "DROP DATABASE IF EXISTS $site; CREATE DATABASE $site"
		sed "s/site000/$site/g" "$lt/tpl/$stack.sql" | mariadb "$site"
		touch "$dir/.ready-db"
	fi
	[ -f "$dir/.ready" ] && continue

	id -u "$site" > /dev/null 2>&1 || useradd -M -U -s /usr/sbin/nologin "$site"
	rm -rf "$dir"
	# PHP files are real per-site copies owned by the site user, as on a
	# shared host. Other files are hard links to save disk space.
	rsync -a --exclude='*.php' --exclude=wp-config.php --link-dest="$dl/stack-$stack/" "$dl/stack-$stack/" "$dir/"
	rsync -a --include='*/' --include='*.php' --exclude='*' --exclude=wp-config.php "$dl/stack-$stack/" "$dir/"
	sed -e "s/SITE_DB/$site/" "$here/wp-config.php" > "$dir/wp-config.php"
	mkdir -p "$dir/wp-content/uploads"
	find "$dir" -type d -exec chown "$site:$site" {} + -exec chmod 751 {} +
	find "$dir" -name '*.php' -exec chown "$site:$site" {} + -exec chmod 640 {} +
	chown -R "$site:$site" "$dir/wp-content/uploads"

	mariadb -e "DROP DATABASE IF EXISTS $site; CREATE DATABASE $site"
	sed "s/site000/$site/g" "$lt/tpl/$stack.sql" | mariadb "$site"
	touch "$dir/.ready" "$dir/.ready-db"
done

cp "$here/status.php" "$lt/status/status.php"
chown -R www-data "$lt/status"

# Request mix, shuffled over all sites
"$php" "$here/uris.php" "$lt/sites.list" 20000 > "$lt/uris.txt"

echo "ready: $sites sites in $lt/sites"
