--TEST--
opcache.enable_dedup: blocks whose keys collide are compared in full, never shared
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

/* The table is keyed with zend_hash_func(), which is not collision
 * resistant: "Ab" and "BA" hash alike, and so does any string made of such
 * pairs. Identical opcodes with these literals give identical keys. Only a
 * full comparison may decide, so every copy must keep its own value. */
$pairs = [['Ab', 'BA'], ['Ab', 'BA'], ['Ab', 'BA']];
$sites = [];
for ($i = 0; $i < 8; $i++) {
    $literal = '';
    foreach ($pairs as $bit => $pair) {
        $literal .= $pair[($i >> $bit) & 1];
    }
    $sites["s$i"] = $literal;
}

$paths = [];
foreach ($sites as $site => $literal) {
    /* __FILE__ keeps the (otherwise identical) main scripts out of the count */
    $paths[$site] = dedup_make_sites('dedup_hash_collision', "<?php\n\$f = __FILE__;\nreturn static fn () => '$literal';\n", [$site])[$site];
}

$before = dedup_stats();
foreach ($paths as $site => $path) {
    $fn = include $path;
    var_dump($fn() === $sites[$site]);
}
$after = dedup_stats();
var_dump($after['hits'] - $before['hits']);
/* Each colliding block got its own slot */
var_dump($after['num_entries'] - $before['num_entries'] >= 8);
?>
--CLEAN--
<?php
require __DIR__ . '/dedup.inc';
dedup_remove_sites('dedup_hash_collision');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
int(0)
bool(true)
