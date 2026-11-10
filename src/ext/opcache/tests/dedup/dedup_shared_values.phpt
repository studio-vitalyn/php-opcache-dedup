--TEST--
opcache.enable_dedup: array literals shared by several op_arrays of a script
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

/* The optimizer substitutes self::MAP into the methods, so the same nested
 * arrays end up in the literals of several op_arrays and in the constant
 * table. The first of them to be persisted moves them to SHM; the others,
 * shared or not, must follow the xlat table instead of the freed copy. */
$paths = dedup_make_sites('dedup_shared_values', <<<'PHP'
<?php
namespace DedupSharedValues;

if (!class_exists(Registry::class, false)) {
    final class Registry
    {
        public const MAP = ['colors' => ['red' => 1, 'green' => 2], 'sizes' => ['s', 'm', 'l']];

        public function all(): array
        {
            return self::MAP;
        }

        public function colors(): array
        {
            return self::MAP['colors'];
        }

        public function sizes(): array
        {
            return self::MAP['sizes'];
        }

        public function nested(): array
        {
            return ['map' => self::MAP, 'colors' => self::MAP['colors']];
        }
    }
}
PHP, ['a', 'b', 'c']);

$before = dedup_stats();
foreach ($paths as $path) {
    var_dump(opcache_compile_file($path));
}
$after = dedup_stats();
var_dump($after['hits'] - $before['hits'] >= 8);

include $paths['c'];
$registry = new DedupSharedValues\Registry();
echo json_encode([$registry->all(), $registry->colors(), $registry->sizes(), $registry->nested()]), "\n";
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_shared_values');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
[{"colors":{"red":1,"green":2},"sizes":["s","m","l"]},{"red":1,"green":2},["s","m","l"],{"map":{"colors":{"red":1,"green":2},"sizes":["s","m","l"]},"colors":{"red":1,"green":2}}]
