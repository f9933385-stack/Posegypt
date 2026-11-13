"""Backups must be authenticated, restorable, consistent and safe to rotate."""
import os
import re
import sqlite3
import tempfile
import unittest
from pathlib import Path
from sys import path as pythonpath
from unittest import mock

pythonpath.insert(0, str(Path(__file__).resolve().parents[1]))
from scheduled_backup import run_once, NAME, LOCK
from backup_database import restore

ROOT = Path(__file__).resolve().parents[2]

class ScheduledBackupTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.database = self.root / "branch.sqlite3"
        self.backups = self.root / "secure-backups"
        self.backups.mkdir(mode=0o700)
        self.passphrase = "test-only-strong-passphrase-for-Kasher!"
        schema = (ROOT / "server/lib/src/schema.dart").read_text(encoding="utf-8")
        statements = re.findall(r"'''(.*?)'''", schema, re.S)
        with sqlite3.connect(self.database) as db:
            db.execute("PRAGMA foreign_keys=ON")
            for sql in statements:
                db.execute(sql)
            db.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Store','now')")
            db.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR','Branch','now')")
            db.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)")
            db.commit()

    def test_verified_snapshot_roundtrip_and_rotation(self):
        from datetime import datetime, timedelta, timezone
        start = datetime(2026, 11, 13, 5, 0, tzinfo=timezone.utc)
        for n in range(4):
            with sqlite3.connect(self.database) as db:
                db.execute("INSERT INTO customers(id,tenant_id,name,created_at) VALUES(?,?,?,?)",
                           (str(n), "T", "customer" + str(n), "now"))
                db.commit()
            status = run_once(self.database, self.backups, self.passphrase,
                              keep=2, timestamp=start + timedelta(minutes=n))
            self.assertEqual(status["status"], "verified")
            self.assertTrue(NAME.fullmatch(status["backup"]))
            self.assertFalse((self.backups / LOCK).exists())
        files = list(self.backups.glob("*.kasherbak"))
        self.assertEqual(len(files), 2)
        restored = self.root / "restored.sqlite3"
        restore(sorted(files)[-1], restored, self.passphrase)
        with sqlite3.connect(restored) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM customers").fetchone()[0], 4)

    def test_failed_restore_never_prunes_prior_good_backup(self):
        good = run_once(self.database, self.backups, self.passphrase)
        path = self.backups / good["backup"]
        with mock.patch("scheduled_backup.restore", side_effect=ValueError("corrupt test")):
            with self.assertRaisesRegex(ValueError, "corrupt"):
                run_once(self.database, self.backups, self.passphrase)
        self.assertTrue(path.exists())
        self.assertEqual(list(self.backups.glob("*.kasherbak")), [path])
        self.assertFalse((self.backups / LOCK).exists())

    def test_competing_backups_fail_safely(self):
        (self.backups / LOCK).write_text("other process running", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Backup already running"):
            run_once(self.database, self.backups, self.passphrase)
        self.assertTrue((self.backups / LOCK).exists())

    def test_wrong_database_and_retention_are_rejected(self):
        with self.assertRaises(ValueError):
            run_once(self.database, self.backups, self.passphrase, keep=1)
        other = self.root / "not-kasher.sqlite3"
        with sqlite3.connect(other) as db:
            db.execute("CREATE TABLE unrelated(id INTEGER)")
        with self.assertRaisesRegex(ValueError, "Not a Kasher"):
            run_once(other, self.backups, self.passphrase)
        self.assertEqual(list(self.backups.glob("*.kasherbak")), [])

    def test_tampered_stock_prevents_new_backup(self):
        with sqlite3.connect(self.database) as db:
            db.execute("INSERT INTO products(id,tenant_id,sku,name_ar,sell_price_minor,created_at,updated_at) VALUES('P','T','P','Product',1,'now','now')")
            db.execute("INSERT INTO stock_balances(branch_id,warehouse_id,product_id,qty_milli,cost_minor) VALUES('B','W','P',500,100)")
            db.commit()
        with self.assertRaisesRegex(ValueError, "audit failed"):
            run_once(self.database, self.backups, self.passphrase)
        self.assertEqual(list(self.backups.glob("*.kasherbak")), [])

    @unittest.skipIf(os.name == "nt", "POSIX permission check")
    def test_world_readable_output_directory_rejected(self):
        self.backups.chmod(0o755)
        with self.assertRaises(PermissionError):
            run_once(self.database, self.backups, self.passphrase)
