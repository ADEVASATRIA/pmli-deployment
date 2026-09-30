#!/usr/bin/env bash
# =============================================================================
# 01-setup-db.sh - provision MySQL 8 on the DB VM (pmli-db-01).
#
# Usage:  sudo ./scripts/01-setup-db.sh [--env PATH]
#
# Does:
#   * installs mysql-server, binds it to DB_BIND_ADDRESS only (backup first)
#   * creates the database (if absent) and ONE app user restricted to
#     API_PRIVATE_IP with privileges on that database only
# Does NOT:
#   * import SQL, run migrations, enable UFW, run mysql_secure_installation,
#     touch root authentication, or create any '%' host account.
#
# Password: DB_APP_PASSWORD from the environment / ignored env file, or an
# interactive hidden prompt. It is never printed, never passed on a command
# line (SQL goes over stdin).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${REPO_DIR}/env/db.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) [[ $# -ge 2 ]] || die "--env needs a path"; ENV_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

DROPIN=/etc/mysql/mysql.conf.d/zz-pmli-bind.cnf
MAIN_CNF=/etc/mysql/mysql.conf.d/mysqld.cnf

# --- Pre-checks --------------------------------------------------------------
require_root
require_command apt-get
require_command systemctl
require_command ip
require_command awk
load_env_file "${ENV_FILE}"
for v in EXPECTED_HOSTNAME DB_BIND_ADDRESS API_PRIVATE_IP DB_NAME DB_APP_USER; do require_var "${v}"; done
confirm_hostname "${EXPECTED_HOSTNAME}"

