# Local branch HTTP API — v0.1

## Transport and identity

Default `http://127.0.0.1:8787` on Windows. `POST /api/v1/auth/login` does not require a bearer token. Every other `api/v1` route requires `Authorization: Bearer <token>`; sessions expire after 12 hours. Every state-changing business command requires an `Idempotency-Key` header with a unique 16–128 character token. Reusing a key for the identical action/body replays the stored result; reusing it for a different payload returns HTTP 409. JSON errors have `{"error": "..."}`.

### Example: get a token

```bash
curl -X POST http://127.0.0.1:8787/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"tenant_id":"<tenant-id>","username":"admin","password":"<password>"}'
```

### Read endpoints

| Route | Details |
|---|---|
| `GET /health` | Local host health (no credentials) |
| `GET /api/v1/me` | Current user role and permitted branch |
| `GET /api/v1/users` | Owner-only list with no password hashes |
| `GET /api/v1/branches` | Tenant/role-filtered branches |
| `GET /api/v1/products?q=...` | Search up to 100 products by Arabic name, SKU, base barcode or alternate-unit barcode (matching unit ID returned) |
| `GET /api/v1/units?product_id=...` | Listed active carton/alternate units for a product within the tenant |
| `GET /api/v1/customers` | Tenant customers (outstanding balance for manager/owner) |
| `GET /api/v1/suppliers` | Suppliers; restricted to owner/manager/purchasing |
| `GET /api/v1/lots?branch_id=...&product_id=...` | Expiry-lot balances by branch, product, and optional warehouse; includes expired and sellable stock |
| `GET /api/v1/stock?branch_id=...` | Quantity and value (cost hidden from cashier/viewer) |
| `GET /api/v1/documents?branch_id=...` | Recent documents (cost hidden from cashier/viewer) |
| `GET /api/v1/documents/<id>` | Immutable invoice, lines, recorded payments |
| `GET /api/v1/dashboard?branch_id=...` | Owner/manager operational overview |
| `GET /api/v1/audit?branch_id=...` | Owner/manager audit history |
| `GET /api/v1/sync/outbox?branch_id=...` | Owner only, pending local events (not a full sync mechanism) |

### Write endpoints

| Route | Command fields |
|---|---|
| `POST /api/v1/users` | Owner only: `username`, `password`, `role`, `branch_id` |
| `POST /api/v1/products` | `sku`, `name_ar`, `sell_price_minor`; optional `barcode`, `tax_rate_bp`, `base_unit`, `track_expiry` (boolean) |
| `POST /api/v1/units` | `product_id`, `unit_name`, `factor_milli`, `sell_price_minor`, optional `barcode`. Example: carton of 12 base units has `factor_milli=12000` |
| `POST /api/v1/customers` | `name`, optional `phone`, `credit_limit_minor` |
| `POST /api/v1/suppliers` | `name`, optional `phone` |
| `POST /api/v1/branches` | Owner only: `name`, `code` |
| `POST /api/v1/purchases` | `branch_id`, `supplier_id`, `lines` with `product_id` and either `qty_milli` **or** `unit_id` + integer `unit_count`, plus `unit_cost_minor` (per chosen unit); tracked products additionally require `lot_no`, `expires_on` (YYYY-MM-DD); optional `payments` |
| `POST /api/v1/sales` | `branch_id`, `lines`: either `product_id` + `qty_milli` OR `product_id` + `unit_id` + `unit_count`; optional `customer_id`, `payments` |
| `POST /api/v1/sales/returns` | `branch_id`, `original_id`, `refund_method` (`cash`/`credit`), `lines` with `original_line_id`, `qty_milli` |
| `POST /api/v1/purchases/returns` | `branch_id`, `original_id`, `lines` with `original_line_id`, `qty_milli` |
| `POST /api/v1/customers/receipts` | `branch_id`, `customer_id`, `amount_minor`, `method` |
| `POST /api/v1/suppliers/payments` | `branch_id`, `supplier_id`, `amount_minor`, `method` |
| `POST /api/v1/expenses` | `branch_id`, `category`, `amount_minor`, `method` |
| `POST /api/v1/inventory/adjustments` | `branch_id`, `product_id`, signed `qty_change_milli`, `added_cost_minor` when adding, `reason`; tracked products: `batch_id` when reducing, `lot_no` and `expires_on` when increasing |
| `POST /api/v1/inventory/preparations` | `branch_id`, `source_product_id`, `output_product_id`, `input_qty_milli`, `output_qty_milli` |
| `POST /api/v1/auth/logout` | Invalidates bearer token |

