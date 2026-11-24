<?php

/**
 * @file
 * PostgreSQL helper for drupal-start, run with the PHP CLI before Drupal
 * itself. Reads the DRUPAL_DATABASE_* variables from the environment, so no
 * credential reaches a command line. Never prints a credential or a driver
 * message (which can name the host); only the SQLSTATE code on failure.
 *
 * Usage: php drupal-db.php ping|state|reset
 *   ping   exit 0 when the database accepts the credentials
 *   state  print "tables=N installed=yes|no": the number of tables in the
 *          public schema, and whether Drupal's installer recorded the
 *          install_task state as "done" (its own "installation finished" flag)
 *   reset  drop and recreate the public schema (an interrupted first install)
 */

$command = $argv[1] ?? '';
$get = static function (string $name): string {
  $value = getenv($name);
  return $value === FALSE ? '' : $value;
};

try {
  $pdo = new PDO(
    sprintf('pgsql:host=%s;port=%s;dbname=%s', $get('DRUPAL_DATABASE_HOST'), $get('DRUPAL_DATABASE_PORT'), $get('DRUPAL_DATABASE_NAME')),
    $get('DRUPAL_DATABASE_USER'),
    $get('DRUPAL_DATABASE_PASSWORD'),
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5],
  );
}
catch (PDOException $e) {
  fwrite(STDERR, 'drupal-db: cannot connect (SQLSTATE ' . $e->getCode() . ")\n");
  exit(2);
}

try {
  switch ($command) {
    case 'ping':
      $pdo->query('SELECT 1');
      exit(0);

    case 'state':
      $tables = (int) $pdo->query("SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public'")->fetchColumn();
      $installed = 'no';
      $exists = $pdo->query("SELECT to_regclass('public.key_value') IS NOT NULL")->fetchColumn();
      if ($exists === TRUE || $exists === 't' || $exists === 1 || $exists === '1') {
        $query = $pdo->prepare("SELECT value FROM public.key_value WHERE collection = 'state' AND name = 'install_task'");
        $query->execute();
        $value = $query->fetchColumn();
        if (is_resource($value)) {
          $value = stream_get_contents($value);
        }
        if ($value !== FALSE && @unserialize($value, ['allowed_classes' => FALSE]) === 'done') {
          $installed = 'yes';
        }
      }
      echo "tables={$tables} installed={$installed}\n";
      exit(0);

    case 'reset':
      $pdo->exec('DROP SCHEMA public CASCADE');
      $pdo->exec('CREATE SCHEMA public');
      exit(0);

    default:
      fwrite(STDERR, "drupal-db: usage: drupal-db.php ping|state|reset\n");
      exit(64);
  }
}
catch (PDOException $e) {
  fwrite(STDERR, 'drupal-db: ' . $command . ' failed (SQLSTATE ' . $e->getCode() . ")\n");
  exit(3);
}
