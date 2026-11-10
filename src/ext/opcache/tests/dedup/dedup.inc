<?php

/* Writes $code to <tests/dedup>/<$name>/<$site>/<$file> for each site and
 * returns the absolute paths, keyed by site. */
function dedup_make_sites(string $name, string $code, array $sites = ['a', 'b'], string $file = 'lib.php'): array
{
    $paths = [];
    foreach ($sites as $site) {
        $dir = __DIR__ . "/$name/$site";
        if (!is_dir($dir)) {
            mkdir($dir, 0777, true);
        }
        file_put_contents("$dir/$file", $code);
        $paths[$site] = "$dir/$file";
    }
    return $paths;
}

function dedup_remove_sites(string $name): void
{
    $base = __DIR__ . "/$name";
    if (!is_dir($base)) {
        return;
    }
    $it = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($it as $entry) {
        $entry->isDir() ? rmdir($entry->getPathname()) : unlink($entry->getPathname());
    }
    rmdir($base);
}

function dedup_stats(): array
{
    return opcache_get_status(false)['dedup'];
}
