#!/usr/bin/env python3
"""Encrypted streaming SQLite snapshot/restore for Kasher.

Requires: python -m pip install -r tools/requirements-backup.txt
Always stop the branch server before RESTORE. Password must come from
KASHER_BACKUP_PASSWORD environment variable; it is never passed in CLI args.
Use a strong unique passphrase and retain it separately from backup files.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import secrets
import sqlite3
import tempfile
from pathlib import Path

MAGIC = b"KASHERB1"  # 8 bytes
SALT_SIZE = 16
NONCE_SIZE = 12
TAG_SIZE = 16
CHUNK = 1024 * 1024


def _crypto():
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    except ImportError as exc:
        raise SystemExit("Install backup dependencies: pip install -r tools/requirements-backup.txt") from exc
    return Cipher, algorithms, modes


def key_from_passphrase(password: str, salt: bytes) -> bytes:
    if len(password) < 16:
        raise ValueError("KASHER_BACKUP_PASSWORD must have at least 16 characters")
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, n=2**14, r=8, p=1, dklen=32)


def _integrity(path: Path) -> None:
    con = sqlite3.connect(f"file:{path.resolve().as_posix()}?mode=ro", uri=True)
    try:
        check = con.execute("PRAGMA integrity_check").fetchone()[0]
        if check != "ok":
            raise ValueError("SQLite integrity check failed")
        issues = con.execute("PRAGMA foreign_key_check").fetchall()
        if issues:
            raise ValueError(f"SQLite foreign-key integrity failed: {len(issues)} violations")
    finally:
        con.close()


def _snapshot(source: Path, tmp: Path) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    src = sqlite3.connect(f"file:{source.resolve().as_posix()}?mode=ro", uri=True)
    dst = sqlite3.connect(str(tmp))
    try:
        with dst:
            src.backup(dst)
    finally:
        dst.close()
        src.close()
    _integrity(tmp)


def backup(source: Path, destination: Path, password: str) -> None:
    Cipher, algorithms, modes = _crypto()
    if destination.exists():
        raise FileExistsError("Backup destination already exists (refusing to overwrite)")
    salt, nonce = secrets.token_bytes(SALT_SIZE), secrets.token_bytes(NONCE_SIZE)
    key = key_from_passphrase(password, salt)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Keep the short-lived plaintext SQLite snapshot on the trusted branch host,
    # NEVER beside the encrypted output (which may be a removable/cloud folder).
    fd, temp_path = tempfile.mkstemp(prefix=".kasher-", suffix=".sqlite3", dir=str(source.resolve().parent))
    os.close(fd)
    temporary = Path(temp_path)
    partial_fd, partial_name = tempfile.mkstemp(prefix=".kasher-encrypted-", suffix=".partial", dir=str(destination.parent))
    os.close(partial_fd)
    partial = Path(partial_name)
    try:
        _snapshot(source, temporary)
        encrypter = Cipher(algorithms.AES(key), modes.GCM(nonce)).encryptor()
        encrypter.authenticate_additional_data(MAGIC + salt + nonce)
        with temporary.open("rb") as inp, partial.open("wb") as out:
            out.write(MAGIC + salt + nonce)
            while block := inp.read(CHUNK):
                out.write(encrypter.update(block))
            out.write(encrypter.finalize())
            out.write(encrypter.tag)
            out.flush()
            os.fsync(out.fileno())
        partial.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
        partial.unlink(missing_ok=True)


def restore(source: Path, destination: Path, password: str) -> None:
    Cipher, algorithms, modes = _crypto()
    if destination.exists():
        raise FileExistsError("Restore target already exists. Restore to a new path; never overwrite a live database.")
    with source.open("rb") as inp:
        header = inp.read(len(MAGIC) + SALT_SIZE + NONCE_SIZE)
        if header[:len(MAGIC)] != MAGIC or len(header) != len(MAGIC) + SALT_SIZE + NONCE_SIZE:
            raise ValueError("Invalid Kasher backup header")
        salt = header[len(MAGIC):len(MAGIC)+SALT_SIZE]
        nonce = header[len(MAGIC)+SALT_SIZE:]
        size = source.stat().st_size
        if size <= len(header) + TAG_SIZE:
            raise ValueError("Truncated Kasher backup")
        inp.seek(size-TAG_SIZE)
        tag = inp.read(TAG_SIZE)
        inp.seek(len(header))
        left = size-len(header)-TAG_SIZE
        key = key_from_passphrase(password, salt)
        decrypter = Cipher(algorithms.AES(key), modes.GCM(nonce, tag)).decryptor()
        decrypter.authenticate_additional_data(header)
        destination.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(prefix=".kasher-restore-", suffix=".sqlite3",dir=str(destination.parent))
        os.close(fd)
        temp = Path(temp_path)
        try:
            with temp.open("wb") as out:
                while left > 0:
                    part = inp.read(min(CHUNK, left))
                    if not part:
                        raise ValueError("Unexpected end of backup")
                    out.write(decrypter.update(part))
                    left -= len(part)
                out.write(decrypter.finalize())  # raises InvalidTag for a wrong key or corrupted file
                out.flush()
                os.fsync(out.fileno())
            _integrity(temp)
            if destination.exists():
                raise FileExistsError(destination)
            temp.replace(destination)
        finally:
            temp.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="cmd", required=True)
    for command in ("backup", "restore"):
        sub = subs.add_parser(command)
        sub.add_argument("source", type=Path)
        sub.add_argument("destination", type=Path)
    args = parser.parse_args()
    password = os.environ.get("KASHER_BACKUP_PASSWORD", "")
    if len(password) < 16:
        parser.error("Set strong KASHER_BACKUP_PASSWORD in environment (at least 16 characters)")
    if args.source.resolve() == args.destination.resolve():
        parser.error("Source and destination must differ")
    if args.cmd == "backup":
        backup(args.source, args.destination, password)
    else:
        restore(args.source, args.destination, password)
    print("Completed:", args.destination)


if __name__ == "__main__":
    main()
