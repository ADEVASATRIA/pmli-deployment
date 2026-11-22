# Rilis 2026-11-17

- **Isi:** BE `8c10..23740` & FE `bdbc7a4..cc2ca2f`: Company Register F1+F2 (registrasi perusahaan, verifikasi admin, anggota & undangan, jabatan), TASK-031 log aktivitas Course OSL, TASK-032/033 import (akun, peserta event, anggota perusahaan) & NIPP di akun, TASK-S07 rapikan filter admin, TASK-037 popup import pemegang, TASK-S08 Fase A management role & permission, ringkasan instansi.
- **9 migration** (8 default, 1 legacy `event_registrations`).  Termasuk `ALTER ... ENGINE=InnoDB`: hanya bisa dibatalkan dengan restore dump backup; jalankan off-peak. Migration terakhir menjalankan `permissions:sync` (±30 detik, hanya guard sanctum; data guard web aplikasi lama tidak disentuh; cache key permission v2 terpisah).
- **Prasyarat server:** `FRONTEND_URL` benar di `.env`; `MAIL_*` (SMTP) sebelum mengaktifkan email; `CACHE_STORE` bukan `array`; cron `schedule:run` (prune-imports, expire-invitations); `php8.3-zip`; upload ≥50M.
- **Pasca-deploy (berurutan):** `permissions:sync --dry-run` (harap 0/0); `users:backfill-nipp --dry-run` → periksa CSV di `storage/app/reports` → jalankan; import 72 akun (`penambahan_akun_lms_261112.R1.csv`) via Admin > User Management > Import Akun, dengan email atur password MATI bila SMTP belum siap.
- **JANGAN jalankan:** `dev:seed-upcoming-events`, `permissions:sync --prune`.
- **Perubahan perilaku:** role admin = super admin; role kustom hanya modul course-code/role/permission (Fase B menyusul); `employee_number` pendaftaran event = NIPP akun; edit NIP peserta/instruktur bisa ditolak bila bentrok.
- **Known issues:** BUG-036 import pemegang sertifikat (masih diinvestigasi, uji di meeting Rabu); import dengan kirim email untuk ratusan baris bisa timeout (kirim bertahap atau tanpa email); menu admin Learning Path, Document Management, Transaction, Company Setting, Global Setting & dashboard admin masih data contoh; TASK-034 & TASK-038 belum dikerjakan.
- **Urutan:** BE lalu FE, tanpa `--swagger`. Rollback FE: `--rollback`; BE: restore backup dari ringkasan script.

```bash
./scripts/update-api.sh /var/www/pmli-backend --release releases/2026-11-17/api.conf                          # API VM
./scripts/update-frontend.sh /home/ecustomer/Learning-Course-FE --release releases/2026-11-17/frontend.conf   # Frontend VM
```
