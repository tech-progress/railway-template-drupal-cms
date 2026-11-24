#!/usr/bin/env bash
# Structural check for the Drupal CMS template: files, version, JSON, shell,
# PHP and Python syntax, Compose config, the compiled IaC graph, defaults that
# match the graph, image pins shared by the Dockerfile, IaC and Compose, the
# Composer project, a single public service, marketplace copy and listing
# metadata, and the offline restore/audit tests.
set -euo pipefail
exec </dev/null
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
fail() { echo "verify: $*" >&2; exit 1; }

for file in .railway/railway.ts .dockerignore .env.example .gitignore CHANGELOG.md LICENSE_REVIEW.md MARKETPLACE.md \
  PUBLISHING.md README.md SUPPORT.md UPGRADE.md VERSION Dockerfile bun.lock compose.yaml package.json \
  template-defaults.json template-descriptions.json template-listing.json template-networking.json template-volumes.json \
  config/settings.php config/apache-railway.conf config/php-railway.ini site/composer.json site/composer.lock site/LICENSE.txt \
  site/web/modules/custom/.gitkeep site/web/themes/custom/.gitkeep \
  scripts/drupal-start.sh scripts/drupal-db.php scripts/drupal-provision.php scripts/iac-graph.sh scripts/audit-template.sh \
  scripts/restore-template-draft.sh scripts/deploy-stored-template.sh scripts/project-status.sh scripts/wait-deployment.sh \
  scripts/smoke.py scripts/local-check.sh scripts/check-standalone.sh tests/restore-audit.sh tests/wrapper-guards.sh tests/install-recovery.sh; do
  test -f "${file}" || fail "missing ${file}"
done

version="$(<VERSION)"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not MAJOR.MINOR.PATCH"
grep -q "^## \[${version}\] - " CHANGELOG.md || fail "CHANGELOG.md has no entry for ${version}"
for file in template-*.json package.json site/composer.json site/composer.lock; do jq empty "${file}"; done
for file in scripts/*.sh tests/*.sh; do bash -n "${file}"; done
python3 -I -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' scripts/smoke.py
docker compose version >/dev/null 2>&1 || fail "docker compose is required"
POSTGRES_PASSWORD=verify DRUPAL_HASH_SALT=verify DRUPAL_ADMIN_PASSWORD=verify docker compose -f compose.yaml config >/dev/null

# Image pins: the Dockerfile's two stages, the IaC seed image and the
# Compose PostgreSQL image are digest-pinned and agree.
base="$(sed -n 's/^FROM \([^ ]*\).*/\1/p' Dockerfile | sort -u)"
[[ "$(wc -l <<<"${base}")" == 1 && "${base}" =~ ^drupal:[0-9.]+-php8\.4-apache-trixie@sha256:[0-9a-f]{64}$ ]] || fail "the Dockerfile stages must share one digest-pinned drupal image"
grep -qF "\"${base}\"" .railway/railway.ts || fail "APP_SEED_IMAGE differs from the Dockerfile base image"
grep -q '^STOPSIGNAL SIGTERM$' Dockerfile || fail "the Dockerfile must stop with SIGTERM (the base image uses SIGWINCH)"
grep -q '^CMD \["/usr/local/bin/drupal-start"\]$' Dockerfile || fail "the Dockerfile CMD must be drupal-start"
! grep -qE '^VOLUME' Dockerfile || fail "Railway's builder rejects VOLUME"
! grep -q 'composer audit' Dockerfile || fail "a build-time audit would break deployments when an advisory appears; audit in local-check.sh"

# The IaC never derives a credential; without DRUPAL_IAC_* every secret compiles empty.
! grep -qE 'ctx\.randomString\(|generator:' .railway/railway.ts || fail "the IaC derives a credential"
graph="$(./scripts/iac-graph.sh)"
jq -e '.ok == true
  and ([.graph.resources[] | select(.type == "service") | .name] | sort) == ["Drupal CMS", "PostgreSQL"]
  and ([.graph.resources[] | select(.type == "volume")] | length) == 2' <<<"${graph}" >/dev/null || fail "graph service or volume set"
