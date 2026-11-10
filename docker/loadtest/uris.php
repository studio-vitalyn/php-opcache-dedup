<?php
/* Prints <count> shuffled request URIs over all sites, with a fixed seed so
 * that both runs replay the same sequence. */
[, $list, $count] = $argv;
$sites = file($list, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$paths = [
    '/' => 35,                          /* home page (block theme) */
    '/article-%d/' => 25,               /* blog post */
    '/shop/' => 10,                     /* WooCommerce catalog */
    '/product/product-%d/' => 15,       /* WooCommerce product */
    '/wp-json/wp/v2/posts' => 10,       /* REST API */
    '/?s=lorem' => 5,                   /* search */
];
$weighted = [];
foreach ($paths as $path => $weight) {
    array_push($weighted, ...array_fill(0, $weight, $path));
}
mt_srand(20261019);
for ($i = 0; $i < $count; $i++) {
    $site = $sites[mt_rand(0, count($sites) - 1)];
    $path = sprintf($weighted[mt_rand(0, count($weighted) - 1)], mt_rand(1, 10));
    echo "http://127.0.0.1:8080/$site$path\n";
}
