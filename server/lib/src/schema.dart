/// DDL v1. Currency is stored as integer piasters (EGP / 100).
/// Inventory quantity is stored as integer thousandths of the base unit.
const schemaV1 = <String>[
  '''CREATE TABLE IF NOT EXISTS tenants (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS branches (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    code TEXT NOT NULL, name TEXT NOT NULL, created_at TEXT NOT NULL,
    UNIQUE(tenant_id, code)
  )''',
  '''CREATE TABLE IF NOT EXISTS warehouses (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    name TEXT NOT NULL, is_default INTEGER NOT NULL DEFAULT 0,
    UNIQUE(branch_id, name)
  )''',
  '''CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    branch_id TEXT REFERENCES branches(id), username TEXT NOT NULL,
    password_salt TEXT NOT NULL, password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('owner','manager','cashier','stock','purchasing','viewer')),
    active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL,
    UNIQUE(tenant_id, username)
  )''',
  '''CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
    expires_at TEXT NOT NULL, created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS products (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    sku TEXT NOT NULL, barcode TEXT, name_ar TEXT NOT NULL, name_en TEXT,
    category TEXT NOT NULL DEFAULT 'عام', base_unit TEXT NOT NULL DEFAULT 'قطعة',
    sell_price_minor INTEGER NOT NULL CHECK(sell_price_minor>=0),
    reorder_qty_milli INTEGER NOT NULL DEFAULT 0,
    tax_rate_bp INTEGER NOT NULL DEFAULT 0 CHECK(tax_rate_bp BETWEEN 0 AND 10000),
    track_expiry INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    UNIQUE(tenant_id,sku), UNIQUE(tenant_id,barcode)
  )''',
  '''CREATE TABLE IF NOT EXISTS stock_balances (
    branch_id TEXT NOT NULL REFERENCES branches(id),
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    qty_milli INTEGER NOT NULL DEFAULT 0 CHECK(qty_milli>=0),
    cost_minor INTEGER NOT NULL DEFAULT 0 CHECK(cost_minor>=0),
    PRIMARY KEY (branch_id, warehouse_id, product_id)
  )''',
  '''CREATE TABLE IF NOT EXISTS customers (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL, phone TEXT, credit_limit_minor INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS suppliers (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    name TEXT NOT NULL, phone TEXT, created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL REFERENCES tenants(id),
    branch_id TEXT NOT NULL REFERENCES branches(id),
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    kind TEXT NOT NULL CHECK(kind IN ('sale','purchase','sale_return','purchase_return','preparation')),
    number TEXT NOT NULL, party_id TEXT, original_id TEXT REFERENCES documents(id),
    subtotal_minor INTEGER NOT NULL, discount_minor INTEGER NOT NULL DEFAULT 0,
    tax_minor INTEGER NOT NULL DEFAULT 0, total_minor INTEGER NOT NULL,
    paid_minor INTEGER NOT NULL DEFAULT 0,
    cost_minor INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'posted' CHECK(state IN ('posted','reversed')),
    snapshot_json TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL, UNIQUE(branch_id, number)
  )''',
  '''CREATE TABLE IF NOT EXISTS document_lines (
    id TEXT PRIMARY KEY, document_id TEXT NOT NULL REFERENCES documents(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    qty_milli INTEGER NOT NULL CHECK(qty_milli>0),
    unit_price_minor INTEGER NOT NULL, discount_minor INTEGER NOT NULL DEFAULT 0,
    tax_minor INTEGER NOT NULL DEFAULT 0, cost_minor INTEGER NOT NULL DEFAULT 0,
    original_line_id TEXT REFERENCES document_lines(id)
  )''',
  '''CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY, document_id TEXT REFERENCES documents(id),
    branch_id TEXT NOT NULL REFERENCES branches(id),
    party_id TEXT, method TEXT NOT NULL CHECK(method IN ('cash','card','wallet','bank')),
    direction TEXT NOT NULL CHECK(direction IN ('in','out')),
    amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    reference TEXT, created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS journal_entries (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    reference_type TEXT NOT NULL, reference_id TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id), created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS journal_lines (
    id TEXT PRIMARY KEY, entry_id TEXT NOT NULL REFERENCES journal_entries(id),
    account TEXT NOT NULL, debit_minor INTEGER NOT NULL DEFAULT 0,
    credit_minor INTEGER NOT NULL DEFAULT 0,
    CHECK(debit_minor>=0 AND credit_minor>=0 AND
    ((debit_minor>0 AND credit_minor=0) OR (credit_minor>0 AND debit_minor=0)))
  )''',
  '''CREATE TABLE IF NOT EXISTS inventory_movements (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    qty_change_milli INTEGER NOT NULL, cost_change_minor INTEGER NOT NULL,
    reference_type TEXT NOT NULL, reference_id TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id), created_at TEXT NOT NULL,
    CHECK(qty_change_milli!=0)
  )''',
  '''CREATE TABLE IF NOT EXISTS expenses (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    category TEXT NOT NULL, note TEXT, amount_minor INTEGER NOT NULL CHECK(amount_minor>0),
    method TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS cash_shifts (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    user_id TEXT NOT NULL REFERENCES users(id),
    opening_minor INTEGER NOT NULL, closing_expected_minor INTEGER,
    closing_actual_minor INTEGER, opened_at TEXT NOT NULL, closed_at TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS audit_logs (
    id TEXT PRIMARY KEY, branch_id TEXT, actor_id TEXT,
    action TEXT NOT NULL, entity_id TEXT, details_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS idempotency_keys (
    actor_id TEXT NOT NULL, request_key TEXT NOT NULL, request_hash TEXT NOT NULL, response_json TEXT NOT NULL,
    created_at TEXT NOT NULL, PRIMARY KEY(actor_id,request_key)
  )''',
  '''CREATE TABLE IF NOT EXISTS sync_outbox (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, topic TEXT NOT NULL,
    payload_json TEXT NOT NULL, created_at TEXT NOT NULL,
    synced_at TEXT
  )''',
  '''CREATE TABLE IF NOT EXISTS batches (
    id TEXT PRIMARY KEY, warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    product_id TEXT NOT NULL REFERENCES products(id), lot_no TEXT,
    expires_on TEXT, qty_milli INTEGER NOT NULL DEFAULT 0,
    UNIQUE(warehouse_id,product_id,lot_no,expires_on)
  )''',
  '''CREATE TABLE IF NOT EXISTS preps (
    id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
    source_product_id TEXT NOT NULL REFERENCES products(id),
    output_product_id TEXT NOT NULL REFERENCES products(id),
    input_milli INTEGER NOT NULL, output_milli INTEGER NOT NULL,
    allocated_cost_minor INTEGER NOT NULL, created_at TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS number_sequences (
    branch_id TEXT NOT NULL REFERENCES branches(id),
    document_type TEXT NOT NULL, next_number INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(branch_id,document_type)
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_products_name ON products(tenant_id,name_ar)''',
  '''CREATE INDEX IF NOT EXISTS ix_docs_branch_time ON documents(branch_id,created_at)''',
  '''CREATE INDEX IF NOT EXISTS ix_moves_product_time ON inventory_movements(product_id,created_at)''',
  '''CREATE INDEX IF NOT EXISTS ix_journal_reference ON journal_entries(reference_type,reference_id)''',
  '''CREATE INDEX IF NOT EXISTS ix_outbox_pending ON sync_outbox(synced_at,created_at)''',
];


/// Additive migration: unit prices remain exact on sales and return documents.
/// Backfill of existing unit pricing is intentionally not inferred.
const schemaV2 = <String>[
  '''CREATE TABLE IF NOT EXISTS product_units (
    id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL REFERENCES products(id),
    unit_name TEXT NOT NULL,
    factor_milli INTEGER NOT NULL CHECK(factor_milli>0),
    sell_price_minor INTEGER NOT NULL CHECK(sell_price_minor>=0),
    barcode TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    UNIQUE(product_id,unit_name)
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_product_units_product ON product_units(product_id,active)''',
  '''CREATE INDEX IF NOT EXISTS ix_product_units_barcode ON product_units(barcode)''',
  '''ALTER TABLE document_lines ADD COLUMN gross_minor INTEGER''',
  '''ALTER TABLE document_lines ADD COLUMN unit_id TEXT''',
  '''ALTER TABLE document_lines ADD COLUMN unit_count INTEGER''',
];