postgres_image="$(jq -r '.graph.resources[] | select(.type == "service" and .name == "PostgreSQL") | .source.image' <<<"${graph}")"
[[ "${postgres_image}" =~ ^postgres:18\.[0-9]+-alpine@sha256:[0-9a-f]{64}$ ]] || fail "PostgreSQL image is not digest-pinned"
[[ "$(grep -c "image: ${postgres_image}$" compose.yaml)" == 2 ]] || fail "compose.yaml does not use ${postgres_image} for volume-init and postgres"
grep -qF "${postgres_image}" tests/wrapper-guards.sh tests/install-recovery.sh || fail "the tests use another PostgreSQL image"
jq -e '.graph.resources[] | select(.type == "service" and .name == "Drupal CMS") | .source
  == {type: "github", repo: "tech-progress/railway-template-drupal-cms", branch: "release-v1", rootDirectory: "/"}' <<<"${graph}" >/dev/null \
  || fail "the Drupal CMS source must be tech-progress/railway-template-drupal-cms release-v1 at /"
jq -e '.graph.resources[] | select(.type == "service" and .name == "Drupal CMS") | .build
  == {builder: "DOCKERFILE", dockerfilePath: "Dockerfile", watchPatterns: ["/Dockerfile", "/site/**", "/config/**", "/scripts/drupal-*"]}' <<<"${graph}" >/dev/null \
  || fail "the Drupal CMS build block differs"
DRUPAL_IAC_SEED=1 ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null \
  | jq -e --arg b "${base}" '.graph.resources[] | select(.type == "service" and .name == "Drupal CMS") | .source.image == $b and .build == null' >/dev/null \
  || fail "the seed graph does not use the base image"

# template-defaults.json must match the graph: identical literals and
# references, and the generated secret wherever the IaC takes a host secret.
alnum='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
jq -e --slurpfile defaults template-defaults.json --arg alnum "${alnum}" '
  {"DRUPAL_HASH_SALT": 64, "DRUPAL_ADMIN_PASSWORD": 32, "POSTGRES_PASSWORD": 32} as $lengths
  | [.graph.resources[] | select(.type == "service")] as $services
  | ($services | map(.name) | sort) == ($defaults[0] | keys | sort)
  and all($services[]; . as $s
      | ($s.variables | keys | sort) == ($defaults[0][$s.name] | keys | sort)
      and all($s.variables | to_entries[]; .key as $k | .value.value as $v | $defaults[0][$s.name][$k] as $d
          | if $v == "" then $lengths[$k] != null and $d == ("${{secret(" + ($lengths[$k] | tostring) + ", \"" + $alnum + "\")}}") else $d == $v end))' \
  <<<"${graph}" >/dev/null || fail "template-defaults.json differs from the IaC graph"
