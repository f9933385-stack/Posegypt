# Verification record — 2026-11-12

Target: `https://github.com/2753442a/Posegypt` (not modified).

## Executed in the preparation container

- PASS: `python tools/verify_schema.py` — parsed and created 28 SQLite DDL
  statements; checked selected foreign-key and uniqueness constraints.
- PASS: `python -m unittest discover -s tools/tests -v` — 6 tests covering
  encrypted backup/restore, wrong-password rejection, audit pass/fail, and
  detection of mismatched stock and unbalanced journals.
- PASS: YAML parser accepted server/app `pubspec.yaml` and CI configuration.
- PASS: simple source inspection for GitHub PAT-like literals.

## Not executed / not certified

- Dart SDK not installed; **`dart pub get`, `dart analyze`, `dart test` NOT RUN**.
- Flutter SDK not installed; **`flutter analyze`, `flutter test`, platform
  builds, installed Windows application, and Android APK NOT RUN**.
- No physical barcodes, printers, scale, cash drawer, payment terminal tests.
- No cross-branch sync, VAT/e-invoice compliance, yearly licensing, LAN TLS,
  customer production backups or restore drills.
- New cash-shift source and its Dart unit test were **not compiled or run**.

The code is a development starting point, **not a production-ready financial
system**. Before commercial use, build on Windows, run `scripts/check.ps1`,
review financial correctness and security, test on target devices and conduct
the 34 documented acceptance checks from `docs/MASTER_SPEC.md`.
