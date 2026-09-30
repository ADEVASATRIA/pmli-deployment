# pmli-deployment

Deployment scaffolding for the **PMLI LMS backend** (Laravel 13, PHP 8.3, Nginx + PHP-FPM, MySQL 8).
This repo holds only scripts, config templates and docs. It does **not** contain, and must never
contain, the backend application code or any secret.

> **WARNING: never commit secrets.** Real env files (`env/*.env`), DB passwords, SSH keys, Laravel `.env`
> files and SQL dumps are git-ignored. Only `*.env.example` files with non-secret values are tracked.

## Server mapping

| Role | Hostname | Private IP | Public | Notes |
|------|----------|-----------|--------|-------|
| API VM | `pmli-app-01-api` | 192.168.50.50 | 160.20.105.140 (`api-lms.pmli.co.id`) | Nginx + PHP 8.3-FPM + Laravel, app in `/var/www/pmli-backend` |
| DB VM | `pmli-db-01` | 192.168.50.55 | none | MySQL 8, listens on 192.168.50.55 only |

Traffic: API `192.168.50.50` → DB `192.168.50.55:3306` over the private subnet `192.168.50.0/24`.
The frontend domain is managed elsewhere.

## Scripts

| Script | Runs on | Purpose |
|--------|---------|---------|
| `scripts/00-preflight.sh <api\|db>` | both | Read-only inspection; non-zero only on critical incompatibility |
| `scripts/01-setup-db.sh` | **DB VM** | Install MySQL, bind to private IP, create DB + restricted app user |
| `scripts/02-setup-api.sh` | **API VM** | Install Nginx, PHP 8.3 + extensions, MySQL client, Composer |
| `scripts/03-deploy-app.sh` | **API VM** | Composer install, permissions, caches, Nginx site, maintenance mode |
| `scripts/04-verify-deployment.sh` | **API VM** | Read-only verification with pass/warn/fail summary |

Shared helpers live in `scripts/lib/common.sh`. All scripts use `set -Eeuo pipefail`, log with
`[INFO] [WARN] [ERROR] [OK]`, and are written to be safely re-runnable.

## Environment files

```bash
cp env/db.env.example  env/db.env    # on the DB VM
cp env/api.env.example env/api.env   # on the API VM
```

Only non-secret values live there. `DB_APP_PASSWORD` is supplied at runtime
(`sudo DB_APP_PASSWORD='…' ./scripts/01-setup-db.sh`), via a hidden prompt, or via your ignored `env/db.env`.
The Laravel `.env` lives in `/var/www/pmli-backend/.env` and is created by hand.

## First deployment

**DB VM**
1. `cp env/db.env.example env/db.env` and review it
2. `./scripts/00-preflight.sh db`
3. `sudo ./scripts/01-setup-db.sh`
4. Manually transfer and import the SQL dump (~71.2 MB) — see the runbook
5. Verify the DB (commands are printed by the script)

**API VM**
1. `cp env/api.env.example env/api.env` and review it (set `ALLOW_PHP_PPA=yes` to consent to the PHP PPA)
2. `./scripts/00-preflight.sh api`
3. `sudo ./scripts/02-setup-api.sh`
4. `git clone <backend-repo> /var/www/pmli-backend`
5. Create the Laravel `.env` from the application team's approved production configuration (`APP_DEBUG=false`; `SESSION_DRIVER=file` is recommended for the initial deployment; `CACHE_STORE`, `QUEUE_CONNECTION` and all other values are owned by the application, not this repo)
6. `sudo ./scripts/03-deploy-app.sh`
7. `sudo ./scripts/04-verify-deployment.sh`

Full detail: [docs/DEPLOYMENT_RUNBOOK.md](docs/DEPLOYMENT_RUNBOOK.md).

## Repeat deployment

1. In `/var/www/pmli-backend`: `git fetch && git pull` (manual, reviewed by you)
2. Review `.env` changes and new migrations
3. `sudo ./scripts/03-deploy-app.sh`
4. `sudo ./scripts/04-verify-deployment.sh`
5. If migrations are needed, run them **manually**, after taking a DB backup

## Intentionally NOT automated

- Database migrations (`php artisan migrate`) — only `migrate:status` is run
- SQL import
- `git clone` / `git pull` of the backend
- Creating or editing the Laravel `.env`, generating `APP_KEY`
- Enabling UFW (review the cloud Security Group first)
- SSL/Certbot provisioning (HTTP only until DNS/SSL is ready)
- `mysql_secure_installation`, root DB authentication changes
- Any deletion of data

## Docs

- [Deployment runbook](docs/DEPLOYMENT_RUNBOOK.md)
- [Rollback](docs/ROLLBACK.md)
- [Security notes](docs/SECURITY_NOTES.md)
- [Generated files review](docs/GENERATED_FILES_REVIEW.md)
