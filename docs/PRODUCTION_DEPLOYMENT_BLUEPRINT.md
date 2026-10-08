# PMLI Production Deployment Blueprint

Panduan standar untuk update aplikasi PMLI ke production dengan aman. Ini adalah **peta urutan**; detail perintah ada di
[DEPLOYMENT_RUNBOOK.md](DEPLOYMENT_RUNBOOK.md), rollback di [ROLLBACK.md](ROLLBACK.md), keamanan di
[SECURITY_NOTES.md](SECURITY_NOTES.md).

**Scope:** Backend Laravel, Frontend Vue, Nginx (API + frontend), konfigurasi upload PHP-FPM, Eranyacloud Object Storage,
Course Video Upload, migrasi Course Video yang sudah ada, verifikasi, rollback.

**Aturan tetap:** tidak ada secret di Git; migrasi database **tidak pernah otomatis**; tidak ada `git pull` otomatis;
setiap langkah yang mengubah server butuh persetujuan eksplisit operator.

## Alur

```text
PRE-CHECK → BACKUP → OBJECT STORAGE CHECK → BACKEND UPDATE → DATABASE MIGRATION → LARAVEL CONFIG/CACHE
→ EXISTING VIDEO COPY → S3 → ENABLE COURSE_VIDEO_DISK=s3 → API NGINX / PHP CONFIG
→ FRONTEND UPDATE → FRONTEND NGINX → VERIFY → SMOKE TEST → MONITOR LOG
```

> **Catatan urutan.** `03-deploy-app.sh` menjalankan Composer, cache Laravel, ini PHP-FPM, restart FPM, dan Nginx API
> **dalam satu run**. Jadi tahap "Backend update", "Laravel config/cache" dan "API Nginx / PHP config" pada praktiknya
> dieksekusi sekaligus oleh script itu. Konsekuensinya, `.env` harus sudah benar (kecuali `COURSE_VIDEO_DISK`, lihat tahap 7)
> sebelum script dijalankan, dan perubahan `.env` setelahnya butuh rebuild cache (tahap 8).

| # | Tahap | VM | Alat | Gerbang lolos |
|---|-------|----|------|---------------|
| 1 | Pre-check | API, DB, Frontend | `00-preflight.sh`, `df -h`, `git status` | Tidak ada `[ERROR]`; disk cukup |
| 2 | Backup | DB, API | `mysqldump`, salinan `.env`, commit SHA | File backup ada, `gzip -t` OK, disalin keluar VM |
| 3 | Object storage check | API | Cek manual bucket (lihat di bawah) | Put/get/range/temporaryUrl OK |
| 4 | Backend update | API | `git fetch/pull` manual → `03-deploy-app.sh` | Composer OK, Laravel boot |
| 5 | Database migration | API | **Manual** `migrate:status` → `migrate` | Status migrasi sesuai ekspektasi |
| 6 | Laravel config/cache | API | `03-deploy-app.sh` / `config:clear` + `config:cache` | Tidak ada cache usang |
| 7 | Copy video lama → S3 | API | Manual (prosedur runbook) | Semua key ada di S3, ukuran cocok |
| 8 | `COURSE_VIDEO_DISK=s3` | API | Edit `.env` manual + rebuild cache | Config baru terbaca |
| 9 | API Nginx / PHP config | API | `03-deploy-app.sh` atau `05-update-api-nginx.sh` | `nginx -t` OK; PHP-FPM 512M/600M |
| 10 | Frontend update | Frontend | Build & salin dist (manual, di luar repo ini) | Build baru ada di `FRONTEND_DIR` |
| 11 | Frontend Nginx | Frontend | `06-update-frontend-nginx.sh` | `nginx -t` OK; reload sukses |
| 12 | Verify | API, Frontend | `04-verify-deployment.sh`, `07-verify-frontend-api.sh` | 0 FAIL |
| 13 | Smoke test | Browser | Manual | Alur kritis lolos |
| 14 | Monitor log | API, Frontend | `tail` log | Tidak ada error baru |

---

## 1. Pre-check

- Konfirmasi commit/tag backend dan frontend yang akan di-deploy, dan perubahan `.env` baru yang dibutuhkan rilis ini.
- `./scripts/00-preflight.sh api` (dan `db` / frontend bila relevan).
- `df -h /` di semua VM. **Frontend & API:** sisakan ≥ ~600 MB per upload bersamaan di `/var/lib/nginx` (Nginx menyangga
  body request ke disk di kedua hop). **DB:** sisakan ruang untuk dump.
