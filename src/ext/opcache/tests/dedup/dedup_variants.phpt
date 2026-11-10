--TEST--
opcache.enable_dedup: two docroots with the same layout, where some functions differ
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

/* name => [code in docroot a, code in docroot b, arguments] */
$variants = [
    /* one difference: never shared, each copy keeps its own behaviour */
    'operator'   => ['fn ($a, $b) => $a + $b', 'fn ($a, $b) => $a - $b', [5, 3]],
    'comparison' => ['fn ($a) => $a < 3 ? "lt" : "ge"', 'fn ($a) => $a <= 3 ? "lt" : "ge"', [3]],
    'int'        => ['fn () => 10', 'fn () => 11', []],
    'string'     => ['fn () => "abc"', 'fn () => "abd"', []],
    'float'      => ['fn () => 0.1 + 0.2', 'fn () => 0.1 + 0.3', []],
    'branches'   => ['function ($x) { if ($x) { return "yes"; } return "no"; }', 'function ($x) { if ($x) { return "no"; } return "yes"; }', [true]],
    'call'       => ['fn ($s) => strtoupper($s)', 'fn ($s) => strtolower($s)', ['MiXeD']],
    'arg_order'  => ['fn ($a, $b) => $a . $b', 'fn ($a, $b) => $b . $a', ['x', 'y']],
    'statement'  => ['function ($a) { $a *= 2; return $a; }', 'function ($a) { $a *= 2; $a++; return $a; }', [4]],
    'default'    => ['fn ($a = 1) => $a', 'fn ($a = 2) => $a', []],
    'array'      => ['fn () => json_encode(["x" => 1, "y" => 2])', 'fn () => json_encode(["y" => 2, "x" => 1])', []],
    'match'      => ['fn ($v) => match ($v) { 1 => "one", 2 => "two", default => "other" }', 'fn ($v) => match ($v) { 1 => "one", 2 => "deux", default => "other" }', [2]],
    'switch'     => ['function ($s) { switch ($s) { case "a": return 1; case "b": return 2; } return 0; }', 'function ($s) { switch ($s) { case "a": return 1; case "c": return 2; } return 0; }', ['b']],
    'catch'      => ['function () { try { throw new LogicException("x"); } catch (LogicException $e) { return "caught"; } catch (Exception $e) { return "generic"; } }',
                     'function () { try { throw new LogicException("x"); } catch (RuntimeException $e) { return "caught"; } catch (Exception $e) { return "generic"; } }', []],
    /* same opcodes, different metadata (variable names, types, initial
     * values of static variables): shared, metadata stays per function */
    'static'     => ['function () { static $n = 0; return ++$n; }', 'function () { static $n = 100; return ++$n; }', []],
    'var_name'   => ['fn ($a) => $a * 3', 'fn ($b) => $b * 3', [7]],
    'param_type' => ['function (int $x) { return gettype($x); }', 'function (string $x) { return gettype($x); }', ['42']],
    'return_type'=> ['function ($x): int { return $x; }', 'function ($x): string { return $x; }', ['5']],
    'identical'  => ['fn ($a) => $a * 2', 'fn ($a) => $a * 2', [21]],
    /* last, as it shifts the lines that follow: different line, not shared */
    'line'       => ['fn () => __LINE__', "\n" . 'fn () => __LINE__', []],
];

$sources = ['a' => "<?php\nreturn [\n", 'b' => "<?php\nreturn [\n"];
foreach ($variants as $name => [$a, $b]) {
    $sources['a'] .= "'$name' => $a,\n";
    $sources['b'] .= "'$name' => $b,\n";
}
$paths = [];
foreach ($sources as $root => $code) {
    $paths[$root] = dedup_make_sites('dedup_variants', $code . "];\n", [$root])[$root];
}

$a = include $paths['a'];
$before = dedup_stats()['hits'];
$b = include $paths['b'];
$shared = dedup_stats()['hits'] - $before;

foreach ($variants as $name => [, , $args]) {
    printf("%-11s a=%s b=%s\n", $name,
        var_export($a[$name](...$args), true), var_export($b[$name](...$args), true));
}
echo "shared by docroot b: $shared\n";
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_variants');
?>
--EXPECT--
operator    a=8 b=2
comparison  a='ge' b='lt'
int         a=10 b=11
string      a='abc' b='abd'
float       a=0.30000000000000004 b=0.4
branches    a='yes' b='no'
call        a='MIXED' b='mixed'
arg_order   a='xy' b='yx'
statement   a=8 b=9
default     a=1 b=2
array       a='{"x":1,"y":2}' b='{"y":2,"x":1}'
match       a='two' b='deux'
switch      a=2 b=0
catch       a='caught' b='generic'
static      a=1 b=101
var_name    a=21 b=21
param_type  a='integer' b='string'
return_type a=5 b='5'
identical   a=42 b=42
line        a=22 b=23
shared by docroot b: 5
