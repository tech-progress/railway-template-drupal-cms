#!/usr/bin/env bash
# Clean-state local verification with Docker Compose: a fresh image build,
# fresh random secrets in a 0600 file, empty Railway-shaped volumes, the smoke
# setup through the edge stand-in (with the per-visitor flood test), forged
# forwarding and Host headers sent straight to Drupal, a restart of every
# container and a recreation of the Drupal container with readback after
# each, a database-down health probe and recovery, resource use, a secret scan
# of every log and of every process environment, the volume layout, clean
# stops, and teardown.
# Usage: ./scripts/local-check.sh   (prints no secret)
set -euo pipefail
exec </dev/null
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
work="$(mktemp -d)"
project="drupal-check-$$"
compose=(docker compose -p "${project}" --env-file "${work}/local.env")
cleanup() { "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "${work:?}"; }
trap cleanup EXIT

gen() { python3 -I -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))))' "$1"; }
( umask 077
  { echo "POSTGRES_PASSWORD=$(gen 32)"
    echo "DRUPAL_HASH_SALT=$(gen 64)"
    echo "DRUPAL_ADMIN_PASSWORD=$(gen 32)"
    echo "DRUPAL_LOCAL_PORT=${DRUPAL_LOCAL_PORT:-18720}"
    echo "DRUPAL_DIRECT_PORT=${DRUPAL_DIRECT_PORT:-18721}"; } > "${work}/local.env"
  sed -n 's/^DRUPAL_ADMIN_PASSWORD=//p' "${work}/local.env" > "${work}/admin-password" )
set -a; . "${work}/local.env"; set +a
edge="https://127.0.0.1:${DRUPAL_LOCAL_PORT}"
direct="http://127.0.0.1:${DRUPAL_DIRECT_PORT}"

smoke() {
  BASE_URL="${edge}" ADMIN_PASSWORD_FILE="${work}/admin-password" STATE_FILE="${work}/state.json" \
    INSECURE_TLS=1 CLIENT_HEADER=1 FLOOD_TEST="${2:-0}" timeout 1200 python3 -I scripts/smoke.py "$1"
}
container() { docker ps -aq --filter "label=com.docker.compose.project=${project}" --filter "label=com.docker.compose.service=$1"; }
fail() { echo "local-check: FAIL $*" >&2; exit 1; }

"${compose[@]}" build --no-cache --pull drupal >/dev/null 2>&1 || fail "the image does not build"
echo "local-check: ok the image builds from a clean cache"
# Known advisories for the locked packages fail the release (not the image
# build, which would break new deployments whenever an advisory appears).
docker run --rm --network bridge -e COMPOSER_HOME=/tmp/c -v "${root}/site:/app:ro" -w /app --entrypoint composer \
  "$(sed -n 's/^FROM \([^ ]*\) AS build$/\1/p' Dockerfile)" audit --locked --no-dev --format=plain >/dev/null 2>&1 \
  || fail "composer audit reports advisories for site/composer.lock"
echo "local-check: ok composer audit reports no advisories for the locked packages"
"${compose[@]}" up -d >/dev/null 2>&1
smoke setup 1

# Straight to Drupal, as a service on the private network would reach it:
# forged host, port and prefix headers must not reach the redirect target,
# and a Host Drupal does not trust is refused.
location="$(curl -s -o /dev/null -w '%{redirect_url}' "${direct}/user" -H 'X-Forwarded-Proto: https' \
  -H 'X-Forwarded-Host: evil.example' -H 'X-Forwarded-Port: 4444' -H 'X-Forwarded-Prefix: /evil' -H 'Forwarded: host=evil.example;proto=http')"
[[ "${location}" == "https://127.0.0.1:${DRUPAL_DIRECT_PORT}/user/login" ]] \
  || fail "a direct request with forged forwarding headers redirected to ${location}"
code="$(curl -s -o /dev/null -w '%{http_code}' "${direct}/user/login" -H 'Host: evil.example')"
[[ "${code}" == 400 ]] || fail "a request for an untrusted Host answered ${code}"
echo "local-check: ok forged X-Forwarded-Host, -Port, -Prefix and Forwarded do not steer Drupal's URLs, and an untrusted Host gets 400"

"${compose[@]}" restart postgres drupal edge >/dev/null 2>&1
smoke readback
"${compose[@]}" up -d --force-recreate --no-deps drupal >/dev/null 2>&1
smoke readback
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' | grep "${project}" | sed "s/${project}-//"

# The health check path fails while PostgreSQL is down, so Railway cannot
# promote a Drupal that cannot reach its database, and Drupal recovers by
# itself when the database returns.
docker stop -t 30 "$(container postgres)" >/dev/null
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${direct}/user/login" || true)"
[[ "${code}" != 200 ]] || fail "/user/login answered 200 with PostgreSQL stopped"
echo "local-check: ok the health check path fails (HTTP ${code}) while PostgreSQL is down"
docker start "$(container postgres)" >/dev/null
for _ in $(seq 1 60); do [[ "$(curl -s -o /dev/null -w '%{http_code}' "${direct}/user/login")" == 200 ]] && break; sleep 2; done
[[ "$(curl -s -o /dev/null -w '%{http_code}' "${direct}/user/login")" == 200 ]] || fail "Drupal did not recover after PostgreSQL returned"
echo "local-check: ok Drupal recovers when PostgreSQL returns"

