<?php
/* Compiles every PHP file of the given sites in this process and prints the
 * CPU time spent, in ms. */
$files = [];
foreach (array_slice($argv, 1) as $dir) {
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)) as $f) {
        if ($f->getExtension() === 'php') $files[] = $f->getPathname();
    }
}
$cpu = fn () => (fn ($u) => ($u['ru_utime.tv_sec'] + $u['ru_stime.tv_sec']) * 1e3 + ($u['ru_utime.tv_usec'] + $u['ru_stime.tv_usec']) / 1e3)(getrusage());
$t = $cpu();
foreach ($files as $f) { try { @opcache_compile_file($f); } catch (Throwable $e) {} }
$s = opcache_get_status(false);
printf("%.0f %.1f %d\n", $cpu() - $t, $s['memory_usage']['used_memory'] / 1048576, $s['dedup']['hits'] ?? 0);
