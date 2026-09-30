# Deployment Runbook

Operator guide for the PMLI LMS backend. Follow the phases in order. Stop and investigate on any `[ERROR]`.

**Key facts**
- API VM `pmli-app-01-api` = **192.168.50.50** (public 160.20.105.140, `api-lms.pmli.co.id`)
- DB VM `pmli-db-01` = **192.168.50.55** (private only)
- SQL dump ≈ **71.2 MB**; DB VM has ≈ **9.3 GB free** before setup (15 GB disk) — run `df -h` before and after import
- **No migrations are run automatically.** Use `php artisan migrate:status` first.
- **`SESSION_DRIVER=file`** for the initial production deployment
- The application **must not use the MySQL root account**

---

## Phase A — Prepare deployment repo

On **both** VMs (or copy the repo to each):

```bash
git clone <pmli-deployment-repo-url> ~/pmli-deployment && cd ~/pmli-deployment
cp env/db.env.example  env/db.env    # DB VM
cp env/api.env.example env/api.env   # API VM
```

Review values. Never put secrets in `*.env.example`.

## Phase B — Provision DB (DB VM)

```bash
./scripts/00-preflight.sh db
df -h /
```

> **Rollback checkpoint 1 — before MySQL config change.** The script backs up `mysqld.cnf` and any existing
> drop-in to `/var/backups/pmli-deploy/` automatically and rolls back if validation/restart fails.

```bash
sudo ./scripts/01-setup-db.sh
# or: sudo DB_APP_PASSWORD='<strong-password>' ./scripts/01-setup-db.sh
```

Result: MySQL 8 listening only on `192.168.50.55:3306`; database `pmli_lms` (utf8mb4 / utf8mb4_unicode_ci);
user `pmli_app`@`192.168.50.50` with privileges on `pmli_lms.*` only.

## Phase C — Transfer / import SQL dump (manual)

From your workstation:

```bash
scp /path/to/pmli_lms.sql <ssh-user>@192.168.50.55:/home/<ssh-user>/     # ~71.2 MB
```

On the DB VM:

```bash
df -h /                      # BEFORE import (expect ~9 GB free)
sha256sum ~/pmli_lms.sql     # compare with the checksum from the source machine
```

> **Rollback checkpoint 2 — before SQL import.** If `pmli_lms` already contains data, back it up first:
> `sudo mysqldump --single-transaction pmli_lms | gzip > ~/pmli_lms_pre_import_$(date +%F-%H%M).sql.gz`
> An import cannot be undone without such a backup (see ROLLBACK.md).

```bash
sudo mysql -u root pmli_lms < ~/pmli_lms.sql
df -h /                      # AFTER import
```

Delete the dump from the VM once verified (you decide when; nothing here deletes it for you).

## Phase D — Validate DB

```bash
sudo mysql -e "SHOW DATABASES LIKE 'pmli_lms';"
sudo mysql -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='pmli_lms';"
sudo mysql -e "SHOW GRANTS FOR 'pmli_app'@'192.168.50.50';"
sudo mysql -e "SELECT user,host FROM mysql.user WHERE user='pmli_app';"   # no '%' host
ss -ltn | grep 3306                                                       # 192.168.50.55:3306 only
```

## Phase E — Provision API (API VM)

```bash
./scripts/00-preflight.sh api
```

Ubuntu 22.04 has no PHP 8.3. `02-setup-api.sh` adds **`ppa:ondrej/php`** (third-party, maintained by the Debian PHP
maintainer) **only** with your consent: set `ALLOW_PHP_PPA=yes` in `env/api.env` or pass `--allow-php-ppa`.

```bash
sudo ./scripts/02-setup-api.sh --allow-php-ppa
```

It installs Nginx, PHP 8.3 (+FPM, required extensions), MySQL client and Composer (installer checksum verified).
If DB port 3306 is not reachable yet it only warns.

## Phase F — Clone backend repo (API VM)

```bash
sudo git clone <backend-repo-url> /var/www/pmli-backend
```

Choose a branch/tag deliberately. Composer is executed by the deploy script; ownership of the checkout stays with
whoever cloned it, except `storage/` and `bootstrap/cache/`, which the script hands to `www-data`.

## Phase G — Create Laravel production `.env`

