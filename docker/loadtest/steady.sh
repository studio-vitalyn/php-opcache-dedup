#!/bin/bash
# Below-saturation A/B: same sites and request mix as night.sh, 8 connections
# instead of 32, so that latencies are not dominated by queueing. The first
# minutes of each run are the cold start (empty OPcache), measured again here
# with the final patch.
# usage: docker/loadtest/steady.sh [requests] [series]
set -uo pipefail
requests=${1:-60000}
series=${2:-8.4}
here=$(cd "$(dirname "$0")" && pwd)
out="$BUILD/results/loadtest"
rm -f "$out/steady.done"
{
	echo "== dedup=0 $(date)"
	CONCURRENCY=8 "$here/run.sh" 0 "$requests" steady-off "$series"
	echo "== dedup=1 $(date)"
	CONCURRENCY=8 "$here/run.sh" 1 "$requests" steady-on "$series"
	"$BUILD/$series-bench/inst/bin/php" "$here/aggregate.php" "$out" steady-off steady-on > "$out/data-steady.json"
	echo "== done $(date)"
} > "$out/steady.log" 2>&1
touch "$out/steady.done"
