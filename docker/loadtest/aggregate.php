<?php
/* Aggregates the load test runs into one JSON document for the report.
 *
 * usage: php aggregate.php <results/loadtest> <label>... > data.json */
ini_set('memory_limit', '-1');
[, $dir] = $argv;
$labels = array_slice($argv, 2);
const BIN = 30; /* seconds, for both latency and resource series */
const TICKS = 100; /* USER_HZ */

function percentile(array $sorted, float $p): float
{
    if (!$sorted) {
        return 0.0;
    }
    $index = (count($sorted) - 1) * $p;
    $lo = (int) floor($index);
    $hi = (int) ceil($index);
    return $sorted[$lo] + ($sorted[$hi] - $sorted[$lo]) * ($index - $lo);
}

$data = [];
foreach ($labels as $label) {
    $run = json_decode(file_get_contents("$dir/$label/run.json"), true);
    $opcache = json_decode(file_get_contents("$dir/$label/opcache.json"), true);

    /* Requests: start (us since epoch), status, duration (us) */
    $fh = fopen("$dir/$label/requests.tsv", 'r');
    $t0 = null;
    $bins = [];
    $all = [];
    $statuses = [];
    while (($line = fgets($fh)) !== false) {
        [$start, $status, $duration] = explode("\t", rtrim($line));
        $t0 ??= (int) $start;
        $bin = intdiv((int) $start - $t0, BIN * 1000000);
        $ms = (int) $duration / 1000;
        $bins[$bin][] = $ms;
        $all[] = $ms;
        $statuses[$status] = ($statuses[$status] ?? 0) + 1;
    }
    fclose($fh);
    sort($all);
    $series = [];
    ksort($bins);
    foreach ($bins as $bin => $values) {
        sort($values);
        $series[] = [
            't' => $bin * BIN,
            'rps' => round(count($values) / BIN, 1),
            'p50' => round(percentile($values, 0.50), 2),
            'p95' => round(percentile($values, 0.95), 2),
            'p99' => round(percentile($values, 0.99), 2),
        ];
    }
    $wall = $run['end'] - $run['start'];

    /* Sampler: CPU ticks are cumulative, memory is instantaneous */
    $rows = array_map(fn ($line) => str_getcsv($line, ',', '"', ''), file("$dir/$label/metrics.csv", FILE_IGNORE_NEW_LINES));
    $header = array_shift($rows);
    $rows = array_map(fn ($r) => array_combine($header, $r), $rows);
    $metrics = [];
    $shm = null;
    $peakPss = 0;
    $window = [];
    $t0m = (float) $rows[0]['t'];
    $flush = function () use (&$window, &$metrics, &$shm, $t0m) {
        if (count($window) < 2) {
            return;
        }
        $a = $window[0];
        $b = end($window);
        $dt = $b['t'] - $a['t'];
        $avg = fn ($k) => array_sum(array_column($window, $k)) / count($window);
        $metrics[] = [
            't' => round($b['t'] - $t0m),
            'fpm_cores' => round(max(0, $b['fpm_ticks'] - $a['fpm_ticks']) / TICKS / $dt, 2),
            'db_cores' => round(max(0, $b['db_ticks'] - $a['db_ticks']) / TICKS / $dt, 2),
            'pss_mb' => round($avg('fpm_pss_kb') / 1024),
            'rss_mb' => round($avg('fpm_rss_kb') / 1024),
            'workers' => round($avg('workers'), 1),
            'shm_mb' => $shm ? round($shm['shm_used'] / 1048576) : null,
            'scripts' => $shm ? (int) $shm['scripts'] : null,
            'dedup_saved_mb' => $shm ? round($shm['dedup_saved'] / 1048576) : null,
        ];
        $window = [end($window)];
    };
    foreach ($rows as $row) {
        if ($row['shm_used'] !== '') {
            $shm = $row;
        }
        $peakPss = max($peakPss, (int) $row['fpm_pss_kb']);
        $window[] = $row;
        if ($row['t'] - $window[0]['t'] >= BIN) {
            $flush();
        }
    }
    $flush();
    $first = $rows[0];
    $last = end($rows);
    $fpmCpu = ($last['fpm_ticks'] - $first['fpm_ticks']) / TICKS;

    $data[$label] = [
        'run' => $run,
        'summary' => [
            'requests' => count($all),
            'wall_s' => round($wall, 1),
            'rps' => round(count($all) / $wall, 1),
            'p50_ms' => round(percentile($all, 0.50), 2),
            'p90_ms' => round(percentile($all, 0.90), 2),
            'p95_ms' => round(percentile($all, 0.95), 2),
            'p99_ms' => round(percentile($all, 0.99), 2),
            'p999_ms' => round(percentile($all, 0.999), 2),
            'mean_ms' => round(array_sum($all) / max(1, count($all)), 2),
            'statuses' => $statuses,
            'fpm_cpu_s' => round($fpmCpu, 1),
            'fpm_cpu_ms_per_req' => round($fpmCpu * 1000 / max(1, count($all)), 3),
            'peak_pss_mb' => round($peakPss / 1024),
            'shm_used_mb' => round($opcache['used'] / 1048576, 1),
            'shm_interned_mb' => round($opcache['interned'] / 1048576, 1),
            'scripts' => $opcache['scripts'],
            'dedup_hits' => $opcache['dedup_hits'],
            'dedup_saved_mb' => round($opcache['dedup_saved'] / 1048576, 1),
        ],
        'latency' => $series,
        'metrics' => $metrics,
    ];
}
echo json_encode($data, JSON_PRETTY_PRINT), "\n";
