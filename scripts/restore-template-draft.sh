#!/usr/bin/env bash
# Restores the Drupal CMS draft to the checked-in contract through the
# Template Composer operation (templateUpsertConfig): the Drupal CMS
# repository source and Dockerfile build in place of its seed image, the
# PostgreSQL image, whole deploy blocks (health check, one replica, restart
# policy), variable defaults (generated secrets and references), descriptions,
# volume sizes, and the single public domain. Prints no secret.
# Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID
set -euo pipefail
template_id="${1:?Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID}"
workspace_id="${2:?Usage: ./scripts/restore-template-draft.sh TEMPLATE_ID WORKSPACE_ID}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="$(jq -r '.name' "${root}/template-listing.json")"
token="${RAILWAY_API_TOKEN:-$(jq -r '.user.accessToken' "${RAILWAY_CONFIG_PATH:-${HOME}/.railway/config.json}")}"

# Compile the IaC without host credentials, keeping each service's source,
# build and deploy settings (the source without the SDK's "type" tag).
desired="$("${root}/scripts/iac-graph.sh" | jq -c '[.graph.resources[] | select(.type == "service")
  | {key: .name, value: {source: (.source | del(.type)), build, deploy}}] | from_entries')"
draft="$(railway api 'query Draft($id:String!){template(id:$id){serializedConfig}}' --var "id=${template_id}" --compact)"

# The draft travels on stdin: it may carry resolved values.
variables="$(jq -c --argjson desired "${desired}" \
  --slurpfile defaults "${root}/template-defaults.json" \
  --slurpfile descriptions "${root}/template-descriptions.json" \
  --slurpfile volumes "${root}/template-volumes.json" \
  --slurpfile networking "${root}/template-networking.json" \
  --arg id "${template_id}" --arg workspaceId "${workspace_id}" --arg name "${name}" '
  .data.template.serializedConfig as $config
  | if ($config.services | type) != "object" then error("Draft services must be an ID-keyed object")
    elif (($config.services | map(.name) | sort) != ($desired | keys | sort)) then error("Draft service set mismatch")
    elif ([$config.services[] | (.volumeMounts // {}) | if type == "object" then keys[] else error("Draft volume mounts must be objects") end] as $ids
          | ($ids | any(length == 0)) or ($ids | length) != ($ids | unique | length)) then error("Draft volume IDs must be nonempty and unique")
    # Keep only the services; no bucket or other top-level resource survives.
    else reduce ($config.services | to_entries[]) as $s ({services: $config.services, buckets: {}};
      $desired[$s.value.name] as $want
      | .services[$s.key] |= {name, icon: null, source, deploy, variables, networking, volumeMounts}
      # Set the source wholesale: an image service gets exactly its image and
      # no build block; the repository service gets exactly repo, branch and
      # root directory (no commit pin, no seed image) and the IaC build block.
      | if $want.source.image != null then
          .services[$s.key].source = {image: $want.source.image}
        else
          .services[$s.key].source = {repo: $want.source.repo, branch: $want.source.branch, rootDirectory: $want.source.rootDirectory}
          | .services[$s.key].build = $want.build
        end
      # Replace the whole deploy block so inherited settings (pre-deploy
      # commands, cron schedules, replica counts, regions) cannot survive.
      | .services[$s.key].deploy = {
          startCommand: ($want.deploy.startCommand // null),
          healthcheckPath: ($want.deploy.healthcheckPath // null),
          healthcheckTimeout: ($want.deploy.healthcheckTimeout // null),
          numReplicas: 1, restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10}
      # Rebuild every variable from the approved fields only, so no stored
      # value, generator or encrypted value from the draft can survive.
      | .services[$s.key].variables = reduce (($defaults[0][$s.value.name] // {}) | to_entries[]) as $v ({};
          .[$v.key] = {defaultValue: $v.value, isOptional: false,
            description: ($descriptions[0][$s.value.name][$v.key] // "")})
      | if $volumes[0][$s.value.name] != null then
          if (.services[$s.key].volumeMounts | type) != "object" or (.services[$s.key].volumeMounts | length) != 1
          then error("Draft volume mount missing for " + $s.value.name)
          else .services[$s.key].volumeMounts |= with_entries(
            .value = {mountPath: $volumes[0][$s.value.name].mountPath, sizeMB: $volumes[0][$s.value.name].sizeMB}) end
        else del(.services[$s.key].volumeMounts) end
      # Replace the whole networking object so no custom domain or TCP proxy survives.
      | if $networking[0][$s.value.name].publicPort != null
        then .services[$s.key].networking = {serviceDomains: {"<hasDomain>": {port: $networking[0][$s.value.name].publicPort}}, customDomains: {}, tcpProxies: {}}
        else .services[$s.key].networking = {serviceDomains: {}, customDomains: {}, tcpProxies: {}} end)
      | {id: $id, input: {name: $name, workspaceId: $workspaceId, serializedConfig: .}}
    end' <<<"${draft}")"

internal() {
  curl --compressed --fail --silent --show-error https://backboard.railway.com/graphql/internal \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${token}") -H 'Content-Type: application/json' --data-binary @- <<<"$1"
}
request="$(jq -c --arg query 'mutation Update($id:String!,$input:TemplateUpsertConfigInput!){templateUpsertConfig(id:$id,input:$input){id code}}' '{query:$query,variables:.}' <<<"${variables}")"
internal "${request}" | jq -e '.data.templateUpsertConfig.id != null and ((.errors // []) | length == 0)' >/dev/null
settings="$(jq -nc --arg id "${template_id}" --arg workspaceId "${workspace_id}" --arg name "${name}" --arg query 'mutation Settings($id:String!,$input:TemplateUpsertSettingsInput!){templateUpsertSettings(id:$id,input:$input){id name}}' '{query:$query,variables:{id:$id,input:{name:$name,workspaceId:$workspaceId}}}')"
internal "${settings}" | jq -e --arg name "${name}" '.data.templateUpsertSettings.name == $name and ((.errors // []) | length == 0)' >/dev/null
echo "Restored ${name} draft ${template_id}."
