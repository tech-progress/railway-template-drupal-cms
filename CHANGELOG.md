# Changelog

## [1.0.0] - 2026-11-24

- Drupal CMS 2.2.10 (Drupal core 11.4.13, Drush 13.8.1) on `drupal:11.4.13-php8.4-apache-trixie`, with PostgreSQL 18.7.
- Unattended install with the Starter site template before Apache opens its port; generated administrator password, never on a command line; recovery of interrupted installs; database updates on every boot.
- Public files, private files and the configuration sync directory on one volume; code read-only in the image.
- Cron every five minutes inside the container; `DRUPAL_TRUSTED_HOSTS` for custom domains; `DRUPAL_RESET_ADMIN_PASSWORD` for password recovery without mail.
- Apache passes Drupal the visitor address from Railway's edge and refuses the web installer.
