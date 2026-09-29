"""Slice 5b0 (Task 4): lib/linkrules.py, the link rules Search and RSS
share, against every pageLink row of tests/fixtures/link-rules-cases.json.
magnetHash rows are JS-only (LinkRules.js); Python has no such rule.
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))
import linkrules  # noqa: E402

DATA = json.loads((ROOT / "tests" / "fixtures" / "link-rules-cases.json").read_text())


class LinkRulesTest(unittest.TestCase):
    def test_page_link_rows(self):
        rows = [c for c in DATA["cases"] if c["kind"] == "pageLink"]
        self.assertTrue(rows)
        for c in rows:
            with self.subTest(c["why"]):
                try:
                    normalised, host = linkrules.page_link(c["input"])
                    ok, message = True, None
                except linkrules.Refused as exc:
                    ok, normalised, host, message = False, None, None, exc.message
                self.assertEqual(ok, c["ok"])
                if not c["ok"]:
                    self.assertEqual(message, c["message"])
                if "host" in c:
                    self.assertEqual(host, c["host"])

    def test_exports(self):
        for name in ("BAD", "CONTROL", "split_url", "host_of", "page_link", "is_space"):
            self.assertTrue(hasattr(linkrules, name), name)


if __name__ == "__main__":
    unittest.main()
