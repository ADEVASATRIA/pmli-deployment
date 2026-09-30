#!/usr/bin/env bash
# =============================================================================
# 03-deploy-app.sh - deploy the (already cloned) Laravel backend on the API VM.
#
# Usage:  sudo ./scripts/03-deploy-app.sh [--env PATH]
#
# Assumes 02-setup-api.sh completed, APP_DIR holds the backend checkout and a
# production .env (with APP_KEY) already exists.
#
# Does NOT: git pull, edit .env, generate APP_KEY, or run migrations.
# `php artisan migrate:status` is run as a read-only check only.
# If maintenance mode was enabled and anything fails, `artisan up` is attempted.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_DIR}/env/api.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || die "--env needs a path"; ENV_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root
for c in php composer nginx runuser systemctl find; do require_command "${c}"; done
load_env_file "${ENV_FILE}"
for v in EXPECTED_HOSTNAME DB_PRIVATE_IP APP_DOMAIN APP_DIR PHP_VERSION WEB_USER WEB_GROUP; do require_var "${v}"; done
confirm_hostname "${EXPECTED_HOSTNAME}"
id -u "${WEB_USER}" >/dev/null 2>&1 || die "User '${WEB_USER}' does not exist."

# --- Validate the application checkout --------------------------------------
[[ -d "${APP_DIR}" ]] || die "APP_DIR ${APP_DIR} does not exist. Clone the backend there first."
require_file "${APP_DIR}/artisan" "artisan"
require_file "${APP_DIR}/composer.json" "composer.json"
require_file "${APP_DIR}/.env" "Laravel .env"
[[ -d "${APP_DIR}/public" ]] || die "${APP_DIR}/public is missing; web root would be wrong."
cd "${APP_DIR}"

php -r 'exit(version_compare(PHP_VERSION, "8.3.0", ">=") ? 0 : 1);' || die "PHP CLI is older than 8.3."
composer --version 2>/dev/null | grep -Eq 'Composer version 2\.' || die "Composer 2.x is required."
log_ok "PHP $(php -r 'echo PHP_VERSION;') and $(composer --version 2>/dev/null | head -n 1)"

# --- .env sanity (values are never printed) ---------------------------------
APP_KEY_V="$(env_get .env APP_KEY)"
[[ -n "${APP_KEY_V}" ]] || die "APP_KEY is empty in ${APP_DIR}/.env. Set it deliberately (this script never generates one)."
unset APP_KEY_V
DB_HOST_V="$(env_get .env DB_HOST)"; DB_PORT_V="$(env_get .env DB_PORT)"
DB_USER_V="$(env_get .env DB_USERNAME)"
[[ -n "${DB_HOST_V}" ]] || die "DB_HOST missing in .env"
[[ -n "$(env_get .env DB_DATABASE)" ]] || die "DB_DATABASE missing in .env"
[[ -n "${DB_USER_V}" ]] || die "DB_USERNAME missing in .env"
[[ "${DB_USER_V}" != "root" ]] || die "DB_USERNAME is 'root'. The application must use its dedicated DB user."
[[ -n "$(env_get .env DB_PASSWORD)" ]] || die "DB_PASSWORD is empty in .env (value not shown)."
[[ "${DB_HOST_V}" == "${DB_PRIVATE_IP}" ]] || log_warn "DB_HOST is '${DB_HOST_V}', expected ${DB_PRIVATE_IP}."
[[ "$(env_get .env APP_ENV)" == "production" ]] || log_warn "APP_ENV is not 'production'."
[[ "$(env_get .env APP_DEBUG)" != "true" ]] || die "APP_DEBUG=true in .env. Refusing to deploy with debug enabled."
[[ "$(env_get .env SESSION_DRIVER)" != "database" ]] || log_warn "SESSION_DRIVER=database but no committed sessions migration is known. Use SESSION_DRIVER=file for the initial deployment."
check_port "${DB_HOST_V}" "${DB_PORT_V:-3306}" 5 || die "Cannot reach DB ${DB_HOST_V}:${DB_PORT_V:-3306}."
log_ok "DB TCP endpoint reachable; credentials present (not displayed)."

as_web() { runuser -u "${WEB_USER}" -- "$@"; }
as_web test -r .env || die ".env is not readable by ${WEB_USER}. Fix (not done automatically):  chgrp ${WEB_GROUP} .env && chmod 640 .env"

# --- Writable directories ----------------------------------------------------
ensure_writable() {
  log_info "Ensuring Laravel writable paths (owner ${WEB_USER}:${WEB_GROUP}, 775/664 - never 777) ..."
  local d
  for d in storage storage/app storage/app/public storage/app/private \
           storage/framework/cache storage/framework/sessions storage/framework/views \
           storage/logs storage/api-docs bootstrap/cache; do
    install -d -m 0775 -o "${WEB_USER}" -g "${WEB_GROUP}" "${APP_DIR}/${d}"
  done
  chown -R "${WEB_USER}:${WEB_GROUP}" storage bootstrap/cache
  find storage bootstrap/cache -type d -exec chmod 775 {} +
  find storage bootstrap/cache -type f -exec chmod 664 {} +
}
ensure_writable

