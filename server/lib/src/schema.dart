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

///// V3: immutable stock-lot movement trail (full lot identifiers are never guessed).
const schemaV3 = <String>[
  '''CREATE TABLE IF NOT EXISTS batch_movements (
    id TEXT PRIMARY KEY,
    batch_id TEXT NOT NULL REFERENCES batches(id),
    qty_change_milli INTEGER NOT NULL CHECK(qty_change_milli != 0),
    reference_type TEXT NOT NULL,
    reference_id TEXT NOT NULL,
    document_line_id TEXT REFERENCES document_lines(id),
    origin_line_id TEXT REFERENCES document_lines(id),
    created_at TEXT NOT NULL
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_batch_moves_line
     ON batch_movements(document_line_id,reference_type)''',
  '''CREATE INDEX IF NOT EXISTS ix_batch_moves_origin
     ON batch_movements(origin_line_id,reference_type)''',
  '''CREATE INDEX IF NOT EXISTS ix_batches_fefo
     ON batches(warehouse_id,product_id,expires_on,qty_milli)''',
  '''CREATE TRIGGER IF NOT EXISTS tr_batches_no_negative_insert
    BEFORE INSERT ON batches WHEN NEW.qty_milli < 0
    BEGIN SELECT RAISE(ABORT,'Batch quantity must not be negative'); END''',
  '''CREATE TRIGGER IF NOT EXISTS tr_batches_no_negative_update
    BEFORE UPDATE OF qty_milli ON batches WHEN NEW.qty_milli < 0
    BEGIN SELECT RAISE(ABORT,'Batch quantity must not be negative'); END''',
];

///// V4: reversible lot quarantine (never changes stock quantities).
const schemaV4 = <String>[
  '''ALTER TABLE batches ADD COLUMN quarantined INTEGER NOT NULL DEFAULT 0
     CHECK(quarantined IN (0,1))''',
  '''ALTER TABLE batches ADD COLUMN quarantine_reason TEXT''',
  '''ALTER TABLE batches ADD COLUMN quarantine_updated_at TEXT''',
];


/// V5: independently counted warehouse snapshots, submitted for four-eye approval.
/// No financial or physical stock effects before an authorized manager approves.
const schemaV5 = <String>[
  '''CREATE TABLE IF NOT EXISTS stock_counts (
    id TEXT PRIMARY KEY,
    branch_id TEXT NOT NULL REFERENCES branches(id),
    warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    status TEXT NOT NULL CHECK(status IN ('draft','submitted','posted','cancelled')),
    reason TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(id),
    approved_by TEXT REFERENCES users(id),
    movement_watermark INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    submitted_at TEXT,
    approved_at TEXT
  )''',
  '''CREATE UNIQUE INDEX IF NOT EXISTS ux_open_count_warehouse
    ON stock_counts(warehouse_id) WHERE status IN ('draft','submitted')''',
  '''CREATE INDEX IF NOT EXISTS ix_stock_counts_branch
    ON stock_counts(branch_id,created_at)''',
  '''CREATE TABLE IF NOT EXISTS stock_count_lines (
    id TEXT PRIMARY KEY,
    count_id TEXT NOT NULL REFERENCES stock_counts(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    batch_id TEXT REFERENCES batches(id),
    expected_qty_milli INTEGER NOT NULL CHECK(expected_qty_milli>=0),
    expected_cost_minor INTEGER NOT NULL CHECK(expected_cost_minor>=0),
    counted_qty_milli INTEGER CHECK(counted_qty_milli>=0),
    added_cost_minor INTEGER CHECK(added_cost_minor>=0),
    counted_by TEXT REFERENCES users(id),
    counted_at TEXT
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_count_lines_parent
    ON stock_count_lines(count_id,product_id)'''
];


