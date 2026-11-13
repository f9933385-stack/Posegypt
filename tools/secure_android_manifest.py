#!/usr/bin/env python3
"""Harden Flutter-generated Android manifest for device-secret storage.

This runs AFTER "flutter create" because native platform scaffolding is
intentionally not tracked in this source repository.
"""
from __future__ import annotations
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID = "{http://schemas.android.com/apk/res/android}"
ET.register_namespace("android", "http://schemas.android.com/apk/res/android")

def secure_manifest(path: Path) -> None:
    root = ET.parse(path)
    app = root.getroot().find("application")
    if app is None:
        raise ValueError("AndroidManifest.xml lacks <application>")
    app.set(ANDROID + "allowBackup", "false")
    app.set(ANDROID + "usesCleartextTraffic", "false")
    root.write(path, encoding="utf-8", xml_declaration=True)
    # Verify output is parseable and the exact protections are present.
    verified = ET.parse(path).getroot().find("application")
    if verified is None or verified.get(ANDROID+"allowBackup") != "false" \
       or verified.get(ANDROID+"usesCleartextTraffic") != "false":
        raise RuntimeError("Could not disable Android auto-backup and cleartext")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: secure_android_manifest.py path/to/AndroidManifest.xml")
    secure_manifest(Path(sys.argv[1]))
