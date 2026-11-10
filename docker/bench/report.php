<?php
/* Builds the Markdown A/B report from the files written by run.sh. */
[, $dir, $series, $sites, $identical] = $argv;

function load(string $dir, int $dedup): array
{
    $status = json_decode(file_get_contents("$dir/status-$dedup.json"), true);
    $warm = array_map(
        fn ($line) => json_decode($line, true),
        file("$dir/warm-$dedup.jsonl", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES)
    );
    [$start, $end] = explode(' ', trim(file_get_contents("$dir/wall-$dedup.txt")));
    return [
        'used' => $status['memory_usage']['used_memory'],
        'interned' => $status['interned_strings_usage']['used_memory'] ?? 0,
        'scripts' => $status['statistics']['num_cached_scripts'],
        'dedup' => $status['dedup'],
        'compiled' => array_sum(array_column($warm, 'compiled')),
        'failed' => array_sum(array_column($warm, 'failed')),
        'cpu_ms' => array_sum(array_column($warm, 'cpu_ms')),
        'wall_s' => (float) $end - (float) $start,
        'smoke' => file("$dir/smoke-$dedup.txt", FILE_IGNORE_NEW_LINES),
        'errors' => (int) trim(file_get_contents("$dir/errors-$dedup.txt")),
        'oom' => (int) trim(@file_get_contents("$dir/oom-$dedup.txt")),
        'sites' => count($warm),
    ];
}

$off = load($dir, 0);
$on = load($dir, 1);
$mb = fn (int $bytes) => number_format($bytes / 1048576, 1, '.', ' ');
$pct = fn (float $a, float $b) => $a ? sprintf('%+.1f%%', ($b - $a) / $a * 100) : 'n/a';

echo "## OPcache dedup A/B — PHP $series, $sites sites ($identical% identical stack)\n\n";
echo "| | dedup=0 | dedup=1 | delta |\n|---|---:|---:|---:|\n";
printf("| SHM used (MB) | %s | %s | %s |\n", $mb($off['used']), $mb($on['used']), $pct($off['used'], $on['used']));
printf("| of which interned strings (MB) | %s | %s | |\n", $mb($off['interned']), $mb($on['interned']));
printf("| per site (MB) | %s | %s | |\n", $mb(intdiv($off['used'], $off['sites'])), $mb(intdiv($on['used'], $on['sites'])));
printf("| cached scripts | %d | %d | |\n", $off['scripts'], $on['scripts']);
printf("| compile CPU, all pools (s) | %.2f | %.2f | %s |\n", $off['cpu_ms'] / 1000, $on['cpu_ms'] / 1000, $pct($off['cpu_ms'], $on['cpu_ms']));
printf("| warm-up wall time (s) | %.2f | %.2f | %s |\n", $off['wall_s'], $on['wall_s'], $pct($off['wall_s'], $on['wall_s']));
printf("| files compiled / failed | %d / %d | %d / %d | |\n", $off['compiled'], $off['failed'], $on['compiled'], $on['failed']);
printf("| opcache errors in log | %d | %d | |\n", $off['errors'], $on['errors']);
printf("| SHM full / restart messages | %d | %d | |\n", $off['oom'], $on['oom']);
if (!empty($on['dedup']['enabled'])) {
    $d = $on['dedup'];
    printf("\ndedup: %d hits, %d misses (%.1f%% shared), %s MB saved in opcodes+literals, %d / %d table entries\n",
        $d['hits'], $d['misses'], $d['hits'] / max(1, $d['hits'] + $d['misses']) * 100,
        $mb($d['saved_memory']), $d['num_entries'], $d['max_entries']);
}
$same = $off['smoke'] === $on['smoke'];
echo "\nsmoke test (WordPress formatting API on every site): ", $same ? 'identical output' : 'OUTPUT DIFFERS', "\n";
exit($same && !$on['errors'] ? 0 : 1);
