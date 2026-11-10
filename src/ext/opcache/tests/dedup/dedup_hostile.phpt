--TEST--
opcache.enable_dedup: pathological code (deep literals, huge functions, full table)
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_update_protection=0
opcache.jit_buffer_size=0
opcache.max_accelerated_files=200
opcache.memory_consumption=256
--FILE--
<?php
require __DIR__ . '/dedup.inc';

/* A constant array nested 200 deep: beyond the serializer's limit, the
 * op_array is simply not shared, and its value is intact. */
$deep = str_repeat('[', 200) . '1' . str_repeat(']', 200);
$paths = dedup_make_sites('dedup_hostile', "<?php\n\$f = __FILE__;\nreturn static fn () => $deep;\n");
$a = include $paths['a'];
$before = dedup_stats();
$b = include $paths['b'];
$after = dedup_stats();
$v = $b();
for ($i = 0; $i < 200; $i++) { $v = $v[0]; }
var_dump($v, $after['hits'] - $before['hits']);

/* 60 000 literals and 60 000 opcodes in one function, twice */
$code = "<?php\nif (!function_exists('big_fn')) {\nfunction big_fn() {\n\$s = 0;\n" . implode("\n", array_map(fn ($i) => "\$s += $i * 3;", range(1, 60000))) . "\nreturn \$s;\n}\n}\nreturn static fn () => big_fn();\n";
$paths = dedup_make_sites('dedup_hostile_big', $code);
var_dump(opcache_compile_file($paths['a']));
$before = dedup_stats();
var_dump(opcache_compile_file($paths['b']));
$after = dedup_stats();
var_dump($after['hits'] - $before['hits'] >= 1);

/* max_accelerated_files=200 gives a 1024-slot table, 768 entries at most:
 * 900 distinct functions fill it, later ones are not registered, nothing
 * else changes */
$code = "<?php\n" . implode("\n", array_map(fn ($i) => "function fill_$i() { return $i; }", range(1, 900))) . "\nreturn fill_900();\n";
$paths = dedup_make_sites('dedup_hostile_fill', $code, ['a']);
var_dump(include $paths['a']);
$s = dedup_stats();
var_dump($s['num_entries'] === $s['max_entries']);
$paths = dedup_make_sites('dedup_hostile_after', "<?php\nreturn static fn () => 'still works';\n", ['a', 'b']);
$a = include $paths['a'];
$b = include $paths['b'];
var_dump($b(), dedup_stats()['num_entries'] === $s['max_entries']);

/* opcache_reset() schedules a restart for the next request: in this one,
 * the table is still full and still consistent. The restart itself is
 * covered by the FPM isolation checks. */
var_dump(opcache_reset());
$paths = dedup_make_sites('dedup_hostile_reset', "<?php\n\$f = __FILE__;\nreturn static fn () => 'after reset';\n", ['a', 'b']);
$a = include $paths['a'];
$b = include $paths['b'];
var_dump($b(), dedup_stats()['num_entries'] === $s['max_entries']);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
foreach (['dedup_hostile', 'dedup_hostile_big', 'dedup_hostile_fill', 'dedup_hostile_after', 'dedup_hostile_reset'] as $d) {
    dedup_remove_sites($d);
}
?>
--EXPECT--
int(1)
int(0)
bool(true)
bool(true)
bool(true)
int(900)
bool(true)
string(11) "still works"
bool(true)
bool(true)
string(11) "after reset"
bool(true)
