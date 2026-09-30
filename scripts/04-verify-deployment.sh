#!/usr/bin/env bash
# =============================================================================
# 04-verify-deployment.sh - READ-ONLY post-deployment verification (API VM).
#
# Usage:  sudo ./scripts/04-verify-deployment.sh [--env PATH]
#
# Changes nothing. Never prints .env secrets. Exit 1 if any check FAILS
# (warnings do not fail the run).
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
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_root   # needed to read .env and run artisan as the web user
for c in php curl nginx runuser systemctl; do require_command "${c}"; done
load_env_file "${ENV_FILE}"
for v in APP_DIR APP_DOMAIN PHP_VERSION WEB_USER DB_PRIVATE_IP; do require_var "${v}"; done

PASS=0; WARN=0; FAIL=0
check_pass() { PASS=$((PASS + 1)); log_ok "$*"; }
check_warn() { WARN=$((WARN + 1)); log_warn "$*"; }
check_fail() { FAIL=$((FAIL + 1)); log_error "$*"; }

as_web() { runuser -u "${WEB_USER}" -- "$@"; }

log_info "=== PMLI deployment verification (read-only) ==="

# --- Runtime -----------------------------------------------------------------
if php -r 'exit(version_compare(PHP_VERSION, "8.3.0", ">=") ? 0 : 1);'; then
  check_pass "PHP version $(php -r 'echo PHP_VERSION;') (>= 8.3)"
else
  check_fail "PHP CLI < 8.3"
fi
systemctl is-active --quiet "php${PHP_VERSION}-fpm" && check_pass "php${PHP_VERSION}-fpm is running" || check_fail "php${PHP_VERSION}-fpm is NOT running"
systemctl is-active --quiet nginx && check_pass "nginx is running" || check_fail "nginx is NOT running"
if nginx -t >/dev/null 2>&1; then check_pass "nginx -t OK"; else check_fail "nginx -t reports errors"; fi

# --- Application layout ------------------------------------------------------
if [[ ! -d "${APP_DIR}" ]]; then
  check_fail "APP_DIR ${APP_DIR} missing"
  log_error "Cannot continue without the application directory."
  echo; log_info "Summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"; exit 1
fi
[[ -f "${APP_DIR}/artisan" ]] && check_pass "artisan present" || check_fail "artisan missing in ${APP_DIR}"
[[ -d "${APP_DIR}/vendor" ]] && check_pass "vendor/ present" || check_fail "vendor/ missing (composer install not done?)"

for d in storage storage/app storage/app/public storage/app/private storage/framework/cache \
         storage/framework/sessions storage/framework/views storage/logs storage/api-docs bootstrap/cache; do
  if [[ ! -d "${APP_DIR}/${d}" ]]; then
    check_fail "Missing directory: ${d}"
  elif as_web test -w "${APP_DIR}/${d}"; then
    check_pass "Writable by ${WEB_USER}: ${d}"
  else
    check_fail "Not writable by ${WEB_USER}: ${d}"
  fi
done

LINK="${APP_DIR}/public/storage"
if [[ -L "${LINK}" && "$(readlink -f "${LINK}")" == "$(readlink -f "${APP_DIR}/storage/app/public")" ]]; then
  check_pass "public/storage -> storage/app/public"
else
  check_fail "public/storage symlink missing or pointing elsewhere"
fi

# --- .env checks (values not printed unless non-secret) ----------------------
ENVF="${APP_DIR}/.env"
if [[ -f "${ENVF}" ]]; then
  check_pass ".env present"
  [[ -n "$(env_get "${ENVF}" APP_KEY)" ]] && check_pass "APP_KEY is set (not shown)" || check_fail "APP_KEY is empty"
  V="$(env_get "${ENVF}" APP_ENV)";   [[ "${V}" == "production" ]] && check_pass "APP_ENV=production" || check_warn "APP_ENV='${V}' (expected production)"
  V="$(env_get "${ENVF}" APP_DEBUG)"; [[ "${V}" != "true" ]] && check_pass "APP_DEBUG is not true" || check_fail "APP_DEBUG=true"
  V="$(env_get "${ENVF}" DB_HOST)";   [[ "${V}" == "${DB_PRIVATE_IP}" ]] && check_pass "DB_HOST=${V}" || check_warn "DB_HOST='${V}' (expected ${DB_PRIVATE_IP})"
  DBPORT="$(env_get "${ENVF}" DB_PORT)"; [[ "${DBPORT}" == "3306" ]] && check_pass "DB_PORT=3306" || check_warn "DB_PORT='${DBPORT}' (expected 3306)"
  V="$(env_get "${ENVF}" DB_USERNAME)"; [[ -n "${V}" && "${V}" != "root" ]] && check_pass "DB_USERNAME is a non-root user" || check_fail "DB_USERNAME is empty or root"
  V="$(env_get "${ENVF}" SESSION_DRIVER)"
  if [[ "${V}" == "file" ]]; then check_pass "SESSION_DRIVER=file"
  else check_warn "SESSION_DRIVER='${V}' (file recommended for initial deployment)"; fi
else
  check_fail ".env missing"
  DBPORT=3306
fi

# --- Database reachability ---------------------------------------------------
DBH="$(env_get "${ENVF}" DB_HOST 2>/dev/null || true)"; DBH="${DBH:-${DB_PRIVATE_IP}}"
if check_port "${DBH}" "${DBPORT:-3306}" 5; then check_pass "TCP ${DBH}:${DBPORT:-3306} reachable"; else check_fail "TCP ${DBH}:${DBPORT:-3306} NOT reachable"; fi

# --- Laravel -----------------------------------------------------------------
if [[ -f "${APP_DIR}/artisan" && -f "${APP_DIR}/vendor/autoload.php" ]]; then
  if ( cd "${APP_DIR}" && as_web php artisan about >/dev/null 2>&1 ); then check_pass "php artisan about OK"; else check_fail "php artisan about failed"; fi
  if ( cd "${APP_DIR}" && as_web php artisan migrate:status ) ; then
    check_pass "migrate:status OK (review any 'Pending' rows above; nothing was run)"
  else
    check_fail "migrate:status failed (DB connection or credentials?)"
  fi
fi

# --- HTTP --------------------------------------------------------------------
http_code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null || echo 000; }
CODE="$(http_code http://127.0.0.1/)"
if [[ "${CODE}" =~ ^[123] || "${CODE}" == "404" || "${CODE}" == "401" || "${CODE}" == "403" ]]; then
  check_pass "curl http://127.0.0.1/ -> HTTP ${CODE}"
else
  check_fail "curl http://127.0.0.1/ -> HTTP ${CODE}"
fi
CODE="$(http_code -H "Host: ${APP_DOMAIN}" http://127.0.0.1/)"
if [[ "${CODE}" =~ ^[123] || "${CODE}" == "404" || "${CODE}" == "401" || "${CODE}" == "403" ]]; then
  check_pass "Host ${APP_DOMAIN} -> HTTP ${CODE}"
else
  check_fail "Host ${APP_DOMAIN} -> HTTP ${CODE} (503 = maintenance mode, 5xx = app error; see storage/logs and nginx error log)"
fi
CODE="$(http_code -H "Host: ${APP_DOMAIN}" http://127.0.0.1/.env)"
[[ "${CODE}" == "404" || "${CODE}" == "403" ]] && check_pass "/.env is blocked (HTTP ${CODE})" || check_fail "/.env returned HTTP ${CODE} - must be blocked!"

echo
log_info "Summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
if (( FAIL > 0 )); then log_error "Verification FAILED."; exit 1; fi
log_ok "Verification passed (${WARN} warning(s))."