Create `/var/www/pmli-backend/.env` by hand (from the app's `.env.example`), then set at minimum:

```dotenv
APP_ENV=production
APP_DEBUG=false
APP_URL=http://api-lms.pmli.co.id        # switch to https once SSL is live
APP_KEY=base64:...                        # generate deliberately, keep it, never regenerate on a live system

DB_CONNECTION=mysql
DB_HOST=192.168.50.55
DB_PORT=3306
DB_DATABASE=pmli_lms
DB_USERNAME=pmli_app                      # NOT root
DB_PASSWORD=<the app user's password>

SESSION_DRIVER=file                       # RECOMMENDED for initial deployment; a sessions-table migration is not committed
```

`SESSION_DRIVER=file` is explicitly recommended for the initial production deployment (it avoids depending on an
uncommitted `sessions` table).

**`CACHE_STORE`, `QUEUE_CONNECTION` and every other application setting must come from the backend application's
approved production `.env` configuration.** The deployment tooling does not choose, default or rewrite them, and the
scripts never modify `.env`. Obtain the approved values from the application team.

```bash
sudo chgrp www-data /var/www/pmli-backend/.env && sudo chmod 640 /var/www/pmli-backend/.env
```

Generate an `APP_KEY` yourself, e.g. `cd /var/www/pmli-backend && php artisan key:generate --show` (after a first
`composer install`), and paste it in. The deploy script never generates or overwrites it.

## Phase H — Application deployment

> **Rollback checkpoint 4 — before Composer application deployment.** Record the current commit and keep a copy of
> `vendor/` if this is not the first deploy: `git -C /var/www/pmli-backend rev-parse HEAD`.

```bash
sudo ./scripts/03-deploy-app.sh
```

The script: validates the checkout/`.env`/APP_KEY, enables maintenance mode (if the app already runs), runs
`composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction`, sets `storage/` and
`bootstrap/cache/` permissions (775/664, never 777), links `public/storage`, runs `php artisan migrate:status`
(**read-only**), caches config/routes/events, generates Swagger docs if available, reloads PHP-FPM and Nginx,
then lifts maintenance mode (a trap lifts it on any failure).

Review the `migrate:status` output. If migrations are pending, agree on them with the application team, take a DB
backup (Phase C command), and run them **manually**: `sudo -u www-data php artisan migrate`.

## Phase I — Nginx validation

> **Rollback checkpoint 3 — before Nginx config change.** The script backs up any existing site file to
> `/var/backups/pmli-deploy/` and rolls back automatically if `nginx -t` fails.

```bash
sudo nginx -t
curl -i -H 'Host: api-lms.pmli.co.id' http://127.0.0.1/
sudo ./scripts/04-verify-deployment.sh
```

## Phase J — DNS / TLS

1. Point `api-lms.pmli.co.id` A record → `160.20.105.140`.
2. Ensure the cloud Security Group allows 80/443 (and 22 from trusted IPs only) on the API VM; allow 3306 on the DB VM
   **only from 192.168.50.50**. UFW is inactive and is not enabled by these scripts.
3. Obtain a certificate for `api-lms.pmli.co.id` (e.g. Certbot, or one issued out-of-band) and place the full chain +
   private key on the API VM — an operator action, not scripted. This repo never issues, renews, or reads the
   contents of a certificate.
4. Set `TLS_CERT_PATH` / `TLS_KEY_PATH` in `env/api.env` to those two file paths, then re-run
   `sudo ./scripts/03-deploy-app.sh`. `nginx/api-lms.pmli.co.id.conf` is a single server block that already serves
   **both** plain HTTP on :80 (the private frontend->API path — deliberately never redirected to HTTPS, since
   redirecting a private-IP request would fail certificate validation) **and** TLS on :443 for the public domain,
   from the same routing rules — no manual Nginx edit is needed. The script refuses to install the site if either
   TLS path does not exist.
5. After HTTPS works: set `APP_URL=https://…` in the Laravel `.env`, re-run `03-deploy-app.sh` again (refreshes the
   config cache), consider HSTS.

## Phase K — Smoke testing

```bash
curl -i http://api-lms.pmli.co.id/                                    # then https:// after Phase J
curl -i http://api-lms.pmli.co.id/.env                                # must be 403/404
# From the Frontend VM — the exact path the frontend Nginx proxy uses. Must NOT be 301
# (would mean private traffic is being redirected to HTTPS again) and must NOT be a bare
# Nginx 404 (would mean :80 is not routing into Laravel); 200/400/401/422/429 are all fine.
curl -i -X POST http://192.168.50.50/api/v1/auth/login -H 'Content-Type: application/json' -d '{}'
sudo tail -n 50 /var/log/nginx/api-lms.pmli.co.id.error.log
sudo tail -n 50 /var/www/pmli-backend/storage/logs/laravel.log
```

Then exercise login, a read endpoint and an upload from the real frontend. Confirm the API user only connects from
192.168.50.50, and rotate any credential that was shared during setup.

---

## Appendix — Items pending confirmation

- **DB DDL privileges.** `pmli_app` currently holds `CREATE, ALTER, DROP, INDEX, REFERENCES` on `pmli_lms.*`. They are
  retained only so migrations can be run **manually** later. Migrations are **never** run automatically by these
  scripts. Review and narrow these privileges after production stabilization.
- **Upload limit.** Nginx `client_max_body_size 20M` is **TEMPORARY / REQUIRES APPLICATION TEAM CONFIRMATION.**
  PHP `upload_max_filesize` / `post_max_size` are not set by these scripts.
