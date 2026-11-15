"""Tests vendor-only Ed25519 issuer; never persist a real private key in git."""
import base64
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from sys import path as pythonpath

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

pythonpath.insert(0,str(Path(__file__).resolve().parents[1]))
from license_issuer import generate_key, sign_license


class LicenseIssuerTest(unittest.TestCase):
    def setUp(self):
        self.work=tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.path=Path(self.work.name)/"issuer.pem"

    def _decode(self,token):
        payload,signature=token.split(".")
        data=base64.urlsafe_b64decode(payload+"="*((-len(payload))%4))
        signed=base64.urlsafe_b64decode(signature+"="*((-len(signature))%4))
        return data,signed

    def test_new_key_is_private_and_verifier_is_public_only(self):
        metadata=generate_key(self.path,kid="vendor-2026")
        self.assertTrue(self.path.is_file())
        self.assertNotIn("PRIVATE KEY",str(metadata))
        self.assertIn("vendor-2026",metadata["verifier_json"])
        if os.name!="nt":
            self.assertEqual(self.path.stat().st_mode & 0o077,0)
        key=serialization.load_pem_private_key(self.path.read_bytes(),password=None)
        token=sign_license(key,kid="vendor-2026",tenant="tenant-1",device="device-1",
                           days=365,issued=datetime(2026,11,14,tzinfo=timezone.utc))
        payload,sig=self._decode(token)
        key.public_key().verify(sig,payload)
        claims=json.loads(payload)
        self.assertEqual(claims["device_id"],"device-1")
        self.assertEqual(claims["tenant_id"],"tenant-1")
        self.assertEqual(claims["issued_at"],"2026-11-14T00:00:00Z")
        self.assertEqual(claims["expires_at"],"2027-11-14T00:00:00Z")
        self.assertEqual(claims["kind"],"kasher-device-v1")
        self.assertEqual(claims["key_id"],"vendor-2026")

    def test_distinct_license_serials_and_signature_bound_to_all_claims(self):
        private=Ed25519PrivateKey.generate()
        a=sign_license(private,kid="k1",tenant="T",device="D")
        b=sign_license(private,kid="k1",tenant="T",device="D")
        self.assertNotEqual(a,b)
        payload,signature=self._decode(a)
        private.public_key().verify(signature,payload)
        altered=payload.replace(b'"device_id":"D"',b'"device_id":"X"')
        self.assertNotEqual(altered,payload)
        with self.assertRaises(Exception):
            private.public_key().verify(signature,altered)

    def test_key_overwrite_and_invalid_durations_are_rejected(self):
        generate_key(self.path,kid="v1")
        original=self.path.read_bytes()
        with self.assertRaises(FileExistsError):
            generate_key(self.path,kid="v1")
        self.assertEqual(self.path.read_bytes(),original)
        key=serialization.load_pem_private_key(original,password=None)
        for days in [0,367,-1]:
            with self.assertRaises(ValueError):
                sign_license(key,kid="v1",tenant="T",device="D",days=days)
        with self.assertRaises(ValueError):
            sign_license(key,kid="v1",tenant="T",device="",days=365)
