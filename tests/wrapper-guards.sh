#!/usr/bin/env bash
# Start-wrapper refusals: every malformed setting makes drupal-start exit 64
# with a message that names the setting and never prints its value, before
# Apache starts. Administrator settings are checked only when an install is
# needed, so those cases run against an empty PostgreSQL. A stop during the
# wait for PostgreSQL ends the container at once.
# Usage: ./tests/wrapper-guards.sh [IMAGE]   (default drupal-cms-template:local)
set -euo pipefail
exec </dev/null
image="${1:-drupal-cms-template:local}"
net=drupal-guards-net pg=drupal-guards-pg
cleanup() {
  docker rm -f drupal-guards-pg drupal-guards-stop >/dev/null 2>&1 || true
  docker network rm drupal-guards-net >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker image inspect "${image}" >/dev/null 2>&1 || { echo "wrapper-guards: build ${image} first (scripts/local-check.sh or docker compose build)" >&2; exit 1; }

secret="GuardSecret$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
docker network create "${net}" >/dev/null
docker run -d --name "${pg}" --network "${net}" --memory 256m -e POSTGRES_DB=drupal -e POSTGRES_USER=drupal \
  -e POSTGRES_PASSWORD="${secret}" postgres:18.7-alpine@sha256:0115267ab5a509022df9319c77be365cef335adb71556c75f60f5360ee247e71 >/dev/null
for _ in $(seq 1 30); do docker exec "${pg}" pg_isready -U drupal -d drupal -q && break; sleep 1; done

base=(PORT=80 DRUPAL_DATABASE_HOST="${pg}" DRUPAL_DATABASE_PORT=5432 DRUPAL_DATABASE_NAME=drupal DRUPAL_DATABASE_USER=drupal
  DRUPAL_DATABASE_PASSWORD="${secret}" DRUPAL_HASH_SALT="${secret}${secret}" DRUPAL_ADMIN_USER=admin
  DRUPAL_ADMIN_EMAIL=admin@example.com DRUPAL_ADMIN_PASSWORD="${secret}" DRUPAL_SITE_NAME="Drupal CMS" DRUPAL_TRUSTED_HOSTS=)
passed=0
# case NAME EXPECTED_MESSAGE MOUNT [KEY=VALUE...]: VALUE "-" removes KEY.
case_() {
  local name="$1" expect="$2" mount="$3"; shift 3
  local -A env=()
  local kv
  for kv in "${base[@]}"; do env["${kv%%=*}"]="${kv#*=}"; done
  for kv in "$@"; do if [[ "${kv#*=}" == - ]]; then unset "env[${kv%%=*}]"; else env["${kv%%=*}"]="${kv#*=}"; fi; done
  local args=() key
  for key in "${!env[@]}"; do args+=(-e "${key}=${env[${key}]}"); done
  case "${mount}" in
    tmpfs) args+=(--mount type=tmpfs,dst=/var/lib/drupal) ;;
    none) ;;
    symlink) args+=(--mount type=tmpfs,dst=/var/lib/drupal --entrypoint /bin/bash) ;;
  esac
  local out status=0
  if [[ "${mount}" == symlink ]]; then
    out="$(timeout 120 docker run --rm --network "${net}" "${args[@]}" "${image}" -c 'ln -s /tmp /var/lib/drupal/files; exec /usr/local/bin/drupal-start' 2>&1)" || status=$?
  else
    out="$(timeout 120 docker run --rm --network "${net}" "${args[@]}" "${image}" 2>&1)" || status=$?
  fi
  [[ "${status}" == 64 ]] || { echo "wrapper-guards: FAIL ${name}: exit ${status}, expected 64" >&2; printf '%s\n' "${out}" | tail -n 5 >&2; exit 1; }
  grep -qF -- "${expect}" <<<"${out}" || { echo "wrapper-guards: FAIL ${name}: message lacks '${expect}'" >&2; printf '%s\n' "${out}" | tail -n 5 >&2; exit 1; }
  ! grep -qF -- "${secret}" <<<"${out}" || { echo "wrapper-guards: FAIL ${name}: output contains the secret" >&2; exit 1; }
  grep -q 'serving on port 80' <<<"${out}" && { echo "wrapper-guards: FAIL ${name}: Apache started" >&2; exit 1; }
  passed=$((passed + 1))
}

