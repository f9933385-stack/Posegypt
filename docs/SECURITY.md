# Security, privacy and deployment restrictions

This is **not yet an internet-facing or production-ready financial service**.

1. **Network:** default bind 127.0.0.1 only. `--bind=0.0.0.0` is a development option for trusted isolated LAN. Plain HTTP sends passwords and bearer tokens unencrypted; require authenticated TLS and secure device pairing before live use. Never expose port 8787 through router NAT/Internet.
2. **Credentials:** set `KASHER_ADMIN_PASSWORD` during first-time bootstrap. No default password and no credentials are stored in the repository. Passwords are PBKDF2-HMAC-SHA256 with random salt; vetted Argon2id upgrade is an optional later enhancement. Session tokens are cryptographically random and stored only as SHA-256 hashes server-side. No token is persisted in Flutter SharedPreferences.
3. **Authorization:** server validates roles, tenant, branch per action. Cost fields are redacted for cashier/viewer. Formal granular RBAC with explicit permission entries, creation and management of users, and audit of denied attempts remain unfinished.
4. **Database:** SQLite foreign keys and WAL are enabled. Writes are synchronous `BEGIN IMMEDIATE` transactions; stock has no-negative-quantity constraint. Database file must remain private to Windows host, backed up safely; never mount to multiple clients over SMB. No encrypted-at-rest policy shipped.
5. **Payment methods:** cash/card/wallet/bank are accounting labels, not integrations. No real payment card information, CVV, or banking credentials should be entered or stored.
6. **Local files:** `data/`, `.env`, `.key`, `.pem`, `.db`, WAL/SHM are gitignored. Also restrict filesystem ACLs for the production host, logs, and backups.
7. **Testing to add:** durable distributed rate limiting, penetration test, denied access tests, TLS and rotation, clock manipulation guard, digital signatures for licenses, key management, logging and monitoring. Basic login throttling and backup restore tests exist but do not replace field validation.
8. **Legal:** do not claim Egyptian e-invoice/e-receipt compliance; tax fields are for internal calculations only pending current legal review.

For testing on Android, modern Android may block cleartext by default; **do not disable this globally for a production build**. Supply a TLS endpoint and certificate trust design when device integration is ready.

## Operator backup tooling (development-grade)

`tools/backup_database.py` creates an **AES-256-GCM encrypted, authenticated**
SQLite-consistent snapshot, using a password-derived key (scrypt). It never
prints the password or passes it as a CLI argument. 
`tools/scheduled_backup.py` provides a verified **one-shot backup cycle** with
restoration, selected accounting audits, exclusive lock and safe retention.
It does not install a scheduler, sync to cloud, or securely store the password:
a human or host OS scheduler with a separate approved vault must invoke it,
monitor failures and complete periodic field restore drills. During backup, a short-lived **unencrypted
SQLite snapshot** is created beside the source database on the trusted branch
host (not next to encrypted backup output) and deleted on normal completion;
use encrypted-at-rest NTFS volume and a private host directory. Avoid crash-residual `.kasher-*` files. Do not use the source
DB file as a backup target. Before **restoring**, stop the server; the script
refuses to overwrite any existing file. Keep the backup password in a secure
password manager. No Google Drive upload is implemented.

Example on PowerShell:

```powershell
python -m pip install -r tools/requirements-backup.txt
# Inject KASHER_BACKUP_PASSWORD from an approved secrets vault at runtime
python tools/scheduled_backup.py server/data/kasher.sqlite3 D:/KasherSecure --keep 14
python tools/backup_database.py restore D:/KasherSecure/CHOSEN_FILE.kasherbak D:/KasherRestore/verified.sqlite3
python tools/audit_database.py D:/KasherRestore/verified.sqlite3
Remove-Item Env:KASHER_BACKUP_PASSWORD
```

Running `tools/audit_database.py` against a **snapshot** is preferred. A
passing audit only checks selected database invariants, not business or
regulatory correctness.

Consult [`PRODUCTION_READINESS_AR.md`](PRODUCTION_READINESS_AR.md) for the complete Arabic backup and restore runbook. Backups are not offsite until they are separately and securely transferred; cloud upload is not implemented.
