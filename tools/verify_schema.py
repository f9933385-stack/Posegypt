"""Independent SQL DDL syntax/integrity checks using Python stdlib sqlite3.

Does not replace Dart/Flutter unit and integration tests.
"""
import re
import sqlite3
from pathlib import Path

source = Path(__file__).resolve().parents[1] / 'server/lib/src/schema.dart'
statements = re.findall(r"'''(.*?)'''", source.read_text(encoding='utf8'), re.S)
assert len(statements) >= 20, 'Schema appears truncated'
conn = sqlite3.connect(':memory:')
conn.execute('PRAGMA foreign_keys=ON')
for sql in statements:
    conn.execute(sql)
tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
for t in ('tenants','branches','users','products','stock_balances','documents',
          'journal_entries','journal_lines','audit_logs','sync_outbox'):
    assert t in tables, f'Missing table {t}'
conn.execute("INSERT INTO tenants VALUES('tenant-1','اختبار','2026-01-01')")
conn.execute("INSERT INTO branches VALUES('branch-1','tenant-1','BR01','الفرع','2026-01-01')")
conn.execute("INSERT INTO warehouses VALUES('wh-1','branch-1','صالة العرض',1)")
conn.execute("""INSERT INTO products(id,tenant_id,sku,barcode,name_ar,sell_price_minor,created_at,updated_at)
VALUES('prod-1','tenant-1','P01','1234567890123','أرز',100,'2026-01-01','2026-01-01')""")
conn.execute("INSERT INTO stock_balances VALUES('branch-1','wh-1','prod-1',1000,100)")
try:
    conn.execute("UPDATE stock_balances SET qty_milli=-1 WHERE product_id='prod-1'")
    raise AssertionError('Negative inventory was accepted')
except sqlite3.IntegrityError:
    pass
try:
    conn.execute("INSERT INTO warehouses VALUES('wh-other','unknown-branch','مخزن وهمي',0)")
    raise AssertionError('Foreign keys not applied')
except sqlite3.IntegrityError:
    pass
try:
    conn.execute("""INSERT INTO products(id,tenant_id,sku,barcode,name_ar,sell_price_minor,created_at,updated_at)
VALUES('prod-2','tenant-1','P02','1234567890123','سكر',100,'2026-01-01','2026-01-01')""")
    raise AssertionError('Duplicate barcode was accepted')
except sqlite3.IntegrityError:
    pass
print(f'PASS: {len(statements)} statements, {len(tables)} tables, FK, inventory and barcode constraints')
