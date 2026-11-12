# Kasher development build and release gates

This branch is a **development build**, not certified commercial software.
GitHub Actions workflow: `.github/workflows/import-kasher-source.yml`.

## What CI verifies
- Static analysis and unit tests for the Dart/Shelf/SQLite branch server
- Static analysis (non-fatal deprecation info) and unit tests for Flutter app
- Python SQLite schema check, audit checker and encrypted backup round-trip
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
separate-branch transfer dispatch and receipt; TLS/pairing for LAN devices;
fully reconciled shifts and role overrides; expiry/lot and multi-unit flows;
price/promotional rules; audited signed annual per-device licensing; scheduled
encrypted backups with restore tests; tested thermal and label printers and
electronic scale models; Egyptian tax/e-invoice compliance; signed Android
release; real Windows installer; accessibility and security review; and the
complete 34-domain acceptance test suite.

Do not expose `--bind=0.0.0.0` on an untrusted network; it is unencrypted HTTP.
The `start_windows.ps1` launcher binds to localhost only.
The Android debug build needs an isolated test LAN setup with a reachable branch host.
