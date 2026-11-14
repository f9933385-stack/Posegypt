#!/usr/bin/env python3
"""Offline Ed25519 annual device license issuer. Never run private key on POS host.

Requires: python -m pip install -r tools/requirements-backup.txt
The private key is kept by the vendor on a separately protected machine.
The server receives ONLY the corresponding public verifier key.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def generate_key(path: Path, *, kid: str) -> dict:
    if not kid or len(kid)>40 or not all(c.isalnum() or c in "-_" for c in kid):
        raise ValueError("key-id must contain only ASCII letters/digits/_/-")
    path.parent.mkdir(parents=True, exist_ok=True)
    private = Ed25519PrivateKey.generate()
    serialized = private.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(serialized)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return {"key_id":kid,"public_key_base64url":b64(public),
            "verifier_json":json.dumps({kid:b64(public)},separators=(",",":"))}


def sign_license(private: Ed25519PrivateKey, *, kid: str, tenant: str,
                 device: str, days: int = 365, issued: datetime | None = None,
                 serial: str | None = None) -> str:
    if not 1<=days<=366:
        raise ValueError("License duration must be 1..366 days")
    if not kid or not tenant or not device or len(tenant)>128 or len(device)>128:
        raise ValueError("Issuer key, tenant and device IDs must be nonempty and reasonable")
    start=(issued or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)
    payload={
        "kind":"kasher-device-v1",
        "key_id":kid,
        "serial":serial or secrets.token_urlsafe(24),
        "tenant_id":tenant,
        "device_id":device,
        "issued_at":utc(start),
        "expires_at":utc(start+timedelta(days=days)),
    }
    if len(payload["serial"])<16 or len(payload["serial"])>128:
        raise ValueError("Serial must be 16..128 characters")
    encoded=json.dumps(payload,sort_keys=True,separators=(",",":"),
                       ensure_ascii=True).encode("utf-8")
    signature=private.sign(encoded)
    return b64(encoded)+"."+b64(signature)


def main() -> None:
    cli=argparse.ArgumentParser(description=__doc__)
    sub=cli.add_subparsers(dest="operation",required=True)
    create=sub.add_parser("generate-key",help="Generate a vendor PRIVATE key outside GitHub")
    create.add_argument("--private-key",type=Path,required=True)
    create.add_argument("--key-id",required=True)
    issue=sub.add_parser("issue",help="Issue annual license bound to enrolled device")
    issue.add_argument("--private-key",type=Path,required=True)
    issue.add_argument("--key-id",required=True)
    issue.add_argument("--tenant-id",required=True)
    issue.add_argument("--device-id",required=True)
    issue.add_argument("--days",type=int,default=365)
    opts=cli.parse_args()
    if opts.operation=="generate-key":
        print(json.dumps(generate_key(opts.private_key,kid=opts.key_id)))
    else:
        # Never echo or log the private signing key, and never store it on POS host.
        key=serialization.load_pem_private_key(opts.private_key.read_bytes(),password=None)
        if not isinstance(key,Ed25519PrivateKey):
            cli.error("Issuer key is not an Ed25519 private key")
        print(sign_license(key,kid=opts.key_id,tenant=opts.tenant_id,
                           device=opts.device_id,days=opts.days))


if __name__=="__main__":
    main()
