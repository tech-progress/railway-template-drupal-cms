#!/usr/bin/env bash
# Offline regression tests for restore-template-draft.sh and audit-template.sh.
# Fake `railway` and `curl` commands on PATH replay a draft built from the IaC
# graph the way `railway templates create` stores it (no variable defaults,
# no volume size, no domain port) and capture the Composer request, so no
# Railway API is called. When tests/fixtures/published-template.json exists
# (the stored template read back after publication), the audit must accept it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "${work:?}"' EXIT
mkdir -p "${work}/bin"
cat > "${work}/bin/railway" <<'EOF'
#!/usr/bin/env bash
cat "${FAKE_TEMPLATE}"
EOF
cat > "${work}/bin/curl" <<'EOF'
#!/usr/bin/env bash
body=""; while (($#)); do
  case "$1" in
    --data-binary) [[ "$2" == @- ]] && body="$(cat)" || body="$2"; shift ;;
    *"Bearer "*) echo "token passed on the command line" >&2; exit 97 ;;
  esac
  shift
done
if grep -q templateUpsertConfig <<<"${body}"; then printf '%s' "${body}" > "${FAKE_REQUEST}"; echo '{"data":{"templateUpsertConfig":{"id":"t","code":"c"}}}'
else jq -c '{data:{templateUpsertSettings:{id:"t", name:.variables.input.name}}}' <<<"${body}"; fi
EOF
chmod +x "${work}/bin/railway" "${work}/bin/curl"
export PATH="${work}/bin:${PATH}" FAKE_REQUEST="${work}/request.json" RAILWAY_API_TOKEN=test-token
failures=0
check() { if "$@"; then echo "ok   ${label}"; else echo "FAIL ${label}"; failures=$((failures + 1)); fi; }
audit() { FAKE_TEMPLATE="$1" "${root}/scripts/audit-template.sh" test-id PUBLISHED >/dev/null 2>&1; }

# A generator-shaped draft: names, images, commands, health paths and mount
# paths, keyed by opaque IDs, with defaults, sizes and ports stripped, plus
# inherited seed settings that restoration must remove.
"${root}/scripts/iac-graph.sh" | jq '{data: {template: {name: "drupal-cms", status: "UNPUBLISHED", serializedConfig: {services:
  ([.graph.resources[] | select(.type == "service")] | to_entries | map({key: "svc-\(.key)", value: ({
    name: .value.name, icon: null,
    source: (if .value.source.image != null then {image: .value.source.image} else {image: "drupal:11.4.13-php8.4-apache-trixie@sha256:60a02ee14c147aad32025da047d16c2251331788e0d912ce23029138d0ad6e85"} end),
    build: {builder: "NIXPACKS"},
    deploy: {startCommand: (.value.deploy.startCommand // null), healthcheckPath: (.value.deploy.healthcheckPath // null),
      preDeployCommand: ["false"], cronSchedule: "0 * * * *", numReplicas: 2},
    variables: (.value.variables | with_entries(.value = {isOptional: true})),
    networking: {serviceDomains: (if .value.name == "Drupal CMS" then {"<hasDomain>": {}} else {} end), customDomains: {"evil.example": {port: 5432}}, tcpProxies: {}},
    volumeMounts: (if (.value.volumeAttachments // {}) | length > 0 then (.value.volumeAttachments | to_entries | map({key: "vol-\(.key)", value: {mountPath: (.value.mountPath // .key)}}) | from_entries) else null end)
  } | if .volumeMounts == null then del(.volumeMounts) else . end)}) | from_entries)}}}}' > "${work}/draft.json"

label="audit rejects the unrestored draft"; check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "${work}/draft.json" "${root}/scripts/audit-template.sh"
FAKE_TEMPLATE="${work}/draft.json" "${root}/scripts/restore-template-draft.sh" test-id test-workspace >/dev/null
jq --arg n "$(jq -r .name "${root}/template-listing.json")" '{data:{template:{name:$n,status:"PUBLISHED",serializedConfig:.variables.input.serializedConfig}}}' "${FAKE_REQUEST}" > "${work}/restored.json"
label="restore produces a draft the audit accepts"; check audit "${work}/restored.json"
label="restore swaps the seed image for the repository source and build"; check bash -c '[[ "$(jq -c "[.data.template.serializedConfig.services[] | select(.name == \"Drupal CMS\") | [.source, .build.builder]]" "$1")" == "[[{\"repo\":\"tech-progress/railway-template-drupal-cms\",\"branch\":\"release-v1\",\"rootDirectory\":\"/\"},\"DOCKERFILE\"]]" ]]' _ "${work}/restored.json"
label="restore keeps the generator's service keys"; check bash -c '[[ "$(jq -r ".data.template.serializedConfig.services | keys | join(\",\")" "$1")" == "svc-0,svc-1" ]]' _ "${work}/restored.json"

mutate() { jq --arg s "$1" "(.data.template.serializedConfig.services[] | select(.name == \$s)) |= ($2)" "${work}/restored.json" > "${work}/mutated.json"; echo "${work}/mutated.json"; }
while IFS='|' read -r service change; do
  label="audit rejects ${service}: ${change}"
  check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id PUBLISHED >/dev/null 2>&1' _ "$(mutate "${service}" "${change}")" "${root}/scripts/audit-template.sh"
