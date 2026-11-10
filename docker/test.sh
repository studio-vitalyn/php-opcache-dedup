#!/bin/sh
# Runs php-src tests against a debug build of one series.
#
# usage: [FLAVOR=debug|asan] docker/test.sh <series> [dedup|opcache|full]
#   dedup    ext/opcache/tests/dedup (default)
#   opcache  ext/opcache/tests, without then with opcache.enable_dedup=1
#   full     Zend/tests, tests/ and ext/opcache/tests, without then with
#            opcache.enable_dedup=1 (like the CI "opcache" variant)
# Both runs of a comparison use the same patched binary; any test that fails
# only with dedup enabled is reported as a regression.
set -eu

series=$1
suite=${2:-dedup}
flavor=${FLAVOR:-debug}
# ASan needs ASLR off on this host (kernel mmap entropy); personality() is
# inherited, so re-exec the whole run under setarch -R
if [ "$flavor" = asan ] && [ -z "${ASAN_NO_ASLR:-}" ]; then
	ASAN_NO_ASLR=1 exec setarch "$(uname -m)" -R "$0" "$@"
fi
tree="$BUILD/$series-$flavor"
out="$BUILD/results/$series-$flavor"
mkdir -p "$out"

"$REPO/docker/build.sh" "$series" "$flavor"
cd "$tree"

php="$tree/sapi/cli/php"
set -- -q -j"$(nproc)" --show-diff -d opcache.enable=1 -d opcache.enable_cli=1
if [ "$flavor" = asan ]; then
	# Same as the php-src CI ASan job: USE_ZEND_ALLOC=0, leak detection
	set -- "$@" --asan
fi
if [ "${MEMCHECK:-0}" = 1 ]; then
	# Valgrind memcheck (run-tests -m), USE_ZEND_ALLOC=0
	set -- "$@" -m
fi
if [ -f modules/opcache.so ]; then
	# A single opcache.so, also for the --EXTENSIONS-- sections
	set -- "$@" -d extension_dir="$tree/modules" -d zend_extension=opcache
fi

run() {
	name=$1; shift
	TEST_PHP_EXECUTABLE="$php" "$php" run-tests.php "$@" -w "$out/$name.failed" > "$out/$name.log" 2>&1 || true
	grep -E '^Tests (passed|failed|skipped)' "$out/$name.log" | sed "s/^/  $name: /"
}

case "$suite" in
	dedup)
		run dedup "$@" ext/opcache/tests/dedup
		if [ -s "$out/dedup.failed" ]; then
			sed -n '/^FAILED TEST SUMMARY/,$p' "$out/dedup.log"
			exit 1
		fi
		;;
	opcache|full)
		if [ "$suite" = opcache ]; then
			dirs="ext/opcache/tests"
		else
			dirs="Zend/tests tests ext/opcache/tests"
		fi
		run "$suite-off" "$@" -d opcache.protect_memory=1 $dirs
		run "$suite-on" "$@" -d opcache.protect_memory=1 -d opcache.enable_dedup=1 $dirs
		sort -o "$out/$suite-off.failed" "$out/$suite-off.failed"
		sort -o "$out/$suite-on.failed" "$out/$suite-on.failed"
		# dedup_disabled.phpt checks the default value, which -d overrides
		regressions=$(comm -13 "$out/$suite-off.failed" "$out/$suite-on.failed" | grep -v '/dedup_disabled\.phpt$' || true)
		if [ -n "$regressions" ]; then
			echo "Tests failing only with opcache.enable_dedup=1:"
			echo "$regressions"
			exit 1
		fi
		echo "  no regression with opcache.enable_dedup=1"
		;;
	*)
		echo "unknown suite $suite" >&2
		exit 1
		;;
esac
