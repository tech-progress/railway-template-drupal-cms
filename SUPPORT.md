# Support

## The Drupal CMS service does not start

Read its deploy logs. Every refusal of the start wrapper begins with `drupal-start:`, names the variable or condition and exits with code 64:

| Message | Fix |
| --- | --- |
| `PORT must be 80` | Set `PORT=80`; the image's Apache listens on 80. |
| `DRUPAL_DATABASE_* must ...` | Restore the reference defaults (`${{PostgreSQL.RAILWAY_PRIVATE_DOMAIN}}`, `${{PostgreSQL.POSTGRES_DB}}` and so on). |
| `DRUPAL_HASH_SALT must be at least 32 ...` | Set a long random value. Changing it invalidates one-time login links and open forms. |
| `DRUPAL_ADMIN_* must ...` | Only checked while the site is being installed (or reset); fix the value. |
| `no volume is mounted at /var/lib/drupal` | Attach a volume at `/var/lib/drupal` to the Drupal CMS service. |
| `this volume belongs to an installed site but the database holds no finished Drupal installation` | The database was emptied or replaced while the files volume kept the site's install record. Restore the database from a backup. To start over on purpose, see "Starting over" below. |
| `the database has N tables but no finished Drupal installation ...` | The database holds something other than a Drupal site. The wrapper does not change it. Point the service at an empty database, or empty this one. |
| `drush site:install failed` or `drush updatedb failed` | Read the Drush output above the message. A failed update leaves the previous deployment serving. |

`waiting for PostgreSQL` repeating means PostgreSQL is not up yet or its password differs from `DRUPAL_DATABASE_PASSWORD`. PostgreSQL sets its password only when its volume is first created, so changing `POSTGRES_PASSWORD` later does not change the database's password.

## Signing in

The administrator is `DRUPAL_ADMIN_USER` (default `admin`), with the password from `DRUPAL_ADMIN_PASSWORD` as it was on the first boot. If you lost the password and mail is not configured:

1. Set `DRUPAL_ADMIN_PASSWORD` to a new value (16 to 128 printable characters without spaces) and add `DRUPAL_RESET_ADMIN_PASSWORD=1` to the Drupal CMS service.
2. Redeploy. The log shows `resetting the password of user 1`.
3. Sign in, then remove `DRUPAL_RESET_ADMIN_PASSWORD`; while it is set, every boot resets the password again.

Five failed sign-ins for one account from one address block that combination for six hours (Drupal's flood control); 50 failed sign-ins from one address block it for an hour. The reset above also clears those blocks.

## HTTP 400 "The provided host name is not valid for this server"

The request's host is not trusted. Add it to `DRUPAL_TRUSTED_HOSTS` (comma-separated host names) and redeploy.

## Mail is not delivered

See "Mail" in `README.md`. Until an SMTP or API transport is configured, Drupal logs mail errors under *Reports* > *Recent log messages*.

## Project Browser says to use Composer

The code is part of the image, so modules are added through `site/composer.json`; see "Adding modules, themes and recipes" in `README.md`.

## Starting over

To reinstall from scratch, delete both volumes (Drupal CMS and PostgreSQL) in Railway and redeploy both services. All content and files are lost.

## Reporting problems

Template problems: open an issue on https://github.com/tech-progress/railway-template-drupal-cms. Drupal CMS problems: https://www.drupal.org/project/issues/drupal_cms.