done <<'EOF'
Drupal CMS|.deploy.preDeployCommand = ["false"]
Drupal CMS|.deploy.startCommand = "apache2-foreground"
Drupal CMS|.deploy.numReplicas = 2
Drupal CMS|.deploy.healthcheckPath = "/"
Drupal CMS|.deploy.healthcheckTimeout = 1
Drupal CMS|.deploy.restartPolicyType = "NEVER"
Drupal CMS|.deploy.cronSchedule = "*/5 * * * *"
Drupal CMS|.deploy.region = "us-west1"
Drupal CMS|.source.image = "drupal:11"
Drupal CMS|.source.commitSha = "0123456789abcdef0123456789abcdef01234567"
Drupal CMS|.source.branch = "main"
Drupal CMS|.source.repo = "someone/railway-template-drupal-cms"
Drupal CMS|.source.rootDirectory = "/site"
Drupal CMS|.source.branch += "\n"
Drupal CMS|del(.build)
Drupal CMS|.build.builder = "RAILPACK"
Drupal CMS|.build.dockerfilePath = "site/Dockerfile"
Drupal CMS|.build.buildCommand = "echo extra"
Drupal CMS|.build.watchPatterns = ["/**"]
Drupal CMS|.configFile = "/railway.json"
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.defaultValue = "KnownPassword1234567890"
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.defaultValue = "${{secret(8)}}"
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.isOptional = true
Drupal CMS|.variables.DRUPAL_HASH_SALT.defaultValue = "${{secret(16)}}"
Drupal CMS|.variables.DRUPAL_ADMIN_EMAIL.defaultValue = "admin@drupal.local"
Drupal CMS|.variables.DRUPAL_DATABASE_HOST.defaultValue = "${{PostgreSQL.RAILWAY_PUBLIC_DOMAIN}}"
Drupal CMS|.variables.DRUPAL_DATABASE_PASSWORD.defaultValue = "${{secret(32)}}"
Drupal CMS|.variables.DRUPAL_TRUSTED_HOSTS = {defaultValue: ".*", isOptional: false, description: ""}
Drupal CMS|.variables.PORT.defaultValue = 80
Drupal CMS|.variables.PORT.isOptional = "false"
Drupal CMS|del(.variables.PORT.isOptional)
Drupal CMS|del(.variables.DRUPAL_SITE_NAME)
Drupal CMS|.variables.DRUPAL_ADMIN_EMAIL.description = "changed"
Drupal CMS|.networking.serviceDomains["<hasDomain>"].port = 8080
Drupal CMS|.networking.serviceDomains["<hasDomain>"].port = "80"
Drupal CMS|.networking.serviceDomains["<hasDomain>"] += {targetPort: 1}
Drupal CMS|.networking.customDomains = {"cms.example.com": {port: 80}}
Drupal CMS|.networking.tcpProxies = {"80": {}}
Drupal CMS|.volumeMounts |= with_entries(.value.mountPath = "/opt/drupal-cms/web/sites/default/files")
Drupal CMS|.volumeMounts |= with_entries(.value.sizeMB = 500)
Drupal CMS|del(.volumeMounts)
PostgreSQL|.networking.serviceDomains = {"<hasDomain>": {port: 5432}}
PostgreSQL|.networking.tcpProxies = {"5432": {}}
PostgreSQL|.deploy.startCommand = "postgres"
PostgreSQL|.deploy.cronSchedule = "0 * * * *"
PostgreSQL|.variables.POSTGRES_PASSWORD.defaultValue = "${{secret(8)}}"
PostgreSQL|.variables.POSTGRES_HOST_AUTH_METHOD = {defaultValue: "trust", isOptional: false, description: ""}
PostgreSQL|.variables.PGDATA.defaultValue = "/var/lib/postgresql"
PostgreSQL|.source.image = "postgres:18"
PostgreSQL|.source.image = "postgres:18.7-alpine"
PostgreSQL|.source.repo = "someone/postgres"
PostgreSQL|.build = {builder: "NIXPACKS"}
PostgreSQL|del(.volumeMounts)
PostgreSQL|.volumeMounts |= with_entries(.value.sizeMB = 500)
PostgreSQL|.volumeMounts |= with_entries(.value.sizeMB = "5000")
PostgreSQL|.volumeMounts |= with_entries(.value.mountPath = "/var/lib/postgresql/data")
PostgreSQL|.volumeMounts |= with_entries(del(.value.sizeMB))
PostgreSQL|.volumeMounts |= with_entries(.value += {extra: true})
Drupal CMS|.volumeMounts = [.volumeMounts[]]
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.value = "KnownPassword1234567890"
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.generator = "secret(8)"
Drupal CMS|.variables.DRUPAL_ADMIN_PASSWORD.encryptedValue = "x"
Drupal CMS|.networking.extra = {}
PostgreSQL|.cronSchedule = "0 * * * *"
PostgreSQL|.source.image += "\n"
PostgreSQL|.source.image += " "
Drupal CMS|.icon = {"url": "x"}
Drupal CMS|.icon = 1
Drupal CMS|del(.icon)
Drupal CMS|.name += "\n"
Drupal CMS|.volumeMounts |= with_entries(.key = "")
EOF
label="audit rejects services as an array"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.services |= [.[]]' "${work}/restored.json" > "${work}/array.json"; echo "${work}/array.json")" "${root}/scripts/audit-template.sh"
label="audit rejects an added bucket"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.buckets = {"b1": {"name": "x"}}' "${work}/restored.json" > "${work}/bucket.json"; echo "${work}/bucket.json")" "${root}/scripts/audit-template.sh"
label="audit rejects an unknown top-level resource"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.functions = {"f": {}}' "${work}/restored.json" > "${work}/fn.json"; echo "${work}/fn.json")" "${root}/scripts/audit-template.sh"
# Restoration drops stored values, generators and encrypted values, and buckets.
jq '(.data.template.serializedConfig.services[] | select(.name == "Drupal CMS") | .variables.DRUPAL_ADMIN_PASSWORD) = {value: "KnownPassword1234567890", isOptional: true}
  | (.data.template.serializedConfig.services[] | select(.name == "Drupal CMS") | .variables.DRUPAL_ADMIN_EMAIL) = {generator: "secret(8)", encryptedValue: "x"}
  | .data.template.serializedConfig.buckets = {"b1": {"name": "x"}}' "${work}/draft.json" > "${work}/dirty.json"
