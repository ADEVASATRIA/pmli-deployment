#!/usr/bin/env bash
# =============================================================================
# 02-setup-api.sh - provision the runtime stack on the API VM.
#
# Usage:  sudo ./scripts/02-setup-api.sh [--env PATH] [--allow-php-ppa]
#
# Installs: Nginx, PHP (PHP_VERSION, default 8.3) + FPM + required extensions,
# MySQL client, Composer 2 (installer checksum verified).
#
# Does NOT: clone/create the Laravel app, touch its .env, enable UFW,
# request secrets, or install anything via "curl | bash".
#
# THIRD-PARTY REPOSITORY NOTE
#   Ubuntu 22.04 ships PHP 8.1 only. PHP 8.3 requires the widely used
#   maintained PPA  ppa:ondrej/php  (Ondřej Surý, Debian PHP maintainer).
#   It is added ONLY if PHP ${PHP_VERSION} is not available from the current
#   apt sources AND you explicitly consent via --allow-php-ppa or
#   ALLOW_PHP_PPA=yes in env/api.env. Otherwise the script stops.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_DIR}/env/api.env"
CLI_ALLOW_PPA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || die "--env needs a path"; ENV_FILE="$2"; shift 2 ;;
    --allow-php-ppa) CLI_ALLOW_PPA=1; shift ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Pre-checks --------------------------------------------------------------
require_root
require_command apt-get
require_command systemctl
load_env_file "${ENV_FILE}"
for v in EXPECTED_HOSTNAME API_PRIVATE_IP DB_PRIVATE_IP APP_DOMAIN APP_DIR PHP_VERSION WEB_USER WEB_GROUP; do
  require_var "${v}"
