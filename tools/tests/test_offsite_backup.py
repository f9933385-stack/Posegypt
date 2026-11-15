"""Offsite copies must be independently decrypted and audited before publish."""
import hashlib
import os
import re
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from sys import path as pythonpath
from unittest import mock

pythonpath.insert(0, str(Path(__file__).resolve().parents[1]))
from scheduled_backup import run_once
from offsite_backup import mirror_verified_backup, LOCK
from backup_database import restore

ROOT = Path(__file__).resolve().parents[2]


class OffsiteBackupTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.database = self.root / "branch.sqlite3"
        self.local = self.root / "local"
        self.remote = self.root / "remote"
        self.scratch = self.root / "scratch"
        for folder in (self.local, self.remote, self.scratch):
            folder.mkdir(mode=0o700)
        self.passphrase = "test-strong-backup-password-DO-NOT-USE-IN-PRODUCTION"
        schema = (ROOT / "server/lib/src/schema.dart").read_text(encoding="utf-8")
        statements = re.findall(r"'''(.*?)'''", schema, re.S)
        with sqlite3.connect(self.database) as db:
            db.execute("PRAGMA foreign_keys=ON")
            for statement in statements:
                db.execute(statement)
            db.execute("INSERT INTO tenants(id,name,created_at) VALUES('T','Store','now')")
            db.execute("INSERT INTO branches(id,tenant_id,code,name,created_at) VALUES('B','T','BR','Branch','now')")
            db.execute("INSERT INTO warehouses(id,branch_id,name,is_default) VALUES('W','B','Main',1)")
            db.commit()

    def _local_backup(self, index=0):
        when = datetime(2026,11,14,0,0,tzinfo=timezone.utc) + timedelta(minutes=index)
        result = run_once(self.database, self.local, self.passphrase,
                          keep=15, timestamp=when)
        return self.local / result["backup"]

    def _mirror(self, local, **options):
        return mirror_verified_backup(local, self.remote, self.passphrase,
                                     scratch=self.scratch, **options)

    def test_copied_snapshot_is_encrypted_restorable_and_audited(self):
        local = self._local_backup()
        result = self._mirror(local, keep=4)
        self.assertEqual(result["status"], "verified-offsite-copy")
        remote = self.remote / result["backup"]
        self.assertEqual(remote.read_bytes(), local.read_bytes())
        self.assertEqual(hashlib.sha256(remote.read_bytes()).hexdigest(), result["sha256"])
        self.assertNotIn(b"SQLite format 3", remote.read_bytes())
        self.assertFalse((self.remote / LOCK).exists())
        self.assertFalse(list(self.remote.glob("*.partial")))
        self.assertFalse(list(self.scratch.iterdir()))
        restored = self.root / "independent-recovery.sqlite3"
        restore(remote, restored, self.passphrase)
        with sqlite3.connect(restored) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM branches").fetchone()[0],1)

    def test_corrupted_copy_is_not_published_and_old_mirror_is_preserved(self):
        first=self._local_backup(0)
        self._mirror(first)
        second=self._local_backup(1)
        preserved=(self.remote / first.name).read_bytes()
        with mock.patch("offsite_backup.restore", side_effect=ValueError("simulated tag failure")):
            with self.assertRaisesRegex(ValueError, "simulated"):
                self._mirror(second, keep=2)
        self.assertEqual((self.remote / first.name).read_bytes(),preserved)
        self.assertFalse((self.remote / second.name).exists())
        self.assertFalse((self.remote / LOCK).exists())
        self.assertFalse(list(self.remote.glob("*.partial")))

    def test_existing_lock_is_not_deleted_by_competing_copy(self):
        backup=self._local_backup()
        lock=self.remote / LOCK
        lock.write_text("first trusted worker is still active",encoding="utf-8")
        with self.assertRaises(FileExistsError):
            self._mirror(backup)
        self.assertEqual(lock.read_text(encoding="utf-8"),
                         "first trusted worker is still active")
        self.assertFalse((self.remote / backup.name).exists())

    def test_wrong_password_never_publishes_unverified_backup(self):
        backup=self._local_backup()
        with self.assertRaises(Exception):
            mirror_verified_backup(backup,self.remote,"wrong-password-that-is-long",
                                   scratch=self.scratch)
        self.assertFalse((self.remote / backup.name).exists())
        self.assertFalse((self.remote / LOCK).exists())
        self.assertFalse(list(self.remote.glob("*.partial")))

    def test_retention_happens_only_after_successful_verified_copy(self):
        backups=[self._local_backup(n) for n in range(3)]
        for backup in backups:
            self._mirror(backup,keep=2)
        retained=sorted(x.name for x in self.remote.glob("*.kasherbak"))
        self.assertEqual(retained,[backups[1].name,backups[2].name])
        self.assertTrue(backups[0].exists(), "local protected backups must not be pruned")
        self.assertFalse((self.remote / LOCK).exists())

    def test_rejects_overwrite_malformed_source_and_untrusted_paths(self):
        backup=self._local_backup()
        self._mirror(backup)
        with self.assertRaises(FileExistsError):
            self._mirror(backup)
        with self.assertRaises(ValueError):
            mirror_verified_backup(backup,self.remote,self.passphrase,
                                   scratch=self.remote)
        with self.assertRaises(ValueError):
            mirror_verified_backup(backup,self.local,self.passphrase,
                                   scratch=self.scratch)
        with self.assertRaises(ValueError):
            mirror_verified_backup(backup,self.remote,self.passphrase,
                                   scratch=self.scratch,keep=1)
        fake=self.root / "fake.kasherbak"
        fake.write_text("plaintext")
        with self.assertRaises(ValueError):
            self._mirror(fake)
        if hasattr(os, "symlink"):
            link=self.root / "kasher-20261114T020000Z-0123456789abcdef.kasherbak"
            try:
                link.symlink_to(backup)
            except (OSError, NotImplementedError):
                pass
            else:
                with self.assertRaises(ValueError):
                    self._mirror(link)

    def test_failed_accounting_audit_never_prunes_existing_verified_mirror(self):
        first=self._local_backup(0)
        self._mirror(first)
        second=self._local_backup(1)
        with mock.patch("offsite_backup.branch_database",
                        side_effect=ValueError("simulated audit issue")):
            with self.assertRaisesRegex(ValueError, "simulated"):
                self._mirror(second,keep=2)
        self.assertEqual(sorted(x.name for x in self.remote.glob("*.kasherbak")),
                         [first.name])
        self.assertFalse((self.remote / LOCK).exists())