FAKE_TEMPLATE="${work}/dirty.json" "${root}/scripts/restore-template-draft.sh" test-id test-workspace >/dev/null
label="restore drops stored variable values and buckets"
check bash -c '! grep -q -e KnownPassword -e encryptedValue -e generator -e "\"b1\"" "$1"' _ "${FAKE_REQUEST}"
jq --arg n "$(jq -r .name "${root}/template-listing.json")" '{data:{template:{name:$n,status:"PUBLISHED",serializedConfig:.variables.input.serializedConfig}}}' "${FAKE_REQUEST}" > "${work}/clean.json"
label="the audit accepts the restored dirty draft"; check audit "${work}/clean.json"
label="audit rejects volume IDs shared between services"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.services[].volumeMounts |= with_entries(.key = "shared-volume")' "${work}/restored.json" > "${work}/shared.json"; echo "${work}/shared.json")" "${root}/scripts/audit-template.sh"
label="restore refuses volume IDs shared between services"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id test-workspace >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.services[].volumeMounts |= with_entries(.key = "shared-volume")' "${work}/draft.json" > "${work}/shared-draft.json"; echo "${work}/shared-draft.json")" "${root}/scripts/restore-template-draft.sh"
label="restore refuses an empty volume ID"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id test-workspace >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.services["svc-0"].volumeMounts |= with_entries(.key = "")' "${work}/draft.json" > "${work}/empty-draft.json"; echo "${work}/empty-draft.json")" "${root}/scripts/restore-template-draft.sh"
label="audit rejects buckets set to false"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.buckets = false' "${work}/restored.json" > "${work}/bfalse.json"; echo "${work}/bfalse.json")" "${root}/scripts/audit-template.sh"
leak="$(FAKE_TEMPLATE="$(mutate "Drupal CMS" '.variables.PORT = "AUDIT_LEAK_SCALAR"')" "${root}/scripts/audit-template.sh" test-id 2>&1 || true)"
label="audit rejects a scalar variable without printing it"; check bash -c '[[ "$1" == *"audit: FAIL"* && "$1" != *AUDIT_LEAK_SCALAR* ]]' _ "${leak}"
label="audit rejects a renamed template"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.name = "Drupal"' "${work}/restored.json" > "${work}/renamed.json"; echo "${work}/renamed.json")" "${root}/scripts/audit-template.sh"
label="audit rejects a duplicated service"
check bash -c '! FAKE_TEMPLATE="$1" "$2" test-id >/dev/null 2>&1' _ "$(jq '.data.template.serializedConfig.services["svc-9"] = .data.template.serializedConfig.services["svc-0"]' "${work}/restored.json" > "${work}/dup.json"; echo "${work}/dup.json")" "${root}/scripts/audit-template.sh"

# A rejected deploy block names the differing keys but never prints their values.
leak="$(FAKE_TEMPLATE="$(mutate "PostgreSQL" '.deploy.preDeployCommand = ["migrate --password AUDIT_LEAK_MARKER"]')" "${root}/scripts/audit-template.sh" test-id 2>&1 || true)"
label="audit failure names preDeployCommand without its value"; check bash -c '[[ "$1" == *preDeployCommand* && "$1" != *AUDIT_LEAK_MARKER* ]]' _ "${leak}"

if [[ -f "${root}/tests/fixtures/published-template.json" ]]; then
  label="audit accepts the stored published template"; check audit "${root}/tests/fixtures/published-template.json"
fi

((failures == 0)) || { echo "${failures} test(s) failed"; exit 1; }
echo "All restore/audit regression tests passed."
