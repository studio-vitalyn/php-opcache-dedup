#!/bin/sh
# Differential fuzzing of the dedup patch. For each seed, gen.php emits a
# deterministic PHP program (functions built from random operators, control
# flow, literals, calls; every call captured so a thrown Error becomes a
# value, never a crash). The program is written byte-identical to sites a and
# b. One process per seed then:
#   opcache_compile_file(a); opcache_compile_file(b)  -> b shares a's blocks
#   include(b)                                        -> runs from those opcodes
# run with dedup=0 (reference) and dedup=1. The result hash must match, and
# dedup=1 must actually have shared something. A mismatch, a crash, or an ASan
# error is a finding in $out/findings/.
#
# usage: ITERATIONS=5000 [SEED_BASE=1] docker/fuzz/run.sh [series]
set -u

series=${1:-8.4}
iterations=${ITERATIONS:-2000}
here=$(cd "$(dirname "$0")" && pwd)
php="$BUILD/$series-bench/inst/bin/php"
asan="$BUILD/$series-asan/sapi/cli/php"
work="$BUILD/fuzz"
out="$BUILD/results/fuzz"
rm -rf "$work" "$out"
mkdir -p "$work/sites" "$out/findings"

"$REPO/docker/build.sh" "$series" bench > /dev/null
[ "${RUNNER:-bench}" = asan ] && "$REPO/docker/build.sh" "$series" asan > /dev/null

# RUNNER=asan uses the AddressSanitizer build (catches heap/stack corruption
# in the serializer, decisions and buffers; not inside the SHM, see
# SECURITY.md). Default is the fast bench build.
if [ "${RUNNER:-bench}" = asan ]; then
	[ -x "$asan" ] || { echo "no ASan build at $asan; build it with FLAVOR=asan" >&2; exit 2; }
	runner="$asan"; setarch="setarch $(uname -m) -R"
	extdir="-d extension_dir=$BUILD/$series-asan/modules -d zend_extension=opcache"
	label=asan
else
	runner="$php"; setarch=""
	extdir="-d zend_extension=opcache"
	label=bench
fi
common="$extdir -n -d opcache.enable=1 -d opcache.enable_cli=1 -d opcache.jit=disable -d opcache.file_update_protection=0 -d opcache.validate_timestamps=0 -d opcache.memory_consumption=256 -d opcache.interned_strings_buffer=32 -d opcache.max_accelerated_files=4000 -d memory_limit=256M -d error_reporting=0 -d display_errors=0"

cat > "$work/driver.php" <<'PHP'
<?php
[, $dir] = $argv;
opcache_compile_file("$dir/a/prog.php");
$before = opcache_get_status(false)['dedup']['hits'] ?? 0;
opcache_compile_file("$dir/b/prog.php");
$after = opcache_get_status(false)['dedup']['hits'] ?? 0;
$r = include "$dir/b/prog.php";
echo json_encode(['hash' => md5(serialize($r)), 'shared' => $after - $before]), "\n";
PHP

found=0; tested=0; i=0
while [ "$i" -lt "$iterations" ]; do
	i=$((i + 1))
	seed=$((i + ${SEED_BASE:-1}))
	d="$work/sites/s$seed"
	rm -rf "$d"; mkdir -p "$d/a" "$d/b"
	"$php" -n "$here/gen.php" "$seed" > "$d/a/prog.php" 2>/dev/null
	cp "$d/a/prog.php" "$d/b/prog.php"

	off=$($setarch $runner $common -d opcache.enable_dedup=0 "$work/driver.php" "$d" 2>"$d/off.err")
	on=$($setarch $runner $common -d opcache.enable_dedup=1 "$work/driver.php" "$d" 2>"$d/on.err")

	shared=$(echo "$on" | sed -nE 's/.*"shared":([0-9]+).*/\1/p')
	# nothing shareable this seed -> did not exercise the patch, skip
	[ "${shared:-0}" -gt 0 ] || { rm -rf "$d"; continue; }
	tested=$((tested + 1))

	ok=1
	[ -n "$off" ] && [ -n "$on" ] || ok=0
	[ "$(echo "$off" | sed 's/,"shared":[0-9]*//')" = "$(echo "$on" | sed 's/,"shared":[0-9]*//')" ] || ok=0
	grep -qiE 'sanitizer|runtime error|segmentation fault|assertion' "$d/off.err" "$d/on.err" 2>/dev/null && ok=0

	if [ "$ok" -ne 1 ]; then
		found=$((found + 1))
		cp "$d/a/prog.php" "$out/findings/seed-$seed-prog.php"
		{ echo "seed=$seed"; echo "off=$off"; echo "on=$on"; echo "--- off.err"; cat "$d/off.err"; echo "--- on.err"; cat "$d/on.err"; } > "$out/findings/seed-$seed.txt"
		echo "FINDING seed=$seed"
	fi
	rm -rf "$d"
	[ $((i % 500)) -eq 0 ] && echo "  $i/$iterations, shared-exercised=$tested, findings=$found"
done
echo "done: $iterations iterations, $tested exercised sharing, $found findings (runner=$label)"
[ "$found" -eq 0 ]
