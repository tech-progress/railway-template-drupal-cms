<?php

/**
 * @file
 * Drupal settings for the Railway template.
 *
 * This file is part of the image and read-only at run time. Credentials come
 * from the environment that Railway (or Compose) gives the container, so no
 * secret is written to disk. Persistent paths live on the volume mounted at
 * /var/lib/drupal; drupal-start prepares them before Drupal runs.
 */

$env = static function (string $name): string {
  $value = getenv($name);
  return $value === FALSE ? '' : $value;
};

$databases['default']['default'] = [
  'driver' => 'pgsql',
  'namespace' => 'Drupal\\pgsql\\Driver\\Database\\pgsql',
  'autoload' => 'core/modules/pgsql/src/Driver/Database/pgsql/',
  'host' => $env('DRUPAL_DATABASE_HOST'),
  'port' => $env('DRUPAL_DATABASE_PORT'),
  'database' => $env('DRUPAL_DATABASE_NAME'),
  'username' => $env('DRUPAL_DATABASE_USER'),
  'password' => $env('DRUPAL_DATABASE_PASSWORD'),
  'prefix' => '',
  // pdo_pgsql passes this as libpq's connect_timeout, so a connection to a
  // PostgreSQL address that went away after a redeploy fails after 5 seconds
  // instead of hanging the request.
  'pdo' => [\PDO::ATTR_TIMEOUT => 5],
];

$settings['hash_salt'] = $env('DRUPAL_HASH_SALT');
$settings['update_free_access'] = FALSE;
$settings['rebuild_access'] = FALSE;
$settings['allow_authorize_operations'] = FALSE;

// Public files are served from sites/default/files, a symbolic link into the
// volume made by the Dockerfile. Private files and the configuration sync
// directory stay outside the web root.
$settings['file_public_path'] = 'sites/default/files';
$settings['file_private_path'] = '/var/lib/drupal/private';
$settings['file_temp_path'] = '/tmp';
$settings['config_sync_directory'] = '/var/lib/drupal/config/sync';

// Host names Drupal answers for: the Railway public and private domains, the
// host Railway's health check sends, loopback, and any custom domains listed
// in DRUPAL_TRUSTED_HOSTS (comma-separated host names). Without this list a
// forged Host header could steer the links in password-reset mail.
$hosts = ['healthcheck.railway.app', 'localhost', '127.0.0.1'];
foreach (['RAILWAY_PUBLIC_DOMAIN', 'RAILWAY_PRIVATE_DOMAIN'] as $name) {
  $hosts[] = $env($name);
}
foreach (explode(',', $env('DRUPAL_TRUSTED_HOSTS')) as $host) {
  $hosts[] = trim($host);
}
$settings['trusted_host_patterns'] = [];
foreach (array_unique($hosts) as $host) {
  if (preg_match('/^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$/', $host)) {
    $settings['trusted_host_patterns'][] = '^' . preg_quote(strtolower($host), '/') . '$';
  }
}

// Apache (zz-railway-client-address.conf) replaces X-Forwarded-For with the
// single client address Railway's edge reports in X-Real-IP, or removes it, and
// removes Forwarded and the X-Forwarded host, port and prefix headers. The
// connecting peer can therefore be trusted for the client address and the
// scheme, and Drupal's per-address login flood control keys on the visitor
// rather than on Railway's edge.
if (!empty($_SERVER['REMOTE_ADDR'])) {
  $settings['reverse_proxy'] = TRUE;
  $settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR']];
  $settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR
    | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO;
}

// The code is part of the image and owned by root, so Package Manager cannot
// change it, and anything it installed would vanish on the next deploy. Project
// Browser shows the Composer commands instead, and unattended updates stay off;
// add modules and apply updates through composer.json (see README.md).
$config['project_browser.admin_settings']['allow_ui_install'] = FALSE;
$config['automatic_updates.settings']['unattended']['level'] = 'disable';

$settings['file_scan_ignore_directories'] = ['node_modules', 'bower_components'];
$settings['entity_update_batch_size'] = 50;
$settings['entity_update_backup'] = TRUE;
$settings['migrate_node_migrate_type_classic'] = FALSE;
