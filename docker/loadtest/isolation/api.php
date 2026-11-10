<?php
/* What the OPcache API lets this site do to the others */
$r = [];
$status = @opcache_get_status(false);
$r['status'] = is_array($status) ? ('ok dedup=' . json_encode($status['dedup'] ?? null)) : 'refused';
$r['invalidate_other'] = @opcache_invalidate($_GET['other'], true) ? 'ok' : 'refused';
$r['reset'] = @opcache_reset() ? 'ok' : 'refused';
echo json_encode($r), "\n";