validate_ipv4 "${DB_BIND_ADDRESS}" || die "DB_BIND_ADDRESS is not a valid IPv4: ${DB_BIND_ADDRESS}"
validate_ipv4 "${API_PRIVATE_IP}"  || die "API_PRIVATE_IP must be one exact IPv4 (no wildcards): ${API_PRIVATE_IP}"
[[ "${DB_BIND_ADDRESS}" != "0.0.0.0" ]] || die "Refusing to bind MySQL to 0.0.0.0."
ip_present "${DB_BIND_ADDRESS}" || die "DB_BIND_ADDRESS ${DB_BIND_ADDRESS} is not assigned to this host."
[[ "${DB_NAME}"     =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME may only contain letters, digits, underscore."
[[ "${DB_APP_USER}" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_APP_USER may only contain letters, digits, underscore."
[[ "${DB_APP_USER}" != "root" ]] || die "DB_APP_USER must not be root."

FREE_KB="$(free_disk_kb /)"
(( FREE_KB > 3 * 1024 * 1024 )) || die "Less than 3 GiB free on /; refusing to install MySQL."
show_disk "before"

# --- Obtain the app password without echoing it ------------------------------
if [[ -z "${DB_APP_PASSWORD:-}" ]]; then
  [[ -t 0 ]] || die "DB_APP_PASSWORD not set and no terminal to prompt on."
  read -r -s -p "Enter password for '${DB_APP_USER}'@'${API_PRIVATE_IP}': " DB_APP_PASSWORD; echo
  read -r -s -p "Repeat password: " _pw2; echo
  [[ "${DB_APP_PASSWORD}" == "${_pw2}" ]] || die "Passwords do not match."
  unset _pw2
fi
(( ${#DB_APP_PASSWORD} >= 16 )) || die "DB_APP_PASSWORD must be at least 16 characters."
# These characters would break the SQL literal; reject rather than escape.
case "${DB_APP_PASSWORD}" in
  *"'"*|*'\'*|*'`'*|*$'\n'*) die "DB_APP_PASSWORD must not contain ', \\, \` or newlines." ;;
esac
export DB_APP_PASSWORD

# --- Install MySQL -----------------------------------------------------------
log_info "Installing mysql-server (apt-get update + install) ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends mysql-server mysql-client ca-certificates iproute2
systemctl enable --now mysql
require_command mysql
require_command mysqld

MYSQL_VER="$(mysql --protocol=socket -uroot -Nse 'SELECT VERSION()')"
version_ge "${MYSQL_VER%%-*}" "8.0.0" || die "MySQL ${MYSQL_VER} is older than 8.0."
log_ok "MySQL version: ${MYSQL_VER}"

# --- Bind address (drop-in override, with backups + validation) --------------
log_info "Configuring bind-address=${DB_BIND_ADDRESS} via ${DROPIN}"
NEW_CNF="$(mktemp)"
trap 'rm -f -- "${NEW_CNF:-}"' EXIT
cat > "${NEW_CNF}" <<EOF
# Managed by pmli-deployment/scripts/01-setup-db.sh
# Loaded after mysqld.cnf (alphabetical), so it overrides bind-address.
[mysqld]
bind-address = ${DB_BIND_ADDRESS}
EOF

CONFIG_CHANGED=0
if [[ -f "${DROPIN}" ]] && cmp -s "${NEW_CNF}" "${DROPIN}"; then
  log_ok "Bind drop-in already up to date."
else
  CONFIG_CHANGED=1
  [[ -f "${MAIN_CNF}" ]] && backup_file "${MAIN_CNF}"
  HAD_DROPIN=0
  if [[ -f "${DROPIN}" ]]; then HAD_DROPIN=1; backup_file "${DROPIN}"; DROPIN_BACKUP="${BACKUP_LAST_PATH}"; fi
  install -m 0644 -o root -g root "${NEW_CNF}" "${DROPIN}"

  rollback_cnf() {
    log_warn "Rolling back MySQL bind configuration."
    if (( HAD_DROPIN )); then cp -a -- "${DROPIN_BACKUP}" "${DROPIN}"; else rm -f -- "${DROPIN}"; fi
  }

  log_info "Validating MySQL configuration ..."
  if ! mysqld --validate-config --user=mysql; then
    rollback_cnf
    die "mysqld --validate-config failed; configuration rolled back, MySQL not restarted."
  fi
  log_ok "Configuration is valid."

  if ! safe_systemctl_restart mysql; then
    rollback_cnf
    safe_systemctl_restart mysql || log_error "MySQL failed to restart even after rollback - investigate manually."
    die "MySQL restart failed with the new bind address; rolled back."
  fi
fi

# --- Verify listener ---------------------------------------------------------
LISTEN="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -E '[:.]3306$' || true)"
if grep -Fxq "${DB_BIND_ADDRESS}:3306" <<<"${LISTEN}"; then
  log_ok "MySQL is listening on ${DB_BIND_ADDRESS}:3306"
else
  die "MySQL is not listening on ${DB_BIND_ADDRESS}:3306 (saw: ${LISTEN:-nothing})."
fi
if grep -Eq '^(0\.0\.0\.0|\*|\[::\]|::):3306$' <<<"${LISTEN}"; then
  die "MySQL is listening on ALL interfaces. This must not happen; check /etc/mysql for other bind-address settings."
fi

# --- Database + application user --------------------------------------------
log_info "Creating database '${DB_NAME}' (if absent) and user '${DB_APP_USER}'@'${API_PRIVATE_IP}' ..."
# Local root uses auth_socket; running as OS root needs no password.
# SQL (incl. the password) is passed on stdin, never on the command line.
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_APP_USER}'@'${API_PRIVATE_IP}' IDENTIFIED BY '${DB_APP_PASSWORD}';
ALTER USER '${DB_APP_USER}'@'${API_PRIVATE_IP}' IDENTIFIED BY '${DB_APP_PASSWORD}';
-- DDL privileges (CREATE, ALTER, DROP, INDEX, REFERENCES) are retained so migrations can be run MANUALLY later.
-- Migrations are never run by this script. Review/narrow these after production stabilization.
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES, CREATE TEMPORARY TABLES, LOCK TABLES
  ON \`${DB_NAME}\`.* TO '${DB_APP_USER}'@'${API_PRIVATE_IP}';
FLUSH PRIVILEGES;
SQL
unset DB_APP_PASSWORD
log_ok "Database and application user are in place."

WILDCARD="$(mysql --protocol=socket -uroot -Nse "SELECT CONCAT(user,'@',host) FROM mysql.user WHERE user='${DB_APP_USER}' AND host='%'")"
if [[ -n "${WILDCARD}" ]]; then
  log_warn "A wildcard account exists: ${WILDCARD}. Remove it manually: DROP USER '${DB_APP_USER}'@'%';"
else
  log_ok "No '%' host account exists for ${DB_APP_USER}."
fi

show_disk "after"

cat <<EOF

================ NEXT STEPS (manual) ================
1. Transfer your dump to this VM, e.g. from your workstation:
     scp /path/to/pmli_lms.sql <ssh-user>@${DB_BIND_ADDRESS}:/home/<ssh-user>/
2. BEFORE importing, check disk:      df -h /
   (if the DB already has data, take a backup first - see docs/ROLLBACK.md)
3. Import (you will be prompted for the MySQL root password/socket auth):
     sudo mysql -u root ${DB_NAME} < /path/to/pmli_lms.sql
   (conceptually: mysql -u root -p ${DB_NAME} < /path/to/pmli_lms.sql)
4. Verify:
     sudo mysql -e "SHOW DATABASES LIKE '${DB_NAME}';"
     sudo mysql -e "SELECT COUNT(*) AS tables_count FROM information_schema.tables WHERE table_schema='${DB_NAME}';"
     sudo mysql -e "SHOW GRANTS FOR '${DB_APP_USER}'@'${API_PRIVATE_IP}';"
     ss -ltn | grep 3306        # must show ${DB_BIND_ADDRESS}:3306 only
     df -h /
5. From the API VM (${API_PRIVATE_IP}):
     mysql -h ${DB_BIND_ADDRESS} -u ${DB_APP_USER} -p ${DB_NAME} -e 'SELECT 1;'
No SQL was imported and no migration was run by this script.
=====================================================
EOF
log_ok "DB provisioning finished."
