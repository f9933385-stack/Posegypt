#!/usr/bin/env python3
"""Mirror a verified encrypted Kasher backup to a separate storage location.

The destination can be a protected Windows UNC share, approved mounted backup
volume, or removable/offsite device. This script does not set up cloud OAuth,
automatic scheduling or prove that a folder is physically off premises.

No plaintext SQLite database is ever written to the mirror folder. Every
candidate mirror is copied, hashed, decrypted on a trusted LOCAL scratch
directory, audited, and only then promoted to the final encrypted filename.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

from backup_database import CHUNK, MAGIC, restore
from scheduled_backup import NAME, _ensure_private_directory, _safe_prune, branch_database

LOCK = ".kasher-offsite.lock"
_PARTIAL_PREFIX = ".kasher-offsite-"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while part := handle.read(CHUNK):
            digest.update(part)
    return digest.hexdigest()


def _private_source(source: Path) -> None:
    if source.is_symlink() or not source.is_file() or not NAME.fullmatch(source.name):
        raise ValueError("Source must be a regular named Kasher encrypted backup")
    if source.stat().st_size <= len(MAGIC) + 16 + 12 + 16:
        raise ValueError("Source backup is incomplete")
    with source.open("rb") as handle:
        if handle.read(len(MAGIC)) != MAGIC:
            raise ValueError("Source backup is not a Kasher AES-GCM snapshot")


def mirror_verified_backup(source: Path, offsite: Path, password: str, *,
                           scratch: Path, keep: int = 30) -> dict:
    """Copy a single encrypted backup and verify it before remote retention.

    The caller must separately provision backup credentials, a trusted host
    scheduler and a physically separate / approved target. 'scratch' must
    be a protected local directory *outside* the offsite destination.
    """
    if keep < 2 or keep > 365:
        raise ValueError("Offsite keep must be between 2 and 365")
    if len(password) < 16:
        raise ValueError("Backup password must have 16+ characters")
    if source.is_symlink() or offsite.is_symlink() or scratch.is_symlink():
        raise ValueError("Symlink backup source, destination or scratch not allowed")
    _private_source(source)
    # Do not make untrusted file path traversal decisions from a filename.
    source = source.resolve(strict=True)
    offsite = offsite.resolve()
    scratch = scratch.resolve()
    if offsite == scratch or offsite == source.parent or scratch == source.parent:
        raise ValueError("Encrypted input, offsite destination and local scratch must be separate")
    if offsite in scratch.parents or scratch in offsite.parents:
        raise ValueError("Local scratch may not be nested in the offsite folder")
    if (offsite in source.parents or source.parent in offsite.parents
            or offsite == source.parent):
        raise ValueError("Offsite must be outside the source backup directory tree")
    _ensure_private_directory(offsite)
    _ensure_private_directory(scratch)
    target = offsite / source.name
    if target.exists() or target.is_symlink():
        raise FileExistsError("Encrypted backup already exists at offsite destination")
    lock_fd = None
    owns_lock = False
    lock = offsite / LOCK
    partial: Path | None = None
    try:
        lock_fd = os.open(str(lock), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        owns_lock = True
        with os.fdopen(lock_fd, "w", encoding="utf-8") as handle:
            lock_fd = None
            handle.write("Kasher verified offsite backup in progress\n")
            handle.flush()
            os.fsync(handle.fileno())
        fd, tmp_name = tempfile.mkstemp(prefix=_PARTIAL_PREFIX,
                                         suffix=".partial", dir=str(offsite))
        partial = Path(tmp_name)
        try:
            with os.fdopen(fd, "wb") as output, source.open("rb") as encrypted:
                digest = hashlib.sha256()
                total = 0
                while block := encrypted.read(CHUNK):
                    output.write(block)
                    digest.update(block)
                    total += len(block)
                output.flush()
                os.fsync(output.fileno())
            expected_hash = digest.hexdigest()
            if (total != source.stat().st_size or _sha256(source) != expected_hash
                    or _sha256(partial) != expected_hash):
                raise ValueError("Encrypted mirror checksum did not match source")
            # Verification temp files stay on a trusted local encrypted volume.
            with tempfile.TemporaryDirectory(prefix="kasher-mirror-check-", dir=str(scratch)) as tmp:
                restore(partial, Path(tmp) / "verification.sqlite3", password)
                branch_database(Path(tmp) / "verification.sqlite3")
            if target.exists() or target.is_symlink():
                raise FileExistsError("Target appeared during verification; refusing overwrite")
            partial.replace(target)
            # Never prune older copies until the NEW copied version passes restore.
            pruned = _safe_prune(offsite, keep)
            return {"status": "verified-offsite-copy", "backup": target.name,
                    "bytes": total, "sha256": expected_hash,
                    "retained_limit": keep, "pruned": pruned}
        finally:
            if partial is not None:
                partial.unlink(missing_ok=True)
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        if owns_lock:
            lock.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("encrypted_backup", type=Path)
    parser.add_argument("offsite_directory", type=Path,
                        help="Dedicated protected backup share or mounted offsite volume")
    parser.add_argument("--scratch", type=Path, required=True,
                        help="Protected local scratch folder on encrypted branch host")
    parser.add_argument("--keep", type=int, default=30)
    options = parser.parse_args()
    password = os.environ.get("KASHER_BACKUP_PASSWORD", "")
    if len(password) < 16:
        parser.error("Set KASHER_BACKUP_PASSWORD using a trusted secrets vault")
    result = mirror_verified_backup(options.encrypted_backup, options.offsite_directory,
                                    password, scratch=options.scratch, keep=options.keep)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
