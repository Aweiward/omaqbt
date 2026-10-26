"""Browser-magnet state stays intact when more than one qbt is running."""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent.parent


class MagnetConcurrencyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="qbt-magnet-race-")
        self.add_started = threading.Event()
        self.second_add = threading.Event()
        self.release_add = threading.Event()
        self.guard = threading.Lock()
        self.torrents = {}
        self.adds = []
        self.procs = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, data):
                body = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path != "/api/v2/torrents/info":
                    self.send_error(404)
                    return
                with owner.guard:
                    rows = list(owner.torrents.values())
                self.reply(rows)

            def do_POST(self):
                fields = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
                if self.path == "/api/v2/torrents/add":
                    url = fields["urls"][0]
                    h = parse_qs(url.split("?", 1)[1])["xt"][0].split(":")[-1]
                    with owner.guard:
                        owner.adds.append(h)
                        first = len(owner.adds) == 1
                    if first:
                        owner.add_started.set()
                        if not owner.release_add.wait(10):
                            self.send_error(504)
                            return
                    else:
                        owner.second_add.set()
                    with owner.guard:
                        owner.torrents[h] = {"hash": h, "infohash_v1": h, "name": h}
                elif self.path == "/api/v2/torrents/delete":
                    with owner.guard:
                        for h in fields["hashes"][0].split("|"):
                            owner.torrents.pop(h, None)
                else:
                    self.send_error(404)
                    return
                self.reply({})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        base = Path(self.tmp.name)
        self.state = base / "magnets"
        self.state.mkdir(mode=0o700)
        self.inbox = self.state / "magnet-inbox.jsonl"
        self.pending = self.state / "magnet-pending.json"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("QBT_")}
        self.env.update({
            "QBT_BASE": f"http://127.0.0.1:{self.server.server_port}",
            "QBT_CONF": str(ROOT / "tests/fixtures/qBittorrent.conf"),
            "QBT_HOME": str(base),
            "QBT_STATE_DIR": str(base / "runtime"),
            "QBT_MAGNET_STATE": str(self.state),
            "QBT_INSTALLED": "1", "QBT_DAEMON": "1", "QBT_LOCK": "nox",
            "QBT_RAISE_CMD": "/bin/true", "QBT_NOTIFY_CMD": "/bin/true",
        })
        self.a, self.b, self.c = (letter * 40 for letter in "abc")

    def tearDown(self):
        self.release_add.set()
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=5)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.tmp.cleanup()

    def magnet(self, h):
        return "magnet:?xt=urn:btih:" + h

    def seed(self, *hashes):
        self.inbox.write_text("".join(json.dumps({"url": self.magnet(h), "ts": 1}) + "\n" for h in hashes))

    def start_drain(self):
        proc = subprocess.Popen([str(ROOT / "qbt"), "magnet-drain"], env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.procs.append(proc)
        return proc

    def finish(self, proc):
        out, err = proc.communicate(timeout=15)
        self.assertEqual(proc.returncode, 0, err + out)
        self.assertTrue(json.loads(out)["ok"], out)

    def qbt(self, *args):
        result = subprocess.run([str(ROOT / "qbt"), *args], env=self.env,
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def test_two_drains_add_each_magnet_once(self):
        self.seed(self.a, self.b)
        first = self.start_drain()
        self.assertTrue(self.add_started.wait(5), "first drain never reached the API")
        second = self.start_drain()
        # Hold the first add open while the second drain starts. The old
        # code enters the API with the same URL; a serialized drain waits.
        self.second_add.wait(2)
        self.release_add.set()
        self.finish(first)
        self.finish(second)
        self.assertEqual(self.adds, [self.a, self.b])
        self.assertEqual(self.inbox.read_text().strip(), "")
        self.assertEqual({row["hash"] for row in json.loads(self.pending.read_text())}, {self.a, self.b})

    def test_cancel_during_add_keeps_the_next_inbox_entry(self):
        self.seed(self.a, self.b)
        first = self.start_drain()
        self.assertTrue(self.add_started.wait(5))
        self.qbt("magnet-inbox-drop")
        self.release_add.set()
        self.finish(first)
        self.assertEqual([json.loads(line)["url"] for line in self.inbox.read_text().splitlines()],
                         [self.magnet(self.b)])
        self.assertNotIn(self.a, self.torrents)

    def test_pending_drop_during_add_is_not_undone(self):
        self.seed(self.a)
        self.pending.write_text(json.dumps([{"hash": self.c, "hashes": [self.c], "url": self.magnet(self.c)}]))
        first = self.start_drain()
        self.assertTrue(self.add_started.wait(5))
        self.qbt("magnet-pending-drop", self.c)
        self.release_add.set()
        self.finish(first)
        self.assertEqual([row["hash"] for row in json.loads(self.pending.read_text())], [self.a])


    def test_malformed_inbox_line_does_not_fail_the_drain(self):
        self.release_add.set()
        junk = "{not json"
        self.inbox.write_text(json.dumps({"url": self.magnet(self.a), "ts": 1}) + "\n"
                              + junk + "\n"
                              + json.dumps({"url": self.magnet(self.b), "ts": 1}) + "\n")
        self.finish(self.start_drain())
        self.assertEqual(self.adds, [self.a])
        self.assertEqual({row["hash"] for row in json.loads(self.pending.read_text())}, {self.a})
        # The drained entry is gone; the line we cannot read is kept, not destroyed.
        lines = self.inbox.read_text().splitlines()
        self.assertEqual(lines[0], junk)
        self.assertEqual([json.loads(ln)["url"] for ln in lines[1:]], [self.magnet(self.b)])
        # A later drain still works around the junk line once it is not first.
        self.inbox.write_text(json.dumps({"url": self.magnet(self.c), "ts": 1}) + "\n" + junk + "\n")
        self.finish(self.start_drain())
        self.assertEqual(self.adds, [self.a, self.c])
        self.assertEqual(self.inbox.read_text(), junk + "\n")

    def inbox_env(self, **extra):
        env = dict(self.env)
        env["QBT_RAISE_CMD"] = "/bin/false"  # no shell to raise: magnet-inbox marks the entry notified
        env.update(extra)
        return env

    def run_inbox(self, h, env):
        return subprocess.run([str(ROOT / "qbt"), "magnet-inbox", self.magnet(h)], env=env,
                              text=True, capture_output=True, timeout=15)

    def test_notified_flag_rewrite_leaves_no_partial_inbox(self):
        self.seed(self.a, self.b)
        shim = Path(self.tmp.name) / "shim"
        shim.mkdir()
        # Make the rewrite die after the inbox has been opened for writing.
        (shim / "sitecustomize.py").write_text(
            "import json\n"
            "_dumps = json.dumps\n"
            "def dumps(obj, *a, **k):\n"
            "    if isinstance(obj, dict) and obj.get('notified') is True:\n"
            "        raise OSError('simulated write failure')\n"
            "    return _dumps(obj, *a, **k)\n"
            "json.dumps = dumps\n")
        result = self.run_inbox(self.c, self.inbox_env(PYTHONPATH=str(shim)))
        self.assertNotEqual(result.returncode, 0, "the simulated failure never reached the rewrite")
        rows = [json.loads(ln) for ln in self.inbox.read_text().splitlines()]
        self.assertEqual([r["url"] for r in rows],
                         [self.magnet(self.a), self.magnet(self.b), self.magnet(self.c)])
        self.assertEqual([p.name for p in self.state.iterdir() if p.name.startswith("tmp")], [])

    def test_notified_flag_rewrite_marks_only_the_new_entry(self):
        self.seed(self.a)
        result = self.run_inbox(self.c, self.inbox_env())
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        rows = [json.loads(ln) for ln in self.inbox.read_text().splitlines()]
        self.assertEqual([(r["url"], r.get("notified")) for r in rows],
                         [(self.magnet(self.a), None), (self.magnet(self.c), True)])
        self.assertEqual(self.inbox.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in self.state.iterdir() if p.name.startswith("tmp")), [])


if __name__ == "__main__":
    unittest.main()
