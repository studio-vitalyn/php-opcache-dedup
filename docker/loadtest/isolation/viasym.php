<?php
/* other.php is a symlink to the other site's secret.php (mode 640) */
$v = @include __DIR__ . '/other.php';
echo 'symlink: ', $v === false ? 'refused' : 'READ ' . var_export($v, true), "\n";
$v = @include $_GET['path'];
echo 'absolute: ', $v === false ? 'refused' : 'READ ' . var_export($v, true), "\n";
