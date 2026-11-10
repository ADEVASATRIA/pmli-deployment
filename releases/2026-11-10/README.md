# Rilis 2026-11-10

- **Backend** `2aae38c..36da6be`: TASK-011, 030, 027 (f1+f2), S03, S05, S06, dev seed command. **Frontend** `ea71955..bdbc7a4`: TASK-011, 028, Lenis, 029, 030, 027, S04, S03, S05, S06.
- **4 migration**: 1 koneksi default (`courses`), 3 koneksi `legacy` (`certificate_events`, `certificate_generals`, `event_member_absents`); backup otomatis.
- **Prasyarat server:** `php8.3-zip` (CLI+FPM); upload ≥50M di FPM & Nginx; `CACHE_STORE` bukan `array`; cron `schedule:run` (untuk `certification:prune-imports`).
- **Pasca-deploy:** `php artisan certification:sync-agencies --dry-run`, lalu jalankan tanpa `--dry-run`; rapikan duplikat via menu Instansi > Gabungkan.
- **JANGAN** jalankan `dev:seed-upcoming-events`. Nomor sertifikat `/` diganti `_` pada nama file ZIP.
- **Urutan:** BACKEND dulu, baru FRONTEND. Tanpa `--swagger`. Rollback: FE `--rollback`; BE restore backup di `~/backups/`.

```bash
./scripts/update-api.sh /var/www/pmli-backend --release releases/2026-11-10/api.conf                          # API VM
./scripts/update-frontend.sh /home/ecustomer/Learning-Course-FE --release releases/2026-11-10/frontend.conf   # Frontend VM
```
