# Drupal CMS on Railway

A Railway template for [Drupal CMS](https://www.drupal.org/project/cms) 2.2.10, the ready-to-use distribution of [Drupal](https://www.drupal.org) core 11.4.13, on [PostgreSQL](https://www.postgresql.org) 18.7. The site installs itself on the first boot with [Drush](https://www.drush.org) and the Drupal CMS Starter site template. It creates an administrator with a generated password and keeps uploads and private files on a volume.

This is a community template published by Tech Progress (listed on Railway as "Drupal CMS by Tech Progress"). It is not an official Drupal project release and is not affiliated with or endorsed by Dries Buytaert or the Drupal Association. Drupal is a registered trademark of Dries Buytaert.

Upstream projects:

- Drupal CMS: https://www.drupal.org/project/cms (source: https://github.com/drupal/cms)
- Drupal core: https://www.drupal.org (source: https://github.com/drupal/drupal)
- Drush: https://www.drush.org
- PostgreSQL: https://www.postgresql.org

## What it deploys

| Service | Source | Public | Volume |
| --- | --- | --- | --- |
| `Drupal CMS` | this repository's `Dockerfile`, built from the `release-v1` branch on the official `drupal:11.4.13-php8.4-apache-trixie` image | yes, port 80 | `/var/lib/drupal`, 5 GB |
| `PostgreSQL` | `postgres:18.7-alpine`, pinned by digest | no (private network only) | `/var/lib/postgresql`, 5 GB |

The Drupal CMS service runs Apache with PHP 8.4. The code (`site/composer.json` and `site/composer.lock`) is fixed in the image at build time and owned by root. The volume holds:

- `files/`: public files (uploads, image styles, aggregated CSS and JavaScript), served from `/sites/default/files`;
- `private/`: Drupal's private file system;
- `config/sync/`: the configuration sync directory, for `drush config:export`;
- `template-state/`: the start wrapper's install record (root only).

Content, configuration, users and sessions live in PostgreSQL.

The support boundary is a single-instance site: a company or project website, a blog, documentation, or an evaluation of Drupal CMS. It runs one replica, with no Redis or Memcached cache, and it includes no backups. Use Railway's volume backups or a scheduled `pg_dump` for the database and the files volume.

## Deploy on Railway

1. Deploy the template. Before deploying, set `DRUPAL_ADMIN_EMAIL` to your own address. Every secret is generated.
2. Wait for both services to report a successful deployment. The first boot installs Drupal CMS before Apache starts, about a minute after the build. Nobody can reach Drupal's web installer at any point.
3. Open the `Drupal CMS` service's public domain and sign in at `/user/login` as `admin`. The password is the `DRUPAL_ADMIN_PASSWORD` variable of the `Drupal CMS` service.
4. Change the password under *My account* > *Edit*. The variable is used only on the first boot, so changing it later does nothing unless you use the reset below.

## Variables

`Drupal CMS` service:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `80` | Apache's port; Railway's health check probes `/user/login` on it. Must be `80`. |
| `DRUPAL_DATABASE_HOST` | `${{PostgreSQL.RAILWAY_PRIVATE_DOMAIN}}` | PostgreSQL's private address. |
| `DRUPAL_DATABASE_PORT` | `5432` | PostgreSQL port. |
| `DRUPAL_DATABASE_NAME` | `${{PostgreSQL.POSTGRES_DB}}` | Database name. |
| `DRUPAL_DATABASE_USER` | `${{PostgreSQL.POSTGRES_USER}}` | Database user. |
| `DRUPAL_DATABASE_PASSWORD` | `${{PostgreSQL.POSTGRES_PASSWORD}}` | Database password (at least 16 characters). |
| `DRUPAL_HASH_SALT` | generated, 64 characters | Drupal's hash salt (one-time login links, form tokens). At least 32 characters. |
| `DRUPAL_ADMIN_USER` | `admin` | Administrator user name, set on the first boot. |
| `DRUPAL_ADMIN_EMAIL` | `admin@example.com` | Administrator email and the site's sender address, set on the first boot. |
| `DRUPAL_ADMIN_PASSWORD` | generated, 32 characters | Administrator password, set on the first boot (16 to 128 printable ASCII characters without spaces). |
| `DRUPAL_SITE_NAME` | `Drupal CMS` | Site name, set on the first boot. |

Optional variables you can add to the `Drupal CMS` service:

| Variable | Purpose |
| --- | --- |
| `DRUPAL_TRUSTED_HOSTS` | Comma-separated extra host names, such as `www.example.com,example.com`, for custom domains. Drupal refuses requests for any host that is not trusted (HTTP 400). The Railway public and private domains are always trusted. |
| `DRUPAL_RESET_ADMIN_PASSWORD` | `1` gives user 1 the current `DRUPAL_ADMIN_PASSWORD` on every boot and clears that account's failed sign-in blocks (the per-address limit stays). Use it to recover a lost password when no mail is configured, then remove it. |

`PostgreSQL` service: `POSTGRES_DB` (`drupal`), `POSTGRES_USER` (`drupal`), `POSTGRES_PASSWORD` (generated) and `PGDATA` (`/var/lib/postgresql/18/docker`, below the volume mount).

The start wrapper refuses to start (exit code 64) if a variable is malformed. Its message names the variable and never prints the value.

## How the first boot works

`scripts/drupal-start.sh` runs as the container's first process:

1. It checks the variables and that a volume is mounted at `/var/lib/drupal`, then prepares the volume's directories.
2. It waits for PostgreSQL.
3. On an empty database it runs `drush site:install` with the Drupal CMS Starter site template. Drush gets a throwaway password, and the configured password is then set from the environment, so it never appears in a command line. An install interrupted by a stop or crash is detected on the next boot and run again; the volume's install record and a claim table in the database carry the same random value, so only the database the install started on is ever cleared. A volume that belongs to an installed site is never installed over. A database with unrelated tables is never changed.
4. On every later boot it runs `drush updatedb` for pending database updates.
5. It starts Apache and a loop that runs Drupal's cron every five minutes (Scheduler, search indexing, cleanups). The administrator password is removed from their environment.

## Mail

Drupal CMS sends mail through Symfony Mailer Lite, set to `sendmail` by default, and the image has no `sendmail`. Password-reset and notification mail therefore fails until you add an SMTP transport under *Configuration* > *System* > *Symfony Mailer Lite* > *Transport* (`/admin/config/system/symfony-mailer-lite/transport`). Railway allows outbound SMTP only on the Pro plan and above. On other plans, use an email provider's HTTP API module, or keep administrator-only registration (the default) and manage accounts yourself.

## Custom domains

Add the domain to the `Drupal CMS` service in Railway, then add its host names to `DRUPAL_TRUSTED_HOSTS` and redeploy.

## Adding modules, themes and recipes

The code is part of the image, so Project Browser shows the Composer commands for a project instead of installing it from the browser, and Automatic Updates' unattended mode is off. Anything installed into the running container would be lost on the next deploy. To add a module, theme or recipe:

1. Eject the service from the template repository (the `Drupal CMS` service's settings, *Source* > *Upstream Repo*), which gives you your own copy on GitHub, or fork `tech-progress/railway-template-drupal-cms` and point the service at your fork.
2. Run `composer require drupal/<project>` in `site/` (with PHP 8.4 and Composer 2, or `docker run --rm -v "$PWD/site:/app" -w /app composer:2 require drupal/<project> --ignore-platform-reqs`) and commit `composer.json` and `composer.lock`.
3. Push. Railway rebuilds the image and redeploys it, and the wrapper applies database updates. Then enable the module under *Extend*, or apply the recipe with Project Browser.

Custom code goes in `site/web/modules/custom` and `site/web/themes/custom`; the `Dockerfile` copies both into the image.

## Updates

Template releases update Drupal CMS, Drupal core, PHP and PostgreSQL pins together. They are published on the `release-v1` branch with a `vX.Y.Z` tag (see `CHANGELOG.md` and `UPGRADE.md`). A redeploy of the `Drupal CMS` service builds the branch's current release, and the start wrapper runs `drush updatedb` before the site opens. On an ejected repository, run `composer update "drupal/core-*" --with-all-dependencies` in `site/` for Drupal core security releases, or merge the template's release.

## Security notes

- Drupal's own accounts protect the site. Registration is limited to administrators (the Drupal CMS default), and the site is public by design, so there is no extra password gateway.
- Apache refuses `/core/install.php` and `/core/authorize.php`. `update.php` and `/core/rebuild.php` require an administrator, as in Drupal.
- Railway's edge reports the visitor's address in `X-Real-IP`. Apache gives Drupal only that address and drops the forwarded host, port, prefix and `Forwarded` headers, so the per-address login limits (Drupal's flood control) apply to each visitor rather than to Railway's edge. A service inside the same Railway project could still claim any address, which only matters if you add services you do not trust.
- `settings.php` reads credentials from the environment and is read-only. The code is not writable by the web server.

## Local verification

```bash
bun install --frozen-lockfile
./scripts/verify.sh          # structure, pins, defaults, copy, offline audit tests
./scripts/local-check.sh     # clean build, smoke test, restarts, log and process checks
./tests/wrapper-guards.sh    # every refusal of the start wrapper
./tests/install-recovery.sh  # interrupted, resumed, adopted and refused installs
```

`compose.yaml` runs the same image and variables with a Caddy stand-in for Railway's edge. `.env.example` lists the local secrets; `local-check.sh` generates its own.

## License

Drupal CMS, Drupal core and Drush are licensed under the GNU General Public License, version 2 or later; `site/LICENSE.txt` is the license text. PostgreSQL is under the PostgreSQL License. This template's own files are published under the same GPL-2.0-or-later terms.
