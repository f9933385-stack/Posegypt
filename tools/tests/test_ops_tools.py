"""Can be run without Dart SDK: python -m unittest discover -s tools/tests -v"""
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from sys import path as pythonpath

pythonpath.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_database import audit
from backup_database import backup, restore


class OperatorToolsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / "test.sqlite3"
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT)")
        con.execute("INSERT INTO records(value) VALUES ('اختبار')")
        con.commit()
        con.close()

    def test_encrypted_backup_roundtrip(self):
        try:
            import cryptography  # noqa F401
        except ImportError:
            self.skipTest("cryptography is not installed")
        back = self.root / "test.kasherbak"
        rec = self.root / "restored.sqlite3"
        backup(self.db, back, "long-random-backup-password-for-testing")
        self.assertNotIn("اختبار".encode(), back.read_bytes())
        self.assertFalse(back.read_bytes().startswith(b"SQLite format 3"))
        restore(back, rec, "long-random-backup-password-for-testing")
        con = sqlite3.connect(rec)
        try:
            self.assertEqual(con.execute("SELECT value FROM records").fetchone()[0], "اختبار")
        finally:
            con.close()
        with self.assertRaises(FileExistsError):
            restore(back, rec, "long-random-backup-password-for-testing")

    def test_wrong_password_rejected(self):
        try:
            import cryptography  # noqa F401
        except ImportError:
            self.skipTest("cryptography is not installed")
        back = self.root / "test.kasherbak"
        backup(self.db, back, "long-random-backup-password-for-testing")
        with self.assertRaises(Exception):
            restore(back, self.root / "bad.sqlite3", "some-other-long-password-for-testing")
        self.assertFalse((self.root / "bad.sqlite3").exists())

    def test_schema_mismatch_reported(self):
        result = audit(str(self.db))
        self.assertEqual(result["status"], "fail")
        self.assertTrue(any("Database error:" in err for err in result["errors"]))


if __name__ == "__main__":
    unittest.main()

class AuditWithRealSchemaTest(unittest.TestCase):
    def setUp(self):
        import re
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'branch.sqlite3'
        content = (Path(__file__).resolve().parents[2] / 'server/lib/src/schema.dart').read_text(encoding='utf-8')
        statements = re.findall(r"'''(.*?)'''", content, re.S)
        con = sqlite3.connect(self.db)
        con.execute('PRAGMA foreign_keys=ON')
        for statement in statements:
            con.execute(statement)
        con.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Store','now')")
        con.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR','Branch','now')")
        con.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)")
        con.execute("INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,role,created_at) VALUES('U','T','B','x','s','h','owner','now')")
        con.execute("INSERT INTO products(id,tenant_id,sku,name_ar,sell_price_minor,created_at,updated_at) VALUES('P','T','SKU','Product',200,'now','now')")
        con.execute("INSERT INTO stock_balances(branch_id,warehouse_id,product_id,qty_milli,cost_minor) VALUES('B','W','P',1000,100)")
        con.execute("INSERT INTO inventory_movements(id,branch_id,warehouse_id,product_id,qty_change_milli,cost_change_minor,reference_type,reference_id,created_by,created_at) VALUES('M','B','W','P',1000,100,'purchase','D','U','now')")
        con.execute("INSERT INTO journal_entries(id,branch_id,reference_type,reference_id,created_by,created_at) VALUES('J','B','purchase','D','U','now')")
        con.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L1','J','INVENTORY',100,0)")
        con.execute("INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor) VALUES('L2','J','AP:S',0,100)")
        con.commit()
        con.close()

    def test_clean_database_passes(self):
        self.assertEqual(audit(str(self.db))['status'], 'pass')

    def test_tampered_stock_is_detected(self):
        con=sqlite3.connect(self.db)
        con.execute('UPDATE stock_balances SET qty_milli=999 WHERE product_id=?', ('P',))
        con.commit()
        con.close()
        output=audit(str(self.db))
        self.assertEqual(output['status'], 'fail')
        self.assertIn('stock_qty_reconciliation', output['errors'])

    def test_unbalanced_entry_is_detected(self):
        con=sqlite3.connect(self.db)
        con.execute("UPDATE journal_lines SET credit_minor=90 WHERE id='L2'")
        con.commit()
        con.close()
        output=audit(str(self.db))
        self.assertEqual(output['status'], 'fail')
        self.assertIn('double_entry_balance', output['errors'])
