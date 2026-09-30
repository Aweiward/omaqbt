#!/usr/bin/env python3
import importlib
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))


class FixtureLogTest(unittest.TestCase):
    """Tests poll QBT_FIXTURE_LOG while the fixture server writes it. A reader
    must never see an empty or half-written file (CI run 3 died on that)."""

    def test_a_reader_never_sees_a_torn_log(self):
        tmp = Path(tempfile.mkdtemp(prefix="qbt-log-"))
        log = tmp / "log.json"
        os.environ["QBT_FIXTURE_LOG"] = str(log)
        os.environ.setdefault("QBT_FIXTURE_CONTROL", str(tmp / "control.json"))
        server = importlib.import_module("server")
        server.LOG = log
        writes = 400

        def writer():
            for i in range(writes):
                server.record("POST", f"/api/v2/x/{i}", "b" * 2000, "")

        t = threading.Thread(target=writer)
        t.start()
        torn = 0
        while t.is_alive():
            if log.exists():
                try:
                    json.loads(log.read_text())
                except ValueError:
                    torn += 1
        t.join()
        self.assertEqual(torn, 0, "reads of a torn log")
        self.assertEqual(len(json.loads(log.read_text())), writes)
        self.assertEqual(sorted(p.name for p in tmp.iterdir() if p.name != "control.json"), ["log.json"])


if __name__ == "__main__":
    unittest.main()