- Pastikan tidak ada pekerjaan lain yang sedang berjalan; umumkan jendela deployment.

## 2. Backup

```bash
# DB VM
sudo mysqldump --single-transaction --routines --triggers pmli_lms | gzip > ~/pmli_lms_$(date +%F-%H%M).sql.gz
gzip -t ~/pmli_lms_*.sql.gz && ls -lh ~/pmli_lms_*.sql.gz

# API VM
git -C /var/www/pmli-backend rev-parse HEAD            # catat SHA rilis sebelumnya
sudo cp -a /var/www/pmli-backend/.env /var/backups/pmli-deploy/env.$(date +%F-%H%M).bak   # dir 0700, jangan commit
```

Salin dump ke luar VM. **Tanpa backup, rollback database tidak mungkin.** Backup Nginx/PHP dibuat otomatis oleh script ke
`/var/backups/pmli-deploy/`.

## 3. Object storage check

Tanpa menampilkan kredensial. Dari aplikasi (mis. `php artisan tinker` sebagai `www-data`, atau skrip uji aplikasi), pastikan:
put/get objek uji, `temporaryUrl` berfungsi, objek privat tidak bisa diakses tanpa URL bertanda tangan, dan `Range`
mengembalikan `206`. Hapus objek uji setelahnya. `.env` produksi harus punya (nama saja):
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION=us-east-1`, `AWS_BUCKET=bucket-codeid`,
`AWS_ENDPOINT=https://jkt-2.s3.eranyacloud.id`, `AWS_USE_PATH_STYLE_ENDPOINT=true`, `COURSE_VIDEO_MAX_KB=512000`,
`COURSE_VIDEO_URL_TTL=300`. Biarkan `COURSE_VIDEO_DISK` pada nilai lama (`local`) sampai tahap 8.

## 4. Backend update

```bash
cd /var/www/pmli-backend && git fetch && git log --oneline HEAD..origin/<branch>   # tinjau perubahan
git pull                                                                           # manual, oleh operator
cd ~/pmli-deployment && git pull
sudo ./scripts/03-deploy-app.sh
```

`03-deploy-app.sh` tidak melakukan `git pull`, tidak mengubah `.env`, tidak membuat `APP_KEY`, dan tidak menjalankan migrasi.
Ia mengaktifkan maintenance mode (bila app sudah berjalan) dan trap `artisan up` bila gagal.

## 5. Database migration (manual)

```bash
cd /var/www/pmli-backend
sudo -u www-data php artisan migrate:status          # tinjau semua baris "Pending"
```

Hanya jika tim aplikasi menyetujui migrasi yang pending **dan backup tahap 2 sudah ada**:
`sudo -u www-data php artisan migrate`. Jangan `--force` tanpa persetujuan. `SESSION_DRIVER=file` tetap direkomendasikan
untuk deployment awal. Privilese DDL `pmli_app` dipertahankan untuk langkah ini; tinjau/persempit setelah produksi stabil.

## 6. Laravel config / cache

`03-deploy-app.sh` sudah menjalankan `config:clear` → `config:cache`/`route:cache`/`event:cache`. Setelah **setiap** perubahan
`.env` ulangi:

```bash
sudo -u www-data php artisan config:clear && sudo -u www-data php artisan config:cache
```

## 7. Copy video lama → S3 (manual, sebelum switch disk)

1. **Audit (read-only):** daftar baris Video di DB (query dari tim aplikasi) vs file lokal
   `find <root-disk-lokal>/courses/materials/videos -type f`. Catat yatim/hilang.
2. **Copy** tiap file dengan **key persis sama**: `courses/materials/videos/<filename>` ke bucket `bucket-codeid`
   (mis. `aws s3 cp --endpoint-url https://jkt-2.s3.eranyacloud.id`). Jangan rename.
3. **Verifikasi** setiap key ada di S3 dengan ukuran (dan checksum bila ada) yang cocok.
4. **Jangan hapus file lokal** pada deployment yang sama; hapus di langkah terpisah yang disetujui kemudian.

## 8. Aktifkan `COURSE_VIDEO_DISK=s3`

