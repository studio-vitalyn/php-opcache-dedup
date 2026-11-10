#!/bin/sh
# Builds one php-src series with the dedup patch applied.
#
# usage: docker/build.sh <series> [debug|release|asan]
#   -> $BUILD/<series>-<flavor>       patched php-src tree (run-tests from here)
#   -> $BUILD/<series>-<flavor>/inst  installed php, php-fpm
set -eu

series=$1
flavor=${2:-debug}
ref=$(awk -v s="$series" '$1 == s { print $2 }' "$REPO/scripts/versions")
[ -n "$ref" ] || { echo "unknown series $series" >&2; exit 1; }

pristine="$BUILD/pristine/$ref"
tree="$BUILD/$series-$flavor"
jobs=$(nproc)

if [ ! -d "$pristine/.git" ]; then
	git -c advice.detachedHead=false clone -q --depth 1 --branch "$ref" https://github.com/php/php-src.git "$pristine"
fi

if [ ! -d "$tree/.git" ]; then
	git clone -q "$pristine" "$tree"
fi

# Re-apply the patch when it changed. Only the files it touches get a new
# mtime, so make only rebuilds opcache. Remove .configured to reconfigure.
stamp="$tree/.dedup-patch.sha"
want=$(sha256sum "$REPO/patches/php-$series.patch" | cut -d' ' -f1)
if [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
	git -C "$tree" reset -q --hard
	git -C "$tree" clean -qfd ext/opcache
	git -C "$tree" apply --whitespace=nowarn "$REPO/patches/php-$series.patch"
	echo "$want" > "$stamp"
fi

cd "$tree"
if [ ! -f .configured ]; then
	opts="--disable-all --enable-fpm --enable-cli --disable-cgi --disable-phpdbg"
	case "$series" in
		8.2|8.3|8.4) opts="$opts --enable-opcache" ;;
	esac
	case "$flavor" in
		debug) opts="$opts --enable-debug" ;;
		# Release build with what WordPress, WooCommerce and wp-cli need
		bench) opts="$opts --enable-mysqlnd --with-mysqli --enable-pdo --with-pdo-mysql --enable-phar \
			--enable-ctype --enable-filter --enable-tokenizer --enable-session --enable-fileinfo \
			--with-libxml --enable-dom --enable-xml --enable-simplexml --enable-xmlreader --enable-xmlwriter \
			--enable-mbstring --with-zlib --with-iconv --with-openssl --enable-exif --enable-bcmath" ;;
		asan) opts="$opts --enable-debug --enable-address-sanitizer" ;;
	esac
	./buildconf --force > /dev/null 2>&1
	./configure -q --prefix="$tree/inst" $opts > configure.log 2>&1
	touch .configured
fi

# Show warnings from opcache only, the rest of old branches is noisy with
# recent compilers
make -s -j"$jobs" > make.log 2>&1 || { tail -50 make.log; exit 1; }
grep -A3 "ext/opcache/.*warning" make.log || true
make -s install > /dev/null 2>&1
"$tree/inst/bin/php" -v | head -1
