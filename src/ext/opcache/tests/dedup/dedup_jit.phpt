--TEST--
opcache.enable_dedup is ignored when the JIT is enabled
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.jit=tracing
opcache.jit_buffer_size=16M
--SKIPIF--
<?php
if (!isset(opcache_get_configuration()['directives']['opcache.jit'])) {
    die('skip JIT not compiled in');
}
?>
--FILE--
<?php
$status = opcache_get_status(false);
var_dump($status['jit']['enabled']);
var_dump($status['dedup']['enabled']);
?>
--EXPECT--
bool(true)
bool(false)
