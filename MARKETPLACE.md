# Deploy and Host Drupal CMS on Railway

Drupal CMS is the ready-to-use distribution of Drupal for marketers, content editors and site builders. It ships smart defaults: the Canvas page builder, media, SEO tools, scheduled publishing, an editorial workflow and an administrator dashboard. This template installs Drupal CMS 2.2.10 (Drupal core 11.4.13) on PostgreSQL 18, unattended, on the first boot.

## About Hosting Drupal CMS

The template runs two services. `Drupal CMS` is Apache with PHP 8.4, built from a pinned Composer lock file on the official Drupal image. It is the only public service. `PostgreSQL` holds content, configuration, users and sessions, and is reachable only on Railway's private network.

On the first boot the start wrapper installs Drupal CMS with Drush and the Starter site template before Apache opens its port, so nobody can reach the web installer. It then creates the administrator `admin` with a generated password. Find the password in the `DRUPAL_ADMIN_PASSWORD` variable of the `Drupal CMS` service and sign in at `/user/login`. Set `DRUPAL_ADMIN_EMAIL` to your own address before deploying.

Uploads, private files and the configuration sync directory live on a 5 GB volume at `/var/lib/drupal`. Database updates run on every boot, and a built-in loop runs Drupal's cron every five minutes, so scheduled publishing works without an external cron service.

## Common Use Cases

- Company, product or project websites with editorial workflow and scheduled publishing
- Marketing sites built with the Canvas page builder and media library
- Blogs, news sections and documentation sites
- Evaluating Drupal CMS before choosing a hosting setup

## Dependencies for Drupal CMS Hosting

- PostgreSQL 18.7 (included, private)
- A volume for files (included)
- Optional: an SMTP or email API provider for password-reset and notification mail. Railway allows outbound SMTP only on the Pro plan and above.

### Deployment Dependencies

- Drupal CMS: https://www.drupal.org/project/cms
- Drupal: https://www.drupal.org
- Drush: https://www.drush.org
- PostgreSQL: https://www.postgresql.org
- Template source: https://github.com/tech-progress/railway-template-drupal-cms

### Implementation Details

- The code is fixed in the image. Project Browser shows Composer commands instead of installing in the browser. To add modules, eject the service from the template repository and run `composer require` in `site/`; Railway rebuilds the image on push.
- For a custom domain, add its host names to `DRUPAL_TRUSTED_HOSTS` (comma-separated). Drupal answers HTTP 400 for hosts it does not trust.
- Lost the administrator password and have no mail set up? Add `DRUPAL_RESET_ADMIN_PASSWORD=1`, redeploy, sign in with `DRUPAL_ADMIN_PASSWORD`, then remove the variable.
- Registration is limited to administrators. Login limits apply per visitor, because the template passes Drupal the visitor address Railway's edge reports.
- Single instance, no cache server and no backups included. Use Railway volume backups or `pg_dump`.

## Why Deploy Drupal CMS on Railway?

Railway runs the site and its database in one project, with private networking, persistent volumes and HTTPS on a generated domain. You get a working Drupal CMS site in about two minutes, with no installer to click through. Every image is pinned and every secret is generated.

This is a community template by Tech Progress, not an official Drupal project release, and it is not affiliated with or endorsed by Dries Buytaert or the Drupal Association. Drupal is a registered trademark of Dries Buytaert.
