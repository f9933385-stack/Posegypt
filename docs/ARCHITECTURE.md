# Architecture overview

```text
        Flutter on Windows          Flutter on Android
               |                          |
               +------ Local HTTP API ---+
                           |
                    Dart Shelf Host
             Auth / RBAC / DTO validation
                           |
                 Transactional Engine
                           |
              SQLite WAL + Foreign Keys
                /         |          \
        Documents     Journal      Inventory
        Payments      Accounts     Balances
                           |
                     Durable Outbox
                           |
                 [Cloud sync: NOT BUILT]
```

The local Windows service owns the SQLite database file. Additional clients must use its API, never a shared database file over SMB. A second independent branch is intended to operate from a separate database and local service, with a future central sync protocol.

## Transaction rule

A business write begins `BEGIN IMMEDIATE`, verifies idempotency, checks tenant/branch/role and stock/credit limits, records documents and signed stock movements, posts balanced accounting lines and audit/outbox entries, saves the idempotency response, then commits. Any thrown exception rolls the transaction back. Reads use parameterized SQL; money and quantities use integers.

## Financial accounts (internal only)

- `INVENTORY`, `COGS`, `SALES_REVENUE`, `SALES_RETURNS`, `VAT_OUTPUT`, `VAT_INPUT`
- `CASH`, `CARD_CLEARING`, `WALLET`, `BANK`, `OPERATING_EXPENSE`
- `AR:<customer-id>`, `AP:<supplier-id>`
- `INVENTORY_ADJUSTMENT`, `PURCHASE_VARIANCE`

Customers never see the chart of accounts in the UI. All ledger entries must balance exactly in integer piasters. Detailed financial/tax certification needs a separate accounting review.

## Data contract

- `*_minor` means **integer piasters** (100 = EGP 1.00).
- `*_milli` means **integer thousandths of the product base unit** (1000 = 1.000 unit).
- `*_bp` means **basis points** (1400 = 14.00%).
- Timestamps are stored in UTC ISO-8601. Cairo timezone display and fiscal calendar handling need to be added.
- Documents carry a JSON snapshot of the transaction payload; a full organization-and-party historical snapshot is still a release gate.
- Database schema v1 is in `server/lib/src/schema.dart`. `sqlite3` and `shelf` are backend dependencies; no Flutter package directly opens the host database.
