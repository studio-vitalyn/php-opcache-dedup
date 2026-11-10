--TEST--
opcache.enable_dedup: identical files at different paths share their opcodes
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_update_protection=0
opcache.jit_buffer_size=0
--FILE--
<?php
require __DIR__ . '/dedup.inc';

$paths = dedup_make_sites('dedup_basic', <<<'PHP'
<?php
/* Declared at runtime, so that both copies can be compiled in one process */
if (!function_exists('dedup_basic_sum')) {
    function dedup_basic_sum(array $values): int
    {
        $sum = 0;
        foreach ($values as $value) {
            $sum += $value;
        }
        return $sum;
    }
}
PHP);

var_dump(dedup_stats()['enabled']);
var_dump(opcache_compile_file($paths['a']));
$before = dedup_stats();
var_dump(opcache_compile_file($paths['b']));
$after = dedup_stats();

/* The function is shared. The main script is too, except on PHP 8.0 where
 * it holds the path-dependent runtime definition key of the function. */
var_dump($after['hits'] - $before['hits'] >= 1);
var_dump($after['hits'] + $after['misses'] - $before['hits'] - $before['misses']);
var_dump($after['saved_memory'] > $before['saved_memory']);
var_dump(opcache_is_script_cached($paths['a']), opcache_is_script_cached($paths['b']));

include $paths['b'];
var_dump(dedup_basic_sum([1, 2, 3]));
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_basic');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
int(2)
bool(true)
bool(true)
bool(true)
int(6)
