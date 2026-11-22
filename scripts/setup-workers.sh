#!/usr/bin/env bash
# =============================================================================
# setup-workers.sh - scheduler (cron) and queue worker (systemd) for the Laravel
# backend on the API VM. Idempotent: safe to re-run; only changes what differs.
#
# Usage:  sudo ./scripts/setup-workers.sh [APP_DIR] [--dry-run]
#         APP_DIR defaults to /var/www/pmli-backend.
# Env:    WEB_USER=www-data   (same default as update-api.sh)
#
# 1. Scheduler: if no `schedule:run` exists in the crontab of OWNER / WEB_USER /
#    root or in /etc/cron.d, creates /etc/cron.d/pmli-scheduler (every minute,
#    as WEB_USER).
# 2. Queue worker: writes /etc/systemd/system/pmli-queue.service (queue:work on
#    the `database` connection, queues cen,default), then enable --now.
# OWNER = owner of APP_DIR (as in update-api.sh). Never prints .env values
# (only QUEUE_CONNECTION / CACHE_STORE, which are not secret).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

APP="/var/www/pmli-backend"; DRY=0; POS=0
WEB_USER="${WEB_USER:-www-data}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) (( POS == 0 )) || die "Only one APP_DIR is accepted."; APP="${1%/}"; POS=1; shift ;;
  esac
done

require_root
for c in systemctl php stat crontab; do require_command "${c}"; done
[[ "${APP}" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "APP_DIR '${APP}' contains unexpected characters."
[[ -d "${APP}" && -f "${APP}/artisan" && -f "${APP}/.env" ]] || die "${APP} is not a Laravel app (artisan/.env missing)."
OWNER="$(stat -c '%U' "${APP}")"
id "${WEB_USER}" >/dev/null 2>&1 || die "Web user '${WEB_USER}' does not exist (set WEB_USER=...)."
PHP_BIN="$(command -v php)"; [[ -x "${PHP_BIN}" ]] || die "Cannot resolve the php binary."
(( DRY )) && log_warn "DRY RUN: nothing will be changed."
log_info "app=${APP} owner=${OWNER} web_user=${WEB_USER} php=${PHP_BIN}"

do_it() { if (( DRY )); then log_info "[dry-run] would run: $*"; else "$@"; fi; }
RC=0

# --- 0. Sanity: the worker runs as WEB_USER -----------------------------------
sudo -n -u "${WEB_USER}" test -r "${APP}/.env" || { log_warn "${WEB_USER} cannot read ${APP}/.env - the worker would crash-loop."; RC=1; }
sudo -n -u "${WEB_USER}" test -w "${APP}/storage" || { log_warn "${WEB_USER} cannot write ${APP}/storage - fix permissions (update-api.sh does it) before relying on the worker."; RC=1; }
for k in QUEUE_CONNECTION CACHE_STORE; do
  v="$(grep -E "^[[:space:]]*${k}=" "${APP}/.env" | tail -n 1 | cut -d= -f2- | tr -d '"'"'"'\r' || true)"
  log_info "${k}=${v:-<not set>}"
  if [[ "${k}" == "QUEUE_CONNECTION" && "${v}" != "database" ]]; then log_warn "QUEUE_CONNECTION is not 'database'; the unit below runs 'queue:work database'."; fi
done

# --- 1. Scheduler ----------------------------------------------------------------
FOUND=""
for u in "${OWNER}" "${WEB_USER}" root; do
  ct="$(crontab -l -u "${u}" 2>/dev/null || true)"
  if grep -q 'schedule:run' <<<"${ct}"; then FOUND="${FOUND} crontab:${u}"; fi
done
CRON_HITS="$(grep -rls 'schedule:run' /etc/cron.d 2>/dev/null || true)"
for f in ${CRON_HITS}; do FOUND="${FOUND} ${f}"; done
CRON_FILE="/etc/cron.d/pmli-scheduler"
if [[ -n "${FOUND}" ]]; then
  SCHED_STATUS="already present:${FOUND}"
  log_ok "schedule:run already configured in:${FOUND} (nothing to do)."
else
  CRON_TXT="* * * * * ${WEB_USER} cd ${APP} && ${PHP_BIN} artisan schedule:run >> /dev/null 2>&1"$'\n'
  if (( DRY )); then
    SCHED_STATUS="would create ${CRON_FILE}"
    log_info "[dry-run] would write ${CRON_FILE} (0644):"; printf '%s' "${CRON_TXT}" | sed 's/^/    /'
  else
    tmp="$(mktemp)"; printf '%s' "${CRON_TXT}" > "${tmp}"
    install -m 0644 -o root -g root "${tmp}" "${CRON_FILE}"; rm -f -- "${tmp}"
    SCHED_STATUS="created ${CRON_FILE}"
    log_ok "Created ${CRON_FILE}:"; sed 's/^/    /' "${CRON_FILE}"
  fi
fi

# --- 2. Queue worker (systemd) ---------------------------------------------------
UNIT="/etc/systemd/system/pmli-queue.service"
UNIT_TXT="[Unit]
Description=PMLI Laravel queue worker
After=network-online.target
Wants=network-online.target

[Service]
User=${WEB_USER}
WorkingDirectory=${APP}
ExecStart=${PHP_BIN} artisan queue:work database --queue=cen,default --sleep=3 --tries=3 --backoff=60 --max-time=3600 --memory=256
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=pmli-queue

[Install]
WantedBy=multi-user.target
"
CHANGED=0
if [[ -f "${UNIT}" ]] && printf '%s' "${UNIT_TXT}" | cmp -s - "${UNIT}"; then
  log_ok "${UNIT} is up to date."
else
  CHANGED=1
  if (( DRY )); then log_info "[dry-run] would write ${UNIT}:"; printf '%s' "${UNIT_TXT}" | sed 's/^/    /'
  else
    backup_file "${UNIT}"
    tmp="$(mktemp)"; printf '%s' "${UNIT_TXT}" > "${tmp}"
    install -m 0644 -o root -g root "${tmp}" "${UNIT}"; rm -f -- "${tmp}"
    log_ok "Wrote ${UNIT}."
  fi
fi
WAS_ACTIVE=0; systemctl is-active --quiet pmli-queue.service 2>/dev/null && WAS_ACTIVE=1
do_it systemctl daemon-reload
do_it systemctl enable --now pmli-queue.service
if (( CHANGED && WAS_ACTIVE )); then do_it systemctl restart pmli-queue.service; fi

WORKER_STATUS="(dry-run)"
if (( ! DRY )); then
  sleep 3
  WORKER_STATUS="$(systemctl is-active pmli-queue.service 2>/dev/null || true)"
  log_info "systemctl is-active pmli-queue: ${WORKER_STATUS}"
  log_info "Last 10 journal lines:"; journalctl -u pmli-queue -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || true
  [[ "${WORKER_STATUS}" == "active" ]] || { log_warn "pmli-queue is not active."; RC=1; }
fi

# --- 3. Summary ------------------------------------------------------------------
echo
log_info "=== setup-workers.sh summary ==="
log_info "Scheduler:  ${SCHED_STATUS}"
log_info "Worker:     pmli-queue.service -> ${WORKER_STATUS}"
log_info "Check later:  systemctl status pmli-queue   |   journalctl -u pmli-queue -n 50"
log_info "              cat ${CRON_FILE}   |   grep CRON /var/log/syslog | tail"
(( RC == 0 )) && log_ok "Done." || log_warn "Done with warnings (see above)."
exit "${RC}"
