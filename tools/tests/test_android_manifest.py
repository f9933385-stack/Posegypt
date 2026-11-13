import tempfile
import unittest
from pathlib import Path
from sys import path as pythonpath
import xml.etree.ElementTree as ET

pythonpath.insert(0,str(Path(__file__).resolve().parents[1]))
from secure_android_manifest import secure_manifest,ANDROID

class AndroidManifestTest(unittest.TestCase):
    def test_backup_and_cleartext_disabled_after_generation(self):
        with tempfile.TemporaryDirectory() as t:
            path=Path(t)/"AndroidManifest.xml"
            path.write_text('''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="Kasher" android:allowBackup="true">
    <activity android:name=".MainActivity"/>
  </application>
</manifest>''',encoding='utf-8')
            secure_manifest(path)
            secure_manifest(path)
            app=ET.parse(path).getroot().find("application")
            self.assertEqual(app.get(ANDROID+"allowBackup"),"false")
            self.assertEqual(app.get(ANDROID+"usesCleartextTraffic"),"false")
            self.assertEqual(len(list(app.findall("activity"))),1)

    def test_missing_application_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            path=Path(t)/"AndroidManifest.xml"
            path.write_text("<manifest/>",encoding="utf-8")
            with self.assertRaises(ValueError):
                secure_manifest(path)
