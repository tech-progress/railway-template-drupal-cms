# Publishing

`Drupal CMS` builds `tech-progress/railway-template-drupal-cms` from `release-v1` with root directory `/`; `PostgreSQL` runs the pinned image. The listing's name, category and description are in `template-listing.json`.

1. `bun install --frozen-lockfile`, `./scripts/verify.sh`, `./scripts/local-check.sh`, `./tests/wrapper-guards.sh` and `./tests/install-recovery.sh`.
2. Sync the public distribution repository (everything except `FINDINGS.md` and `node_modules`), run `./scripts/check-standalone.sh <checkout>`, and fast-forward `release-v1`; tag `v<version>` once the release is verified.
3. Source project: `railway init --name drupal-cms` (under `script -qc`), link it, and run `DRUPAL_IAC_SEED=1 DRUPAL_IAC_POSTGRES_PASSWORD=<fresh> DRUPAL_IAC_HASH_SALT=<fresh> DRUPAL_IAC_ADMIN_PASSWORD=<fresh> railway config apply --yes`. The seed image keeps `templates create` from rejecting a repository the Railway GitHub App cannot read. Do not attach a domain to the source project.
4. `railway templates create --project <PROJECT_ID> --environment <ENVIRONMENT_ID> --json` (under `script -qc`), then `./scripts/restore-template-draft.sh <TEMPLATE_ID> <WORKSPACE_ID>` and `./scripts/audit-template.sh <TEMPLATE_ID> UNPUBLISHED`.
5. `./scripts/deploy-stored-template.sh <TEMPLATE_ID> <WORKSPACE_ID>` deploys the stored `serializedConfig` with `templateDeployV2`. Wait until `./scripts/project-status.sh <PROJECT_ID>` shows both services `SUCCESS` with one running replica and one domain, on `Drupal CMS` only. Read `DRUPAL_ADMIN_PASSWORD` from the deployed service into a 0600 file and run `python3 -I scripts/smoke.py setup` with `BASE_URL=https://<domain>` and `ADMIN_PASSWORD_FILE`; redeploy both services, wait for the new deployments (`./scripts/wait-deployment.sh`), and run `scripts/smoke.py readback`. Check replicas, metrics, and that no generated value appears in either service's logs.
6. Publish:

```bash
railway templates publish <TEMPLATE_ID> \
  --category CMS \
  --description "Drupal CMS on PostgreSQL with a generated admin and a files volume" \
  --readme-file MARKETPLACE.md \
  --json
./scripts/audit-template.sh <TEMPLATE_ID> PUBLISHED
```

7. Add the template to the root `railway-template-metadata.json`, then from the repository root run `scripts/sync-template-marketplace.sh drupal-cms` and `scripts/audit-template-marketplace.sh drupal-cms`; both must pass.
8. Delete the source and verification projects, confirm each returns "Project not found", and tag `drupal-cms-v<version>` in the monorepo.
