# Security, privacy and deployment restrictions

This is **not yet an internet-facing or production-ready financial service**.

1. **Network:** default bind 127.0.0.1. HTTP is now allowed only on loopback; the Dart server requires both a TLS certificate and private key for every non-loopback bind address, and Flutter rejects remote HTTP before sending credentials. OS certificate/hostname trust remains mandatory. Initial device pairing and session revocation are now implemented with single-use tickets and OS-protected client secrets; hardware attestation, mTLS, automated credential rotation, certificate lifecycle management and penetration testing remain incomplete. Never expose the service publicly; see [Arabic HTTPS guide](HTTPS_LAN_AR.md).
2. **Credentials:** set `KASHER_ADMIN_PASSWORD` during first-time bootstrap. No default password and no credentials are stored in the repository. Passwords are PBKDF2-HMAC-SHA256 with random salt; vetted Argon2id upgrade is an optional later enhancement. Session tokens are cryptographically random and stored only as SHA-256 hashes server-side. No token is persisted in Flutter SharedPreferences.
3. **Authorization:** server validates roles, tenant, branch per action. Cost fields are redacted for cashier/viewer. Formal granular RBAC with explicit permission entries, creation and management of users, and audit of denied attempts remain unfinished.
4. **Database:** SQLite foreign keys and WAL are enabled. Writes are synchronous `BEGIN IMMEDIATE` transactions; stock has no-negative-quantity constraint. Database file must remain private to Windows host, backed up safely; never mount to multiple clients over SMB. No encrypted-at-rest policy shipped.
5. **Payment methods:** cash/card/wallet/bank are accounting labels, not integrations. No real payment card information, CVV, or banking credentials should be entered or stored.
6. **Local files:** `data/`, `.env`, `.key`, `.pem`, `.db`, WAL/SHM are gitignored. Also restrict filesystem ACLs for the production host, logs, and backups.
7. **Testing to add:** durable distributed rate limiting, penetration test, denied access tests, managed TLS trust and certificate rotation on store hardware, clock manipulation guard, digital signatures for licenses, key management, logging and monitoring. Basic login throttling and backup restore tests exist but do not replace field validation.
8. **Legal:** do not claim Egyptian e-invoice/e-receipt compliance; tax fields are for internal calculations only pending current legal review.

Android clients now require a trusted HTTPS branch endpoint on the LAN. Never disable certificate verification or Android network protection to work around trust errors. Loopback HTTP is restricted to the same device.

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

## Device enrollment v6
- Owner/manager issues a single-use 10-minute pairing code; only its SHA-256 hash is persisted.
- Device claims receive a high-entropy one-time secret; the server stores its hash and Flutter keeps the secret in Windows/Android OS secure storage, never in SharedPreferences.
- Remote service login requires both an enrolled active device credential and staff credentials; authenticated sessions are bound to the device and rejected/revoked when it is deactivated.
- Initial provisioning must be done from the local loopback server; an enrolled administrator can issue further tickets over trusted HTTPS.
- Android APK build disables auto-backup and plaintext traffic in the generated main Android manifest; repeat controls on official production manifests.
- **Limitations:** this is credential-based pairing, not hardware-backed device attestation or mTLS. Stolen bearer tokens remain usable before detection until their session is revoked/expired. See [Device pairing guide](DEVICE_PAIRING_AR.md).


## Verified secondary encrypted backup path

`tools/offsite_backup.py` supports mirroring a valid named AES-GCM `.kasherbak` file to a second protected storage directory or Windows UNC share. It copies **encrypted bytes only**, verifies the SHA-256 hash and then decrypts a temporary verification copy on a distinct trusted **local scratch** directory. It performs the accounting/inventory audit before promoting the remote file to its final name or pruning old remote backups. A dedicated remote lock prevents concurrent writers. A failed mirror does not delete existing verified copies or prune local retained backups. `tools/scheduled_backup.py --offsite-directory ... --scratch ...` can invoke this in the same one-shot run **before local retention**.

This is not a cloud sync service and does not prove the target is physically off site. Restrict Windows share/NTFS ACLs manually and monitor failed scheduled jobs; no automatic Task Scheduler registration, immutable object lock or Google Drive OAuth is provided. See [Arabic offsite backup runbook](BACKUP_OFFSITE_AR.md).


## Signed device licenses v9

Ed25519 annual grants bind the `tenant_id` and enrolled `device_id` and are verified on each ordinary protected POST. Only **public verifier keys** are accepted in `KASHER_LICENSE_PUBLIC_KEYS_JSON`; issuing private keys must stay on the vendor's separate trusted workstation/HSM. The license can be activated via a bound owner/manager session; a renewal replaces the grant only for that device. A per-device durable clock guard rejects rollbacks larger than 5 minutes (not tamper-proof against privileged OS/DB rollback). Expiration leaves authenticated read operations available. LAN binding enforces licenses; local single-device commercial mode must explicitly use `--license-enforced`. The development Windows launcher intentionally does not, and thus is **not a production launcher**. No paid renewal backend, licensing key rotation service or hardware trust anchor exists yet. See [Arabic license runbook](LICENSES_AR.md).
