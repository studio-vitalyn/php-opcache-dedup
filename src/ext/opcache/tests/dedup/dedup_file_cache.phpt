--TEST--
opcache.enable_dedup is ignored when opcache.file_cache is set
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.enable_dedup=1
opcache.file_cache={TMP}
opcache.jit_buffer_size=0
--FILE--
<?php
var_dump(opcache_get_status(false)['dedup']);
var_dump(opcache_get_configuration()['directives']['opcache.enable_dedup']);
?>
--EXPECT--
array(1) {
  ["enabled"]=>
  bool(false)
}
bool(true)