/// V6: per-device enrollment credentials and revocable bearer-session binding.
/// Pairing tickets are one-time, short-lived and only ever stored as SHA-256.
const schemaV6 = <String>[
  '''CREATE TABLE IF NOT EXISTS registered_devices (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    branch_id TEXT NOT NULL REFERENCES branches(id),
    name TEXT NOT NULL,
    secret_hash TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_by TEXT REFERENCES users(id),
    revoked_at TEXT
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_registered_devices_branch
    ON registered_devices(tenant_id,branch_id,active)''',
  '''CREATE TABLE IF NOT EXISTS device_pairing_tickets (
    token_hash TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    branch_id TEXT NOT NULL REFERENCES branches(id),
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    claimed_at TEXT
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_device_tickets_tenant_expiry
    ON device_pairing_tickets(tenant_id,expires_at)''',
  '''ALTER TABLE sessions ADD COLUMN device_id TEXT REFERENCES registered_devices(id)'''
];


/// V7: individually approved promotional price windows. Base and unit prices
/// have independent scopes; the cashier never creates or overrides them.
const schemaV7 = <String>[
  '''CREATE TABLE IF NOT EXISTS price_promotions (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    unit_id TEXT REFERENCES product_units(id),
    title TEXT NOT NULL,
    promo_price_minor INTEGER NOT NULL CHECK(promo_price_minor>0),
    starts_at TEXT NOT NULL,
    ends_at TEXT NOT NULL,
    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    stopped_by TEXT REFERENCES users(id),
    stopped_at TEXT,
    CHECK(starts_at<ends_at)
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_promotions_lookup
    ON price_promotions(tenant_id,product_id,unit_id,active,starts_at,ends_at)'''
];


/// V8: local single-database, two-phase inter-branch stock dispatch and receipt.
/// Transit is a separate financial asset; destination stock changes on receipt.
const schemaV8 = <String>[
  '''CREATE TABLE IF NOT EXISTS branch_shipments (
    id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    source_branch_id TEXT NOT NULL REFERENCES branches(id),
    destination_branch_id TEXT NOT NULL REFERENCES branches(id),
    source_warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    destination_warehouse_id TEXT NOT NULL REFERENCES warehouses(id),
    product_id TEXT NOT NULL REFERENCES products(id),
    qty_milli INTEGER NOT NULL CHECK(qty_milli>0),
    cost_minor INTEGER NOT NULL CHECK(cost_minor>=0),
    status TEXT NOT NULL CHECK(status IN ('in_transit','received','cancelled')),
    dispatched_by TEXT NOT NULL REFERENCES users(id),
    dispatched_at TEXT NOT NULL,
    received_by TEXT REFERENCES users(id),
    received_at TEXT,
    cancelled_by TEXT REFERENCES users(id),
    cancelled_at TEXT,
    cancellation_reason TEXT,
    CHECK(source_branch_id<>destination_branch_id)
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_branch_shipments_source
     ON branch_shipments(tenant_id,source_branch_id,status,dispatched_at)''',
  '''CREATE INDEX IF NOT EXISTS ix_branch_shipments_destination
     ON branch_shipments(tenant_id,destination_branch_id,status,dispatched_at)''',
  '''CREATE TABLE IF NOT EXISTS branch_shipment_lots (
    id TEXT PRIMARY KEY,
    shipment_id TEXT NOT NULL REFERENCES branch_shipments(id),
    lot_no TEXT NOT NULL,
    expires_on TEXT NOT NULL,
    qty_milli INTEGER NOT NULL CHECK(qty_milli>0)
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_branch_shipment_lots_shipment
     ON branch_shipment_lots(shipment_id)'''
];


/// V9: signed annual license for every enrolled POS device. Only the vendor
/// holds private signing keys; branch databases contain signed grants.
const schemaV9 = <String>[
  '''CREATE TABLE IF NOT EXISTS device_licenses (
    device_id TEXT PRIMARY KEY REFERENCES registered_devices(id),
    tenant_id TEXT NOT NULL REFERENCES tenants(id),
    serial TEXT NOT NULL UNIQUE,
    key_id TEXT NOT NULL,
    token TEXT NOT NULL,
    issued_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    activated_by TEXT NOT NULL REFERENCES users(id),
    activated_at TEXT NOT NULL
  )''',
  '''CREATE INDEX IF NOT EXISTS ix_device_licenses_tenant_expiry
    ON device_licenses(tenant_id,expires_at)''',
  '''CREATE TABLE IF NOT EXISTS license_clock_guards (
    device_id TEXT PRIMARY KEY REFERENCES registered_devices(id),
    max_seen_at TEXT NOT NULL
  )'''
];