done
confirm_hostname "${EXPECTED_HOSTNAME}"
validate_ipv4 "${API_PRIVATE_IP}" || die "Invalid API_PRIVATE_IP: ${API_PRIVATE_IP}"
validate_ipv4 "${DB_PRIVATE_IP}"  || die "Invalid DB_PRIVATE_IP: ${DB_PRIVATE_IP}"
[[ "${PHP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || die "PHP_VERSION must look like 8.3"
[[ "$(os_field ID)" == "ubuntu" && "$(os_field VERSION_ID)" == "22.04" ]] || die "This script supports Ubuntu 22.04 only."
(( $(free_disk_kb /) > 5 * 1024 * 1024 )) || die "Less than 5 GiB free on /; refusing to continue."
show_disk "before"

export DEBIAN_FRONTEND=noninteractive
PV="${PHP_VERSION}"

# --- Base prerequisites ------------------------------------------------------
log_info "Installing base prerequisites ..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg unzip git iproute2 software-properties-common

# --- PHP repository decision -------------------------------------------------
php_candidate() { apt-cache policy "php${PV}-fpm" 2>/dev/null | awk '/Candidate:/ {print $2}'; }
CAND="$(php_candidate || true)"
if [[ -z "${CAND}" || "${CAND}" == "(none)" ]]; then
  log_warn "php${PV}-fpm is NOT available from the configured apt sources."
  if [[ "${CLI_ALLOW_PPA}" -eq 1 || "${ALLOW_PHP_PPA:-no}" == "yes" ]]; then
    log_warn "Adding THIRD-PARTY repository ppa:ondrej/php (consented). Reason: Ubuntu 22.04 lacks PHP ${PV}."
    add-apt-repository -y ppa:ondrej/php
    apt-get update -y
    CAND="$(php_candidate || true)"
    [[ -n "${CAND}" && "${CAND}" != "(none)" ]] || die "php${PV}-fpm still unavailable after adding the PPA."
    log_ok "PPA added; php${PV}-fpm candidate: ${CAND}"
  else
    die "PHP ${PV} is not available. Re-run with --allow-php-ppa (or ALLOW_PHP_PPA=yes) to consent to adding ppa:ondrej/php, or provide PHP ${PV} another way."
  fi
else
  log_ok "php${PV}-fpm available from existing sources (${CAND}); no extra repository needed."
fi

# --- Packages ----------------------------------------------------------------
# dom/simplexml/xmlreader/xmlwriter come from php-xml; ctype/tokenizer/openssl/
# fileinfo are bundled in php-common (pulled in as a dependency).
PKGS=(
  nginx
  "php${PV}-cli" "php${PV}-fpm" "php${PV}-common"
  "php${PV}-mysql" "php${PV}-mbstring" "php${PV}-xml" "php${PV}-curl"
  "php${PV}-zip" "php${PV}-gd" "php${PV}-bcmath"
  mysql-client
)
log_info "Installing: ${PKGS[*]}"
apt-get install -y --no-install-recommends "${PKGS[@]}"

# --- Composer (official installer, checksum verified) ------------------------
if command -v composer >/dev/null 2>&1 && composer --version 2>/dev/null | grep -Eq 'Composer version 2\.'; then
  log_ok "Composer 2 already installed: $(composer --version 2>/dev/null | head -n 1)"
else
  log_info "Installing Composer using the official installer with checksum verification ..."
  CTMP="$(mktemp -d)"
  cleanup_composer() { rm -f -- "${CTMP}/composer-setup.php" "${CTMP}/installer.sig"; rmdir -- "${CTMP}" 2>/dev/null || true; }
  trap cleanup_composer EXIT
  EXPECTED_SIG="$(curl -fsSL --max-time 30 https://composer.github.io/installer.sig)"
  [[ "${EXPECTED_SIG}" =~ ^[0-9a-f]{96}$ ]] || die "Unexpected Composer installer signature format; aborting."
  curl -fsSL --max-time 60 -o "${CTMP}/composer-setup.php" https://getcomposer.org/installer
  ACTUAL_SIG="$("php${PV}" -r "echo hash_file('sha384', '${CTMP}/composer-setup.php');")"
  if [[ "${EXPECTED_SIG}" != "${ACTUAL_SIG}" ]]; then
    die "Composer installer checksum MISMATCH. Refusing to run it."
  fi
  log_ok "Composer installer checksum verified."
  "php${PV}" "${CTMP}/composer-setup.php" --2 --quiet --install-dir=/usr/local/bin --filename=composer
  cleanup_composer
  trap - EXIT
fi

# --- Verify tool versions ----------------------------------------------------
log_info "Verifying installed components ..."
php -v | head -n 1
php -r 'exit(version_compare(PHP_VERSION, "8.3.0", ">=") ? 0 : 1);' \
  || die "Active 'php' CLI is older than 8.3. Check: update-alternatives --display php"

REQUIRED_EXT=(ctype tokenizer openssl fileinfo mbstring xml dom SimpleXML xmlreader xmlwriter curl zip gd bcmath pdo_mysql mysqlnd)
MODULES="$(php -m)"
MISSING=()
for e in "${REQUIRED_EXT[@]}"; do
  grep -Fxiq -- "${e}" <<<"${MODULES}" || MISSING+=("${e}")
done
(( ${#MISSING[@]} == 0 )) || die "Missing PHP extensions: ${MISSING[*]}"
log_ok "All required PHP extensions are loaded."

"php-fpm${PV}" -v | head -n 1
"php-fpm${PV}" -t
composer --version
nginx -v
mysql --version

# --- Services ----------------------------------------------------------------
systemctl enable --now nginx "php${PV}-fpm"
systemctl is-active --quiet nginx           || die "nginx is not active."
systemctl is-active --quiet "php${PV}-fpm"  || die "php${PV}-fpm is not active."
log_ok "nginx and php${PV}-fpm are enabled and running."

# --- DB connectivity (informational) ----------------------------------------
if check_port "${DB_PRIVATE_IP}" 3306 5; then
  log_ok "DB ${DB_PRIVATE_IP}:3306 is reachable from this VM."
else
  log_warn "DB ${DB_PRIVATE_IP}:3306 is NOT reachable yet. Finish DB setup / check the cloud Security Group, then re-test:  nc -vz ${DB_PRIVATE_IP} 3306"
fi

show_disk "after"
cat <<EOF

Next (manual):
  1. git clone <backend-repo-url> ${APP_DIR}
  2. Create ${APP_DIR}/.env for production (see docs/DEPLOYMENT_RUNBOOK.md, Phase G)
  3. sudo ./scripts/03-deploy-app.sh
UFW was not touched. No application files were created.
EOF
log_ok "API provisioning finished."
