<?php
$status = opcache_get_status(false);
echo json_encode([
    'memory_usage' => $status['memory_usage'],
    'interned_strings_usage' => $status['interned_strings_usage'] ?? null,
    'statistics' => $status['opcache_statistics'],
    'dedup' => $status['dedup'] ?? null,
]), "\n";
