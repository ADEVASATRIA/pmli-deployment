#!/usr/bin/env bash
# =============================================================================
# update-api.sh - interactive update of an already-deployed Laravel backend
# (API VM): git pull -> composer -> DB backup -> migrate (with confirmation)
# -> caches -> PHP-FPM restart -> summary.
#
# Usage:  ./scripts/update-api.sh [APP_DIR] [--backup-tables "a b"]
#         APP_DIR defaults to /var/www/pmli-backend.
#         Run as an admin user with sudo (or root); git/composer/artisan always
#         run as the OWNER of APP_DIR via `sudo -u <owner>`, never as root.
# Env:    PHP_VERSION=8.3   WEB_USER=www-data
#
# Differs from 03-deploy-app.sh: this one DOES `git pull --ff-only` and, after
# you type y, `migrate --force`. Use 03 for provisioning/Nginx/PHP-ini changes.
# Backup: --backup-tables dumps only those tables; without it the WHOLE database
# is dumped. Credentials come from the app's .env through a temporary 0600
# defaults file (removed on exit); nothing secret is printed or put on a CLI.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP="/var/www/pmli-backend"; TABLES=""; PHP_VERSION="${PHP_VERSION:-8.3}"; WEB_USER="${WEB_USER:-www-data}"
POS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-tables) [[ $# -ge 2 ]] || die "--backup-tables needs a value, e.g. \"users courses\""; TABLES="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) (( POS == 0 )) || die "Only one APP_DIR is accepted."; APP="${1%/}"; POS=1; shift ;;
  esac
done
[[ "${TABLES}" =~ ^[A-Za-z0-9_\ ]*$ ]] || die "--backup-tables may only contain table names (letters, digits, _) separated by spaces."

for c in git composer php mysqldump curl sudo stat; do require_command "${c}"; done
[[ -d "${APP}" && -f "${APP}/artisan" && -f "${APP}/.env" ]] || die "${APP} is not a Laravel app (artisan/.env missing)."

OWNER="$(stat -c '%U' "${APP}")"
[[ "${OWNER}" != "root" ]] || die "${APP} is owned by root; artisan/composer must not run as root. chown it to the deploy/web user first."
if [[ "$(id -un)" == "${OWNER}" ]]; then run_as() { "$@"; }; else run_as() { sudo -H -u "${OWNER}" -- "$@"; }; fi
if [[ "$(id -u)" -eq 0 ]]; then priv() { "$@"; }; else priv() { sudo "$@"; }; fi
[[ "${OWNER}" == "${WEB_USER}" ]] || log_warn "Owner is '${OWNER}', not '${WEB_USER}': files artisan creates in storage/ must stay writable by ${WEB_USER} (shared group, or chown per scripts/03-deploy-app.sh)."

cd "${APP}"
ENV_TXT="$(run_as cat "${APP}/.env")" || die "Cannot read ${APP}/.env as ${OWNER}."
# envv KEY - value from .env (never echoed by this script except non-secret APP_URL).
envv() {
  local line val
  line="$(printf '%s\n' "${ENV_TXT}" | grep -E "^[[:space:]]*$1=" | tail -n 1 || true)"
  val="${line#*=}"; val="${val%$'\r'}"
  if [[ "${val}" =~ ^\"(.*)\"$ || "${val}" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
  printf '%s' "${val}"
}

# --- Cleanup: temp credentials + guaranteed `artisan up` ----------------------
MAINT=0; CNF=""
on_exit() {
  local rc=$?
  [[ -z "${CNF}" ]] || rm -f -- "${CNF}"
  if (( MAINT )); then
    log_warn "Exiting while in maintenance mode - attempting 'artisan up' ..."
    run_as php artisan up || log_error "FAILED to bring the app up. Run: cd ${APP} && sudo -u ${OWNER} php artisan up"
  fi
  if (( rc != 0 )); then log_error "Update aborted (exit ${rc}). Nothing after the failed step was run."; fi
}
trap on_exit EXIT

# --- 1. git pull -----------------------------------------------------------
BEFORE="$(run_as git -C "${APP}" rev-parse --short HEAD)"
log_info "git pull --ff-only (branch $(run_as git -C "${APP}" rev-parse --abbrev-ref HEAD)) ..."
run_as git -C "${APP}" pull --ff-only
AFTER="$(run_as git -C "${APP}" rev-parse --short HEAD)"
log_ok "Commit: ${BEFORE} -> ${AFTER}"

# --- 2. composer -------------------------------------------------------------
log_info "composer install --no-dev --optimize-autoloader ..."
run_as composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction

# --- 3. DB backup ------------------------------------------------------------
[[ "$(envv DB_CONNECTION)" == "mysql" || "$(envv DB_CONNECTION)" == "mariadb" ]] || die "DB_CONNECTION is not mysql/mariadb; backup step not supported."
DB_NAME="$(envv DB_DATABASE)"; DB_USER="$(envv DB_USERNAME)"; DB_HOST="$(envv DB_HOST)"; DB_PORT="$(envv DB_PORT)"
[[ -n "${DB_NAME}" && -n "${DB_USER}" && -n "${DB_HOST}" && -n "$(envv DB_PASSWORD)" ]] || die "DB_HOST/DB_DATABASE/DB_USERNAME/DB_PASSWORD incomplete in .env."
[[ "${DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "Unexpected characters in DB_DATABASE."

umask 077
install -d -m 0700 "${HOME}/backups"
BACKUP="${HOME}/backups/${DB_NAME}-$(timestamp).sql"
CNF="$(mktemp)"
esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
{
  echo "[client]"
  echo "user=\"$(esc "${DB_USER}")\""
  echo "password=\"$(esc "$(envv DB_PASSWORD)")\""
  echo "host=\"$(esc "${DB_HOST}")\""
  echo "port=${DB_PORT:-3306}"
} > "${CNF}"
chmod 600 "${CNF}"

if [[ -n "${TABLES}" ]]; then log_info "Backing up tables [${TABLES}] of ${DB_NAME} ..."; else log_warn "No --backup-tables given: dumping the WHOLE database ${DB_NAME}."; fi
# shellcheck disable=SC2086  # TABLES is validated above and intentionally word-split
mysqldump --defaults-extra-file="${CNF}" --single-transaction --no-tablespaces "${DB_NAME}" ${TABLES} > "${BACKUP}"
rm -f -- "${CNF}"; CNF=""
[[ -s "${BACKUP}" ]] || die "Backup file is empty: ${BACKUP}"
chmod 600 "${BACKUP}"
log_ok "Backup written: ${BACKUP} ($(du -h "${BACKUP}" | cut -f1))"

# --- 4. Pending migrations + dry run + confirmation ---------------------------
STATUS="$(run_as php artisan migrate:status --no-ansi)" || die "migrate:status failed (DB connection?)."
PENDING="$(printf '%s\n' "${STATUS}" | grep -i 'pending' || true)"
RAN_MIGRATIONS=""
if [[ -z "${PENDING}" ]]; then
  log_ok "No pending migrations; migrate will be skipped."
else
  log_info "Pending migrations:"; printf '%s\n' "${PENDING}" | sed 's/^/    /'
  log_info "migrate --pretend (SQL preview, nothing executed):"
  run_as php artisan migrate --pretend --force --no-ansi
  [[ -t 0 ]] || die "Confirmation needed but no terminal available."
  read -r -p "Lanjutkan migrate --force pada ${DB_NAME}? Backup: ${BACKUP}  [y/N] " ANS
  [[ "${ANS}" =~ ^[yY]$ ]] || die "Dibatalkan oleh operator. Kode sudah ter-pull (${AFTER}); database TIDAK diubah."
  RAN_MIGRATIONS="$(printf '%s\n' "${PENDING}" | awk '{print $1}')"
fi

# --- 5. Maintenance window ---------------------------------------------------
run_as php artisan down --retry=60
MAINT=1
log_info "Maintenance mode enabled."
if [[ -n "${PENDING}" ]]; then run_as php artisan migrate --force --no-ansi; fi
run_as php artisan optimize:clear
run_as php artisan config:cache
run_as php artisan route:cache
run_as php artisan event:cache
run_as php artisan up
MAINT=0
log_ok "Maintenance mode disabled."
run_as php artisan queue:restart

# --- 6. PHP-FPM --------------------------------------------------------------
priv systemctl restart "php${PHP_VERSION}-fpm"
sleep 2
priv systemctl is-active --quiet "php${PHP_VERSION}-fpm" || die "php${PHP_VERSION}-fpm is not active after restart."
log_ok "php${PHP_VERSION}-fpm restarted."

# --- 7. Summary --------------------------------------------------------------
BASE="$(envv APP_URL)"; BASE="${BASE%/}"
probe() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE}$1" 2>/dev/null || echo 000; }
echo
log_info "=== update-api.sh summary ==="
log_info "Commit:      ${BEFORE} -> ${AFTER}"
log_info "Migrations:  ${RAN_MIGRATIONS:-none run}"
log_info "Backup:      ${BACKUP}"
if [[ -n "${BASE}" ]]; then
  log_info "App status:  ${BASE}/health -> HTTP $(probe /health) | ${BASE}/up -> HTTP $(probe /up)"
else
  log_warn "APP_URL not set in .env; HTTP status not checked."
fi
log_ok "Update finished."
