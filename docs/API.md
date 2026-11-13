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
| `POST /api/v1/purchases` | `branch_id`, `supplier_id`, `lines` with `product_id`, `qty_milli`, `unit_cost_minor`; tracked products additionally require `lot_no`, `expires_on` (YYYY-MM-DD); optional `payments` |
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
