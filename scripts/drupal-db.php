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
 *   claim NONCE   record that this wrapper started an install on this database
 *                 (table railway_template_install_claim)
 *   owns NONCE    exit 0 only when that claim exists with exactly NONCE, so an
 *                 install record on the volume never authorizes changes to a
 *                 database the install did not start on
 *   release       drop the claim once the install is finished
 */

$command = $argv[1] ?? '';
$nonce = $argv[2] ?? '';
if (in_array($command, ['claim', 'owns'], TRUE) && !preg_match('/^[0-9a-f]{32}$/', $nonce)) {
  fwrite(STDERR, "drupal-db: {$command} needs a 32-character hexadecimal nonce\n");
  exit(64);
}
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

    // reset and claim each run in one transaction (PostgreSQL DDL is
    // transactional), so a crash cannot leave the database without its public
    // schema, or with a claim table that holds no nonce.
    case 'reset':
      $pdo->beginTransaction();
      $pdo->exec('DROP SCHEMA public CASCADE');
      $pdo->exec('CREATE SCHEMA public');
      $pdo->commit();
      exit(0);

    case 'claim':
      $pdo->beginTransaction();
      $pdo->exec('CREATE TABLE IF NOT EXISTS public.railway_template_install_claim (nonce text PRIMARY KEY)');
      $pdo->prepare('INSERT INTO public.railway_template_install_claim (nonce) VALUES (?) ON CONFLICT DO NOTHING')->execute([$nonce]);
      $pdo->commit();
      exit(0);

    case 'owns':
      $exists = $pdo->query("SELECT to_regclass('public.railway_template_install_claim') IS NOT NULL")->fetchColumn();
      if (!($exists === TRUE || $exists === 't' || $exists === 1 || $exists === '1')) {
        exit(1);
      }
      $query = $pdo->prepare('SELECT count(*) FROM public.railway_template_install_claim WHERE nonce = ?');
      $query->execute([$nonce]);
      $rows = (int) $query->fetchColumn();
      $all = (int) $pdo->query('SELECT count(*) FROM public.railway_template_install_claim')->fetchColumn();
      exit($rows === 1 && $all === 1 ? 0 : 1);

    case 'release':
      $pdo->exec('DROP TABLE IF EXISTS public.railway_template_install_claim');
      exit(0);

    default:
      fwrite(STDERR, "drupal-db: usage: drupal-db.php ping|state|reset|claim NONCE|owns NONCE|release\n");
      exit(64);
  }
}
catch (PDOException $e) {
  fwrite(STDERR, 'drupal-db: ' . $command . ' failed (SQLSTATE ' . $e->getCode() . ")\n");
  exit(3);
}
