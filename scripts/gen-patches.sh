#!/bin/sh
# Regenerates patches/php-<series>.patch from src/ and scripts/hooks.pl.
#
# usage: scripts/gen-patches.sh <dir containing one pristine php-src clone per
#        series, named after its ref, e.g. php-8.4.26/ and master/>
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
trees=$1

grep -v '^#' "$repo/scripts/versions" | while read -r series ref; do
	tree="$trees/$ref"
	[ -d "$tree/.git" ] || { echo "missing $tree" >&2; exit 1; }

	git -C "$tree" reset -q --hard
	git -C "$tree" clean -qfdx ext/opcache
	base=$(git -C "$tree" rev-parse HEAD)

	perl "$repo/scripts/hooks.pl" "$tree"
	cp -R "$repo/src/ext/opcache/." "$tree/ext/opcache/"


	git -C "$tree" add -A
	git -C "$tree" -c user.name="${GIT_AUTHOR_NAME:-$(git config user.name)}" \
		-c user.email="${GIT_AUTHOR_EMAIL:-$(git config user.email)}" \
		commit -q -F "$repo/scripts/commit-message.txt"
	git -C "$tree" format-patch -1 --stdout --no-signature > "$repo/patches/php-$series.patch"
	git -C "$tree" reset -q --hard "$base"
	git -C "$tree" clean -qfdx ext/opcache
	echo "patches/php-$series.patch ($ref)"
done