Hanya setelah tahap 7 lolos 100%. Edit `.env` secara manual (script tidak menulis `.env`), lalu rebuild cache (tahap 6) dan
reload PHP-FPM. Uji putar satu video lama dan satu upload baru sebelum lanjut.

## 9. API Nginx / PHP config

Sudah tercakup oleh `03-deploy-app.sh`; bila hanya Nginx yang berubah: `sudo ./scripts/05-update-api-nginx.sh`.
Target (lihat runbook "Course Video uploads"): PHP-FPM `upload_max_filesize=512M`, `post_max_size=600M`; Nginx
`client_max_body_size 600m`; `fastcgi_read_timeout 300s`. `nginx -t` dijalankan script sebelum reload dan akan rollback bila gagal.

## 10–11. Frontend update dan Nginx

Build Vue dan penyalinan hasil build ke `FRONTEND_DIR` dilakukan manual (di luar repo ini; repo ini tidak menjalankan
`npm`). Lalu:

```bash
sudo ./scripts/06-update-frontend-nginx.sh      # client_max_body_size 600m, proxy_read_timeout 300s pada /api/
```

Urutan penting: **jangan** update frontend Nginx ke limit baru sebelum API siap; sebaliknya, API tanpa limit baru akan
menolak upload besar dengan 413.

## 12. Verify

```bash
sudo ./scripts/04-verify-deployment.sh          # API VM: PHP/Nginx/.env/limit efektif/HTTP
sudo ./scripts/07-verify-frontend-api.sh        # Frontend VM: jalur proxy ke API
```

Harus 0 FAIL; tinjau semua WARN (mis. `SESSION_DRIVER`).

## 13. Smoke test

Login admin dan student; baca endpoint utama; **upload video ~500 MB** lewat jalur nyata (browser → frontend Nginx →
API Nginx → PHP → S3) dan catat waktunya (< 300 s); putar video (admin & student) termasuk seek (Range `206`); video lama
dari tahap 7 tetap terputar; `/.env` ditolak (403/404); upload PDF biasa tetap berfungsi.

## 14. Monitor log

```bash
sudo tail -f /var/log/nginx/api-lms.pmli.co.id.error.log
sudo tail -f /var/log/nginx/lms.pmli.co.id.error.log                 # Frontend VM
sudo tail -f /var/www/pmli-backend/storage/logs/laravel.log
```

Waspadai 413 (limit), 499/504 (timeout), 500 (aplikasi/S3), `No space left on device` (`/var/lib/nginx`). Pantau minimal
beberapa jam pertama dan simpan backup tahap 2 sampai rilis dinyatakan stabil.

---

## Rollback ringkas per tahap

| Gagal di | Tindakan | Detail |
|----------|----------|--------|
| 4 / 6 (backend, cache) | `artisan up`, checkout SHA sebelumnya, `03-deploy-app.sh`, `config:clear` | ROLLBACK.md §3–4 |
| 5 (migrasi) | Restore dari backup tahap 2 — satu-satunya jalan | ROLLBACK.md §2 |
| 7 (copy video) | Tidak ada yang berubah di app; ulangi copy | file lokal tidak dihapus |
| 8 (disk s3) | Kembalikan `COURSE_VIDEO_DISK=local`, rebuild cache | file lokal masih utuh |
| 9 / 11 (Nginx) | Otomatis oleh script bila `nginx -t` gagal; manual dari `/var/backups/pmli-deploy/` | ROLLBACK.md §5 |
| PHP ini | Hapus `/etc/php/8.3/fpm/conf.d/99-pmli-uploads.ini` atau restore `.bak`, `php-fpm8.3 -t`, restart FPM | — |

Rollback tahap 8 hanya aman selama file lokal belum dihapus dan tidak ada video **baru** yang hanya ada di S3; video baru
tersebut harus disalin balik lebih dulu.

## Pertanyaan terbuka (butuh keputusan manusia)

- Query audit Video dan lokasi root disk lokal (tim aplikasi).
- Apakah migrasi database ada di rilis ini, dan siapa yang menyetujui.
- Alat/credential untuk copy ke S3 dan cara verifikasi checksum.
- Proses build/rilis frontend dan lokasi `FRONTEND_DIR` yang sebenarnya.
- Kapan file video lokal asli boleh dihapus.
