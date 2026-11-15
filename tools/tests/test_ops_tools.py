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

    def test_tracked_product_without_lots_is_rejected(self):
        con=sqlite3.connect(self.db)
        con.execute("UPDATE products SET track_expiry=1 WHERE id='P'")
        con.commit()
        con.close()
        output=audit(str(self.db))
        self.assertEqual(output['status'], 'fail')
        self.assertIn('tracked_product_lot_quantity', output['errors'])

    def test_tampered_lot_balance_is_reported(self):
        con=sqlite3.connect(self.db)
        con.execute("UPDATE products SET track_expiry=1 WHERE id='P'")
        con.execute("""
          INSERT INTO batches(id,warehouse_id,product_id,lot_no,expires_on,qty_milli)
          VALUES('LOT','W','P','L-1','2031-01-01',1000)
        """)
        con.execute("""
          INSERT INTO batch_movements(id,batch_id,qty_change_milli,reference_type,reference_id,created_at)
          VALUES('LM','LOT',1000,'purchase','test','now')
        """)
        con.commit()
        self.assertEqual(audit(str(self.db))['status'],'pass')
        con.execute("UPDATE batches SET qty_milli=999 WHERE id='LOT'")
        con.commit()
        con.close()
        output=audit(str(self.db))
        self.assertIn('tracked_lot_movement_balance', output['errors'])
        self.assertIn('tracked_product_lot_quantity', output['errors'])

    def test_stock_count_requires_independent_approval(self):
        con=sqlite3.connect(self.db)
        con.execute("""
          INSERT INTO stock_counts(id,branch_id,warehouse_id,status,
            reason,created_by,approved_by,created_at,approved_at)
          VALUES('COUNT','B','W','posted','count','U','U','now','now')
        """)
        con.execute("""
          INSERT INTO stock_count_lines(id,count_id,product_id,expected_qty_milli,
            expected_cost_minor,counted_qty_milli)
          VALUES('LINE','COUNT','P',1000,100,1000)
        """)
        con.commit()
        con.close()
        result=audit(str(self.db))
        self.assertIn('posted_stock_count_approval',result['errors'])

    def test_stock_count_posted_variance_must_equal_movement(self):
        con=sqlite3.connect(self.db)
        con.execute("""
          INSERT INTO users(id,tenant_id,branch_id,username,password_salt,password_hash,
            role,created_at)
          VALUES('MGR','T','B','manager','s','h','manager','now')
        """)
        con.execute("""
          INSERT INTO stock_counts(id,branch_id,warehouse_id,status,reason,
            created_by,approved_by,created_at,approved_at)
          VALUES('COUNT','B','W','posted','count','U','MGR','now','now')
        """)
        con.execute("""
          INSERT INTO stock_count_lines(id,count_id,product_id,expected_qty_milli,
            expected_cost_minor,counted_qty_milli)
          VALUES('LINE','COUNT','P',1000,100,1500)
        """)
        con.commit()
        con.close()
        result=audit(str(self.db))
        self.assertIn('stock_count_variance_movement',result['errors'])

    def test_in_transit_shipment_without_source_movement_is_detected(self):
        con=sqlite3.connect(self.db)
        con.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B2','T','BR2','Branch2','now')")
        con.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W2','B2','Destination',1)")
        con.execute("""
          INSERT INTO branch_shipments(
            id,tenant_id,source_branch_id,destination_branch_id,
            source_warehouse_id,destination_warehouse_id,product_id,
            qty_milli,cost_minor,status,dispatched_by,dispatched_at
          ) VALUES('SHIP','T','B','B2','W','W2','P',1000,100,'in_transit','U','now')
        """)
        con.commit()
        con.close()
        result=audit(str(self.db))
        self.assertIn('branch_shipment_movement',result['errors'])
        self.assertIn('branch_shipment_transit_value',result['errors'])

    def test_invoice_allocation_must_match_its_payment_and_invoice(self):
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO suppliers(id,tenant_id,name,created_at) VALUES('S','T','Supplier','now')")
        con.execute("""
          INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,
            party_id,subtotal_minor,discount_minor,tax_minor,total_minor,
            paid_minor,cost_minor,snapshot_json,created_by,created_at)
          VALUES('D','T','B','W','purchase','P-01','S',100,0,0,100,0,100,'{}','U','now')
        """)
        con.execute("""
          INSERT INTO payments(id,branch_id,party_id,method,direction,amount_minor,created_at)
          VALUES('PAY','B','S','cash','out',100,'now')
        """)
        con.execute("""
          INSERT INTO debt_allocations(id,payment_id,document_id,branch_id,
            party_id,party_type,amount_minor,created_at)
          VALUES('ALLOC','PAY','D','B','S','supplier',90,'now')
        """)
        con.commit()
        con.close()
        result=audit(str(self.db))
        self.assertIn('invoice_allocation_consistency', result['errors'])
        con=sqlite3.connect(self.db)
        con.execute("UPDATE debt_allocations SET amount_minor=100 WHERE id='ALLOC'")
        con.commit()
        con.close()
        result=audit(str(self.db))
        self.assertNotIn('invoice_allocation_consistency',result['errors'])

    def test_split_payment_total_and_scope_tampering_is_detected(self):
        con = sqlite3.connect(self.db)
        con.execute("INSERT INTO suppliers(id,tenant_id,name,created_at) VALUES('SUP','T','Supplier','now')")
        for invoice in ('INV1', 'INV2'):
            con.execute("""
              INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,
                party_id,subtotal_minor,discount_minor,tax_minor,total_minor,
                paid_minor,cost_minor,snapshot_json,created_by,created_at)
              VALUES(?, 'T','B','W','purchase',?,'SUP',100,0,0,100,0,100,'{}','U','now')
            """,(invoice, invoice))
        con.execute("""
          INSERT INTO payments(id,branch_id,party_id,method,direction,amount_minor,created_at)
          VALUES('SPLITPAY','B','SUP','cash','out',100,'now')
        """)
        for a, invoice in (('A1','INV1'),('A2','INV2')):
            con.execute("""
              INSERT INTO debt_allocation_lines(id,payment_id,document_id,
                branch_id,party_id,party_type,amount_minor,created_at)
              VALUES(?, 'SPLITPAY', ?, 'B','SUP','supplier',50,'now')
            """, (a, invoice))
        con.commit()
        con.close()
        self.assertEqual(audit(str(self.db))['status'],'pass')
        con = sqlite3.connect(self.db)
        con.execute("UPDATE debt_allocation_lines SET amount_minor=30 WHERE id='A2'")
        con.commit()
        con.close()
        self.assertIn('split_payment_amounts',audit(str(self.db))['errors'])
        con = sqlite3.connect(self.db)
        con.execute("UPDATE debt_allocation_lines SET amount_minor=50 WHERE id='A2'")
        con.execute("UPDATE debt_allocation_lines SET party_id='MISMATCH' WHERE id='A1'")
        con.commit()
        con.close()
        self.assertIn('split_allocation_consistency',audit(str(self.db))['errors'])

    def test_independent_drawer_cash_links_and_operator_scope_are_audited(self):
        con=sqlite3.connect(self.db)
        con.execute("""
          INSERT INTO cash_drawers(id,branch_id,name,created_by,created_at)
          VALUES('DRAWER','B','Till One','U','zzzz')
        """)
        con.execute("""
          INSERT INTO cash_shifts(id,branch_id,user_id,drawer_id,
            opening_minor,opened_at)
          VALUES('SHIFT','B','U','DRAWER',1000,'zzzz')
        """)
        con.execute("""
          INSERT INTO journal_entries(id,branch_id,reference_type,reference_id,
            created_by,created_at)
          VALUES('CASHJ','B','sale','CASHSALE','U','zzzz')
        """)
        con.execute("""
          INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor)
          VALUES('CASH1','CASHJ','CASH',200,0)
        """)
        con.execute("""
          INSERT INTO journal_lines(id,entry_id,account,debit_minor,credit_minor)
          VALUES('CASH2','CASHJ','SALES_REVENUE',0,200)
        """)
        con.commit()
        con.close()
        self.assertIn('cash_shift_unattributed_cash',audit(str(self.db))['errors'])

        con=sqlite3.connect(self.db)
        con.execute("""
          INSERT INTO cash_shift_journal_links(
            journal_entry_id,shift_id,cash_delta_minor,created_at)
          VALUES('CASHJ','SHIFT',200,'zzzz')
        """)
        con.commit()
        con.close()
        self.assertEqual(audit(str(self.db))['status'],'pass')

        con=sqlite3.connect(self.db)
        con.execute("""
          UPDATE cash_shift_journal_links SET cash_delta_minor=199
          WHERE journal_entry_id='CASHJ'
        """)
        con.commit()
        con.close()
        self.assertIn('cash_shift_posting_integrity',audit(str(self.db))['errors'])

        con=sqlite3.connect(self.db)
        con.execute("""
          UPDATE cash_shift_journal_links SET cash_delta_minor=200
          WHERE journal_entry_id='CASHJ'
        """)
        con.execute("UPDATE journal_entries SET created_by='ANOTHER' WHERE id='CASHJ'")
        con.commit()
        con.close()
        self.assertIn('cash_shift_posting_integrity',audit(str(self.db))['errors'])

    def test_return_credit_application_scope_and_totals_are_audited(self):
        con=sqlite3.connect(self.db)
        con.execute("INSERT INTO suppliers(id,tenant_id,name,created_at) VALUES('CRED_SUP','T','Supplier','now')")
        con.execute("""
          INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,
            party_id,subtotal_minor,discount_minor,tax_minor,total_minor,
            paid_minor,cost_minor,snapshot_json,created_by,created_at)
          VALUES('CRED_ORIG','T','B','W','purchase','CRED-ORIG',
            'CRED_SUP',100,0,0,100,100,100,'{}','U','now')
        """)
        con.execute("""
          INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,
            party_id,original_id,subtotal_minor,discount_minor,tax_minor,total_minor,
            paid_minor,cost_minor,snapshot_json,created_by,created_at)
          VALUES('CRED_RETURN','T','B','W','purchase_return','CRED-RET',
            'CRED_SUP','CRED_ORIG',50,0,0,50,0,50,
            '{"refund_method":"credit"}','U','now')
        """)
        con.execute("""
          INSERT INTO documents(id,tenant_id,branch_id,warehouse_id,kind,number,
            party_id,subtotal_minor,discount_minor,tax_minor,total_minor,
            paid_minor,cost_minor,snapshot_json,created_by,created_at)
          VALUES('CRED_TARGET','T','B','W','purchase','CRED-TARGET',
            'CRED_SUP',100,0,0,100,0,100,'{}','U','now')
        """)
        con.execute("""
          INSERT INTO debt_credit_allocations(id,credit_document_id,document_id,
            branch_id,party_id,party_type,amount_minor,reason,created_by,created_at)
          VALUES('CRED_ALLOC','CRED_RETURN','CRED_TARGET','B','CRED_SUP',
            'supplier',50,'approved supplier credit allocation','U','now')
        """)
        con.commit()
        con.close()
        self.assertEqual(audit(str(self.db))['status'],'pass')
        con=sqlite3.connect(self.db)
        con.execute("UPDATE debt_credit_allocations SET amount_minor=51 WHERE id='CRED_ALLOC'")
        con.commit()
        con.close()
        self.assertIn('debt_credit_source_overallocated',audit(str(self.db))['errors'])
        con=sqlite3.connect(self.db)
        con.execute("UPDATE debt_credit_allocations SET amount_minor=50,party_id='WRONG' WHERE id='CRED_ALLOC'")
        con.commit()
        con.close()
        self.assertIn('debt_credit_allocation_scope',audit(str(self.db))['errors'])

    def test_reconciliation_review_and_approved_links_are_audited(self):
        con = sqlite3.connect(self.db)
        con.execute("""
          INSERT INTO users(id,tenant_id,branch_id,username,password_salt,
            password_hash,role,created_at)
          VALUES('REVIEWER','T','B','reviewer','s','h','manager','now')
        """)
        con.execute("""
          INSERT INTO suppliers(id,tenant_id,name,created_at)
          VALUES('RECON_SUP','T','Historical vendor','now')
        """)
        con.execute("""
          INSERT INTO documents(
            id,tenant_id,branch_id,warehouse_id,kind,number,party_id,
            subtotal_minor,discount_minor,tax_minor,total_minor,
            paid_minor,cost_minor,snapshot_json,created_by,created_at)
          VALUES('RECON_DOC','T','B','W','purchase','RECON-01','RECON_SUP',
            100,0,0,100,0,100,'{}','U','now')
        """)
        con.execute("""
          INSERT INTO payments(
            id,branch_id,party_id,method,direction,amount_minor,created_at)
          VALUES('RECON_PAY','B','RECON_SUP','cash','out',100,'now')
        """)
        con.execute("""
          INSERT INTO debt_reconciliations(
            id,payment_id,branch_id,party_id,party_type,status,
            reason,requested_by,reviewed_by,requested_at,reviewed_at,review_reason)
          VALUES('RECON','RECON_PAY','B','RECON_SUP','supplier',
            'approved','verified old transfer','U','REVIEWER','old','now',
            'independent paper audit')
        """)
        con.execute("""
          INSERT INTO debt_reconciliation_lines(
            id,reconciliation_id,document_id,amount_minor)
          VALUES('REQUEST_LINE','RECON','RECON_DOC',100)
        """)
        con.execute("""
          INSERT INTO debt_allocation_lines(
            id,payment_id,document_id,branch_id,party_id,
            party_type,amount_minor,created_at)
          VALUES('MATCHED_LINE','RECON_PAY','RECON_DOC','B','RECON_SUP',
            'supplier',100,'now')
        """)
        con.commit()
        con.close()
        self.assertEqual(audit(str(self.db))['status'],'pass')
        con = sqlite3.connect(self.db)
        con.execute("UPDATE debt_reconciliations SET reviewed_by='U' WHERE id='RECON'")
        con.commit()
        con.close()
        self.assertIn('debt_reconciliation_review_controls',
                      audit(str(self.db))['errors'])
        con = sqlite3.connect(self.db)
        con.execute("UPDATE debt_reconciliations SET reviewed_by='REVIEWER' WHERE id='RECON'")
        con.execute("UPDATE debt_reconciliation_lines SET amount_minor=90 WHERE id='REQUEST_LINE'")
        con.commit()
        con.close()
        self.assertIn('approved_debt_reconciliation_matches_allocations',
                      audit(str(self.db))['errors'])

    def test_unbalanced_entry_is_detected(self):
        con=sqlite3.connect(self.db)
        con.execute("UPDATE journal_lines SET credit_minor=90 WHERE id='L2'")
        con.commit()
        con.close()
        output=audit(str(self.db))
        self.assertEqual(output['status'], 'fail')
        self.assertIn('double_entry_balance', output['errors'])
