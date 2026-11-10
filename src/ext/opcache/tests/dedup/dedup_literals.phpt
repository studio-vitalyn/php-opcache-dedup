--TEST--
opcache.enable_dedup: blocks differing only in literal values are not shared
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

$template = <<<'PHP'
<?php
$file = __FILE__; /* keeps the main script out of the comparison */
return static function () {
    return [STR, INT, FLOAT, ARR];
};
PHP;
$variants = [
    'a' => ['"abc"', '1', '0.0', "['x' => 1, 'y' => [2]]"],
    'b' => ['"abd"', '1', '0.0', "['x' => 1, 'y' => [2]]"],
    'c' => ['"abc"', '2', '0.0', "['x' => 1, 'y' => [2]]"],
    'd' => ['"abc"', '1', '-0.0', "['x' => 1, 'y' => [2]]"],
    'e' => ['"abc"', '1', '0.0', "['y' => [2], 'x' => 1]"],
    'f' => ['"abc"', '1', '0.0', "['x' => 1, 'y' => ['2']]"],
    'g' => ['"abc"', '1', '0.0', "['x' => 1, 'y' => [2]]"], /* same as a */
];

$closures = [];
foreach ($variants as $site => [$str, $int, $float, $arr]) {
    $code = str_replace(['STR', 'INT', 'FLOAT', 'ARR'], [$str, $int, $float, $arr], $template);
    $path = dedup_make_sites('dedup_literals', $code, [$site])[$site];
    $before = dedup_stats();
    $closures[$site] = include $path;
    $after = dedup_stats();
    echo $site, ': ', json_encode($closures[$site](), JSON_PRESERVE_ZERO_FRACTION), ' ',
        $after['hits'] > $before['hits'] ? 'shared' : 'stored', "\n";
}
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_literals');
?>
--EXPECT--
a: ["abc",1,0.0,{"x":1,"y":[2]}] stored
b: ["abd",1,0.0,{"x":1,"y":[2]}] stored
c: ["abc",2,0.0,{"x":1,"y":[2]}] stored
d: ["abc",1,-0.0,{"x":1,"y":[2]}] stored
e: ["abc",1,0.0,{"y":[2],"x":1}] stored
f: ["abc",1,0.0,{"x":1,"y":["2"]}] stored
g: ["abc",1,0.0,{"x":1,"y":[2]}] shared
