# Kasher development build and release gates

This branch is a **development build**, not certified commercial software.
GitHub Actions workflow: `.github/workflows/import-kasher-source.yml`.

## What CI verifies
- Static analysis and unit tests for the Dart/Shelf/SQLite branch server
- Static analysis (non-fatal deprecation info) and unit tests for Flutter app
- Python SQLite schema check, audit checker, encrypted backup round-trip and verified retention tests
- Android **debug** APK build, uploaded as an Actions artifact
- Windows **release-mode UI binary** and compiled branch-service executable, packaged together as an Actions artifact
- Compiled Windows branch-service initialization, authenticated API purchase and sale smoke test (see latest workflow run)

## How to download
Open the newest green GitHub Actions run on the feature branch. In the Artifacts
section download `Kasher-Windows-development` or `Kasher-Android-development`.
Artifacts expire under GitHub retention settings (currently 14 days). Windows ZIP
contains `start_windows.ps1` if the launch script is present in the source commit.

## Critical exclusions before production
The project is **not** ready for a real supermarket, despite green builds.
Remaining blockers include branch-to-cloud sync and conflict reconciliation;
separate-branch transfer dispatch and receipt; managed TLS certificate trust, device attestation, credential rotation and hardware-backed renewal for LAN devices;
fully reconciled shifts and role overrides; lot-aware preparation/recalls and purchase-side unit conversion;
price/promotional rules; audited signed annual per-device licensing; host-scheduled/offsite
backup automation and full disaster-recovery drills; tested thermal and label printers and
electronic scale models; Egyptian tax/e-invoice compliance; signed Android
release; real Windows installer; accessibility and security review; and the
complete 34-domain acceptance test suite.

Non-loopback bindings now require configured TLS certificates and keys; plaintext is loopback-only.
The Windows launcher binds to localhost only. Android testing requires a reachable LAN HTTPS endpoint with an OS-trusted CA and matching DNS SAN.

## New hardening checkpoints
- Schema v2 migration retains existing v1 records and rejects unknown future versions.
- POS supports alternate carton/box units with exact line gross, barcode lookup and cumulative return rounding.
- Encrypted backup rotation runner: `python tools/scheduled_backup.py DATABASE PRIVATE_BACKUP_DIR --keep 14`. It verifies restore before retaining/pruning; **host scheduler, vault and offsite restore drill still required**.
- Read [`docs/PRODUCTION_READINESS_AR.md`](PRODUCTION_READINESS_AR.md) for Arabic operations and release restrictions.

## Expiry-lot milestone (schema v3)
- Purchases validate `lot_no` + `expires_on` for tracked products; tracked sale consumes FEFO unexpired lots transactionally.
- Returns, supplier returns, same-branch warehouse transfers and batch-level stock adjustments preserve lot provenance.
- A separate batch movement ledger is audited against tracked warehouse stock and includes original document-line references.
- Expired stock cannot be sold, while returned expired stock stays outside FEFO sale availability.
- **Not yet complete:** recalls, quarantine workflows, automatic expired-write-off with approvals, lot-aware preparation and fully verified stocktakes; refer to [expiry lot restrictions](EXPIRY_LOTS_AR.md).

### Lot quarantine (schema v4)
- Authorized warehouse stock staff can block a lot from FEFO sale/transfer, with a required reason and audit event.
- Only owner/manager can release the lot; physical stock balances remain unchanged.
- Full recall workflow, disposal certificates, supplier notifications, temperature logs and separate sellable/unsellable warehouses remain unfinished.


## Independent warehouse stocktake milestone (schema v5)
- Draft count from a branch warehouse snapshot (up to 2000 lines), live sales still run.
- Counted quantity including zero for every line, plus exact positive-cost variance.
- Independent owner/manager approval; atomic stock adjustment, WAC journal and lot movement.
- Reject approvals after intervening inventory movement; cancel/restart the count.
- SQLite migration is forward-only; completed counts retain an auditable record.
- **Not production certified:** multi-cashier field trial, blind second count,
  device integration, approvals at configurable variance thresholds and cloud sync.

[دليل الجرد بالعربية](STOCKTAKE_AR.md)

## HTTPS milestone
- Server refuses all plaintext non-loopback listening and accepts a configured TLS certificate/key pair.
- Flutter refuses remote HTTP endpoints before sending login credentials or bearer tokens.
- TLS tests use an ephemeral local test certificate with a real Shelf HTTPS listener when OpenSSL is available.
- Still missing: per-device pairing, revocation, managed certificate lifecycle and field security validation.
- [Arabic trusted HTTPS guide](HTTPS_LAN_AR.md).

## Device pairing v6 milestone
- One-time 10-minute admin-generated pairing codes, hash-only storage, one-time secret claim.
- Persistent encrypted device credentials via flutter_secure_storage (Windows/Android), server-bound sessions and immediate revocation.
- LAN mode requires device and employee credentials; loopback retains explicitly local initial enrollment.
- Hardened Android manifest auto-backup and cleartext settings in CI.
- Device pairing is NOT a substitute for managed MDM, hardware attestation, mTLS, intrusion monitoring or complete security review. [Arabic enrollment guide](DEVICE_PAIRING_AR.md).
