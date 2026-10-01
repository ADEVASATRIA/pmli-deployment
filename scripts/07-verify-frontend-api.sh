#!/usr/bin/env bash
# =============================================================================
# 07-verify-frontend-api.sh - READ-ONLY check that the Frontend -> API path
# still works (Frontend VM).
#
# Usage:  sudo ./scripts/07-verify-frontend-api.sh [--env PATH]
#
# Changes nothing; does not require root (curl-only), but is safe to run with
# sudo as documented in docs/DEPLOYMENT_RUNBOOK.md. Exit 1 if any check FAILS
# (warnings do not fail the run).
#
# Checks:
#   1. Direct private-network call to the API (the path already confirmed
#      working: POST /api/v1/auth/login with no credentials -> Laravel's own
#      422 validation JSON, never a 301 or a bare Nginx 404).
#   2. The SAME call through the Frontend Nginx proxy (Host: <FRONTEND_DOMAIN>,
#      http://127.0.0.1/api/...) - only if the frontend site is actually
#      installed yet; otherwise this is a WARN, not a FAIL, since
#      06-update-frontend-nginx.sh may not have run yet.
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
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

require_command curl
load_env_file "${ENV_FILE}"
for v in FRONTEND_DOMAIN API_PRIVATE_IP; do require_var "${v}"; done
API_PRIVATE_PORT="${API_PRIVATE_PORT:-80}"

PASS=0; WARN=0; FAIL=0
check_pass() { PASS=$((PASS + 1)); log_ok "$*"; }
check_warn() { WARN=$((WARN + 1)); log_warn "$*"; }
check_fail() { FAIL=$((FAIL + 1)); log_error "$*"; }

log_info "=== Frontend -> API verification (read-only) ==="

# login_check LABEL URL [EXTRA_CURL_ARGS...]
# No credentials are sent or required - a Laravel JSON response (any of
# 200/400/401/422/429) proves the request reached Laravel's own routing/
# validation; 301 or a bare Nginx 404 means the path is broken.
login_check() {
  local label="$1" url="$2"; shift 2
  local body code
  body="$(mktemp)"
  code="$(curl -sS -o "${body}" -w '%{http_code}' --max-time 10 \
    -X POST "${url}" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d '{}' "$@" 2>/dev/null || echo 000)"

  if [[ "${code}" == "301" ]]; then
    check_fail "${label}: HTTP 301 (redirecting instead of proxying to Laravel)"
  elif [[ "${code}" == "404" ]] && ! grep -q '"success"' "${body}" 2>/dev/null; then
    check_fail "${label}: HTTP 404 with a non-Laravel body (not reaching Laravel)"
  elif [[ "${code}" =~ ^(200|400|401|422|429)$ ]]; then
    check_pass "${label}: HTTP ${code} (reached Laravel; no credentials were sent)"
  else
    check_fail "${label}: HTTP ${code} (unexpected)"
  fi
  rm -f -- "${body}"
}

# --- 1. Direct private-network call (already confirmed working) ------------
login_check "Direct API (http://${API_PRIVATE_IP}:${API_PRIVATE_PORT}/api/v1/auth/login)" \
  "http://${API_PRIVATE_IP}:${API_PRIVATE_PORT}/api/v1/auth/login"

# --- 2. Through the Frontend Nginx proxy, only if it is installed ----------
FRONTEND_SITE="/etc/nginx/sites-enabled/${FRONTEND_DOMAIN}.conf"
if [[ -e "${FRONTEND_SITE}" ]]; then
  login_check "Via Frontend Nginx (Host: ${FRONTEND_DOMAIN}, http://127.0.0.1/api/v1/auth/login)" \
    "http://127.0.0.1/api/v1/auth/login" -H "Host: ${FRONTEND_DOMAIN}"
else
  check_warn "Frontend Nginx site not installed yet (${FRONTEND_SITE} not found) - skipping the proxied check. Run scripts/06-update-frontend-nginx.sh first."
fi

echo
log_info "Summary: ${PASS} passed, ${WARN} warnings, ${FAIL} failed"
if (( FAIL > 0 )); then log_error "Verification FAILED."; exit 1; fi
log_ok "Verification passed (${WARN} warning(s))."
