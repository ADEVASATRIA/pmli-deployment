# Security Notes

- **Secrets are not committed.** `env/*.env`, Laravel `.env`, SQL dumps and logs are git-ignored. Only `*.env.example`
  with non-secret values is tracked. Pass `DB_APP_PASSWORD` at runtime or via a `chmod 600` ignored file.
- **The database is not public.** MySQL binds only to `192.168.50.55`; the DB VM has no public IP. The scripts refuse to
  bind to `0.0.0.0`.
- **Dedicated DB application user.** `pmli_app` has privileges on `pmli_lms.*` only (no `GRANT OPTION`, no global privileges).
  The DDL privileges (`CREATE, ALTER, DROP, INDEX, REFERENCES`) are currently retained so migrations can be run
  **manually** later; migrations are never run automatically. Review and narrow these privileges after production
  stabilization.
- **No `%` host grants.** The user exists only as `'pmli_app'@'192.168.50.50'`. The DB script warns if a `%` account exists.
- **API → DB over the private network** (`192.168.50.50 → 192.168.50.55:3306`). Restrict 3306 in the cloud Security Group
  to the API VM's private IP.
- **Never use root DB credentials for Laravel.** `03-deploy-app.sh` and `04-verify-deployment.sh` fail if `DB_USERNAME=root`.
- **`APP_DEBUG=false`** and `APP_ENV=production`. Deploy refuses `APP_DEBUG=true`.
- **Web root must be `public/`.** Nginx serves `/var/www/pmli-backend/public`; only `index.php` is executed; dotfiles
  (except `/.well-known/`) are denied. The verify script checks `/.env` returns 403/404.
- **Firewall.** UFW is currently inactive and these scripts do not enable it (enabling blindly can lock you out of SSH).
  The **cloud Security Group must be reviewed**: API VM — 80/443 public, 22 from trusted IPs only; DB VM — 3306 from
  192.168.50.50 only, 22 from trusted IPs only. If enabling UFW later, allow SSH first.
- **SSL/HTTPS is required before production go-live.** The provided Nginx config serves both plain HTTP on :80 (for
  the private frontend->API path — deliberately never redirected to HTTPS, since a redirect to the private IP would
  fail certificate validation) and TLS on :443 for the public domain, from a single server block. The cert/key paths
  come from `TLS_CERT_PATH`/`TLS_KEY_PATH` in `env/api.env` — provision the certificate first (this repo never issues
  or renews it), then switch `APP_URL` to `https://` and consider HSTS.
- **Rotate credentials that have been shared during setup** (DB app password, root/sudo passwords, SSH keys, any token pasted into chats or tickets).
- **Least-privilege file ownership.** Only `storage/` and `bootstrap/cache/` are owned by `www-data` (dirs 775, files 664).
  Application code and `vendor/` stay non-writable by the web user. `.env` should be `640`, group `www-data`.
- **No `chmod 777`** anywhere; reviewed by grep in `docs/GENERATED_FILES_REVIEW.md`.
- **Supply chain.** The PHP 8.3 PPA is third-party and added only with explicit consent. Composer's installer is checksum-verified;
  nothing is piped from `curl` into a shell.