`method` is one of `cash`, `card`, `wallet`, `bank`. Methods are recorded as internal cash/clearing accounts, **not gateway integrations**.

### Example: Sale

```bash
curl -X POST http://127.0.0.1:8787/api/v1/sales \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: order-20261112-BR01-POS02-0001' \
  -d '{
    "branch_id":"<branch-id>",
    "lines":[{"product_id":"<product-id>","qty_milli":2500}],
    "payments":[{"method":"cash","amount_minor":500}]
  }'
```

Amounts are integer **piasters** (100 piasters = 1 EGP); quantities are integer thousandths of the selected base unit (`qty_milli=2500` means 2.5 units). Payment total smaller than invoice total requires `customer_id` and available credit limit; overpayments are rejected. No line is committed if stock is insufficient or any journal post fails.

## Cash shifts (development release)

- `GET /api/v1/shifts?branch_id=<id>`: last 100 shifts of authorized branch; a cashier sees only their own shifts.
- `POST /api/v1/shifts/open`: `{"branch_id":"...","opening_minor":10000}`. Only one branch-wide cash till shift is allowed at a time.
- `POST /api/v1/shifts/close`: `{"branch_id":"...","shift_id":"...","closing_actual_minor":12345}`. Difference is returned after the count is submitted (blind close); discrepancies are **not** automatically posted as cash adjustment.

Both POST commands require Bearer authorization and unique `Idempotency-Key`; amounts are **integer piasters**. Shift expected cash is opening count plus CASH ledger movement after open. This is a **single shared drawer** design, not independent cashier till attribution.

## Multi-unit / carton sale accounting (schema v2)

For a product sold as individual pieces and as a carton containing 12 pieces,
create one unit with `factor_milli=12000` and `sell_price_minor=16100`.
To sell two cartons:

```json
{"branch_id":"<branch-id>",
 "lines":[{"product_id":"<product-id>","unit_id":"<carton-unit-id>","unit_count":2}],
 "payments":[{"method":"cash","amount_minor":32200}]}
```

The sale debits 24,000 thousandths of base stock but prices the invoice at
32200 piasters exactly, even if this differs from the base per-piece price.
The original gross line amount is saved for exact cumulative partial refunds.
A unit belongs to exactly one product and tenant; duplicate barcodes on a product
and its alternate units in the same tenant are rejected.

The present purchase endpoint remains base-unit quantities only; automatic
conversion in purchasing and expiry-lot tracking are not part of this migration.

## FEFO lot stock (schema v3)

Perishable products with `track_expiry=true` require a named lot and a valid expiry date for new purchases. Sales consume only unexpired lot quantities in earliest-expiry-first order. Returned sales restore the original sold batch identities; suppliers are returned only the original purchased lot. Tracked warehouse movements stay within a single branch. The API rejects tracked preparation until lot-preserving production is implemented.

Read [the Arabic lot and expiry policy](EXPIRY_LOTS_AR.md) before use. Existing unbatched tracked stock requires a documented reconciliation; the server does **not** manufacture fake lot history.

## Lot quarantine (schema v4)

`POST /api/v1/lots/quarantine` requires `branch_id`, `warehouse_id`, `batch_id`, `quarantined` (boolean), and nonempty `reason`. Stock managers may **quarantine**, but only owner/manager may **release**. Changes are audited, idempotent, and added to the local sync outbox. Quarantined batches are excluded from FEFO sale/transfer but remain in physical inventory balances. This is **not a full recall or legal quarantine management system**.


## Independent stocktake workflow (schema v5)

Warehouse counting is separate from posting: the stock team opens a snapshot,
records an actual quantity for every line, and submits it. A **different**
owner/manager explicitly approves all movements and double-entry valuation.
Any intervening warehouse inventory movement invalidates the snapshot.
Only one open count is allowed per warehouse; cancelled and posted counts
remain immutable records.

