"""Regression guard for the public, demo-only preview shipped with Kasher.
No third-party Python dependencies. Node is only used to syntax-check inline JS.
"""
from html.parser import HTMLParser
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
INDEX = ROOT / "preview" / "index.html"

class ScanPreview(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.scripts = []
        self.in_script = False
        self.remote_scripts = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "script":
            self.in_script = True
            if "src" in attrs:
                self.remote_scripts.append(attrs["src"])
    def handle_endtag(self, tag):
        if tag == "script":
            self.in_script = False
    def handle_data(self, data):
        if self.in_script:
            self.scripts.append(data)

class PreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = INDEX.read_text(encoding="utf-8")
        cls.scanner = ScanPreview()
        cls.scanner.feed(cls.html)

    def test_preview_is_explicitly_demo_only(self):
        self.assertIn("تجريبية", self.html)
        self.assertIn("لا توجد عمليات مالية أو ضريبية حقيقية", self.html)
        self.assertIn("غير مكتمل", self.html)

    def test_all_navigation_views_exist(self):
        for section in ("dashboard", "pos", "products", "purchases", "customers", "reports", "readiness"):
            with self.subTest(section=section):
                self.assertIn(section, self.scanner.ids)
                self.assertIn('data-page="' + section + '"', self.html)

    def test_preview_contains_interactive_controls(self):
        for control in ("posSearch", "cart", "checkout", "productsTable", "addStock", "resetDemo"):
            self.assertIn(control, self.scanner.ids)

    def test_no_remote_scripts_or_untrusted_data_endpoints(self):
        self.assertEqual(self.scanner.remote_scripts, [])
        self.assertNotIn("fetch(", self.html)
        self.assertNotIn("XMLHttpRequest", self.html)
        self.assertNotIn("localStorage", self.html)
        self.assertNotIn("document.cookie", self.html)

    def test_javascript_parses(self):
        if shutil.which("node") is None:
            self.skipTest("Node.js not available")
        script = "\n".join(self.scanner.scripts)
        self.assertIn('"use strict"', script)
        result = subprocess.run(["node", "--check", "-"], input=script,
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == "__main__":
    unittest.main()
