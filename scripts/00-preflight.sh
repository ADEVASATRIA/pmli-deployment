#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh - READ-ONLY inspection of a server before provisioning.
#
# Usage:
#   ./scripts/00-preflight.sh api [--env PATH]
#   ./scripts/00-preflight.sh db  [--env PATH]
#
# Changes NOTHING on the server. Exits non-zero only for clear critical
# incompatibilities (wrong OS, missing private IP, wrong hostname, too little
# disk/RAM). Everything else is reported as a warning.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() { echo "Usage: $0 <api|db> [--env PATH]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
MODE="$1"; shift
ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || usage; ENV_FILE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "${MODE}" == "api" || "${MODE}" == "db" ]] || usage

# Optional env file; built-in defaults are used when it does not exist.
[[ -n "${ENV_FILE}" ]] || ENV_FILE="${REPO_DIR}/env/${MODE}.env"
if [[ -f "${ENV_FILE}" ]]; then
  load_env_file "${ENV_FILE}"
else
  log_warn "No env file at ${ENV_FILE}; using built-in defaults from the known infrastructure."
fi

CRITICAL=0
crit() { log_error "$*"; CRITICAL=$((CRITICAL + 1)); }

if [[ "${MODE}" == "db" ]]; then
  : "${EXPECTED_HOSTNAME:=pmli-db-01}"
  : "${DB_BIND_ADDRESS:=192.168.50.55}"
  : "${API_PRIVATE_IP:=192.168.50.50}"
  SELF_IP="${DB_BIND_ADDRESS}"
  MIN_DISK_GB=3
  MIN_MEM_MB=3500
else
  : "${EXPECTED_HOSTNAME:=pmli-app-01-api}"
  : "${API_PRIVATE_IP:=192.168.50.50}"
  : "${DB_PRIVATE_IP:=192.168.50.55}"
  : "${PHP_VERSION:=8.3}"
  SELF_IP="${API_PRIVATE_IP}"
  MIN_DISK_GB=10
  MIN_MEM_MB=7000
fi

log_info "=== PMLI preflight (${MODE}) - read-only ==="

# --- Hostname ----------------------------------------------------------------
ACTUAL_HOST="$(hostname)"
if [[ "${ACTUAL_HOST}" == "${EXPECTED_HOSTNAME}" ]]; then
  log_ok "Hostname: ${ACTUAL_HOST}"
else
  crit "Hostname is '${ACTUAL_HOST}', expected '${EXPECTED_HOSTNAME}'. Wrong server?"
fi

# --- OS / arch ---------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  OS_ID="$(os_field ID)"; OS_VER="$(os_field VERSION_ID)"
  log_info "OS: $(os_field PRETTY_NAME)"
  if [[ "${OS_ID}" == "ubuntu" && "${OS_VER}" == "22.04" ]]; then
    log_ok "OS is Ubuntu 22.04 as expected."
  else
    crit "Expected Ubuntu 22.04, found ${OS_ID} ${OS_VER}. Scripts target 22.04 only."
  fi
else
  crit "/etc/os-release not found; cannot identify OS."
fi
ARCH="$(uname -m)"
if [[ "${ARCH}" == "x86_64" ]]; then log_ok "Architecture: ${ARCH}"; else log_warn "Architecture is ${ARCH}, expected x86_64."; fi
log_info "CPU cores: $(nproc)"

# --- Memory / disk -----------------------------------------------------------
MEM_MB="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
log_info "Memory total: ${MEM_MB} MiB"
if (( MEM_MB < MIN_MEM_MB )); then
  log_warn "Memory (${MEM_MB} MiB) is below the expected size for this role."
fi
(( MEM_MB >= 1500 )) || crit "Less than 1.5 GiB RAM; not viable."

FREE_KB="$(free_disk_kb /)"
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
log_info "Free disk on /: ~${FREE_GB} GiB"
df -h / | sed 's/^/        /'
if (( FREE_GB < MIN_DISK_GB )); then
  crit "Free disk ${FREE_GB} GiB is below the ${MIN_DISK_GB} GiB minimum for this role."
else
  log_ok "Free disk is sufficient (>= ${MIN_DISK_GB} GiB)."
fi

# --- Network -----------------------------------------------------------------
if ip_present "${SELF_IP}"; then
  log_ok "Private IP ${SELF_IP} is present on this host."
else
  crit "Expected private IP ${SELF_IP} is NOT assigned to any interface."
fi

if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  log_ok "DNS resolution works (archive.ubuntu.com)."
else
  log_warn "DNS resolution for archive.ubuntu.com failed; package installs will fail."
fi
if command -v curl >/dev/null 2>&1; then
  if curl -sSf -I --max-time 8 http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
    log_ok "Outbound HTTP works."
  else
    log_warn "Outbound HTTP to archive.ubuntu.com failed."
  fi
else
  log_warn "curl not installed; skipping outbound HTTP check."
fi

# --- Role-specific -----------------------------------------------------------
if [[ "${MODE}" == "db" ]]; then
  if command -v mysqld >/dev/null 2>&1 || dpkg -s mysql-server >/dev/null 2>&1; then
    log_warn "MySQL already appears to be installed. 01-setup-db.sh is rerunnable but review before proceeding."
  else
    log_ok "MySQL is not installed yet."
  fi
  if command -v mariadbd >/dev/null 2>&1 || dpkg -s mariadb-server >/dev/null 2>&1; then
    crit "MariaDB is installed; this repo targets MySQL 8. Resolve the conflict first."
  fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]3306$'; then
    log_warn "Something is already listening on TCP 3306:"
    ss -ltn | grep -E '[:.]3306\b' | sed 's/^/        /' || true
  else
    log_ok "Nothing is listening on 3306 yet."
  fi
  log_info "Expected DB bind address: ${DB_BIND_ADDRESS}; app user host: ${API_PRIVATE_IP}"
else
  if command -v git >/dev/null 2>&1; then log_ok "git: $(git --version)"; else log_warn "git not installed."; fi
  if check_port "${DB_PRIVATE_IP}" 3306 4; then
    log_ok "DB ${DB_PRIVATE_IP}:3306 is reachable."
  elif command -v ping >/dev/null 2>&1 && ping -c 1 -W 2 "${DB_PRIVATE_IP}" >/dev/null 2>&1; then
    log_warn "DB host ${DB_PRIVATE_IP} answers ping but port 3306 is closed (expected before DB setup)."
  else
    log_warn "DB host ${DB_PRIVATE_IP} not reachable (ICMP/3306). Expected only if DB VM is not ready."
  fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]22$'; then
    log_ok "SSH (22) is listening."
  else
    log_warn "Nothing is listening on port 22."
  fi
  for c in php composer nginx mysql; do
    if command -v "${c}" >/dev/null 2>&1; then
      log_info "${c}: already present ($(command -v "${c}"))"
    else
      log_info "${c}: not installed (will be installed by 02-setup-api.sh)."
    fi
  done
  if command -v php >/dev/null 2>&1; then
    log_info "Existing PHP: $(php -r 'echo PHP_VERSION;')"
  fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]80$'; then
    log_warn "Port 80 already in use:"; ss -ltnp 2>/dev/null | grep -E '[:.]80\b' | sed 's/^/        /' || true
  fi
fi

if command -v ufw >/dev/null 2>&1; then
  log_info "UFW: $(ufw status 2>/dev/null | head -n 1 || echo 'status needs root')"
fi

echo
if (( CRITICAL > 0 )); then
  log_error "Preflight FAILED with ${CRITICAL} critical issue(s)."
  exit 1
fi
log_ok "Preflight passed (review any [WARN] lines above)."
