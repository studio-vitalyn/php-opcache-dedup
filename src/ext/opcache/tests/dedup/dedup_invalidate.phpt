--TEST--
opcache.enable_dedup: unchanged functions are shared again after a file is updated
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_update_protection=0
opcache.jit_buffer_size=0
opcache.validate_timestamps=1
opcache.revalidate_freq=0
--FILE--
<?php
require __DIR__ . '/dedup.inc';

$v1 = <<<'PHP'
<?php
return [
    'greet' => static fn (string $name): string => "Hello, $name!",
    'version' => static fn (): int => 1,
];
PHP;
$v2 = str_replace('=> 1,', '=> 2,', $v1);

$paths = dedup_make_sites('dedup_invalidate', $v1, ['a']);
$lib = include $paths['a'];
echo $lib['greet']('a'), ' v', $lib['version'](), "\n";

file_put_contents($paths['a'], $v2);
touch($paths['a'], time() + 10);
clearstatcache();
var_dump(opcache_invalidate($paths['a'], true));

$before = dedup_stats();
$lib = include $paths['a'];
$after = dedup_stats();
echo $lib['greet']('a'), ' v', $lib['version'](), "\n";
/* "greet" is unchanged and shared with the stale copy */
var_dump($after['hits'] > $before['hits']);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_invalidate');
?>
--EXPECT--
Hello, a! v1
bool(true)
Hello, a! v2
bool(true)
