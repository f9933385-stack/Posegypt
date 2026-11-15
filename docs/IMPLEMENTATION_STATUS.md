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


## Security follow-up (2026-11-15)

Schema v10 and SQLite-backed per-identity staff-login throttling replace the
prior process-memory throttle. The lockout survives API process restarts and is
covered by expiry, identity-isolation, and restart tests. Cross-host/IP
rate limiting, monitoring, and penetration testing are **not** implemented.
This addendum supersedes the earlier login-throttling sentence in the
initial 2026-11-12 snapshot above; it does not revise the remaining statuses.


## Follow-up: invoice-specific debt allocation (schema v11)

Added an explicit one-payment-to-one-invoice allocation table and read
endpoint; the existing customer/supplier receipt API now accepts an optional
invoice ID. Checks run inside the original atomic posting transaction and
respect party, tenant and branch permissions, posted returns, journal balance,
and request idempotency. The Flutter debts screen can select an invoice.
Legacy untargeted receipts are **not** guessed into invoices: new targeted
payments are conservatively blocked until reconciliation. Multi-document
allocation, historical repair, refund credits after overpayment, and
cross-host replication remain open commercial gates.


## Continued accounts work: schema v12 multi-invoice allocations

Added additive `debt_allocation_lines` schema, preserving v11 single-invoice
allocations. One payment now accepts up to 20 distinct invoice allocations
whose values sum exactly to the posted amount, with branch, party,
tenant, credit-return, and idempotency enforcement. Flutter debt page
supports selecting multiple invoices and entering per-invoice amounts.
New Dart regression suite and independent Python read-only audit detect
broken sum-to-payment or mismatched party/document links.

Still unresolved: legacy unallocated receipt reconciliation, automatic
FIFO allocation, post-settlement return overcredits, cloud branch sync,
and release certification.


## Legacy debt reconciliation: maker-checker stage v13

Added additive `debt_reconciliations` and
`debt_reconciliation_lines` tables and three idempotent
commands to propose, independently approve or reject manual matches
of old unallocated customer/supplier settlements. Approved requests
create invoice-allocation links referring to the **original**
payment row; no second cash or journal post occurs. Journal
validation, party/branch role checks, reasons, revalidation after
return changes and independent reviewer checks are covered by
tests. A manager-only Flutter reconciliation dialog lists old
payments, supports invoice allocation proposals, and displays
pending/approved/rejected decisions.

Separate financial-system sign-off, old bank document review,
overpaid returns, cloud sync and physical device certification
remain unresolved commercial gates.


## Return credit application and carry-forward: schema v14

Added `debt_credit_allocations` to represent existing credit-refund
return notes applied to posted invoices. New credit returns are
automatically applied up to the original invoice's outstanding due;
excess remains available. Owner/manager can apply that balance to a
different invoice for the same party/branch. The operation creates
allocation/audit/outbox records only and never reposts cash or journal
entries. `GET debts/invoices` exposes available credit notes and
`POST debts/credits/apply` validates source/target, amount and reason.

The v14 migration backfills old credit returns in chronological order,
preserving the historical reduction of each original invoice while
leaving excess available. Dashboard separates positive receivables/
payables from net customer/supplier credit balances. Domain, API and
migration tests cover customer/supplier flows, partial original invoice
settlement, cash-return exclusion, party isolation, idempotency and
no duplicate journal posting.

Remaining commercial gates still include Egyptian ETA fiscal integration,
physical cash-register/printer certification, independent cloud sync,
bank reconciliation and live-store accounting sign-off.


## Independent cash drawers: schema v15

Additive `cash_drawers`, nullable `cash_shifts.drawer_id`, and
`cash_shift_journal_links` provide **opt-in** physical cash separation:
legacy branches continue using their single shared shift until the
first drawer is registered, which requires closing the shared shift.
One open shift per registered drawer and operator; each CASH journal
posted in independent mode must map to that same authenticated actor's
open shift or the business transaction rolls back. Debit/credit deltas
come exclusively from actual balanced `CASH` journal lines.
Independent shift closing counts only linked journal cash and opening
float, not other operators or card/bank/wallet payments.

Supervisor closure of another user's shift requires a reason.
The Flutter shift screen allows managers to register drawers and each
operator to open/close their own, including cash counts.
Domain/API/migration tests and read-only Python auditing verify
scope, actor identities and ledger delta consistency.

This is NOT a complete cash management suite. There is still no
cash transfer between drawers, safe-drop/bank deposit, float issue
workflow, second-person count sign-off or certified physical
cash drawer integration.


## v16: independently accepted cash-drawer handovers

Added additive `cash_drawer_transfers` with `pending`,
`approved`, `rejected`, `cancelled` lifecycle. A sender
with an open, active branch drawer shift may propose a transfer;
only the receiving shift's distinct authenticated operator can
approve or reject it, with documented reason. The sender may
cancel a pending proposal. No proposed/rejected/cancelled amount
changes balances; approved amounts reduce the sender's shift
expectation and increase the recipient's by the same amount.
The operation intentionally posts no general-ledger CASH entry.

Both shifts must remain open for approval; closing is blocked
until pending handovers have been reviewed. Approval rechecks
source cash availability to prevent committing stale promises.
This is branch-local physical cash attribution only, not a
cash vault, bank-deposit posting or cross-host synchronization.
Tests cover domain/API authorization, approval, cancellation,
amount limits, replay safety, journal invariance and v15 migration.


## Branch-local cash safe — v17

Added `cash_safes` (one optional zero-opening safe per
independent-drawer branch) and `cash_safe_drops` with
`pending/approved/rejected/cancelled` lifecycle. An active
drawer operator proposes a physical drop; a *different*
authorized owner/manager confirms physical receipt. Only
approved drops reduce sender shift expected cash and increase
safe expected balance. Pending proposals block shift closure;
reject/cancel do not move anything. Rechecks at approval
prevent stale/overdrawn requests. Each command is idempotent,
audit-traced and queued in the branch outbox; no extra CASH
general-ledger posting occurs.

Added scoped GET/POST API, Flutter safe drop interface,
migration from v16, domain and API coverage, and Python
read-only financial custody audit. This milestone is not
bank deposits, treasury withdrawals, inventory sync,
hardware certification or complete production accounting.
