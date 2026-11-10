--TEST--
opcache.enable_dedup: shared blocks are never written at runtime
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_update_protection=0
opcache.jit_buffer_size=0
opcache.protect_memory=1
--FILE--
<?php
require __DIR__ . '/dedup.inc';

$paths = dedup_make_sites('dedup_protect_memory', <<<'PHP'
<?php
return static function (array $words): array {
    $out = [];
    foreach ($words as $i => $word) {
        $out[] = match ($i % 3) {
            0 => strtoupper($word),
            1 => strrev($word),
            default => str_repeat($word, 2),
        };
    }
    return $out;
};
PHP, ['a', 'b', 'c']);

foreach ($paths as $path) {
    $fn = include $path;
    echo implode(',', $fn(['foo', 'bar', 'baz', 'qux'])), "\n";
}
var_dump(dedup_stats()['hits'] >= 2);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_protect_memory');
?>
--EXPECT--
FOO,rab,bazbaz,QUX
FOO,rab,bazbaz,QUX
FOO,rab,bazbaz,QUX
bool(true)