# --- Maintenance mode with guaranteed 'up' on failure ------------------------
MAINT_ON=0
on_exit() {
  local rc=$?
  if (( MAINT_ON )); then
    log_warn "Exiting while in maintenance mode - attempting 'artisan up' ..."
    as_web php artisan up || log_error "FAILED to bring the app up. Run manually: cd ${APP_DIR} && sudo -u ${WEB_USER} php artisan up"
  fi
  if (( rc != 0 )); then log_error "Deployment aborted (exit ${rc}). See docs/ROLLBACK.md."; fi
}
trap on_exit EXIT

if [[ -f vendor/autoload.php ]]; then
  as_web php artisan down --retry=60
  MAINT_ON=1
  log_info "Maintenance mode enabled."
else
  log_info "No vendor/ yet (first deployment) - skipping maintenance mode."
fi

# --- Composer ----------------------------------------------------------------
log_info "Running composer install (no-dev) ..."
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
ensure_writable   # composer scripts ran as root; hand cache files back to the web user

# --- Clear stale caches ------------------------------------------------------
for c in config:clear route:clear event:clear view:clear; do
  as_web php artisan "${c}" >/dev/null 2>&1 || log_warn "artisan ${c} failed (continuing)."
done

# --- storage symlink (idempotent) -------------------------------------------
LINK="${APP_DIR}/public/storage"
TARGET="${APP_DIR}/storage/app/public"
if [[ -L "${LINK}" ]]; then
  if [[ "$(readlink -f "${LINK}")" == "$(readlink -f "${TARGET}")" ]]; then
    log_ok "public/storage already points to storage/app/public."
  else
    die "public/storage is a symlink to a different target ($(readlink "${LINK}")). Fix manually."
  fi
elif [[ -e "${LINK}" ]]; then
  die "public/storage exists and is not a symlink. Inspect and move it manually."
else
  as_web php artisan storage:link
  log_ok "Created public/storage symlink."
fi

# --- Migration status (READ ONLY) -------------------------------------------
log_info "Migration status (no migrations are run by this script):"
as_web php artisan migrate:status || die "migrate:status failed - check DB connectivity/credentials in .env."

# --- Production caches -------------------------------------------------------
for c in config route event; do
  if as_web php artisan "${c}:cache"; then
    log_ok "${c}:cache done."
  else
    log_warn "${c}:cache failed; clearing it so a broken cache is not left behind."
    as_web php artisan "${c}:clear" >/dev/null 2>&1 || true
  fi
done

if as_web php artisan list --raw 2>/dev/null | grep -q '^l5-swagger:generate'; then
  as_web php artisan l5-swagger:generate || log_warn "l5-swagger:generate failed (API docs may be stale)."
else
  log_info "l5-swagger:generate not available; skipping."
fi

as_web php artisan about >/dev/null || die "Laravel failed to boot (php artisan about)."
log_ok "Laravel boots correctly."

# --- PHP-FPM -----------------------------------------------------------------
safe_systemctl_restart "php${PHP_VERSION}-fpm"

# --- Nginx site --------------------------------------------------------------
SRC_CONF="${REPO_DIR}/nginx/${APP_DOMAIN}.conf"
require_file "${SRC_CONF}" "nginx site config"
AVAIL="/etc/nginx/sites-available/${APP_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${APP_DOMAIN}.conf"
DEFAULT_LINK="/etc/nginx/sites-enabled/default"

RENDERED="$(mktemp)"
sed -e "s#/var/www/pmli-backend/public#${APP_DIR}/public#g" \
    -e "s#php8\.3-fpm\.sock#php${PHP_VERSION}-fpm.sock#g" "${SRC_CONF}" > "${RENDERED}"

HAD_AVAIL=0; PREV_BACKUP=""
if [[ -f "${AVAIL}" ]]; then
  HAD_AVAIL=1; backup_file "${AVAIL}"; PREV_BACKUP="${BACKUP_LAST_PATH}"
fi
HAD_LINK=0; [[ -L "${ENABLED}" ]] && HAD_LINK=1
REMOVED_DEFAULT=0

nginx_rollback() {
  log_warn "Rolling back Nginx configuration."
  if (( HAD_AVAIL )); then cp -a -- "${PREV_BACKUP}" "${AVAIL}"; else rm -f -- "${AVAIL}"; fi
  if (( ! HAD_LINK )); then rm -f -- "${ENABLED}"; fi
  if (( REMOVED_DEFAULT )); then ln -sfn /etc/nginx/sites-available/default "${DEFAULT_LINK}"; fi
}

install -m 0644 -o root -g root "${RENDERED}" "${AVAIL}"
rm -f -- "${RENDERED}"
ln -sfn "${AVAIL}" "${ENABLED}"
# The stock default site would otherwise claim default_server on port 80.
if [[ -L "${DEFAULT_LINK}" ]]; then
  rm -f -- "${DEFAULT_LINK}"; REMOVED_DEFAULT=1
  log_info "Disabled Nginx 'default' site (symlink removed; file kept in sites-available)."
fi

if ! nginx -t; then
  nginx_rollback
  nginx -t || log_error "Nginx config still invalid after rollback - fix manually."
  die "nginx -t failed for the new site; rolled back."
fi
log_ok "nginx -t passed."
systemctl reload nginx || { nginx_rollback; systemctl reload nginx || true; die "nginx reload failed; rolled back."; }
log_ok "Nginx reloaded."

# --- Leave maintenance mode --------------------------------------------------
if (( MAINT_ON )); then
  as_web php artisan up
  MAINT_ON=0
  log_ok "Maintenance mode disabled."
fi

log_ok "Deployment complete. Run: sudo ./scripts/04-verify-deployment.sh"
