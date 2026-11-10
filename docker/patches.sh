#!/bin/sh
# Regenerates patches/*.patch inside the container from pristine clones kept
# in the build volume.
set -eu

grep -v '^#' "$REPO/scripts/versions" | while read -r series ref; do
	[ -d "$BUILD/pristine/$ref/.git" ] ||
		git clone -q --depth 1 --branch "$ref" https://github.com/php/php-src.git "$BUILD/pristine/$ref"
done
git config --global --add safe.directory '*'
"$REPO/scripts/gen-patches.sh" "$BUILD/pristine"
