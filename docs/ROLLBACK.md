# Rollback Guide

Backups made by the scripts go to `/var/backups/pmli-deploy/` (mode 0700, timestamped). Take **manual** backups
before anything destructive; the scripts never delete data.

> **A database cannot be rolled back without a backup.** Before any destructive DB change (import into a non-empty
> database, migrations, schema edits), create one first:
> ```bash
> sudo mysqldump --single-transaction --routines --triggers pmli_lms | gzip > ~/pmli_lms_$(date +%F-%H%M).sql.gz
> ```
> Verify it is non-empty (`ls -lh`, `gzip -t`) and copy it off the VM. Check `df -h /` first (DB VM has little free space).

## 1. MySQL bind config

`01-setup-db.sh` rolls back automatically if `mysqld --validate-config` or the restart fails. Manual recovery:

```bash
ls -l /var/backups/pmli-deploy/
sudo rm -f /etc/mysql/mysql.conf.d/zz-pmli-bind.cnf          # remove our drop-in (or restore its .bak copy)
sudo cp -a /var/backups/pmli-deploy/mysqld.cnf.<timestamp>.bak /etc/mysql/mysql.conf.d/mysqld.cnf   # only if you changed it
sudo mysqld --validate-config --user=mysql
sudo systemctl restart mysql && systemctl status mysql --no-pager
sudo journalctl -u mysql -n 50 --no-pager
```

Without the drop-in MySQL binds to 127.0.0.1 (Ubuntu default), so the API loses connectivity — expected. Never "fix"
connectivity by binding to `0.0.0.0`.

## 2. Database import failure

- **Import into an empty, fresh database:** drop and recreate it, then re-import.
  ```bash
  sudo mysql -e "DROP DATABASE pmli_lms; CREATE DATABASE pmli_lms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  ```
  Only do this when you are sure nothing valuable is in the database. Re-run `01-setup-db.sh` afterwards to restore grants
  (dropping the DB does not drop the user, but re-check `SHOW GRANTS`).
- **Import into a non-empty database:** restore from the pre-import backup taken at checkpoint 2. If no backup exists, there
  is **no rollback**.
- Out of disk during import: free space (`df -h /`, remove the transferred dump once you have a copy elsewhere) and retry.
  Check `sudo journalctl -u mysql -n 50`.

## 3. Application Composer deployment failure

`03-deploy-app.sh` lifts maintenance mode on failure. Then:

```bash
cd /var/www/pmli-backend
sudo -u www-data php artisan up                                  # if still in maintenance
git log --oneline -n 5                                           # identify the last good commit
git checkout <last-good-commit>                                  # or restore your saved copy of the release
sudo COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
sudo ./scripts/03-deploy-app.sh                                  # from the pmli-deployment repo
```

Database schema changes made by migrations are **not** undone by this — restore the DB from backup only if a migration was run.

## 4. Laravel cache issue

Symptoms: stale config, wrong routes, "Class not found" after deploy, `.env` changes ignored.

```bash
cd /var/www/pmli-backend
sudo -u www-data php artisan config:clear
sudo -u www-data php artisan route:clear
sudo -u www-data php artisan event:clear
sudo -u www-data php artisan view:clear
sudo systemctl reload php8.3-fpm        # reset OPcache
```

Then re-run `03-deploy-app.sh` to rebuild caches. Remember `config:cache` bakes in `.env`: re-cache after every `.env` change.

## 5. Nginx config failure

`03-deploy-app.sh` restores the previous site file (or removes the new one) and re-enables `default` if `nginx -t` fails.
Manual recovery:

```bash
sudo nginx -t
ls -l /var/backups/pmli-deploy/
sudo cp -a /var/backups/pmli-deploy/api-lms.pmli.co.id.conf.<timestamp>.bak /etc/nginx/sites-available/api-lms.pmli.co.id.conf
sudo nginx -t && sudo systemctl reload nginx
# Last resort: restore the stock site
sudo ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/sites-enabled/api-lms.pmli.co.id.conf
sudo nginx -t && sudo systemctl reload nginx
```

A running Nginx keeps serving the last good configuration until a successful reload, so a failed `nginx -t` does not cause downtime.
