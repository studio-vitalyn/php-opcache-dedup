<?php
/* Load test site configuration, SITE_DB is replaced per site. */
define('DB_NAME', 'SITE_DB');
define('DB_USER', 'wp');
define('DB_PASSWORD', 'wp-bench');
define('DB_HOST', 'localhost:/run/mysqld/mysqld.sock');
define('DB_CHARSET', 'utf8mb4');
define('DB_COLLATE', '');

define('AUTH_KEY', 'SITE_DB-auth');
define('SECURE_AUTH_KEY', 'SITE_DB-secure-auth');
define('LOGGED_IN_KEY', 'SITE_DB-logged-in');
define('NONCE_KEY', 'SITE_DB-nonce');
define('AUTH_SALT', 'SITE_DB-auth-salt');
define('SECURE_AUTH_SALT', 'SITE_DB-secure-auth-salt');
define('LOGGED_IN_SALT', 'SITE_DB-logged-in-salt');
define('NONCE_SALT', 'SITE_DB-nonce-salt');

$table_prefix = 'wp_';

/* No background work or outgoing HTTP during the benchmark */
define('DISABLE_WP_CRON', true);
define('WP_HTTP_BLOCK_EXTERNAL', true);
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_DEBUG', false);

if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}
require_once ABSPATH . 'wp-settings.php';
