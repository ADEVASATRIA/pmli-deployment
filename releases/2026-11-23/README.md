# Rilis 2026-11-23

- **Isi:** BE `0651dc1` & FE `6c50c21`: TASK-034 (transkrip video + PDF), BUG-036 (validasi importer), TASK-038 (multi PIC + menu aksi baris), TASK-S13 (masa berlaku sertifikat per pemegang + import sertifikasi), TASK-S12 (master entitas HR, kontak SDM, penempatan pekerja).
- **9 migration.** `certificate_events` dan `certificate_generals` (koneksi `legacy`) dikonversi MyISAM → InnoDB: **tidak bisa dibatalkan** kecuali dengan restore dump legacy; jalankan off-peak.
- **Berjalan di dalam migration** (tanpa langkah artisan manual): backfill masa berlaku pemegang sertifikat dan sinkron permission HR (master HR/penempatan).
- **Prasyarat server:** MySQL 5.7+ (generated column di `employee_placements`); PHP `zip dom mbstring gd`; upload ≥50M; cron `schedule:run`.
- **Backup legacy** memakai `--lock-tables` selama tabel masih MyISAM; user DB koneksi `legacy` perlu hak `LOCK TABLES`.
- **Pasca-deploy (read-only):** `php artisan permissions:sync --dry-run` (harap `Created: 0`) dan `php artisan certification:backfill-holders --dry-run` (hanya pemegang yatim yang tersisa).
- **Urutan:** BE lalu FE, tanpa `--swagger`. Rollback FE: `--rollback`; BE: restore backup dari ringkasan script.

```bash
./scripts/update-api.sh /var/www/pmli-backend --release releases/2026-11-23/api.conf                          # API VM
./scripts/update-frontend.sh /home/ecustomer/Learning-Course-FE --release releases/2026-11-23/frontend.conf   # Frontend VM
```
