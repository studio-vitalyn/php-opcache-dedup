<?php
/* Per-site configuration: the only file that differs between sites of the
 * same stack. */
define('DB_NAME', 'SITE_NAME');
define('DB_USER', 'SITE_NAME');
define('DB_PASSWORD', 'SITE_NAME-secret');
define('DB_HOST', 'localhost');
$table_prefix = 'wp_';
if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
