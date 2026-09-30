#!/usr/bin/env bash
# =============================================================================
# common.sh - shared helpers for the PMLI deployment scripts.
#
# This file is meant to be SOURCED, never executed:
#     source "${SCRIPT_DIR}/lib/common.sh"
#
# It deliberately does not change shell options; each calling script sets
#     set -Eeuo pipefail
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "[ERROR] common.sh must be sourced, not executed." >&2
  exit 1
fi

# --- Colours (only when stdout is a terminal) --------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

# --- Logging -----------------------------------------------------------------
log_info()  { printf '%s[INFO]%s  %s\n'  "${C_BLUE}"   "${C_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n'  "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_ok()    { printf '%s[OK]%s    %s\n'  "${C_GREEN}"  "${C_RESET}" "$*"; }

# die MESSAGE - log an error and exit non-zero.
die() { log_error "$*"; exit 1; }

# --- Generic helpers ---------------------------------------------------------
timestamp() { date +%Y%m%d-%H%M%S; }

# Backups are kept outside the config directories so a stray *.bak can never
# be picked up as live configuration (e.g. by MySQL's !includedir).
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/pmli-deploy}"
BACKUP_LAST_PATH=""

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must run as root (use: sudo $0 ...)."
}

# require_command CMD [HINT]
require_command() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "Required command '${cmd}' not found.${hint:+ ${hint}}"
  fi
}

# require_file PATH [DESCRIPTION]
require_file() {
  local path="$1" desc="${2:-file}"
  [[ -f "${path}" ]] || die "Required ${desc} not found: ${path}"
}

# require_var NAME - fail if the named variable is unset or empty.
require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required variable '${name}' is not set (check your env file)."
}

# confirm_hostname EXPECTED - refuse to continue on the wrong machine.
confirm_hostname() {
  local expected="$1" actual
  actual="$(hostname)"
  if [[ "${actual}" != "${expected}" ]]; then
    die "Hostname mismatch: this host is '${actual}', expected '${expected}'. Refusing to continue on the wrong server."
  fi
  log_ok "Hostname confirmed: ${actual}"
}

# backup_file PATH - copy PATH to ${BACKUP_ROOT} with a timestamp.
# Sets BACKUP_LAST_PATH. Does nothing (and returns 0) if PATH does not exist.
backup_file() {
  local src="$1" dest
  BACKUP_LAST_PATH=""
  if [[ ! -e "${src}" ]]; then
    log_info "No existing ${src} to back up."
    return 0
  fi
  install -d -m 0700 "${BACKUP_ROOT}"
  dest="${BACKUP_ROOT}/$(basename "${src}").$(timestamp).bak"
  cp -a -- "${src}" "${dest}"
  BACKUP_LAST_PATH="${dest}"
  log_ok "Backed up ${src} -> ${dest}"
}

# validate_ipv4 ADDRESS - returns 0 if valid dotted-quad IPv4.
validate_ipv4() {
  local ip="$1" octet
  local IFS=.
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for octet in ${ip}; do
    (( 10#${octet} <= 255 )) || return 1
  done
  return 0
}

# ip_present ADDRESS - is ADDRESS assigned to a local interface?
ip_present() {
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq -- "$1"
}

# check_port HOST PORT [TIMEOUT_SECONDS] - TCP connect test, no data sent.
check_port() {
  local host="$1" port="$2" t="${3:-5}"
  timeout "${t}" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "${host}" "${port}" >/dev/null 2>&1
}

# version_ge A B - returns 0 if version A >= version B.
version_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# safe_systemctl_restart UNIT - restart, then verify the unit is active.
safe_systemctl_restart() {
  local unit="$1"
  require_command systemctl
  if ! systemctl cat "${unit}" >/dev/null 2>&1; then
    log_error "systemd unit '${unit}' does not exist."
    return 1
  fi
  log_info "Restarting ${unit} ..."
  if ! systemctl restart "${unit}"; then
    log_error "Restart of ${unit} failed. Recent log:"
    journalctl -u "${unit}" -n 30 --no-pager >&2 || true
    return 1
  fi
  sleep 2
  if ! systemctl is-active --quiet "${unit}"; then
    log_error "${unit} is not active after restart. Recent log:"
    journalctl -u "${unit}" -n 30 --no-pager >&2 || true
    return 1
  fi
  log_ok "${unit} is active."
}

# --- Env-file handling -------------------------------------------------------

# load_env_file PATH - read KEY=VALUE lines WITHOUT executing the file.
# Variables already present in the environment win, so a secret supplied at
# runtime (e.g. DB_APP_PASSWORD) is never overridden by a file.
load_env_file() {
  local file="$1" line key val
  require_file "${file}" "env file"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "${val}" =~ ^\"(.*)\"$ || "${val}" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      if [[ -z "${!key+x}" ]]; then
        export "${key}=${val}"
      fi
    else
      log_warn "Ignoring unparsable line in ${file}"
    fi
  done < "${file}"
  log_info "Loaded env file: ${file}"
}

# env_get FILE KEY - print the value of KEY from a Laravel-style .env file.
# Prints nothing if absent. Never logs the value; callers decide what to show.
env_get() {
  local file="$1" key="$2" line val
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ "${val}" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then
    val="${BASH_REMATCH[1]}"
  elif [[ "${val}" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
    val="${BASH_REMATCH[1]}"
  else
    val="${val%%[[:space:]]#*}"
    val="${val%"${val##*[![:space:]]}"}"
  fi
  printf '%s' "${val}"
}

# --- System info helpers -----------------------------------------------------

# free_disk_kb PATH - free space (KiB) on the filesystem holding PATH.
free_disk_kb() { df -Pk -- "$1" | awk 'NR==2 {print $4}'; }

# show_disk LABEL - print human-readable free space for /.
show_disk() {
  log_info "Disk ($1):"
  df -h / | sed 's/^/        /'
}

# os_field KEY - read a field from /etc/os-release.
os_field() {
  ( . /etc/os-release 2>/dev/null && printf '%s' "${!1:-}" )
}