| Route | Body / notes |
|---|---|
| `GET /api/v1/counts?branch_id=...` | Open/posted warehouse counts |
| `GET /api/v1/counts/<id>` | Count lines; costs redacted for stock role |
| `POST /api/v1/counts` | `branch_id`, `warehouse_id`, `reason` |
| `POST /api/v1/counts/lines` | `count_id`, `line_id`, `counted_qty_milli`, optional `added_cost_minor` required for positive variance |
| `POST /api/v1/counts/submit` | `count_id` (all count lines must be recorded) |
| `POST /api/v1/counts/approve` | `count_id` (owner/manager other than creator) |
| `POST /api/v1/counts/cancel` | `count_id`, `reason` (owner/manager) |

More detail: [Arabic stocktake guide](STOCKTAKE_AR.md).

## Enrolled branch devices (schema v6)

In non-loopback HTTPS mode, `/api/v1/auth/login` requires `device_id` and `device_secret` as well as tenant/username/password. The LAN API also rejects bearer sessions that have no enrolled active device binding. Revoking a device deletes its sessions immediately.

| Route | Access | Payload |
|---|---|---|
| `GET /api/v1/devices?branch_id=...` | owner/manager | Device status, **never** secret hash |
| `POST /api/v1/devices/pairings` | owner/manager | `branch_id`, returns one-time pairing_code valid 10 minutes |
| `POST /api/v1/devices/claim` | anonymous pairing ticket | `pairing_code`, `device_name`, `tenant_id`; returns device ID + one-time secret |
| `POST /api/v1/devices/revoke` | owner/manager | `device_id`, `reason`; revokes sessions |

Initial pairing on the same server uses the local loopback-only mode; production remote operation requires HTTPS and enrollment. See [Arabic pairing guide](DEVICE_PAIRING_AR.md).

## Purchase by carton / alternate unit

For a product with a 12-piece carton (`factor_milli=12000`), a purchase line with `unit_id`, `unit_count=3`, and `unit_cost_minor=185` records **36 base pieces and a line gross of 555 piasters**. It stores the alternate unit identity, count and exact line gross in the immutable document; the base-unit stock ledger increases by 36000 thousandths and its inventory value by 555 piasters. `unit_cost_minor` is the purchase cost of each **carton**, not of a base piece. Optional `bonus_qty_milli` adds free units in base-unit thousandths without inflating invoice gross or stock valuation. Expiry-controlled goods require a real lot number and ISO expiry even for carton purchases. A purchase line must not mix `unit_id` with `qty_milli` or send `unit_count` without `unit_id`.

Example:

```json
{"branch_id":"<branch-id>","supplier_id":"<supplier-id>",
 "lines":[{"product_id":"<product-id>","unit_id":"<carton-unit-id>",
 "unit_count":3,"unit_cost_minor":185}],"payments":[]}
```

Returns still specify **base-unit** `qty_milli` against an immutable original purchase line, preserving cumulative fractional-piaster rounding on partial returns. The feature does not yet support purchase-order approvals or supplier EDI.

## Promotional prices (schema v7)

`GET /api/v1/promotions?product_id=...` lists offers.
`POST /api/v1/promotions` accepts `product_id`, optional `unit_id`, `title`, integer `promo_price_minor`, and `starts_at`/`ends_at` UTC timestamps (YYYY-MM-DDTHH:MM:SSZ). Owner/manager only; promotions may not overlap for the same product and unit. `POST /api/v1/promotions/stop` accepts `promotion_id` and `reason`.

Product and unit lookup responses include `effective_sell_price_minor` and `promotion_id` alongside original `sell_price_minor`. The sale endpoint always determines the current effective price server-side at posting time; a cashier cannot override it. Original receipt line amount is immutable for returns. See [Arabic price guide](PROMOTIONS_AR.md).

### Optional cart total lock (promotional price changes)

For sale requests, pass integer `expected_total_minor` equal to the amount the operator approved in the client cart. The server **recomputes** current promotional pricing at the moment of posting and rejects mismatches with HTTP 409, without posting any inventory or financial movement. The latest Flutter POS includes this field by default. Historical integrations omitting it remain backwards compatible, but should add it to prevent stale cart pricing.


## Local shared-database branch shipment workflow (schema v8)

