<?php
/* Polled by sample.sh through its own FPM pool */
$s = opcache_get_status(false);
echo json_encode([
    'used' => $s['memory_usage']['used_memory'],
    'wasted' => $s['memory_usage']['wasted_memory'],
    'interned' => $s['interned_strings_usage']['used_memory'] ?? 0,
    'scripts' => $s['opcache_statistics']['num_cached_scripts'],
    'hits' => $s['opcache_statistics']['hits'],
    'misses' => $s['opcache_statistics']['misses'],
    'dedup_hits' => $s['dedup']['hits'] ?? 0,
    'dedup_saved' => $s['dedup']['saved_memory'] ?? 0,
]);
