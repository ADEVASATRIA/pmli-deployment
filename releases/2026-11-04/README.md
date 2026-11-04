# Rilis 2026-11-04

- **Backend** `40af314..bccb3fa`: 6 migration (Assessment, EventSchedule), backup tabel assessment + `course_modules` (default) dan `event_members`/`event_member_absents` (koneksi `legacy`).
- **Frontend** `23239f9..c7cbd7e`: route SPA baru `/trainer`, `/trainer/penilaian`, `/admin/attendance`; HTTPS wajib.
- **Urutan:** deploy BACKEND dulu (migration), baru FRONTEND.

```bash
./scripts/update-api.sh /var/www/pmli-backend --release releases/2026-11-04/api.conf --swagger     # API VM
./scripts/update-frontend.sh /path/ke/repo-frontend --release releases/2026-11-04/frontend.conf    # Frontend VM
./scripts/update-frontend.sh --rollback                                                            # bila perlu
```
