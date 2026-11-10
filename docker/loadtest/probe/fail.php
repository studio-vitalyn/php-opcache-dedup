<?php
require __DIR__ . '/lib.php';

(new ProbeThing())->fail($_GET['kind'] ?? 'warning');
echo "survived\n";
