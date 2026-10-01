#!/usr/bin/env bash
# =============================================================================
# 06-update-frontend-nginx.sh - install/update ONLY the Frontend Nginx site
# (Frontend VM, pmli-app-02-frontend).
#
# Usage:  sudo ./scripts/06-update-frontend-nginx.sh [--env PATH]
#
# Serves the frontend's static production build and reverse-proxies /api/ to the
# Laravel API over the private network (see nginx/lms.pmli.co.id.conf) - so a
# browser hitting https://lms.pmli.co.id/api/... never sees the API's private IP.
# Does NOT touch the API VM or its already-working deployment in any way.
#
# Does NOT: npm install, npm run build, composer, php artisan (any), migrations,
# any database operation, package installs, restarting the API, restarting
# PHP-FPM, issuing/modifying TLS certificates, or editing the Laravel .env.
#
# Idempotent: safe to run repeatedly. Backs up any existing installed config
# before replacing it, rolls back automatically if `nginx -t` fails, and never
# reloads Nginx on a failed test.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_DIR}/env/frontend.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || die "--env needs a path"; ENV_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Pre-checks --------------------------------------------------------------
require_root
for c in nginx systemctl; do require_command "${c}"; done
load_env_file "${ENV_FILE}"
for v in EXPECTED_HOSTNAME FRONTEND_DOMAIN FRONTEND_DIR API_PRIVATE_IP FRONTEND_TLS_CERT_PATH FRONTEND_TLS_KEY_PATH; do
  require_var "${v}"
done
confirm_hostname "${EXPECTED_HOSTNAME}"
validate_ipv4 "${API_PRIVATE_IP}" || die "Invalid API_PRIVATE_IP: ${API_PRIVATE_IP}"

SRC_CONF="${REPO_DIR}/nginx/${FRONTEND_DOMAIN}.conf"
require_file "${SRC_CONF}" "nginx site config"
[[ -d "${FRONTEND_DIR}" ]] || die "FRONTEND_DIR '${FRONTEND_DIR}' does not exist. Confirm the real build path in env/frontend.env - this script never guesses it."
require_file "${FRONTEND_DIR}/index.html" "frontend build (index.html) in FRONTEND_DIR"
# This script never issues or modifies certificates; it only wires in the paths
# env/frontend.env already points at. See the assumption noted in
# nginx/lms.pmli.co.id.conf if TLS actually terminates somewhere else for this VM.
require_file "${FRONTEND_TLS_CERT_PATH}" "TLS certificate (FRONTEND_TLS_CERT_PATH)"
require_file "${FRONTEND_TLS_KEY_PATH}"  "TLS private key (FRONTEND_TLS_KEY_PATH)"

AVAIL="/etc/nginx/sites-available/${FRONTEND_DOMAIN}.conf"
ENABLED="/etc/nginx/sites-enabled/${FRONTEND_DOMAIN}.conf"
DEFAULT_LINK="/etc/nginx/sites-enabled/default"

# --- Render --------------------------------------------------------------
RENDERED="$(mktemp)"
sed -e "s#__FRONTEND_DIR__#${FRONTEND_DIR}#g" \
    -e "s#__FRONTEND_TLS_CERT_PATH__#${FRONTEND_TLS_CERT_PATH}#g" \
    -e "s#__FRONTEND_TLS_KEY_PATH__#${FRONTEND_TLS_KEY_PATH}#g" \
    -e "s#http://192\.168\.50\.50#http://${API_PRIVATE_IP}:${API_PRIVATE_PORT:-80}#g" "${SRC_CONF}" > "${RENDERED}"

# --- Backup + rollback plumbing ----------------------------------------------
HAD_AVAIL=0; PREV_BACKUP=""
if [[ -f "${AVAIL}" ]]; then
  HAD_AVAIL=1; backup_file "${AVAIL}"; PREV_BACKUP="${BACKUP_LAST_PATH}"
fi
HAD_LINK=0; [[ -L "${ENABLED}" ]] && HAD_LINK=1
REMOVED_DEFAULT=0

# Everything that can change on disk (new config, symlink swap, default removal)
# happens BEFORE this point is reached; nginx_rollback() undoes all of it in one
# place, and is only ever called before any reload - Nginx keeps serving its last
# successfully-reloaded config the entire time (see docs/ROLLBACK.md).
nginx_rollback() {
  log_warn "Rolling back Nginx configuration - Nginx was NOT reloaded."
  if (( HAD_AVAIL )); then cp -a -- "${PREV_BACKUP}" "${AVAIL}"; else rm -f -- "${AVAIL}"; fi
  if (( ! HAD_LINK )); then rm -f -- "${ENABLED}"; fi
  if (( REMOVED_DEFAULT )); then ln -sfn /etc/nginx/sites-available/default "${DEFAULT_LINK}"; fi
}

# --- Install -------------------------------------------------------------
install -m 0644 -o root -g root "${RENDERED}" "${AVAIL}"
rm -f -- "${RENDERED}"
ln -sfn "${AVAIL}" "${ENABLED}"
log_ok "Installed ${SRC_CONF} -> ${AVAIL} (enabled: ${ENABLED})"

# Drop the stock default site before validating (it would otherwise claim
# default_server on :80/:443 if this is the first site on the box) - if nginx -t
# then fails, nginx_rollback() above re-links it in the same step.
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
log_info "=== 06-update-frontend-nginx.sh summary ==="
log_info "Hostname:          $(hostname)"
log_info "Config installed:  ${AVAIL}"
log_info "Enabled symlink:   ${ENABLED} -> $(readlink -f "${ENABLED}")"
log_info "Frontend root:     ${FRONTEND_DIR}"
log_info "API upstream:      http://${API_PRIVATE_IP}:${API_PRIVATE_PORT:-80}"
(( REMOVED_DEFAULT )) && log_info "Default symlink:   removed (${DEFAULT_LINK})" || log_info "Default symlink:   not present"
if nginx -t >/dev/null 2>&1; then log_ok "nginx config test: OK"; else log_error "nginx config test: FAILED"; fi
systemctl is-active --quiet nginx && log_ok "nginx service:     active" || log_error "nginx service:     NOT active"

log_ok "Frontend Nginx update complete. Verify with: sudo ./scripts/07-verify-frontend-api.sh"