For branches registered **in the same SQLite host** (not offline/cloud replication), `POST /api/v1/branch-shipments/dispatch` accepts source/destination branch+warehouse IDs, product ID, and quantity in thousandths. Dispatch debits `IN_TRANSIT` and credits source `INVENTORY`; `POST /api/v1/branch-shipments/receive` requires a distinct authorized receiver and transfers value to destination inventory, preserving FEFO lot numbers and expiry dates. `POST /api/v1/branch-shipments/cancel` reverses an outstanding dispatch to source with a required reason. `GET /api/v1/branch-shipments?branch_id=...` lists relevant shipments, and `GET /api/v1/branch-shipments/<id>` includes lots. [Arabic instructions](BRANCH_SHIPMENTS_AR.md).


## Signed per-device annual licenses (schema v9)

Remote LAN mode enforces an Ed25519-signed annual license on **all normal POS POST commands**, regardless of user role. A new **enrolled and active device** must be licensed before financial/inventory/product writes. To activate or renew a grant as owner/manager on that same device, send `POST /api/v1/licenses/activate` with `license_token` plus a 16..128 character `Idempotency-Key`. `GET /api/v1/licenses/status` returns `status`, `writable`, `device_id`, `serial` and `expires_at` only; it never returns the raw token or private signing keys. Devices without grants or with expired/revoked/invalid signatures may still read records according to their staff permissions. Tokens are verified again **on every protected write**; a persistent clock-guard detects gross server clock rollback. Device pairing, authentication, license activation and logout routes remain available without an active grant so recovery and renewal are possible.

For a single-PC deployment, start with `--license-enforced` and an administrator-provisioned `KASHER_LICENSE_PUBLIC_KEYS_JSON` map of key IDs to 32-byte Base64URL Ed25519 **public** keys. The default localhost development launcher does not impose the licensing gate and must not be presented as a production-commercial deployment. [Arabic instructions](LICENSES_AR.md).


## Read-only verified printed sale receipt

`GET /api/v1/receipts/<id>` returns ONLY a posted `sale` (not purchases or unposted documents), scoped to the authenticated tenant and branch. The server reconciles **persisted** line gross, discount and VAT amounts against posted totals, and persisted payment method amounts against `paid_minor`, before returning a sanitized receipt object (no COGS, purchase cost, hidden password, customer PII, or payment reference). The response carries `store_name`, `branch_name`, `cashier_name`, number, UTC timestamp, items with base/alternate-unit quantity, tax, `total_minor`, `paid_minor`, `due_minor`, `payments` and a clear **non-fiscal** disclaimer. Any inconsistent stored accounting data fails closed with 409. This is a GET-only read: reprints never post another sale or inventory movement. [Arabic printing guide](PRINTING_AR.md).


## Branch-isolated debt settlements and read-only account statements

The optional `branch_id` query parameter on `GET /api/v1/customers` and
`GET /api/v1/suppliers` restricts returned `balance_minor` to the requested,
authorized branch. For backward compatibility, omitting the parameter retains
the previously exposed tenant-wide balance for owners and managers.
Cashiers see customer debt balances only for their branch; purchasing staff
see supplier debt balances only for their branch.

`GET /api/v1/debts/statement?branch_id=<branch>&party_type=customer&party_id=<id>`
(or `party_type=supplier`) returns the party name, current branch balance,
`opening_minor`, and up to 200 latest journal entries (newest first), each
with `debit_minor`, `credit_minor`, `change_minor`, and
`balance_after_minor`. Positive change increases the party's debt;
negative change reduces it. Earlier movements are included in opening.
Cashiers can view customer statements for their own branch only; purchasing
staff can view supplier statements for their own branch only. Managers/owners
have role-appropriate authorized-branch access. The statement is derived
from immutable journal lines, not from invoice paid labels.

**Critical safety fix:** `POST /api/v1/customers/receipts` and
`POST /api/v1/suppliers/payments` now verify debt **in the selected
authorized branch**, not against the aggregate tenant balance. This prevents
cash applied against an unrelated branch's debt. Customer **credit-limit**
checking remains intentionally tenant-wide until the per-branch credit
policy is approved. Cross-branch reallocations, per-invoice allocation, and
multi-host replication are **not implemented**. No balances are silently moved.


## Invoice-targeted debt settlement (schema v11)

