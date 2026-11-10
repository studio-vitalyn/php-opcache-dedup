<?php
/* Compiles every PHP file of this site into OPcache, as the site's user. */
$start = hrtime(true);
$compiled = $failed = 0;
$files = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator(__DIR__, FilesystemIterator::SKIP_DOTS)
);
foreach ($files as $file) {
    if ($file->getExtension() !== 'php') {
        continue;
    }
    try {
        @opcache_compile_file($file->getPathname()) ? $compiled++ : $failed++;
    } catch (Throwable $e) {
        $failed++;
    }
}
$usage = getrusage();
echo json_encode([
    'site' => basename(__DIR__),
    'compiled' => $compiled,
    'failed' => $failed,
    'ms' => (hrtime(true) - $start) / 1e6,
    'cpu_ms' => ($usage['ru_utime.tv_sec'] + $usage['ru_stime.tv_sec']) * 1000
        + ($usage['ru_utime.tv_usec'] + $usage['ru_stime.tv_usec']) / 1000,
]), "\n";