case_ "port unset" "PORT must be 80" tmpfs PORT=-
case_ "port 8080" "PORT must be 80" tmpfs PORT=8080
case_ "database host unset" "DRUPAL_DATABASE_HOST" tmpfs DRUPAL_DATABASE_HOST=-
case_ "database host with a slash" "DRUPAL_DATABASE_HOST" tmpfs DRUPAL_DATABASE_HOST=evil/host
case_ "database port 0" "DRUPAL_DATABASE_PORT" tmpfs DRUPAL_DATABASE_PORT=0
case_ "database port 70000" "DRUPAL_DATABASE_PORT" tmpfs DRUPAL_DATABASE_PORT=70000
case_ "database name with a quote" "DRUPAL_DATABASE_NAME" tmpfs "DRUPAL_DATABASE_NAME=dru'pal"
case_ "database user unset" "DRUPAL_DATABASE_USER" tmpfs DRUPAL_DATABASE_USER=-
case_ "database password short" "DRUPAL_DATABASE_PASSWORD" tmpfs DRUPAL_DATABASE_PASSWORD=short
case_ "database password with a space" "DRUPAL_DATABASE_PASSWORD" tmpfs "DRUPAL_DATABASE_PASSWORD=${secret} x"
case_ "hash salt unset" "DRUPAL_HASH_SALT" tmpfs DRUPAL_HASH_SALT=-
case_ "hash salt short" "DRUPAL_HASH_SALT" tmpfs DRUPAL_HASH_SALT=abcdefghijklmnopqrstuvwxyz
case_ "trusted hosts with a space" "DRUPAL_TRUSTED_HOSTS" tmpfs "DRUPAL_TRUSTED_HOSTS=a.example, b.example"
case_ "trusted hosts with a pattern" "DRUPAL_TRUSTED_HOSTS" tmpfs "DRUPAL_TRUSTED_HOSTS=^.*$"
case_ "reset flag yes" "DRUPAL_RESET_ADMIN_PASSWORD" tmpfs DRUPAL_RESET_ADMIN_PASSWORD=yes
case_ "no volume" "no volume is mounted" none
case_ "files directory is a symbolic link" "is a symbolic link" symlink
case_ "admin user unset" "DRUPAL_ADMIN_USER" tmpfs DRUPAL_ADMIN_USER=-
case_ "admin user starting with -" "DRUPAL_ADMIN_USER" tmpfs DRUPAL_ADMIN_USER=-admin
case_ "admin user with a space" "DRUPAL_ADMIN_USER" tmpfs "DRUPAL_ADMIN_USER=site admin"
case_ "admin email unset" "DRUPAL_ADMIN_EMAIL" tmpfs DRUPAL_ADMIN_EMAIL=-
case_ "admin email without a domain" "DRUPAL_ADMIN_EMAIL" tmpfs DRUPAL_ADMIN_EMAIL=admin@localhost
case_ "admin password unset" "DRUPAL_ADMIN_PASSWORD" tmpfs DRUPAL_ADMIN_PASSWORD=-
case_ "admin password short" "DRUPAL_ADMIN_PASSWORD" tmpfs DRUPAL_ADMIN_PASSWORD=shortpassword
case_ "admin password with a no-break space" "DRUPAL_ADMIN_PASSWORD" tmpfs "DRUPAL_ADMIN_PASSWORD=${secret}$(printf '\302\240')x"
case_ "site name unset" "DRUPAL_SITE_NAME" tmpfs DRUPAL_SITE_NAME=-
case_ "site name starting with -" "DRUPAL_SITE_NAME" tmpfs "DRUPAL_SITE_NAME=--yes"
# None of the administrator cases may have touched the empty database.
[[ "$(docker exec "${pg}" psql -U drupal -d drupal -Atc "select count(*) from pg_tables where schemaname='public'")" == 0 ]] \
  || { echo "wrapper-guards: FAIL a refused start wrote to the database" >&2; exit 1; }

# A stop while waiting for PostgreSQL (here an unresolvable host) ends the
# container within two seconds instead of waiting for the kill timeout.
stop_args=()
for kv in "${base[@]}"; do [[ "${kv}" == DRUPAL_DATABASE_HOST=* ]] || stop_args+=(-e "${kv}"); done
docker run -d --name drupal-guards-stop --network "${net}" --mount type=tmpfs,dst=/var/lib/drupal \
  "${stop_args[@]}" -e DRUPAL_DATABASE_HOST=nowhere.invalid "${image}" >/dev/null
for _ in $(seq 1 30); do grep -q 'waiting for PostgreSQL' <<<"$(docker logs drupal-guards-stop 2>&1)" && break; sleep 1; done
sleep 4
started=${SECONDS}
docker stop -t 20 drupal-guards-stop >/dev/null
(( SECONDS - started <= 2 )) || { echo "wrapper-guards: FAIL a stop during the PostgreSQL wait took $((SECONDS - started))s" >&2; exit 1; }
grep -q 'stopped during setup' <<<"$(docker logs drupal-guards-stop 2>&1)" || { echo "wrapper-guards: FAIL the wrapper did not handle the stop signal" >&2; exit 1; }
[[ "$(docker inspect drupal-guards-stop --format '{{.Config.StopSignal}}')" == SIGTERM ]] || { echo "wrapper-guards: FAIL the image does not stop with SIGTERM" >&2; exit 1; }
passed=$((passed + 1))
# The base image's SIGWINCH (a platform that keeps the base image's stop
# signal) stops it as well.
docker rm -f drupal-guards-stop >/dev/null
docker run -d --name drupal-guards-stop --network "${net}" --mount type=tmpfs,dst=/var/lib/drupal \
  "${stop_args[@]}" -e DRUPAL_DATABASE_HOST=nowhere.invalid "${image}" >/dev/null
for _ in $(seq 1 30); do grep -q 'waiting for PostgreSQL' <<<"$(docker logs drupal-guards-stop 2>&1)" && break; sleep 1; done
docker kill --signal WINCH drupal-guards-stop >/dev/null
for _ in $(seq 1 20); do [[ "$(docker inspect drupal-guards-stop --format '{{.State.Running}}')" == false ]] && break; sleep 0.1; done
[[ "$(docker inspect drupal-guards-stop --format '{{.State.Running}}')" == false ]] || { echo "wrapper-guards: FAIL SIGWINCH did not stop the wrapper" >&2; exit 1; }
passed=$((passed + 1))
echo "wrapper-guards: passed (${passed} cases)"