An optional `invoice_id` is now accepted on
`POST /api/v1/customers/receipts` and `POST /api/v1/suppliers/payments`.
The target must be an approved posted sale/purchase belonging to the same
tenant, branch, and customer/supplier. The amount must not exceed the
remaining invoice credit balance **or** the branch's journal liability.
A targeted payment writes an immutable `debt_allocations` row and its cash,
journal and audit records atomically with the existing idempotency key.

`GET /api/v1/debts/invoices?branch_id=...&party_id=...&party_type=customer|supplier`
lists up to 500 recent invoices with positive remaining credit, deducting
upfront payments, explicit allocations and credit-form returns. It also
returns `balance_minor`, `unallocated_settlements_minor`,
`allocation_available`, and `has_more`. A legacy account-wide settlement
with no target prevents **new targeted allocations** for that party and
branch until separately reviewed; historical allocations are never guessed.
The untargeted legacy settlement route remains supported.

Only **one** invoice per settlement is supported; this does not yet perform
automatic FIFO distribution, payment allocation across multiple invoices,
historical reconciliation or customer credits after overpaid returns.
See [Arabic operator guide](INVOICE_ALLOCATIONS_AR.md).


## Split settlement across several invoices (schema v12)

Both `POST /api/v1/customers/receipts` and
`POST /api/v1/suppliers/payments` now accept an optional `allocations` array
instead of `invoice_id`:

```json
{
  "branch_id": "<branch-id>",
  "supplier_id": "<supplier-id>",
  "method": "bank",
  "amount_minor": 900,
  "allocations": [
    {"invoice_id": "<invoice-A-id>", "amount_minor": 600},
    {"invoice_id": "<invoice-B-id>", "amount_minor": 300}
  ]
}
```

The API validates 1–20 unique invoices with **positive integer-piaster**
allocations whose sum **exactly equals** the payment amount, without
exceeding any individual invoice balance, the party's branch journal balance,
or crossing a tenant/party/branch. `invoice_id` and `allocations` cannot
be submitted together. A single payment row and journal entry is posted,
with one immutable `debt_allocation_lines` row per invoice; all writes and
the idempotency key run in the same SQLite transaction. The response includes
`allocations` with each invoice's `invoice_remaining_minor`.

Existing v11 single-invoice allocations remain untouched and included in
invoice remaining balances. Legacy untargeted payments still block new
targeted allocations pending human reconciliation. This workflow does not
auto-allocate oldest invoices, net returns that over-credit prior payments,
or reconcile historical unallocated receipts. The Flutter form supports
manual split input across at most 20 of the currently displayed invoices.


## Reviewable reconciliation of legacy account payments (schema v13)

Historical account-wide receipts/supplier payments **without a document ID or
allocation** can be matched to invoices, but only with independent review.
This is a **linking-only** operation: no new cash payment, journal entry,
or modification of original receipts is created.

Owner/manager scoped reads:
- `GET /api/v1/debts/unallocated?branch_id=...&party_id=...&party_type=customer|supplier` lists up to 200 unmatched original payments with a pending request ID if any.
- `GET /api/v1/debts/reconciliations?branch_id=...&party_id=...&party_type=customer|supplier` lists recent requests, their proposed invoice lines, requester, and review outcome.

Owner/manager state-changing actions each require a unique
`Idempotency-Key`:
- `POST /api/v1/debts/reconciliations`: `branch_id`,
  `party_id`, `party_type`, `payment_id`,
  `reason` (12–1000 characters) and
  `allocations: [{invoice_id,amount_minor},...]` (1–20 unique documents,
  exact full amount of original payment).
- `POST /api/v1/debts/reconciliations/approve`: `reconciliation_id`
  and `reason` (12–1000 characters); only a **different** authorized
  owner/manager may approve, and all invoice balances and original
  payment/journal checks are rerun inside the approval transaction.
- `POST /api/v1/debts/reconciliations/reject`: same fields; closes
  a pending request so a new corrected proposal can be made.

A request stores immutable proposal lines and audit records. On approval,
only `debt_allocation_lines` is augmented with links back to the
**pre-existing** payment ID. The legacy amount stops blocking targeted
payments only after **all** unmatched payments for that party and
branch are reconciled. Rejected requests never allocate invoices.
Cross-tenant/branch/party mismatches, duplicate invoices,
stale returns, over-allocation and self-review are rejected.

