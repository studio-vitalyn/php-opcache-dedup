<?php
/* Runs WordPress code through the (possibly shared) cached opcodes and
 * prints a digest that must be identical with and without dedup. */
define('ABSPATH', __DIR__ . '/');
define('WPINC', 'wp-includes');

function get_option($name, $default = false)
{
    return $name === 'blog_charset' ? 'UTF-8' : $default;
}

require ABSPATH . WPINC . '/version.php';
require ABSPATH . WPINC . '/plugin.php';
require ABSPATH . WPINC . '/formatting.php';

$out = [
    $wp_version,
    sanitize_title_with_dashes('Héllo Wörld, ça va ? 100% !'),
    wpautop("first\n\nsecond\nline"),
    esc_html('<a href="x">Tom & "Jerry"</a>'),
    remove_accents('Ångström Ærøskøbing', 'en_US'),
    __FILE__ === ABSPATH . '__smoke.php' ? 'own-path' : 'WRONG-PATH',
];
try {
    (new ReflectionFunction('wpautop'))->getFileName() === ABSPATH . WPINC . '/formatting.php'
        or throw new LogicException('wrong file');
    $out[] = 'reflection-ok';
} catch (Throwable $e) {
    $out[] = get_class($e) . ': ' . $e->getMessage();
}
echo md5(serialize($out)), ' ', $wp_version, ' ', $out[1], "\n";
