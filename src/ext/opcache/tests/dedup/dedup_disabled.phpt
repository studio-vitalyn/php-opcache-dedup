--TEST--
opcache.enable_dedup is off by default
--EXTENSIONS--
opcache
--INI--
opcache.enable=1
opcache.enable_cli=1
opcache.file_update_protection=0
--FILE--
<?php
var_dump(opcache_get_status(false)['dedup']);
var_dump(opcache_get_configuration()['directives']['opcache.enable_dedup']);
var_dump(ini_get('opcache.enable_dedup'));
var_dump(ini_set('opcache.enable_dedup', '1'));
?>
--EXPECT--
array(1) {
  ["enabled"]=>
  bool(false)
}
bool(false)
string(1) "0"
bool(false)
