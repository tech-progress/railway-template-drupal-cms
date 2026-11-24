#!/usr/bin/env bash
# The install decisions in drupal-start, one case per branch, against a real
# PostgreSQL and real volumes:
#   1. a container killed (SIGKILL) during `drush site:install` leaves the
#      install-started record; the next boot clears the tables and installs
#      again, and the administrator gets the configured password;
#   2. an install that finished but whose provisioning did not (install-started
#      record, no installed record) is resumed: the password is set again;
#   3. a complete Drupal database met by a volume without any record is
#      adopted, and the administrator password is left unchanged;
#   4. a volume with the installed record and an empty database is refused
#      (exit 64): never reinstall over a site's files;
#   5. a database with tables but no finished installation, and a volume
#      without records, is refused and left untouched;
#   3b. DRUPAL_RESET_ADMIN_PASSWORD=1 restores the configured password;
#   6, 7. an install record left on a volume never clears or re-provisions a
#      database the install did not start on.
# Usage: ./tests/install-recovery.sh [IMAGE]   (default drupal-cms-template:local)
set -euo pipefail
exec </dev/null
image="${1:-drupal-cms-template:local}"
cleanup() {
  docker rm -f drupal-recovery-web drupal-recovery-pg >/dev/null 2>&1 || true
  docker volume rm drupal-recovery-a drupal-recovery-b drupal-recovery-c >/dev/null 2>&1 || true
  docker network rm drupal-recovery-net >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker image inspect "${image}" >/dev/null 2>&1 || { echo "install-recovery: build ${image} first" >&2; exit 1; }
fail() { echo "install-recovery: FAIL $*" >&2; docker logs drupal-recovery-web 2>&1 | tail -n 8 >&2 || true; exit 1; }

secret="Recovery$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
admin_password="Admin$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
other_password="Other$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
docker network create drupal-recovery-net >/dev/null
for v in a b c; do docker volume create "drupal-recovery-${v}" >/dev/null; done
docker run -d --name drupal-recovery-pg --network drupal-recovery-net --memory 384m -e POSTGRES_DB=drupal -e POSTGRES_USER=drupal \
  -e POSTGRES_PASSWORD="${secret}" postgres:18.7-alpine@sha256:0115267ab5a509022df9319c77be365cef335adb71556c75f60f5360ee247e71 >/dev/null
for _ in $(seq 1 30); do docker exec drupal-recovery-pg pg_isready -U drupal -d drupal -q && break; sleep 1; done
sleep 2

env_args=(-e PORT=80 -e DRUPAL_DATABASE_HOST=drupal-recovery-pg -e DRUPAL_DATABASE_PORT=5432 -e DRUPAL_DATABASE_NAME=drupal
  -e DRUPAL_DATABASE_USER=drupal -e DRUPAL_DATABASE_PASSWORD="${secret}" -e DRUPAL_HASH_SALT="${secret}${secret}"
  -e DRUPAL_ADMIN_USER=admin -e DRUPAL_ADMIN_EMAIL=admin@example.com -e DRUPAL_ADMIN_PASSWORD="${admin_password}"
  -e "DRUPAL_SITE_NAME=Drupal CMS")
start() { local volume="$1"; shift; docker rm -f drupal-recovery-web >/dev/null 2>&1 || true
  docker run -d --name drupal-recovery-web --network drupal-recovery-net --memory 1536m "${env_args[@]}" "$@" \
    -v "drupal-recovery-${volume}:/var/lib/drupal" "${image}" >/dev/null; }
refused() { docker rm -f drupal-recovery-web >/dev/null 2>&1 || true
  local out status=0
  out="$(timeout 120 docker run --name drupal-recovery-web --network drupal-recovery-net "${env_args[@]}" \
    -v "drupal-recovery-$1:/var/lib/drupal" "${image}" 2>&1)" || status=$?
  [[ "${status}" == 64 ]] || fail "case $2: exit ${status}, expected 64"
  grep -qF -- "$3" <<<"${out}" || fail "case $2: the refusal does not say '$3'"
  ! grep -q 'serving on port 80' <<<"${out}" || fail "case $2: Apache started"; }
wait_log() { local i; for i in $(seq 1 "${2:-180}"); do grep -qF -- "$1" <<<"$(docker logs drupal-recovery-web 2>&1)" && return 0
  [[ "$(docker inspect drupal-recovery-web --format '{{.State.Running}}')" == true ]] || fail "the container exited before '$1'"; sleep 1; done
  fail "no '$1' in the log"; }
db() { docker run --rm --network drupal-recovery-net "${env_args[@]}" --entrypoint php "${image}" /usr/local/lib/drupal-template/drupal-db.php "$@"; }
drush() { docker exec drupal-recovery-web setpriv --reuid=www-data --regid=www-data --init-groups -- env HOME=/tmp/drupal-home \
  php /opt/drupal-cms/vendor/bin/drush.php --root=/opt/drupal-cms/web "$@"; }
password_is() { local got
  got="$(docker exec -e "CHECK=$1" drupal-recovery-web setpriv --reuid=www-data --regid=www-data --init-groups -- env HOME=/tmp/drupal-home \
    php /opt/drupal-cms/vendor/bin/drush.php --root=/opt/drupal-cms/web php:eval \
    'echo \Drupal::service("password")->check(getenv("CHECK"), \Drupal\user\Entity\User::load(1)->getPassword()) ? "match" : "differs";')"
  [[ "${got}" == match ]]; }
records() { docker run --rm -v "drupal-recovery-$1:/v" --entrypoint /bin/sh "${image}" -c 'ls /v/template-state 2>/dev/null | tr "\n" " "'; }

# 1. Killed during site:install.
start a
wait_log "installing Drupal CMS with the Starter site template"
sleep 3
docker kill drupal-recovery-web >/dev/null
[[ "$(db state)" =~ ^tables=[1-9][0-9]*\ installed=no$ ]] || fail "case 1: the kill did not land during the install ($(db state))"
[[ "$(records a)" == "install-started " ]] || fail "case 1: records after the kill: $(records a)"
start a
wait_log "the previous install was interrupted; starting it again"
wait_log "serving on port 80" 300
password_is "${admin_password}" || fail "case 1: the administrator does not have the configured password"
[[ "$(records a)" == "installed " ]] || fail "case 1: records after recovery: $(records a)"
claim_gone() { [[ "$(docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc "select to_regclass('public.railway_template_install_claim') is null")" == t ]]; }
claim_gone || fail "case 1: the install claim survived the finished install"
echo "install-recovery: ok 1 an install killed midway is cleared and repeated"

# 2. Finished install, unfinished provisioning.
drush user:password admin "${other_password}" >/dev/null 2>&1
docker stop drupal-recovery-web >/dev/null
# The state a crash between site:install and provisioning leaves: the
# install-started record and the database's claim with the same nonce.
docker run --rm -v drupal-recovery-a:/v --entrypoint /bin/sh "${image}" -c \
  'rm -f /v/template-state/installed; printf "nonce=00112233445566778899aabbccddeeff\n" > /v/template-state/install-started'
docker exec drupal-recovery-pg psql -U drupal -d drupal -qc \
  "create table railway_template_install_claim (nonce text primary key); insert into railway_template_install_claim values ('00112233445566778899aabbccddeeff')"
start a
wait_log "resuming an install that finished before the last stop"
wait_log "serving on port 80" 120
password_is "${admin_password}" || fail "case 2: provisioning was not repeated"
[[ "$(records a)" == "installed " ]] || fail "case 2: records after resuming: $(records a)"
claim_gone || fail "case 2: the install claim survived the resumed install"
# A stop after the installed record but before the claim was released: the
# next boot of the installed site drops the leftover claim.
docker stop drupal-recovery-web >/dev/null
docker exec drupal-recovery-pg psql -U drupal -d drupal -qc \
  "create table railway_template_install_claim (nonce text primary key); insert into railway_template_install_claim values ('00112233445566778899aabbccddeeff')"
start a
wait_log "serving on port 80" 120
claim_gone || fail "case 2: a leftover claim on an installed site was not released"
echo "install-recovery: ok 2 a finished install with unfinished provisioning is resumed"

# 3. A complete database and a volume without records: adopted, password kept.
drush user:password admin "${other_password}" >/dev/null 2>&1
docker stop drupal-recovery-web >/dev/null
start b
wait_log "adopting the existing Drupal database"
wait_log "serving on port 80" 120
password_is "${other_password}" || fail "case 3: adopting changed the administrator password"
[[ "$(records b)" == "installed " ]] || fail "case 3: records after adopting: $(records b)"
echo "install-recovery: ok 3 an existing complete database is adopted without changing the administrator"

# 3b. DRUPAL_RESET_ADMIN_PASSWORD=1 on an installed site gives user 1 the
# configured password again; without it the next boot leaves it alone.
drush php:eval 'foreach (["1-198.51.100.7", "1", "2-198.51.100.7"] as $id) { \Drupal::flood()->register("user.failed_login_user", 21600, $id); } \Drupal::flood()->register("user.failed_login_ip", 3600, "198.51.100.7");' >/dev/null
flood() { docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc "select event || ':' || identifier from flood order by 1" | tr '\n' ' '; }
docker stop drupal-recovery-web >/dev/null
start b -e DRUPAL_RESET_ADMIN_PASSWORD=1
wait_log "resetting the password of user 1"
wait_log "serving on port 80" 120
password_is "${admin_password}" || fail "case 3b: the reset did not restore the configured password"
[[ "$(flood)" == "user.failed_login_ip:198.51.100.7 user.failed_login_user:2-198.51.100.7 " ]] || fail "case 3b: flood records after the reset: $(flood)"
drush user:password admin "${other_password}" >/dev/null 2>&1
docker stop drupal-recovery-web >/dev/null
start b
wait_log "serving on port 80" 120
password_is "${other_password}" || fail "case 3b: a boot without the reset variable changed the password"
echo "install-recovery: ok 3b DRUPAL_RESET_ADMIN_PASSWORD=1 restores the configured password, and only while it is set"

# 3c. The reset also applies on the boot that adopts a database (a fresh
# volume, here volume c before case 5 uses it).
docker stop drupal-recovery-web >/dev/null
start c -e DRUPAL_RESET_ADMIN_PASSWORD=1
wait_log "adopting the existing Drupal database"
wait_log "serving on port 80" 120
password_is "${admin_password}" || fail "case 3c: the reset was skipped on the adopting boot"
docker stop drupal-recovery-web >/dev/null
docker run --rm -v drupal-recovery-c:/v --entrypoint /bin/sh "${image}" -c 'rm -rf /v/template-state'
start b
wait_log "serving on port 80" 120
echo "install-recovery: ok 3c the reset applies on an adopting boot too"

# 4. Installed record, empty database.
docker stop drupal-recovery-web >/dev/null
db reset
refused b 4 "this volume belongs to an installed site"
[[ "$(db state)" == "tables=0 installed=no" ]] || fail "case 4: the refused start wrote to the database"
echo "install-recovery: ok 4 an installed volume with an empty database is refused"

# 5. Unknown tables, no records.
docker exec drupal-recovery-pg psql -U drupal -d drupal -qc 'create table unrelated (id int); insert into unrelated values (42)'
refused c 5 "refusing to change it"
[[ "$(docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc 'select id from unrelated')" == 42 ]] || fail "case 5: the unrelated table changed"
[[ "$(records c)" == "" ]] || fail "case 5: the refused start wrote a record: $(records c)"
echo "install-recovery: ok 5 a database with unrelated tables is refused and left untouched"

# 6. An interrupted install's record on the volume never authorizes clearing a
# database it did not start on: volume a gets an install-started record (with
# its own nonce), and the database still holds only the unrelated table.
docker run --rm -v drupal-recovery-a:/v --entrypoint /bin/sh "${image}" -c \
  'rm -f /v/template-state/installed; printf "nonce=0123456789abcdef0123456789abcdef\n" > /v/template-state/install-started'
refused a 6 "did not start on it; refusing to change it"
[[ "$(docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc 'select id from unrelated')" == 42 ]] || fail "case 6: the unrelated table changed"
# The same record with no nonce at all is refused as well.
docker run --rm -v drupal-recovery-a:/v --entrypoint /bin/sh "${image}" -c 'printf "2026-11-24T00:00:00Z\n" > /v/template-state/install-started'
refused a 6b "did not start on it; refusing to change it"
[[ "$(docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc 'select id from unrelated')" == 42 ]] || fail "case 6b: the unrelated table changed"
echo "install-recovery: ok 6 an install record never clears a database the install did not start on"

# 7. Nor does it re-provision another finished Drupal site: install a site on
# a clean database with volume c, then point a volume whose interrupted record
# belongs elsewhere (a) at it.
docker exec drupal-recovery-pg psql -U drupal -d drupal -qc 'drop table unrelated'
docker run --rm -v drupal-recovery-c:/v --entrypoint /bin/sh "${image}" -c 'rm -rf /v/template-state'
start c
wait_log "serving on port 80" 300
drush user:password admin "${other_password}" >/dev/null 2>&1
docker stop drupal-recovery-web >/dev/null
[[ "$(docker exec drupal-recovery-pg psql -U drupal -d drupal -Atc "select to_regclass('public.railway_template_install_claim') is null")" == t ]] || fail "case 7: the claim table survived the finished install"
refused a 7 "refusing to change it"
start c
wait_log "serving on port 80" 120
password_is "${other_password}" || fail "case 7: the other site's administrator was changed"
echo "install-recovery: ok 7 an install record never re-provisions another finished site"
echo "install-recovery: passed"