[[ "$(jq '[.[][] | select(test("secret\\("))] | length' template-defaults.json)" == 3 ]] || fail "expected exactly three generated secrets"
jq -e '."Drupal CMS" | .DRUPAL_DATABASE_HOST == "${{PostgreSQL.RAILWAY_PRIVATE_DOMAIN}}" and .DRUPAL_DATABASE_PASSWORD == "${{PostgreSQL.POSTGRES_PASSWORD}}"
  and .PORT == "80" and (has("DRUPAL_TRUSTED_HOSTS") or has("DRUPAL_RESET_ADMIN_PASSWORD") | not)' template-defaults.json >/dev/null \
  || fail "Drupal CMS defaults: private database reference, PORT 80, and no optional variable in the template"
jq -e --slurpfile d template-descriptions.json 'to_entries | all(.key as $s | (.value | keys | sort) == ($d[0][$s] | keys | sort))' template-defaults.json >/dev/null \
  || fail "every variable needs a description, and nothing else"
for name in $(jq -r '."Drupal CMS" | keys[]' template-defaults.json) DRUPAL_TRUSTED_HOSTS DRUPAL_RESET_ADMIN_PASSWORD; do
  grep -q "${name}" README.md || fail "README.md does not document ${name}"
done
for name in $(jq -r '."Drupal CMS" | keys[] | select(. != "PORT")' template-defaults.json); do
  grep -q "${name}" compose.yaml || fail "compose.yaml does not set ${name}"
done

# Health checks, independent of the graph: Drupal's sign-in page (it needs
# PostgreSQL) with a long first-boot window; none on PostgreSQL.
jq -e '[.graph.resources[] | select(.type == "service") | {key: .name, value: {path: .deploy.healthcheckPath, timeout: .deploy.healthcheckTimeout, start: .deploy.startCommand}}]
  | from_entries == {"Drupal CMS": {path: "/user/login", timeout: 600, start: null}, "PostgreSQL": {path: null, timeout: null, start: null}}' \
  <<<"${graph}" >/dev/null || fail "health checks or start commands differ"

# Only Drupal CMS is public, and the volumes match template-volumes.json.
[[ "$(jq -c . template-networking.json)" == '{"Drupal CMS":{"publicPort":80}}' ]] || fail "template-networking.json"
jq -e --slurpfile v template-volumes.json '
  [.graph.resources[] | select(.type == "service") | {key: .name, value: (.volumeAttachments | to_entries[0].value.mountPath)}] | from_entries
  == ($v[0] | map_values(.mountPath))' <<<"${graph}" >/dev/null || fail "volume mount paths"
jq -e --slurpfile v template-volumes.json '[.graph.resources[] | select(.type == "volume") | .config.sizeMB] | sort == ([$v[0][].sizeMB] | sort)' <<<"${graph}" >/dev/null || fail "volume sizes"
grep -q '^data=/var/lib/drupal$' scripts/drupal-start.sh || fail "the wrapper's volume path differs"

# The Composer project: Drupal CMS with the Starter site template and Drush as
# a runtime dependency, locked, with core matching the base image.
jq -e '.name == "drupal/cms" and (.require | has("drupal/drupal_cms_starter") and has("drush/drush")) and ((."require-dev" // {}) | has("drush/drush") | not)' site/composer.json >/dev/null \
  || fail "site/composer.json must require drupal/drupal_cms_starter and drush/drush"
core="$(jq -r '.packages[] | select(.name == "drupal/core") | .version' site/composer.lock)"
[[ "${base}" == "drupal:${core}-"* ]] || fail "the locked core ${core} differs from the base image ${base}"
[[ "$(jq -r '.packages[] | select(.name == "drupal/drupal_cms_starter") | .version' site/composer.lock)" =~ ^2\. ]] || fail "drupal_cms_starter is not locked"
[[ "$(jq '."packages-dev" | length' site/composer.lock)" == 0 ]] || fail "the lock holds dev packages"
grep -qF "[Drupal CMS](https://www.drupal.org/project/cms) $(jq -r .version site/composer.json)" README.md || fail "README.md does not name Drupal CMS $(jq -r .version site/composer.json)"
grep -q "core ${core}" README.md || fail "README.md does not name Drupal core ${core}"

# settings.php keeps secrets in the environment and the code read-only.
for needle in "getenv(\$name)" "\$settings['hash_salt'] = \$env('DRUPAL_HASH_SALT')" "trusted_host_patterns" "reverse_proxy_addresses" \
  "\$config['project_browser.admin_settings']['allow_ui_install'] = FALSE" "/var/lib/drupal/private" "/var/lib/drupal/config/sync"; do
  grep -qF -- "${needle}" config/settings.php || fail "config/settings.php lacks ${needle}"
done
grep -qF 'LocationMatch "^/core/(install|authorize)\.php"' config/apache-railway.conf || fail "Apache must refuse the web installer"

# Marketplace copy and listing metadata.
for heading in '^# Deploy and Host' '^## About Hosting' '^## Why Deploy' '^## Common Use Cases' '^## Dependencies for' '^### Deployment Dependencies'; do
  grep -q "${heading}" MARKETPLACE.md || fail "MARKETPLACE.md lacks ${heading}"
done
! grep -q '<[A-Za-z_-]*>' MARKETPLACE.md || fail "MARKETPLACE.md has an angle-bracket placeholder"
for link in https://www.drupal.org/project/cms https://www.drupal.org https://github.com/drupal/drupal https://www.drush.org https://www.postgresql.org; do
  grep -qF "${link}" README.md || fail "README.md does not link ${link}"
done
notice='Drupal is a registered trademark of Dries Buytaert.'
for file in README.md MARKETPLACE.md; do
  grep -qF "${notice}" "${file}" || fail "${file} lacks the trademark notice"
  grep -q 'not affiliated with or endorsed by Dries Buytaert or the Drupal Association' "${file}" || fail "${file} lacks the independence statement"
done
description="$(jq -r .description template-listing.json)"
(( ${#description} >= 45 && ${#description} <= 75 )) || fail "the listing description must be 45-75 characters"
grep -qF -- "--description \"${description}\"" PUBLISHING.md || fail "PUBLISHING.md publishes another description"
grep -qF -- "--category $(jq -r .category template-listing.json)" PUBLISHING.md || fail "PUBLISHING.md publishes another category"

./tests/restore-audit.sh >/dev/null || fail "the restore/audit regression tests failed"
echo "Drupal CMS template structure, pins, defaults, Composer project, networking, marketplace copy and audit are valid."