# The recreated container runs its first cron 60 seconds after it starts serving.
for _ in $(seq 1 30); do grep -q 'drupal-start: cron run completed' <<<"$(docker logs "$(container drupal)" 2>&1)" && break; sleep 5; done

# Secret scan: exactly one container per service, each log read successfully
# and non-trivially, and no generated value in any of them.
for service in drupal postgres edge; do
  ids="$(container "${service}")"
  [[ "$(wc -w <<<"${ids}")" == 1 ]] || fail "expected one ${service} container"
  docker logs "${ids}" > "${work}/${service}.log" 2>&1 || fail "cannot read the ${service} log"
  (( $(wc -l < "${work}/${service}.log") >= 5 )) || fail "the ${service} log is too short"
  for name in POSTGRES_PASSWORD DRUPAL_HASH_SALT DRUPAL_ADMIN_PASSWORD; do
    if grep -qF -- "${!name}" "${work}/${service}.log"; then fail "${name} appears in the ${service} log"; fi
  done
done
grep -q 'drupal-start: cron run completed' "${work}/drupal.log" || fail "the drupal log has no completed cron run"
echo "local-check: ok no generated secret in the drupal, postgres or edge logs, and cron runs"

# Process environments: PID 1 and every descendant (Apache, its workers, the
# cron loop) is read with ptrace rights, at least five of them, and none holds
# the administrator password. Zombie children of PID 1 would mean the
# supervisor does not reap.
docker exec --privileged -e "NEEDLE=DRUPAL_ADMIN_PASSWORD=${DRUPAL_ADMIN_PASSWORD}" "$(container drupal)" php -r '
  $parent = []; foreach (glob("/proc/[0-9]*/stat") as $f) { $s = @file_get_contents($f); if ($s === false) continue;
    $s = substr($s, strrpos($s, ")") + 2); $p = explode(" ", $s); $parent[(int) basename(dirname($f))] = [(int) $p[1], $p[0]]; }
  $tree = [1]; do { $n = count($tree); foreach ($parent as $pid => [$pp, $st]) if (in_array($pp, $tree, true) && !in_array($pid, $tree, true)) $tree[] = $pid; } while (count($tree) > $n);
  $read = 0; $zombies = 0;
  foreach ($tree as $pid) { if (($parent[$pid][1] ?? "") === "Z") { if (($parent[$pid][0] ?? 0) === 1) $zombies++; continue; }
    $env = @file_get_contents("/proc/$pid/environ"); if ($env === false) { fwrite(STDERR, "cannot read $pid\n"); exit(2); }
    $read++; if (str_contains($env, getenv("NEEDLE"))) { fwrite(STDERR, "pid $pid holds the administrator password\n"); exit(1); } }
  if ($read < 5) { fwrite(STDERR, "read only $read processes\n"); exit(3); }
  if ($zombies > 0) { fwrite(STDERR, "$zombies zombie children of PID 1\n"); exit(4); }
  echo "read $read processes\n";' >/dev/null || fail "a process environment holds the administrator password, could not be read, or PID 1 leaves zombies"
echo "local-check: ok no process under PID 1 holds the administrator password, and PID 1 reaps its children"

# The volume: Drupal's public files with the uploaded logo, the private and
# configuration directories, and the wrapper's root-only install record.
docker exec "$(container drupal)" bash -c '
  d=/var/lib/drupal
  [[ "$(stat -c "%U %a" $d/template-state)" == "root 700" && -s $d/template-state/installed && ! -e $d/template-state/install-started ]] || exit 1
  [[ "$(stat -c %U $d/files)" == www-data && -d $d/private && -d $d/config/sync ]] || exit 2
  ls $d/files/smoke-logo-*.png >/dev/null 2>&1 || exit 3
  [[ "$(readlink /opt/drupal-cms/web/sites/default/files)" == "$d/files" ]] || exit 4
  [[ "$(stat -c "%U %a" /opt/drupal-cms/web/sites/default/settings.php)" == "root 444" ]] || exit 5
  ! setpriv --reuid=www-data --regid=www-data --init-groups -- test -w /opt/drupal-cms/web/core || exit 6' \
  || fail "the volume layout, install record or read-only code differs (exit $?)"
echo "local-check: ok the volume holds the files, private and config directories and the install record; the code is read-only to www-data"

# Clean stops: each container exits 0 well within the stop timeout.
for service in drupal postgres; do
  id="$(container "${service}")"; started=${SECONDS}
  docker stop -t 30 "${id}" >/dev/null
  code="$(docker inspect "${id}" --format '{{.State.ExitCode}}')"
  [[ "${code}" == 0 ]] && (( SECONDS - started < 15 )) || fail "${service} stopped with ${code} after $((SECONDS - started))s"
done
echo "local-check: ok Drupal and PostgreSQL stop cleanly with status 0"
echo "local-check: passed"
