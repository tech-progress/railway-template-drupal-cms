#!/bin/bash
# Start wrapper for the Drupal CMS image, run as root (PID 1) before Apache:
#   1. refuses to start (exit 64) on a malformed configuration, naming the
#      variable but never printing its value;
#   2. prepares the volume at /var/lib/drupal (public files, private files,
#      configuration sync directory, and this wrapper's own install markers);
#   3. waits for PostgreSQL, then either installs Drupal CMS (first boot),
#      finishes or repeats an install that was interrupted, adopts an existing
#      complete Drupal database, or applies pending database updates;
#   4. re-executes itself without DRUPAL_ADMIN_PASSWORD and supervises Apache
#      and a loop that runs Drupal's cron every five minutes.
# Apache opens port 80 only in step 4, so no visitor can reach Drupal's
# interactive installer while the site is being set up.
set -euo pipefail
export LC_ALL=C
fail() { echo "drupal-start: $*" >&2; exit 64; }
log() { echo "drupal-start: $*"; }

app=/opt/drupal-cms
data=/var/lib/drupal
state="${data}/template-state"
helpers=/usr/local/lib/drupal-template
cron_interval=300

# Commands run as www-data, the owner of Drupal's files, keeping the
# environment (settings.php reads the database credentials from it). Arrays,
# not functions, so a backgrounded command is the process itself and a stop
# signal reaches it.
as_www=(setpriv --reuid=www-data --regid=www-data --init-groups -- env HOME=/tmp/drupal-home)
drush=("${as_www[@]}" php -d memory_limit=1024M "${app}/vendor/bin/drush.php" --root="${app}/web")

# Long steps run as background children so a stop signal is handled at once:
# bash as PID 1 runs a trap only after its foreground child ends.
child=""
stop_during_setup() {
  log "stopped during setup"
  [[ -n "${child}" ]] && kill -TERM "${child}" 2>/dev/null && wait "${child}" 2>/dev/null
  exit 143
}
run() {
  "$@" & child=$!
  local status=0
  wait "${child}" || status=$?
  child=""
  return "${status}"
}

serve() {
  local apache="" cron="" stopping=0 status=0
  trap 'stopping=1; [[ -n "${apache}" ]] && kill -TERM "${apache}" 2>/dev/null; [[ -n "${cron}" ]] && kill -TERM "${cron}" 2>/dev/null' TERM INT WINCH
  apache2-foreground & apache=$!
  cron_loop & cron=$!
  log "serving on port 80"
  wait -n "${apache}" "${cron}" || status=$?
  if (( stopping )); then
    wait "${apache}" "${cron}" 2>/dev/null || true
    log "stopped"
    exit 0
  fi
  # A child that exits on its own is a failure even with status 0, so the
  # ON_FAILURE restart policy brings the container back.
  log "a supervised process exited (status ${status}); stopping"
  kill -TERM "${apache}" "${cron}" 2>/dev/null || true
  wait "${apache}" "${cron}" 2>/dev/null || true
  exit 1
}

cron_loop() {
  local pid=""
  trap '[[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null; exit 0' TERM INT
  local delay=60
  while true; do
    sleep "${delay}" & pid=$!; wait "${pid}" || true
    delay="${cron_interval}"
    timeout 900 "${as_www[@]}" php -d memory_limit=512M "${app}/vendor/bin/drush.php" --root="${app}/web" --quiet core:cron & pid=$!
    if wait "${pid}"; then log "cron run completed"; else log "cron run failed"; fi
    pid=""
  done
}

if [[ "${1:-}" == --serve ]]; then
  serve
fi

