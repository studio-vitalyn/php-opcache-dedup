#!/bin/sh
# Compile-CPU microbenchmark with repetitions, for a confidence interval on
# the dedup overhead. Builds a reproducible synthetic corpus with the fuzzer
# generator (CORPUS distinct programs, each in two identical copies so dedup
# shares), then measures the CPU to opcache_compile_file the whole corpus,
# REPS times, native vs dedup. Closures only, so no redeclare across files.
# usage: REPS=15 CORPUS=400 docker/bench/compile-ci.sh [series]
set -eu
series=${1:-8.4}
reps=${REPS:-15}
corpus=${CORPUS:-400}
php="$BUILD/$series-bench/inst/bin/php"
gen="$REPO/docker/fuzz/gen.php"
work="$BUILD/compile-ci"
"$REPO/docker/build.sh" "$series" bench > /dev/null

rm -rf "$work"; mkdir -p "$work/a" "$work/b"
s=1; while [ "$s" -le "$corpus" ]; do
	"$php" -n "$gen" "$s" > "$work/a/p$s.php" 2>/dev/null
	cp "$work/a/p$s.php" "$work/b/p$s.php"
	s=$((s + 1))
done

cat > "$work/measure.php" <<'PHP'
<?php
[, $dir] = $argv;
$files = array_merge(glob("$dir/a/*.php"), glob("$dir/b/*.php"));
$u = getrusage();
$t0 = ($u['ru_utime.tv_sec'] + $u['ru_stime.tv_sec']) * 1e3 + ($u['ru_utime.tv_usec'] + $u['ru_stime.tv_usec']) / 1e3;
foreach ($files as $f) { @opcache_compile_file($f); }
$u = getrusage();
$t1 = ($u['ru_utime.tv_sec'] + $u['ru_stime.tv_sec']) * 1e3 + ($u['ru_utime.tv_usec'] + $u['ru_stime.tv_usec']) / 1e3;
$s = opcache_get_status(false)['dedup'] ?? null;
printf("%.1f %d\n", $t1 - $t0, $s['hits'] ?? 0);
PHP

common="-n -d zend_extension=opcache -d opcache.enable=1 -d opcache.enable_cli=1 -d opcache.jit=disable -d opcache.file_update_protection=0 -d opcache.validate_timestamps=0 -d opcache.memory_consumption=512 -d opcache.interned_strings_buffer=64 -d opcache.max_accelerated_files=100000 -d memory_limit=-1"

stat() {
	"$php" -r '
		$v = array_values(array_filter(array_map("floatval", explode(" ", trim($argv[1])))));
		$n = count($v); if (!$n) { echo "no data\n"; return; }
		$m = array_sum($v) / $n;
		$sd = $n > 1 ? sqrt(array_sum(array_map(fn($x) => ($x - $m) ** 2, $v)) / ($n - 1)) : 0;
		$ci = 1.96 * $sd / sqrt($n);
		printf("mean=%.0f ms  sd=%.0f ms  95%%CI ±%.0f ms  n=%d  [%.0f..%.0f]\n", $m, $sd, $ci, $n, min($v), max($v));
	' "$1"
}

echo "corpus: $corpus programs x2 copies, $reps reps"
for mode in 0 1; do
	vals=""; hits=0
	r=1; while [ "$r" -le "$reps" ]; do
		out=$("$php" $common -d opcache.enable_dedup=$mode "$work/measure.php" "$work" 2>/dev/null)
		vals="$vals $(echo "$out" | awk '{print $1}')"
		hits=$(echo "$out" | awk '{print $2}')
		r=$((r + 1))
	done
	echo "dedup=$mode (shared=$hits):  $(stat "$vals")"
done
