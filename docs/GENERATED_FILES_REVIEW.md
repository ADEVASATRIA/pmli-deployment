# Generated Files Review

## Files created

| File | Purpose |
|------|---------|
| `README.md` | Overview, server mapping, execution order, what is not automated |
| `.gitignore` | Ignores real env files, logs, dumps, `.DS_Store`, temp artifacts (keeps `*.env.example`) |
| `env/db.env.example` | Non-secret DB VM settings (no password) |
| `env/api.env.example` | Non-secret API VM settings, incl. `ALLOW_PHP_PPA` consent flag |
| `scripts/lib/common.sh` | Logging, `require_*`, `confirm_hostname`, `backup_file`, `validate_ipv4`, `check_port`, `safe_systemctl_restart`, safe env-file parsing |
| `scripts/00-preflight.sh` | Read-only checks for `api` / `db`; non-zero only on critical mismatch |
| `scripts/01-setup-db.sh` | MySQL 8 install, private-IP bind (backup + validation + auto-rollback), DB + restricted user |
| `scripts/02-setup-api.sh` | Nginx, PHP 8.3-FPM + extensions, MySQL client, checksum-verified Composer |
| `scripts/03-deploy-app.sh` | Composer install, perms, storage link, `migrate:status`, caches, Nginx site, maintenance-mode trap |
| `scripts/04-verify-deployment.sh` | Read-only verification with pass/warn/fail summary |
| `nginx/api-lms.pmli.co.id.conf` | Laravel server block serving both :80 (private, never redirected) and :443 TLS (PHP-FPM 8.3 socket, only `index.php` executed) |
| `docs/DEPLOYMENT_RUNBOOK.md` | Phases A–K with rollback checkpoints |
| `docs/ROLLBACK.md` | Rollback per component; DB rollback requires a backup |
| `docs/SECURITY_NOTES.md` | Security posture and open items |
| `docs/GENERATED_FILES_REVIEW.md` | This report |

## Safety decisions

- All scripts: `set -Eeuo pipefail`, explicit dependency/variable checks, hostname confirmation.
- Env files are **parsed, not sourced** (no code execution); runtime environment variables take precedence.
- DB password: hidden prompt or env; min 16 chars; rejected if it contains characters that break the SQL literal; passed to `mysql` over **stdin**, never argv; unset afterwards.
- MySQL bind is set via a drop-in (`zz-pmli-bind.cnf`) so `mysqld.cnf` stays intact; both files are backed up to `/var/backups/pmli-deploy` (0700); `mysqld --validate-config` runs before restart; failure restores the previous state. Script aborts if MySQL ends up listening on a wildcard address.
- App user only as `'pmli_app'@'192.168.50.50'`, grants on `pmli_lms.*` only; script warns if a `%` account exists. Root auth untouched; no `mysql_secure_installation`.
- PHP 8.3 PPA (`ppa:ondrej/php`) is added only if PHP 8.3 is unavailable **and** the operator consents (`--allow-php-ppa` / `ALLOW_PHP_PPA=yes`).
- Composer installer signature (sha384) is verified before execution; no `curl | bash`.
- Deploy script: no `git pull`, no `.env` edits, no `APP_KEY` generation, no `migrate`; only `migrate:status`. Refuses `APP_DEBUG=true` and `DB_USERNAME=root`. Artisan runs as `www-data`; only `storage/` and `bootstrap/cache/` are chowned (775/664). Maintenance mode is lifted by an `EXIT` trap on failure. Failed caches (`route:cache`, etc.) are cleared instead of left broken. Nginx install rolls back if `nginx -t` fails.
- Nginx: HTTP only, no cert paths, dotfiles denied except `/.well-known/`, non-front-controller `.php` returns 404.
- UFW is never enabled; MySQL is never exposed on `0.0.0.0`.

## Assumptions

