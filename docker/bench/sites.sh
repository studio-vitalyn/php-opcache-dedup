#!/bin/sh
# Creates <sites> WordPress sites under $BUILD/bench/sites, one Unix user each.
# <identical_percent> of them run the same stack, the others an older one,
# mimicking a shared host where most sites are up to date.
set -eu

sites=$1
identical=$2
here=$(cd "$(dirname "$0")" && pwd)
root="$BUILD/bench"
dl="$BUILD/downloads"
mkdir -p "$dl" "$root/sites"

fetch() {
	[ -s "$dl/$2" ] || curl -fsSL -o "$dl/$2" "$1"
}

# stack <name> <wordpress version|latest> <plugin.version>...
stack() {
	name=$1 wp=$2
	shift 2
	dir="$dl/stack-$name"
	[ -d "$dir" ] && return
	if [ "$wp" = latest ]; then url=https://wordpress.org/latest.tar.gz; else url=https://wordpress.org/wordpress-$wp.tar.gz; fi
	fetch "$url" "wordpress-$wp.tar.gz"
	rm -rf "$dir.tmp"
	mkdir -p "$dir.tmp"
	tar -xzf "$dl/wordpress-$wp.tar.gz" -C "$dir.tmp"
	for plugin in "$@"; do
		fetch "https://downloads.wordpress.org/plugin/$plugin.zip" "$plugin.zip"
		unzip -qo "$dl/$plugin.zip" -d "$dir.tmp/wordpress/wp-content/plugins"
	done
	mv "$dir.tmp/wordpress" "$dir"
	rm -rf "$dir.tmp"
}

stack current latest \
	woocommerce.latest-stable wordpress-seo.latest-stable contact-form-7.latest-stable elementor.latest-stable
stack previous 6.5.5 \
	woocommerce.9.0.0 wordpress-seo.22.0 contact-form-7.5.9 elementor.3.20.0

# The load test only needs the stacks
[ "${SITES_ONLY_DOWNLOAD:-0}" = 1 ] && exit 0

count=$(seq 1 "$sites" | wc -l)
same=$((count * identical / 100))
: > "$root/sites.list.tmp"
for i in $(seq 1 "$sites"); do
	site=$(printf 'site%03d' "$i")
	echo "$site" >> "$root/sites.list.tmp"
	id -u "$site" > /dev/null 2>&1 || useradd -M -U -s /usr/sbin/nologin "$site"
	dir="$root/sites/$site"
	[ -f "$dir/.ready" ] && continue
	if [ "$i" -le "$same" ]; then src=current; else src=previous; fi
	rm -rf "$dir"
	# Only PHP files matter for OPcache; skip assets to save disk
	rsync -a --prune-empty-dirs --include='*/' --include='*.php' --exclude='*' \
		"$dl/stack-$src/" "$dir/"
	sed "s/SITE_NAME/$site/" "$here/wp-config.php" > "$dir/wp-config.php"
	cp "$here/__warm.php" "$here/__smoke.php" "$here/__status.php" "$dir/"
	chown -R "$site:$site" "$dir"
	chmod -R u=rwX,g=rX,o= "$dir"
	touch "$dir/.ready"
done
mv "$root/sites.list.tmp" "$root/sites.list"
