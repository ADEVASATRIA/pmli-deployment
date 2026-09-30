#!/usr/bin/env bash
# =============================================================================
# 05-update-api-nginx.sh - update ONLY the API Nginx site config (API VM).
#
# Usage:  sudo ./scripts/05-update-api-nginx.sh [--env PATH]
#
# For when nginx/api-lms.pmli.co.id.conf changes and nothing else needs
# touching. Installs the repo's Nginx config, validates it, reloads Nginx.
#
# Does NOT: composer install, php artisan (any), migrate, edit the Laravel
# .env, restart PHP-FPM, install packages, touch the database, or touch the
# TLS certificate/key files themselves (only references their configured
# paths - see scripts/03-deploy-app.sh, which introduced TLS_CERT_PATH/
# TLS_KEY_PATH). For a full deployment (Composer, caches, PHP-FPM, Nginx),
# use scripts/03-deploy-app.sh instead.
#
# Idempotent: safe to run repeatedly. Backs up any existing installed config
# before replacing it, rolls back automatically if `nginx -t` fails, and
# never reloads Nginx on a failed test.
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
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Pre-checks --------------------------------------------------------------
require_root
for c in nginx systemctl; do require_command "${c}"; done
load_env_file "${ENV_FILE}"
for v in EXPECTED_HOSTNAME APP_DOMAIN APP_DIR PHP_VERSION TLS_CERT_PATH TLS_KEY_PATH; do require_var "${v}"; done
confirm_hostname "${EXPECTED_HOSTNAME}"

SRC_CONF="${REPO_DIR}/nginx/${APP_DOMAIN}.conf"
require_file "${SRC_CONF}" "nginx site config"
# This script never issues or modifies certificates; it only wires in the paths env/api.env
# already points at (the same TLS_CERT_PATH/TLS_KEY_PATH scripts/03-deploy-app.sh uses).
require_file "${TLS_CERT_PATH}" "TLS certificate (TLS_CERT_PATH)"
require_file "${TLS_KEY_PATH}"  "TLS private key (TLS_KEY_PATH)"

AVAIL="/etc/nginx/sites-available/${APP_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${APP_DOMAIN}.conf"
LEGACY_LINK="/etc/nginx/sites-enabled/pmli-backend"
DEFAULT_LINK="/etc/nginx/sites-enabled/default"

# --- Render (identical substitution to scripts/03-deploy-app.sh) ------------
RENDERED="$(mktemp)"
sed -e "s#/var/www/pmli-backend/public#${APP_DIR}/public#g" \
    -e "s#php8\.3-fpm\.sock#php${PHP_VERSION}-fpm.sock#g" \
    -e "s#/etc/ssl/pmli/fullchain\.crt#${TLS_CERT_PATH}#g" \
    -e "s#/etc/ssl/pmli/private\.key#${TLS_KEY_PATH}#g" "${SRC_CONF}" > "${RENDERED}"

# --- Backup + rollback plumbing ----------------------------------------------
HAD_AVAIL=0; PREV_BACKUP=""
if [[ -f "${AVAIL}" ]]; then
  HAD_AVAIL=1; backup_file "${AVAIL}"; PREV_BACKUP="${BACKUP_LAST_PATH}"
fi
HAD_LINK=0; [[ -L "${ENABLED}" ]] && HAD_LINK=1
REMOVED_LEGACY=0
REMOVED_DEFAULT=0

# Everything that can change on disk (new config, symlink swaps, legacy/default
# removal) happens BEFORE this point is reached; nginx_rollback() undoes all of it
# in one place, and is only ever called before any reload - Nginx keeps serving
# its last successfully-reloaded config the entire time (see docs/ROLLBACK.md).
nginx_rollback() {
  log_warn "Rolling back Nginx configuration - Nginx was NOT reloaded."
  if (( HAD_AVAIL )); then cp -a -- "${PREV_BACKUP}" "${AVAIL}"; else rm -f -- "${AVAIL}"; fi
  if (( ! HAD_LINK )); then rm -f -- "${ENABLED}"; fi
  if (( REMOVED_DEFAULT )); then ln -sfn /etc/nginx/sites-available/default "${DEFAULT_LINK}"; fi
  if (( REMOVED_LEGACY )); then
    log_warn "Legacy symlink ${LEGACY_LINK} was removed and is NOT restored (its old target is not tracked); recreate it manually if truly needed."
  fi
}

# --- Install -------------------------------------------------------------
install -m 0644 -o root -g root "${RENDERED}" "${AVAIL}"
rm -f -- "${RENDERED}"
ln -sfn "${AVAIL}" "${ENABLED}"
log_ok "Installed ${SRC_CONF} -> ${AVAIL} (enabled: ${ENABLED})"

# Drop the legacy/default symlinks before validating, exactly like
# scripts/03-deploy-app.sh does - if nginx -t then fails, nginx_rollback()
# above restores everything (including re-linking the default site) in one step.
if [[ -L "${LEGACY_LINK}" || -e "${LEGACY_LINK}" ]]; then
  rm -f -- "${LEGACY_LINK}"; REMOVED_LEGACY=1
  log_info "Removed legacy symlink ${LEGACY_LINK}."
fi
if [[ -L "${DEFAULT_LINK}" ]]; then
  rm -f -- "${DEFAULT_LINK}"; REMOVED_DEFAULT=1
  log_info "Disabled Nginx 'default' site (symlink removed; file kept in sites-available)."
fi

if ! nginx -t; then
  nginx_rollback
  nginx -t || log_error "Nginx config still invalid after rollback - fix manually."
  die "nginx -t failed for the new site; rolled back. Nginx was NOT reloaded."
fi
log_ok "nginx -t passed."

systemctl reload nginx || { nginx_rollback; systemctl reload nginx || true; die "nginx reload failed; rolled back."; }
log_ok "Nginx reloaded."

# --- Status summary ------------------------------------------------------
echo
log_info "=== 05-update-api-nginx.sh summary ==="
log_info "Hostname:          $(hostname)"
log_info "Config installed:  ${AVAIL}"
log_info "Enabled symlink:   ${ENABLED} -> $(readlink -f "${ENABLED}")"
(( REMOVED_LEGACY )) && log_info "Legacy symlink:    removed (${LEGACY_LINK})" || log_info "Legacy symlink:    not present"
(( REMOVED_DEFAULT )) && log_info "Default symlink:   removed (${DEFAULT_LINK})" || log_info "Default symlink:   not present"
if nginx -t >/dev/null 2>&1; then log_ok "nginx config test: OK"; else log_error "nginx config test: FAILED"; fi
systemctl is-active --quiet nginx && log_ok "nginx service:     active" || log_error "nginx service:     NOT active"

log_ok "Nginx update complete."
