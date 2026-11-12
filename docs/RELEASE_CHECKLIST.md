# Release gate checklist

All unchecked items block a commercial production claim.

- [ ] Flutter packages fetch, `flutter analyze` and `flutter test` all pass.
- [ ] Dart server packages fetch, `dart analyze` and `dart test` all pass.
- [ ] Windows application and packaged server successfully installed on clean Windows machine with SQLite runtime dependencies.
- [ ] Android APK installed and tested on physical device with secure branch connectivity.
- [ ] Multiple simultaneous cashiers, power failure, duplicate submits and intermittent LAN extensively tested.
- [ ] Accounting reconciliation: journals balanced, inventory value ties to COGS, customer/supplier receivable/payable balances match statements.
- [ ] Expiry/batch policy, unit conversions, promos and safe returns implemented and approved.
- [ ] TLS, pair/revoke devices, login rate limit, RBAC scope and security assessment complete.
- [ ] Central branch sync, multi-branch stock transfer with in-transit workflow and replay tests complete.
- [ ] Encrypted local + Google Drive backups and documented restore drill complete.
- [ ] Device license signature + expiry read-only API enforcement and time rollback tests complete.
- [ ] Printer, barcode labels and scale integrations verified on selected hardware models.
- [ ] Egyptian legal/tax compliance reviewed against current official requirements.
- [ ] All 34 `docs/MASTER_SPEC.md` acceptance cases executed with evidence.
- [ ] Performance tests with target product/transaction volumes and safe upgrade/migration rollback complete.
