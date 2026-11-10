--TEST--
opcache.enable_dedup: __FILE__, __DIR__, exceptions and reflection stay per path
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

$paths = dedup_make_sites('dedup_paths', <<<'PHP'
<?php
return [
    'file' => __FILE__,
    'dir' => __DIR__,
    'classify' => static function (int|string $value): string {
        $kind = match (true) {
            is_int($value) && $value < 0 => 'negative',
            is_int($value) => 'positive',
            default => 'string',
        };
        switch ($value) {
            case 'alpha': return "$kind:first";
            case 'beta': return "$kind:second";
            case 'gamma': return "$kind:third";
        }
        return "$kind:other";
    },
    'thrower' => static function (): void {
        throw new RuntimeException('boom');
    },
    'where' => static function (): string {
        return __FILE__;
    },
];
PHP);

$before = dedup_stats();
$a = include $paths['a'];
$b = include $paths['b'];
$after = dedup_stats();

var_dump($a['file'] === $paths['a'], $b['file'] === $paths['b']);
var_dump($a['dir'] === dirname($paths['a']), $b['dir'] === dirname($paths['b']));
var_dump($a['where']() === $paths['a'], $b['where']() === $paths['b']);
var_dump($a['classify']('beta'), $b['classify'](-3), $b['classify']('zeta'));

foreach (['a' => $a, 'b' => $b] as $site => $lib) {
    try {
        $lib['thrower']();
    } catch (RuntimeException $e) {
        var_dump($e->getFile() === $paths[$site], $e->getLine());
        var_dump($e->getTrace()[0]['file'] === __FILE__);
    }
    var_dump((new ReflectionFunction($lib['thrower']))->getFileName() === $paths[$site]);
}

/* "classify" and "thrower" are shared, "where" and the main script are not */
var_dump($after['hits'] - $before['hits'] >= 2);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_paths');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
string(13) "string:second"
string(14) "negative:other"
string(12) "string:other"
bool(true)
int(19)
bool(true)
bool(true)
bool(true)
int(19)
bool(true)
bool(true)
bool(true)