Do not infer that a payment belongs to an invoice without original
bank/cashier documentation. This is a conservative, manual workflow and
does not support split approvals by one employee, chargebacks,
overpayment credit settlement, or cross-host reconciliation.
See [Arabic workflow](LEGACY_DEBT_RECONCILIATION_AR.md).


## Applying existing customer/supplier return credits (schema v14)

A credit-refund return note is an existing AR/AP credit, not cash.
The original return automatically applies up to the amount still due
on its original invoice. Any excess remains as a visible available
credit note and can be applied to another posted invoice for the
**same party and branch**.

`GET /api/v1/debts/invoices?branch_id=...&party_id=...&party_type=customer|supplier`
now also returns:
- `available_credit_minor`: total unused credit-note value for this party/branch.
- `credit_notes[]`: source return ID, return number/date, original invoice
  number, total and `available_minor`.

`POST /api/v1/debts/credits/apply` (owner/manager only) accepts
`branch_id`, `party_type`, `party_id`, `credit_document_id`,
`invoice_id`, `amount_minor`, and a required 12–1000 character
`reason`. The amount must fit both the source note's remaining value
and the target invoice's current outstanding balance. Both documents
must be posted, same-tenant, same-branch, same-party and of the correct
customer/supplier types. Cash-refund notes cannot be used.

Applying a credit note writes one `debt_credit_allocations` row and
an audit/outbox event only. It does **not** create a payment row,
cash movement, journal entry, VAT event, or profit change. The
existing return journal already posted the AR/AP credit. Idempotency
keys prevent accidental duplicate allocation on retry.

Schema v14 migrates historical credit returns additively. It
materializes the portion that previously reduced the original invoice
as an explicit allocation; the excess is retained as an available
credit note. Original documents, payment rows and journals are not
rewritten. See [Arabic operator guide](RETURN_CREDIT_APPLICATION_AR.md).


## Independent cash drawers and shift-specific cash attribution (schema v15)

By default, upgraded branches retain the earlier **single shared branch shift**
behaviour. Creating the **first** drawer permanently opts that branch into
independent drawer mode; the shared shift must be closed first.

- `GET /api/v1/shifts/drawers?branch_id=...` returns registered drawer IDs,
  names, active flags, and current open-shift IDs for owner/manager/cashier.
- `POST /api/v1/shifts/drawers` (owner/manager, idempotent) accepts
  `{branch_id,name}` (maximum 32 drawers per branch; names unique).
- `POST /api/v1/shifts/open` accepts `{branch_id,opening_minor,
  cash_drawer_id}` in independent mode; cashier/manager/owner opens
  a shift as themselves on an available active drawer. One active shift
  per drawer and operator is enforced by SQLite partial unique indexes.
- `GET /api/v1/shifts?branch_id=...` additionally returns
  `drawer_id`, `drawer_name`, and `operator_name`.
  Cashiers see only their shifts and never the expected amount on an open
  shift.
- `POST /api/v1/shifts/close` accepts `{branch_id,shift_id,
  closing_actual_minor}`; if a manager/owner closes another operator's
  independent-drawer shift, `override_reason` of 12–500 characters is
  mandatory and audited.

On every **CASH** journal posting after drawer activation, the server looks
up the authenticated actor's **own one open drawer shift**. If none exists,
it rejects the entire transaction (including the sale/document/stock
posting); it never guesses the till or silently attributes a sale to
another employee. The exact signed `CASH` delta from the balanced
journal is linked to that shift via `cash_shift_journal_links`. Cash
closing is the shift's opening physical float plus these linked ledger
deltas, excluding another employee's cash and all noncash card/bank/
wallet payments. Discrepancies are logged but not booked to the ledger
without independent approval.

Branches that never register drawers continue to support one branch-wide
shift without forcing new POS field entry. There is no cash float
transfer between drawers, hardware door/coin control, double-count
handoff, cash deposit journal workflow, or shared cashier session
identity; cash transactions without an actor's open drawer shift are
blocked once independent drawers are enabled. See
[Arabic operator guide](MULTI_CASH_DRAWERS_AR.md).