- Ubuntu 22.04 on both VMs; scripts run as root via `sudo`; `mysql` root uses default `auth_socket`.
- Laravel serves from `/var/www/pmli-backend/public`; `SESSION_DRIVER=file` is recommended for the initial deployment; cache/queue settings are owned by the application (see Pre-production corrections).
- Granted DDL privileges (`CREATE, ALTER, DROP, INDEX, REFERENCES`) are retained for manual migrations; to be narrowed after stabilization.
- `client_max_body_size 20M` is TEMPORARY / REQUIRES APPLICATION TEAM CONFIRMATION; PHP `upload_max_filesize`/`post_max_size` are not tuned by these scripts.
- `03-deploy-app.sh` runs Composer as root (`COMPOSER_ALLOW_SUPERUSER=1`) so `vendor/` stays non-writable by the web user; the checkout owner is whoever cloned it.
- Unset `SESSION_DRIVER` in Laravel 13 defaults to `database`; the runbook requires setting `file` explicitly.

## Requires human input

- Backend repository URL and branch/tag to deploy.
- `DB_APP_PASSWORD` (strong, ≥ 16 chars) and Laravel `APP_KEY`.
- Consent to the third-party PHP PPA.
- Location of the SQL dump and its checksum.
- Cloud Security Group review; DNS A record for `api-lms.pmli.co.id`; SSL certificate.
- Decision on when/how to run migrations (after a DB backup) and on narrowing DB privileges.
- Upload size limits and PHP-FPM tuning for an 8 vCPU / 16 GB host.

## Validation performed (development machine only; nothing was executed against a server)

```
bash -n scripts/00-preflight.sh scripts/01-setup-db.sh scripts/02-setup-api.sh \
        scripts/03-deploy-app.sh scripts/04-verify-deployment.sh scripts/lib/common.sh   -> all OK
grep -rniE 'password=|root80|token=|secret=|api_key=' .   -> only placeholder/documentation lines (e.g. DB_APP_PASSWORD='...'); no real credentials
grep for rm -rf /, rm -rf *, curl|bash, chmod 777, MySQL '%' grants -> no dangerous usage;
   the only '%' matches are a comment and the detection/warning query in 01-setup-db.sh
```

Not done: `shellcheck` and real-host dry runs. Recommend running `shellcheck scripts/*.sh scripts/lib/*.sh` and a test on
disposable Ubuntu 22.04 VMs before production use.

## Pre-production corrections

1. `docs/DEPLOYMENT_RUNBOOK.md` (Phase G): removed the deployment-generated `CACHE_STORE=file` and `QUEUE_CONNECTION=sync`
   lines. `SESSION_DRIVER=file` is now explicitly recommended for initial deployment, and the runbook states that
   `CACHE_STORE`, `QUEUE_CONNECTION` and all other values must come from the backend application's approved production
   `.env`. The scripts never write `.env`, so they never rewrite these values.
2. `docs/GENERATED_FILES_REVIEW.md`: removed the same assumption from the Assumptions section.
3. `README.md`: first-deployment step 5 defers `CACHE_STORE`/`QUEUE_CONNECTION` to the application team.
4. DDL privileges (`CREATE, ALTER, DROP, INDEX, REFERENCES`) kept unchanged. Documented in `docs/SECURITY_NOTES.md`, the
   runbook appendix and a SQL comment in `scripts/01-setup-db.sh`: retained so migrations can be run manually later;
   migrations are never automatic; review and narrow after production stabilization.
5. `nginx/api-lms.pmli.co.id.conf`: `client_max_body_size 20M` retained; comment now marks it
   TEMPORARY / REQUIRES APPLICATION TEAM CONFIRMATION (also in the runbook appendix). No replacement limit invented.
6. Scripts: `03-deploy-app.sh` and `04-verify-deployment.sh` only *read* `SESSION_DRIVER` (warn if not `file`). No script
   reads, defaults or writes `CACHE_STORE` or `QUEUE_CONNECTION`.
7. `bash -n scripts/*.sh scripts/lib/*.sh` re-run: all passed. No infrastructure commands were executed.
