# Rilis 2026-11-05

- **Backend** `bccb3fa..2aae38c`: TASK-017, BUG-012. Tanpa migration dan tanpa package baru (backup dilewati otomatis).
- **Frontend** `c7cbd7e..ea71955`: BUG-011, TASK-017, BUG-S01, BUG-014, menu Katalog, TASK-S01, BUG-012, TASK-022.
- **Urutan:** deploy BACKEND dulu, baru FRONTEND.
- **Jangan pakai `--swagger`**: fix exclude tests belum masuk backend.

```bash
./scripts/update-api.sh /var/www/pmli-backend --release releases/2026-11-05/api.conf                # API VM
./scripts/update-frontend.sh /home/ecustomer/Learning-Course-FE --release releases/2026-11-05/frontend.conf  # Frontend VM
```
