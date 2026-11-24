#!/usr/bin/env bash
# Audits Railway's stored serializedConfig for the Drupal CMS template against
# the checked-in IaC and template-*.json files. Compares JSON values (never
# strings), names mismatched fields only and never prints a resolved value.
# Usage: ./scripts/audit-template.sh TEMPLATE_ID [EXPECTED_STATUS]
set -euo pipefail
template_id="${1:?Usage: ./scripts/audit-template.sh TEMPLATE_ID [EXPECTED_STATUS]}"
expected_status="${2:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="$(jq -r '.name' "${root}/template-listing.json")"
fail() { echo "audit: FAIL $*" >&2; exit 1; }

template="$(railway api 'query Audit($id:String!){template(id:$id){name status serializedConfig}}' --var "id=${template_id}" --compact)"
graph="$("${root}/scripts/iac-graph.sh")"

[[ "$(jq -c '.data.template.name' <<<"${template}")" == "$(jq -cn --arg v "${name}" '$v')" ]] || fail "template name"
[[ -z "${expected_status}" || "$(jq -c '.data.template.status' <<<"${template}")" == "$(jq -cn --arg v "${expected_status}" '$v')" ]] || fail "status"
# The graph's shape: only services and an empty bucket set at the top, services
# as an ID-keyed object, no service key outside the known set, and nonempty,
# globally unique volume mount IDs.
jq -e '.data.template.serializedConfig | type == "object"
  and ((keys - ["services", "buckets"]) | length) == 0
  and ((has("buckets") | not) or .buckets == {})
  and (.services | type) == "object"
  and all(.services[]; type == "object" and ((keys - ["name", "icon", "source", "build", "deploy", "variables", "networking", "volumeMounts"]) | length) == 0
    and has("icon") and (.icon == null) and (.name | type) == "string"
    and ((.variables | type) == "object") and all(.variables[]; type == "object"))
  and ([.services[] | (.volumeMounts // {}) | if type == "object" then keys[] else error("mounts") end] as $ids
    | ($ids | all(length > 0)) and ($ids | length) == ($ids | unique | length))' \
  <<<"${template}" >/dev/null 2>&1 || fail "graph shape (top-level resources, service keys, icons, ID-keyed services or unique volume IDs)"
[[ "$(jq -c '.data.template.serializedConfig.services | map(.name) | sort' <<<"${template}")" \
  == "$(jq -c '[.graph.resources[] | select(.type == "service") | .name] | sort' <<<"${graph}")" ]] || fail "service set"
[[ "$(jq -c '[.graph.resources[] | select(.type == "service") | .name] | sort' <<<"${graph}")" == '["Drupal CMS","PostgreSQL"]' ]] || fail "IaC service set"

while IFS= read -r service; do
  desired="$(jq -c --arg n "${service}" '.graph.resources[] | select(.type == "service" and .name == $n)' <<<"${graph}")"
  actual="$(jq -c --arg n "${service}" '[.data.template.serializedConfig.services[] | select(.name == $n)] | if length == 1 then .[0] else error("duplicate") end' <<<"${template}" 2>/dev/null)" \
    || fail "${service} appears more than once"
  # The whole source object, as JSON: exactly the pinned image, or exactly the
  # repository, release branch and root directory (no commit pin or seed image).
  if [[ "$(jq -r '.source.image // ""' <<<"${desired}")" != "" ]]; then
    [[ "$(jq -cS '.source' <<<"${actual}")" == "$(jq -cS '{image: .source.image}' <<<"${desired}")" ]] || fail "${service} image or mixed source"
    [[ "$(jq -r 'has("build")' <<<"${actual}")" == false ]] || fail "${service} build settings"
  else
    [[ "$(jq -cS '.source' <<<"${actual}")" == "$(jq -cS '.source | {repo, branch, rootDirectory}' <<<"${desired}")" ]] || fail "${service} repository source"
    [[ "$(jq -cS '.source' <<<"${actual}")" == '{"branch":"release-v1","repo":"tech-progress/railway-template-drupal-cms","rootDirectory":"/"}' ]] || fail "${service} repository source literal"
    [[ "$(jq -cS '.build' <<<"${actual}")" == "$(jq -cS '.build' <<<"${desired}")" ]] || fail "${service} build block"
  fi

  # The deploy block must be exactly this; any other key fails.
  expected_deploy="$(jq -cS '{startCommand: (.deploy.startCommand // null), healthcheckPath: (.deploy.healthcheckPath // null),
    healthcheckTimeout: (.deploy.healthcheckTimeout // null), numReplicas: 1, restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10}' <<<"${desired}")"
  [[ "$(jq -cS '.deploy' <<<"${actual}")" == "${expected_deploy}" ]] \
    || fail "${service} deploy block differs in: $(jq -r --argjson e "${expected_deploy}" '(.deploy // {}) as $a | if ($a | type) != "object" then "deploy" else ([$a, $e] | map(keys) | add | unique) | map(select($a[.] != $e[.])) | join(", ") end' <<<"${actual}")"

  volume="$(jq -c --arg n "${service}" '.[$n] // null' "${root}/template-volumes.json")"
  if [[ "${volume}" == null ]]; then
    [[ "$(jq -r '(.volumeMounts // {}) | length' <<<"${actual}")" == 0 ]] || fail "${service} unexpected volume"
  else
    [[ "$(jq -r '.volumeMounts | type' <<<"${actual}")" == object ]] || fail "${service} volume mounts are not an object"
    [[ "$(jq -cS '[(.volumeMounts | length), (.volumeMounts | to_entries[0].value)]' <<<"${actual}")" \
      == "$(jq -cS '[1, {mountPath, sizeMB}]' <<<"${volume}")" ]] || fail "${service} volume"
  fi

  expected_domains="$(jq -cS --arg n "${service}" 'if .[$n].publicPort != null then {"<hasDomain>": {port: .[$n].publicPort}} else {} end' "${root}/template-networking.json")"
  [[ "$(jq -cS '.networking' <<<"${actual}")" == "$(jq -cS --argjson d "${expected_domains}" -n '{serviceDomains: $d, customDomains: {}, tcpProxies: {}}')" ]] \
    || fail "${service} networking (exactly the expected service domain, no custom domain or TCP proxy)"

  [[ "$(jq -c '(.variables // {}) | keys | sort' <<<"${actual}")" == "$(jq -c --arg n "${service}" '.[$n] | keys | sort' "${root}/template-defaults.json")" ]] \
    || fail "${service} variable set"
  # Each variable is exactly {defaultValue, description, isOptional}: a stored
  # value, generator or encrypted value fails, whatever it holds.
  [[ "$(jq -r '[.variables[] | keys | sort == ["defaultValue", "description", "isOptional"]] | all' <<<"${actual}")" == true ]] \
    || fail "${service} variable fields (only defaultValue, description and isOptional are allowed)"
  while IFS= read -r key; do
    [[ "$(jq -c --arg k "${key}" '.variables[$k].defaultValue' <<<"${actual}")" == "$(jq -c --arg n "${service}" --arg k "${key}" '.[$n][$k]' "${root}/template-defaults.json")" ]] \
      || fail "${service} ${key} default"
    [[ "$(jq -c --arg k "${key}" '.variables[$k].description' <<<"${actual}")" == "$(jq -c --arg n "${service}" --arg k "${key}" '.[$n][$k]' "${root}/template-descriptions.json")" ]] \
      || fail "${service} ${key} description"
    [[ "$(jq -c --arg k "${key}" '.variables[$k] | if has("isOptional") then .isOptional else "missing" end' <<<"${actual}")" == false ]] || fail "${service} ${key} optional"
  done < <(jq -r --arg n "${service}" '.[$n] | keys[]' "${root}/template-defaults.json")
done < <(jq -r '[.graph.resources[] | select(.type == "service") | .name] | sort | .[]' <<<"${graph}")

echo "Template ${template_id} matches the complete ${name} contract."
