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
| `GET /api/v1/products?q=...` | Search up to 100 products by Arabic name, SKU, barcode |
| `GET /api/v1/customers` | Tenant customers (outstanding balance for manager/owner) |
| `GET /api/v1/suppliers` | Suppliers; restricted to owner/manager/purchasing |
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
| `POST /api/v1/products` | `sku`, `name_ar`, `sell_price_minor`; optional `barcode`, `tax_rate_bp`, `base_unit` |
| `POST /api/v1/customers` | `name`, optional `phone`, `credit_limit_minor` |
| `POST /api/v1/suppliers` | `name`, optional `phone` |
| `POST /api/v1/branches` | Owner only: `name`, `code` |
| `POST /api/v1/purchases` | `branch_id`, `supplier_id`, `lines` with `product_id`, `qty_milli`, `unit_cost_minor`; optional `payments` |
| `POST /api/v1/sales` | `branch_id`, `lines` with `product_id`, `qty_milli`; optional `customer_id`, `payments` |
| `POST /api/v1/sales/returns` | `branch_id`, `original_id`, `refund_method` (`cash`/`credit`), `lines` with `original_line_id`, `qty_milli` |
| `POST /api/v1/purchases/returns` | `branch_id`, `original_id`, `lines` with `original_line_id`, `qty_milli` |
| `POST /api/v1/customers/receipts` | `branch_id`, `customer_id`, `amount_minor`, `method` |
| `POST /api/v1/suppliers/payments` | `branch_id`, `supplier_id`, `amount_minor`, `method` |
| `POST /api/v1/expenses` | `branch_id`, `category`, `amount_minor`, `method` |
| `POST /api/v1/inventory/adjustments` | `branch_id`, `product_id`, signed `qty_change_milli`, `added_cost_minor` when adding, `reason` |
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
