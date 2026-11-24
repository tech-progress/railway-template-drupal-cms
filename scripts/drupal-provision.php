<?php

/**
 * @file
 * First-install provisioning, run by drupal-start through `drush php:script`
 * after `drush site:install` and before the public port opens. It gives the
 * administrator (user 1) the password from DRUPAL_ADMIN_PASSWORD, read from the
 * environment so it never appears in a command line; site:install itself ran
 * with a throwaway password. Safe to run again: a boot that was interrupted
 * after the install finished runs it once more.
 *
 * DRUPAL_PROVISION_MODE=reset (DRUPAL_RESET_ADMIN_PASSWORD=1 on an installed
 * site) sets only the password, unblocks the account and clears its own
 * per-account failed sign-in records; the name and email stay as the
 * administrator left them.
 */

use Drupal\user\Entity\User;

$mode = getenv('DRUPAL_PROVISION_MODE');
$password = getenv('DRUPAL_ADMIN_PASSWORD');
if ($mode !== 'install' && $mode !== 'reset') {
  throw new \RuntimeException('drupal-provision: DRUPAL_PROVISION_MODE must be install or reset');
}
if (!is_string($password) || strlen($password) < 16) {
  throw new \RuntimeException('drupal-provision: DRUPAL_ADMIN_PASSWORD is required');
}

$admin = User::load(1);
if ($admin === NULL) {
  throw new \RuntimeException('drupal-provision: the database has no user 1');
}
if ($mode === 'install') {
  $name = getenv('DRUPAL_ADMIN_USER');
  $mail = getenv('DRUPAL_ADMIN_EMAIL');
  if (!is_string($name) || $name === '' || !is_string($mail) || $mail === '') {
    throw new \RuntimeException('drupal-provision: DRUPAL_ADMIN_USER and DRUPAL_ADMIN_EMAIL are required');
  }
  $admin->setUsername($name);
  $admin->setEmail($mail);
}
$name = $admin->getAccountName();
$admin->setPassword($password);
$admin->activate();
$admin->save();
if ($mode === 'reset' && \Drupal::database()->schema()->tableExists('flood')) {
  // Only user 1's per-account records ("1" or "1-<address>"); other
  // accounts' blocks and the per-address limit stay in place.
  $or = \Drupal::database()->condition('OR')->condition('identifier', '1')->condition('identifier', '1-%', 'LIKE');
  \Drupal::database()->delete('flood')->condition('event', 'user.failed_login_user')->condition($or)->execute();
}

// Read back what was stored: the account is active, has the expected name and
// accepts the configured password.
$admin = User::load(1);
$hasher = \Drupal::service('password');
if (!$admin->isActive() || $admin->getAccountName() !== $name || !$hasher->check($password, $admin->getPassword())) {
  throw new \RuntimeException('drupal-provision: user 1 does not hold the configured name and password');
}
echo $mode === 'install' ? "drupal-provision: administrator account ready\n" : "drupal-provision: administrator password reset\n";
