#!/bin/bash
# Full A/B sequence: warm-up, then <requests> with dedup off and on.
# usage: docker/loadtest/night.sh [requests] [series]
set -uo pipefail
requests=${1:-1000000}
series=${2:-8.4}
here=$(cd "$(dirname "$0")" && pwd)
out="$BUILD/results/loadtest"
mkdir -p "$out"
rm -f "$out/night.done"
{
	if [ "${SKIP_WARMUP:-0}" != 1 ]; then
		echo "== warmup $(date)"
		"$here/run.sh" 1 30000 warmup "$series"
	fi
	echo "== dedup=0 $(date)"
	"$here/run.sh" 0 "$requests" off "$series"
	echo "== dedup=1 $(date)"
	"$here/run.sh" 1 "$requests" on "$series"
	echo "== aggregate $(date)"
	"$BUILD/$series-bench/inst/bin/php" "$here/aggregate.php" "$out" off on > "$out/data.json"
	echo "== done $(date)"
} > "$out/night.log" 2>&1
touch "$out/night.done"
