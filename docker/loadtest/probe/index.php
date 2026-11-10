<?php
require __DIR__ . '/lib.php';

$thing = new ProbeThing();
$out = [
    'user' => getenv('USER') ?: null,
    'index' => ['file' => __FILE__, 'dir' => __DIR__, 'line' => __LINE__],
    'lib' => probe_where(),
    'method' => $thing->where(),
];
try {
    $thing->fail('exception');
} catch (RuntimeException $e) {
    $out['caught'] = ['file' => $e->getFile(), 'line' => $e->getLine(), 'trace' => $e->getTraceAsString()];
}
$out['reflection'] = (new ReflectionMethod(ProbeThing::class, 'fail'))->getFileName();
echo json_encode($out, JSON_UNESCAPED_SLASHES), "\n";
