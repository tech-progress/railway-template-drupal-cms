# Upgrading

Template versions follow `VERSION` and `CHANGELOG.md`. The Drupal CMS service builds the `release-v1` branch of `tech-progress/railway-template-drupal-cms`. A redeploy builds the branch's current release, and the start wrapper then runs `drush updatedb` before Apache starts. A failed update stops the boot and leaves the previous deployment serving.

Before an upgrade, back up the PostgreSQL volume (or run `pg_dump`) and the Drupal CMS volume.

## Maintainers: preparing a release

1. Regenerate the lock for the new Drupal CMS or core release, inside the pinned base image:
   `docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e COMPOSER_HOME=/tmp/c -v "$PWD/site:/opt/site" -w /opt/site --entrypoint composer <base image> update --no-dev --with-all-dependencies`
   Keep `drush/drush` in `require`, not `require-dev`.
2. Update the base image tag and digest in the `Dockerfile` (both stages) and `.railway/railway.ts` (`APP_SEED_IMAGE`), and the PostgreSQL pin in `.railway/railway.ts` and `compose.yaml`. Read the PostgreSQL release notes: a new major version needs a dump and restore, which this template does not do automatically.
3. Run `./scripts/verify.sh`, `./scripts/local-check.sh`, `./tests/wrapper-guards.sh` and `./tests/install-recovery.sh`, plus an upgrade test: install the previous release, then boot the new image on the same volumes.
4. Follow `TEMPLATE_VERSIONING.md` in the authoring repository: bump `VERSION`, add the changelog entry, tag, and fast-forward `release-v1`.

The PostgreSQL image is pinned in the stored template, not in the branch. Changing it needs a change to the published template.
