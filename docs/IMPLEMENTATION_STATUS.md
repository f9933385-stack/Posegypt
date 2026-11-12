# Implementation status / حالة التنفيذ

Date: 2026-11-12. Source of truth: [`MASTER_SPEC.md`](MASTER_SPEC.md).

Legend: **Implemented source** = code exists but Flutter/Dart build has not yet been run. **Partial** = foundation exists but spec remains unsatisfied. **Not implemented** = no working implementation should be assumed. This status is not certification of production readiness.

| Workstream | Status | Evidence / limitations |
|---|---|---|
| Flutter Arabic Windows/Android UI | Implemented source | Login and role-aware operating screens (including branch-wide shifts); native platform scaffolds must be generated and built/tested |
| SQLite transactional branch host / Shelf | Implemented source | Schema v1, WAL, transactions, API |
| Users/passwords/role restrictions | Partial | PBKDF2 + opaque sessions + basic scoped roles; user provisioning UI, lockouts, MFA, audit of failed logins missing |
| Products/barcodes | Partial | SKU, unique barcode, EAN-13 utility; multiple UOM and price lists absent |
| Purchases: cash, credit, partial | Implemented source | WAC stock input, supplier payable, cash/card/wallet/bank recording |
| Sale and mixed payment | Implemented source | POS cart, quantity fractions, cashier discount/price override protection |
| Credit customers and supplier settlement | Implemented source | Limit checking and account settlements; company-wide vs branch debt policy still needs decision |
| Supplier/customer returns | Implemented source | Original document linkage, remaining-quantity check; full complex tax/bonus proration needs acceptance tests |
| Double-entry journal | Implemented source | Every posted sale/purchase/settlement/expense/adjustment linked to balanced entry; preparation reclassification maintains total stock asset |
| Simple owner reports | Partial | Sales, COGS, inventory value, cash, receivables, payables, expenses, estimated profit; dates, rollups, advanced P&L missing |
| Product preparation | Partial | Raw consumption and produced stock with conserved cost; waste classifications and labels missing |
| Inventory counting | Partial | Quantity adjustments and WAC; live-cycle count with snapshot and delta not built |
| Expiry/lot tracking | Not implemented | DB groundwork only; no physical/virtual FEFO or warnings in app |
| Warehouse and branch transfers | Not implemented | Branch warehouse schema present; workflows absent |
| Central cloud sync | Not implemented | Durable outbox only, no transport, inbox, conflicts or central server |
| Backup and restoration | Not implemented | No encrypted verified rotating backup or cloud drive integration |
| Annual per-device licensing | Not implemented | No Ed25519 license verification or read-only expiry gate |
| Shift management | Partial | Branch-wide shared till opening, blind closing, cash delta, difference review; independent tills, approval workflow, hardware drawer not implemented |
| Printing / scales / ESC-POS / QR pairing | Not implemented | Barcode math helper; physical device interfaces absent |
| Egyptian e-receipt/e-invoice | Not implemented | Tax rate fields only; no regulatory integration or legal compliance claim |
| Full 34 acceptance tests | Not complete | Dart unit tests supplied, unexecuted; SQLite DDL constraints tested in Python |
| Installer / tested binaries | Not implemented | Build scripts provided but no executable/APK delivered |

## Verification completed in this environment

- `python tools/verify_schema.py`: **PASS** on creation of all DDL statements plus selected FK, stock and duplicate-barcode constraints.
- `yaml.safe_load` on both `pubspec.yaml` files and CI YAML: **PASS**.
- Dart / Flutter package fetch, analysis, unit tests, desktop build and Android build: **NOT RUN** (SDK absent and outbound network unavailable).
- GitHub targets `jjBurgur/Kasher` and `2753442a/Posegypt`: inspected; each had `README.md` only, linked account had `pull: true`, `push: false`. No remote modifications made.

## Engineering decisions not closed

In particular, source code currently refuses negative stock; stock cost uses warehouse-level moving WAC, not per-branch aggregate. These are conservative development choices, not approved final accounting policies. The API is HTTP on LAN without TLS; it **must not** be exposed outside an isolated test network. Session state is held in RAM by the Flutter app (host and tenant ID only cached).

## Additional work included in the source archive

- Added read-only consistency checker (`tools/audit_database.py`) covering
  foreign keys, SQLite integrity, zero journal imbalance, inventory movement
  reconciliation, positive payment bounds, and cross-tenant product movements.
- Added password-protected AES-256-GCM streaming snapshot/restore utility with
  round-trip tests (`tools/backup_database.py`). This is a **manual local** tool,
  not encrypted cloud backup automation. Test restoration on a separate path.
- Fixed missing Flutter `flutter_localizations` SDK dependency in pubspec.
- Added steps to publish to the new target `2753442a/Posegypt` without placing
  a token in source. Repository remains unmodified due to absent push rights.

The new tools do not change the status of any remaining production gate.

- Added branch-wide cash shift commands (`shift_open` / `shift_close`), REST endpoints and
  a Flutter shift page with blind close. This assumes one shared branch till;
  separate physical cash drawers and formal variance approval remain unfinished.
