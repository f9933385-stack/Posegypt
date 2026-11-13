#!/usr/bin/env python3
"""One-shot verified, encrypted backup with conservative retention.

Run from a trusted host scheduler. This script deliberately does NOT install a
scheduler or save its encryption password on disk. Inject KASHER_BACKUP_PASSWORD
from a secure vault/service account at execution time. Never store a passphrase
in Task Scheduler arguments, GitHub Secrets, or this repository.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from audit_database import audit
from backup_database import backup, restore

NAME = re.compile(r"^kasher-(\d{8}T\d{6}Z)-([0-9a-f]{16})\.kasherbak$")
LOCK = ".kasher-backup.lock"


def branch_database(path: Path) -> None:
    """Reject arbitrary SQLite files and obvious incomplete/corrupt branches."""
    if not path.is_file():
        raise FileNotFoundError(path)
    db = sqlite3.connect(f"file:{path.resolve().as_posix()}?mode=ro", uri=True)
    try:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        required = {"tenants", "branches", "documents", "journal_entries",
                    "journal_lines", "stock_balances", "inventory_movements"}
        missing = required - tables
        if missing:
            raise ValueError("Not a Kasher branch database; missing tables: " + ", ".join(sorted(missing)))
        result = audit(str(path))
        if result["status"] != "pass":
            raise ValueError("Accounting / stock audit failed: " + ", ".join(result["errors"]))
    finally:
        db.close()


def _ensure_private_directory(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.name != "nt":
        perms = directory.stat().st_mode & 0o777
        if perms & 0o077:
            raise PermissionError("Backup directory must be private: chmod 700 " + str(directory))


def _safe_prune(directory: Path, keep: int) -> list[str]:
    """Only delete explicitly named Kasher backups, never arbitrary files."""
    valid = sorted(
        (p for p in directory.iterdir()
         if p.is_file() and not p.is_symlink() and NAME.fullmatch(p.name)),
        key=lambda p: p.name,
        reverse=True,
    )
    removed = []
    for old in valid[keep:]:
        old.unlink()
        removed.append(old.name)
    return removed


def run_once(source: Path, backup_dir: Path, password: str, *, keep: int = 14,
             timestamp: datetime | None = None) -> dict:
    """Snapshot live SQLite safely, decrypt to a disposable file, audit, then prune.

    Snapshot consistency uses SQLite backup API, including live WAL activity.
    Success means cryptographic restore and selected accounting invariants pass.
    It is not a full disaster-recovery drill or cloud backup.
    """
    if keep < 2 or keep > 365:
        raise ValueError("keep must be between 2 and 365")
    if len(password) < 16:
        raise ValueError("KASHER_BACKUP_PASSWORD must have at least 16 characters")
    source = source.resolve()
    backup_dir = backup_dir.resolve()
    _ensure_private_directory(backup_dir)
    if backup_dir == source.parent:
        raise ValueError("Backups must be stored in a separate private directory")
    # Source audit must pass before backup; do not preserve known corrupt balances.
    branch_database(source)
    lock_file = backup_dir / LOCK
    try:
        lock_fd = os.open(str(lock_file), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError as exc:
        raise RuntimeError("Backup already running or stale lock exists; inspect manually") from exc
    try:
        with os.fdopen(lock_fd, "w", encoding="utf-8") as f:
            f.write("Kasher backup in progress\n")
        moment = (timestamp or datetime.now(timezone.utc)).astimezone(timezone.utc)
        stamp = moment.strftime("%Y%m%dT%H%M%SZ")
        name = f"kasher-{stamp}-{secrets.token_hex(8)}.kasherbak"
        target = backup_dir / name
        # The existing backup() uses SQLite backup API and authenticated AES-GCM.
        # A temporary plaintext snapshot must stay on the host, not in cloud output.
        backup(source, target, password)
        try:
            with tempfile.TemporaryDirectory(prefix="kasher-verify-", dir=source.parent) as temp:
                restored = Path(temp) / "verification.sqlite3"
                restore(target, restored, password)
                branch_database(restored)
        except Exception:
            # Never retain an unverified "success" backup or prune other copies.
            target.unlink(missing_ok=True)
            raise
        removed = _safe_prune(backup_dir, keep)
        return {"status": "verified", "backup": name, "bytes": target.stat().st_size,
                "retained": keep, "pruned": removed}
    finally:
        lock_file.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("backup_directory", type=Path)
    parser.add_argument("--keep", type=int, default=14)
    args = parser.parse_args()
    password = os.environ.get("KASHER_BACKUP_PASSWORD", "")
    if len(password) < 16:
        parser.error("Inject KASHER_BACKUP_PASSWORD from an approved secrets vault (16+ characters)")
    outcome = run_once(args.database, args.backup_directory, password, keep=args.keep)
    print(json.dumps(outcome, ensure_ascii=False))


if __name__ == "__main__":
    main()