# 1. Configuration.
[[ "${PORT:-}" == 80 ]] || fail "PORT must be 80, the port the image's Apache listens on"
[[ "${DRUPAL_DATABASE_HOST:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]{0,251}[A-Za-z0-9])?$ ]] || fail "DRUPAL_DATABASE_HOST must be a host name or address"
[[ "${DRUPAL_DATABASE_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] && (( DRUPAL_DATABASE_PORT <= 65535 )) || fail "DRUPAL_DATABASE_PORT must be a port number"
[[ "${DRUPAL_DATABASE_NAME:-}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || fail "DRUPAL_DATABASE_NAME must be letters, digits or _ (at most 63)"
[[ "${DRUPAL_DATABASE_USER:-}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || fail "DRUPAL_DATABASE_USER must be letters, digits or _ (at most 63)"
[[ "${DRUPAL_DATABASE_PASSWORD:-}" =~ ^[[:graph:]]{16,}$ ]] || fail "DRUPAL_DATABASE_PASSWORD must be at least 16 printable ASCII characters without spaces"
[[ "${DRUPAL_HASH_SALT:-}" =~ ^[[:graph:]]{32,}$ ]] || fail "DRUPAL_HASH_SALT must be at least 32 printable ASCII characters without spaces"
[[ "${DRUPAL_TRUSTED_HOSTS:-}" =~ ^([A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*)?$ ]] || fail "DRUPAL_TRUSTED_HOSTS must be empty or comma-separated host names without spaces"
[[ "${DRUPAL_RESET_ADMIN_PASSWORD:-0}" =~ ^[01]?$ ]] || fail "DRUPAL_RESET_ADMIN_PASSWORD must be 1 (reset on every boot while set) or 0"

check_admin_settings() {
  [[ "${DRUPAL_ADMIN_USER:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,59}$ ]] || fail "DRUPAL_ADMIN_USER must be 1-60 letters, digits or . _ @ - and start with a letter or digit"
  [[ "${DRUPAL_ADMIN_EMAIL:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "DRUPAL_ADMIN_EMAIL must be an email address such as you@example.com"
  [[ "${DRUPAL_ADMIN_PASSWORD:-}" =~ ^[[:graph:]]{16,128}$ ]] || fail "DRUPAL_ADMIN_PASSWORD must be 16-128 printable ASCII characters without spaces"
  [[ "${DRUPAL_SITE_NAME:-}" =~ ^[[:alnum:]][[:print:]]{0,127}$ ]] || fail "DRUPAL_SITE_NAME must be 1-128 printable ASCII characters and start with a letter or digit"
}

# 2. The volume. Railway mounts it empty and root-owned, with lost+found.
mountpoint -q "${data}" || fail "no volume is mounted at ${data}; uploads and settings would be lost on every deploy"
for dir in files private config config/sync template-state; do
  [[ ! -L "${data}/${dir}" ]] || fail "${data}/${dir} is a symbolic link; refusing to follow it"
done
mkdir -p "${data}/files" "${data}/private" "${data}/config/sync" "${state}"
chown www-data:www-data "${data}/files" "${data}/private" "${data}/config" "${data}/config/sync"
chmod 0755 "${data}/files"
chmod 0750 "${data}/private" "${data}/config" "${data}/config/sync"
chown root:root "${state}"; chmod 0700 "${state}"
install -d -o www-data -g www-data -m 0700 /tmp/drupal-home

# 3. Apache. Railway's runtime has been seen to ignore the whiteouts with which
# the PHP base image disables mpm_event in a later layer, so the deleted links
# reappear and Apache refuses to start ("More than one MPM loaded"). mod_php
# needs prefork, which the image enables.
rm -f /etc/apache2/mods-enabled/mpm_event.load /etc/apache2/mods-enabled/mpm_event.conf \
  /etc/apache2/mods-enabled/mpm_worker.load /etc/apache2/mods-enabled/mpm_worker.conf
[[ -e /etc/apache2/mods-enabled/mpm_prefork.load ]] || fail "the image no longer enables Apache's prefork MPM, which mod_php needs"
if ! check="$(apache2ctl -t 2>&1)"; then
  printf '%s\n' "${check}" | tail -n 5 >&2
  fail "the Apache configuration does not parse"
fi

# The PHP Apache base image declares STOPSIGNAL SIGWINCH (Apache's graceful
# stop); the Dockerfile sets SIGTERM, and WINCH is handled too in case a
# platform sends the base image's signal.
trap stop_during_setup TERM INT WINCH
cd "${app}"
log "waiting for PostgreSQL at ${DRUPAL_DATABASE_HOST}:${DRUPAL_DATABASE_PORT}"
until run php "${helpers}/drupal-db.php" ping 2>/dev/null; do
  run sleep 3
done
log "PostgreSQL accepts Drupal's credentials"

db_state() {
  local out
  out="$(php "${helpers}/drupal-db.php" state)" || fail "cannot read the database state"
  [[ "${out}" =~ ^tables=([0-9]+)\ installed=(yes|no)$ ]] || fail "unexpected database state"
  tables="${BASH_REMATCH[1]}" installed="${BASH_REMATCH[2]}"
}
mark() { printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${state}/$1.tmp" && mv -f "${state}/$1.tmp" "${state}/$1"; }

# An install binds the volume to the database it started on: the volume's
# install-started record and a claim table in the database hold the same
# random nonce. Only a database holding exactly that claim may be cleared or
# provisioned again; a record left by an interrupted install never authorizes
# changes to a database that was swapped in afterwards.
started_nonce() {
  local line=""
  [[ -f "${state}/install-started" ]] && IFS= read -r line < "${state}/install-started"
  [[ "${line}" =~ ^nonce=([0-9a-f]{32})$ ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}
owns_database() {
  local nonce; nonce="$(started_nonce)"
  [[ -n "${nonce}" ]] && php "${helpers}/drupal-db.php" owns "${nonce}"
}

provision() {
  log "setting the administrator account"
  run env DRUPAL_PROVISION_MODE=install "${drush[@]}" php:script "${helpers}/drupal-provision.php" || fail "provisioning the administrator failed"
  db_state
  [[ "${installed}" == yes ]] || fail "the installer did not record a finished installation"
  mark installed
  rm -f "${state}/install-started"
  php "${helpers}/drupal-db.php" release || fail "could not remove the install claim"
  provisioned=1
  log "Drupal CMS is installed; sign in as ${DRUPAL_ADMIN_USER} at /user/login"
}

install_site() {
  check_admin_settings
  local nonce
  if (( tables > 0 )); then
    owns_database \
      || fail "the database has ${tables} tables, and this volume's interrupted install did not start on it; refusing to change it"
    nonce="$(started_nonce)"
    log "clearing the tables of an interrupted install"
    run php "${helpers}/drupal-db.php" reset || fail "could not clear the interrupted install"
  else
    nonce="$(started_nonce)"
    [[ -n "${nonce}" ]] || nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf 'nonce=%s\n' "${nonce}" > "${state}/install-started.tmp" && mv -f "${state}/install-started.tmp" "${state}/install-started"
  fi
  php "${helpers}/drupal-db.php" claim "${nonce}" || fail "could not record the install claim"
  log "installing Drupal CMS with the Starter site template (first boot)"
  # site:install gets a throwaway password; provision() sets the real one from
  # the environment, so DRUPAL_ADMIN_PASSWORD never appears in a command line.
  local throwaway
  throwaway="$(head -c 32 /dev/urandom | base64 | tr -dc A-Za-z0-9)"
  run "${drush[@]}" site:install "${app}/recipes/drupal_cms_starter" --yes \
    --account-name="${DRUPAL_ADMIN_USER}" --account-mail="${DRUPAL_ADMIN_EMAIL}" --account-pass="${throwaway}" \
    --site-name="${DRUPAL_SITE_NAME}" --site-mail="${DRUPAL_ADMIN_EMAIL}" --locale=en \
    || fail "drush site:install failed"
  unset throwaway
  provision
}

provisioned=0
db_state
if [[ -e "${state}/installed" ]]; then
  # This volume belongs to an installed site; never reinstall over it.
  [[ "${installed}" == yes ]] \
    || fail "this volume belongs to an installed site but the database holds no finished Drupal installation (${tables} tables); restore the database, or see SUPPORT.md to start over"
  rm -f "${state}/install-started"
elif [[ -e "${state}/install-started" ]]; then
  if [[ "${installed}" == yes ]]; then
    owns_database \
      || fail "this volume's interrupted install did not start on this database, which holds another finished Drupal installation; refusing to change it"
    log "resuming an install that finished before the last stop"
    check_admin_settings
    provision
  else
    log "the previous install was interrupted; starting it again"
    install_site
  fi
elif (( tables == 0 )); then
  install_site
elif [[ "${installed}" == yes ]]; then
  log "adopting the existing Drupal database (this volume had no install record); the administrator password is left unchanged"
  mark installed
else
  fail "the database has ${tables} tables but no finished Drupal installation and this volume has no install record; refusing to change it"
fi

# Recovery for a lost administrator password when no mail is configured:
# with DRUPAL_RESET_ADMIN_PASSWORD=1, user 1 gets DRUPAL_ADMIN_PASSWORD again
# (and its failed-login blocks are cleared) on every boot until it is unset,
# including a boot that adopts an existing database. A boot that has just
# provisioned the administrator has set that password already.
if [[ "${DRUPAL_RESET_ADMIN_PASSWORD:-0}" == 1 ]] && (( ! provisioned )); then
  [[ "${DRUPAL_ADMIN_PASSWORD:-}" =~ ^[[:graph:]]{16,128}$ ]] || fail "DRUPAL_ADMIN_PASSWORD must be 16-128 printable ASCII characters without spaces"
  log "DRUPAL_RESET_ADMIN_PASSWORD=1: resetting the password of user 1; remove the variable after signing in"
  run env DRUPAL_PROVISION_MODE=reset "${drush[@]}" php:script "${helpers}/drupal-provision.php" || fail "resetting the administrator password failed"
fi

log "applying pending database updates"
run "${drush[@]}" updatedb --yes || fail "drush updatedb failed"
trap - TERM INT WINCH

# 4. Serve, without the administrator password in the environment of Apache,
# PHP or cron.
exec env -u DRUPAL_ADMIN_PASSWORD /bin/bash "$0" --serve
