"""Slice 5a (Task 2): the sidecar's search watch (tests/fixtures/search-contract.md,
"The sidecar's search watch"), against the fixture's search API.

The window owns the offset (OV7): a restarted sidecar resumes exactly
where the command says. Replies carry qBittorrent's rows untouched (OV9),
never cross row 2000 (OV15), and the final reply (Ruling FB: Stopped and
offset + rows == min(total, 2000), zero rows allowed) is always sent, then
the watch drops.
"""
import json
import subprocess
import sys
import time
import unittest
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, urlencode

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import harness  # noqa: E402
from test_serve import ServeProcess, _read_log, _write_control  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
ROW_CASES = [c["input"] for c in json.loads(
    (ROOT / "tests" / "fixtures" / "search-rules-cases.json").read_text())["cases"] if c["kind"] == "row"]


def expected_row(i, pattern="debian"):
    # The fixture's generated row i (server.py _search_row).
    return {
        "fileName": f"{pattern} result {i}",
        "fileUrl": f"magnet:?xt=urn:btih:{format(i, '040x')}&dn=r{i}",
        "fileSize": 1000 * (i + 1),
        "nbSeeders": i,
        "nbLeechers": 1,
        "engineName": "piratebay",
        "siteUrl": "https://thepiratebay.org",
        "descrLink": f"https://thepiratebay.org/t/{i}",
        "pubDate": 1757894400 + i,
    }


def is_search(obj):
    return obj.get("type") == "search"


class SearchWatchCase(unittest.TestCase):
    def setUp(self):
        self._cm = harness.fixture_server()
        self.port, self.env = self._cm.__enter__()
        self.addCleanup(self._cm.__exit__, None, None, None)
        self.control_path = self.env["QBT_FIXTURE_CONTROL"]

    def control(self, mapping):
        _write_control(self.control_path, mapping)

    def start_job(self, spec, pattern="debian", jar_path=None):
        """Starts a fixture job directly (the window would use qbt)."""
        self.control({"search": spec})
        body = urlencode({"pattern": pattern, "category": "all", "plugins": "enabled"}).encode()
        # In the key's session, as `qbt search start` would.
        return json.loads(harness.qbt_urlopen(self.env, "/api/v2/search/start", data=body, jar_path=jar_path))["id"]

    def post(self, path, body):
        harness.qbt_urlopen(self.env, path, data=body.encode())

    def serve(self):
        sp = ServeProcess(self.env)
        self.addCleanup(sp.cleanup)
        sp.readline(timeout=5)  # the first status line
        return sp

    def search_reads(self):
        """The sidecar's search reads (the test's own POSTs left out)."""
        return [e for e in _read_log(self.env["QBT_FIXTURE_LOG"])
                if e["path"].startswith("/api/v2/search/") and e["method"] == "GET"]

    def no_search_reply_for(self, sp, seconds):
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            try:
                obj = sp.readline(timeout=remaining)
            except AssertionError:
                return
            self.assertFalse(is_search(obj), obj)

    def collect_until_final(self, sp, jid, timeout=15):
        """Every reply up to and including the final one, checking the
        window's offset rule on the way."""
        replies, held = [], 0
        deadline = time.monotonic() + timeout
        while True:
            reply = sp.read_until(is_search, timeout=max(0.1, deadline - time.monotonic()))
            self.assertEqual(reply["id"], jid)
            self.assertNotIn("error", reply)
            self.assertEqual(reply["offset"], held, "no gap, no duplicate")
            held += len(reply["rows"])
            replies.append(reply)
            if reply["status"] == "Stopped" and held == min(reply["total"], 2000):
                return replies


class SearchWatchTest(SearchWatchCase):
    def test_a_command_is_answered_at_once_and_streams_to_the_final_reply(self):
        jid = self.start_job({"total": 40, "rate": 20, "finish": 2.5})
        sp = self.serve()
        started = time.monotonic()
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        first = sp.read_until(is_search, timeout=2)
        # The default status cadence is 5 s: the watch answers at once.
        self.assertLess(time.monotonic() - started, 1.5)
        self.assertEqual(list(first), ["type", "id", "status", "total", "offset", "rows", "capped"])
        self.assertEqual((first["status"], first["offset"], first["capped"]), ("Running", 0, False))
        self.assertEqual(first["total"], len(first["rows"]))
        self.assertEqual(first["status"], "Running")
        replies = [first] + self.collect_until_final_from(sp, jid, len(first["rows"]))
        rows = [row for r in replies for row in r["rows"]]
        self.assertEqual(rows, [expected_row(i) for i in range(40)])
        self.assertGreater(len(replies), 2, "rows arrive about once a second while it runs")
        self.assertEqual(replies[-1]["status"], "Stopped")
        # The watch dropped: no more reads, no more replies.
        count = len(self.search_reads())
        self.no_search_reply_for(sp, 2.5)
        self.assertEqual(len(self.search_reads()), count)
        # And only GETs: the one POST is the test's own start.
        posts = [e["path"] for e in _read_log(self.env["QBT_FIXTURE_LOG"]) if e["method"] == "POST"]
        self.assertEqual(posts, ["/api/v2/search/start"])

    def collect_first(self, sp, jid, offset=0):
        sp.send({"cmd": "search", "id": jid, "offset": offset})
        return sp.read_until(is_search, timeout=3)

    def test_the_final_reply_with_zero_rows(self):
        jid = self.start_job({"total": 3})
        sp = self.serve()
        reply = self.collect_first(sp, jid, offset=3)
        self.assertEqual((reply["status"], reply["total"], reply["offset"], reply["rows"]), ("Stopped", 3, 3, []))
        count = len(self.search_reads())
        self.no_search_reply_for(sp, 2.5)
        self.assertEqual(len(self.search_reads()), count, "dropped after the final reply")

    def test_an_empty_stopped_job_is_final_at_once(self):
        jid = self.start_job({"total": 0})
        sp = self.serve()
        reply = self.collect_first(sp, jid)
        self.assertEqual((reply["status"], reply["total"], reply["rows"]), ("Stopped", 0, []))
        self.no_search_reply_for(sp, 1.5)

    def test_stopped_but_not_final_continues(self):
        # 1200 rows at once: Stopped from the start, but three pages to read.
        jid = self.start_job({"total": 1200})
        sp = self.serve()
        replies = []
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        replies = self.collect_until_final(sp, jid)
        self.assertEqual([(r["status"], r["offset"], len(r["rows"])) for r in replies],
                         [("Stopped", 0, 500), ("Stopped", 500, 500), ("Stopped", 1000, 200)])
        reads = [parse_qs(e["path"].partition("?")[2]) or e["query"] for e in self.search_reads()]
        self.assertTrue(all(q["limit"] == ["500"] for q in reads), reads)

    def test_the_2000_row_cap(self):
        jid = self.start_job({"total": 2600})
        sp = self.serve()
        sp.send({"cmd": "search", "id": jid, "offset": 1200})
        replies = self.collect_until_final_from(sp, jid, 1200)
        self.assertEqual([(r["offset"], len(r["rows"]), r["capped"], r["total"]) for r in replies],
                         [(1200, 500, True, 2600), (1700, 300, True, 2600)])
        self.assertEqual(replies[-1]["rows"][-1], expected_row(1999))
        reads = [e["query"] for e in self.search_reads()]
        self.assertEqual([(q["offset"], q["limit"]) for q in reads], [(["1200"], ["500"]), (["1700"], ["300"])])
        self.no_search_reply_for(sp, 1.5)

    def collect_until_final_from(self, sp, jid, held):
        replies = []
        while True:
            reply = sp.read_until(is_search, timeout=5)
            self.assertEqual(reply["offset"], held)
            held += len(reply["rows"])
            replies.append(reply)
            if reply["status"] == "Stopped" and held == min(reply["total"], 2000):
                return replies

    def test_at_the_cap_it_reads_status_not_results(self):
        # Running past 2000 rows: the window holds 2000; the sidecar reads
        # status (a results read with limit 0 would return every row).
        jid = self.start_job({"total": 2500, "rate": 2400, "finish": 3})
        time.sleep(1.2)
        sp = self.serve()
        sp.send({"cmd": "search", "id": jid, "offset": 2000})
        replies = self.collect_until_final_from(sp, jid, 2000)
        self.assertTrue(all(r["rows"] == [] and r["capped"] for r in replies))
        self.assertEqual((replies[-1]["status"], replies[-1]["total"]), ("Stopped", 2500))
        paths = {e["path"] for e in self.search_reads()}
        self.assertEqual(paths, {"/api/v2/search/status"})
        self.assertTrue(all(e["query"] == {"id": [str(jid)]} for e in self.search_reads()))

    def test_nothing_is_sent_while_nothing_changes(self):
        jid = self.start_job({"total": 5, "rate": 0, "finish": None})
        sp = self.serve()
        first = self.collect_first(sp, jid)
        self.assertEqual((first["status"], first["total"], first["rows"]), ("Running", 0, []))
        before = len(self.search_reads())
        self.no_search_reply_for(sp, 2.6)
        polls = len(self.search_reads()) - before
        self.assertGreaterEqual(polls, 2, "it keeps polling about once a second")
        # ...and no faster (Ruling FG): about one read a second, never a busy loop.
        self.assertLessEqual(polls, 4, "at most about one read a second")

    def test_a_stalled_read_gives_up_after_one_second(self):
        # Ruling FG: the search read times out after 1 s (like inspect), so
        # a stalled qBittorrent holds the main thread no longer than that.
        jid = self.start_job({"total": 3, "finish": None})
        sp = self.serve()
        self.control({"search_results": "sleep7"})
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        time.sleep(0.2)
        sent = time.monotonic()
        sp.send({"cmd": "refresh"})
        sp.read_until(lambda o: o.get("type") == "status", timeout=5)
        # The refresh can wait out two stalled reads (the answer-at-once one
        # and the next poll, due as it ends): about 1.8 s at 1 s, 3.8 s at 2 s.
        self.assertLess(time.monotonic() - sent, 2.8)

    def test_the_three_minute_cancel_on_a_fake_clock(self):
        spec = {"total": 1000, "rate": 1, "finish": None}
        jid = self.start_job(spec)
        sp = self.serve()
        first = self.collect_first(sp, jid)
        self.assertEqual(first["status"], "Running")
        self.control({"search": spec, "search_clock": 181})
        replies = self.collect_until_final_from(sp, jid, len(first["rows"]))
        last = replies[-1]
        self.assertEqual((last["status"], last["total"]), ("Stopped", 180))
        self.assertEqual(last["offset"] + len(last["rows"]), 180)

    def test_a_restarted_sidecar_resumes_exactly_at_the_windows_offset(self):
        jid = self.start_job({"total": 60, "rate": 10, "finish": None})
        sp = self.serve()
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        held = []
        while len(held) < 10:
            reply = sp.read_until(is_search, timeout=5)
            self.assertEqual(reply["offset"], len(held))
            held += reply["rows"]
        sp.cleanup()
        # A second sidecar knows nothing until the window says where it is.
        sp2 = ServeProcess(self.env)
        self.addCleanup(sp2.cleanup)
        sp2.readline(timeout=5)
        self.no_search_reply_for(sp2, 1.5)
        sp2.send({"cmd": "search", "id": jid, "offset": len(held)})
        reply = sp2.read_until(is_search, timeout=3)
        self.assertEqual(reply["offset"], len(held))
        self.assertTrue(reply["rows"])
        self.assertEqual(reply["rows"][0], expected_row(len(held)))
        self.post("/api/v2/search/stop", f"id={jid}")
        rest = self.collect_until_final_from(sp2, jid, len(held) + len(reply["rows"]))
        rows = held + reply["rows"] + [row for r in rest for row in r["rows"]]
        self.assertEqual(rows, [expected_row(i) for i in range(len(rows))])

    def test_rows_pass_through_untouched(self):
        rows = ROW_CASES + [{"fileName": "‮evil\u0000", "extra": {"nested": [1, None]}, "fileSize": 1.5e300}]
        jid = self.start_job({"rows": rows})
        sp = self.serve()
        reply = self.collect_first(sp, jid)
        self.assertEqual(reply["rows"], rows)
        self.assertEqual((reply["status"], reply["total"]), ("Stopped", len(rows)))

    def test_a_deleted_job_is_gone(self):
        jid = self.start_job({"total": 1, "finish": None})
        sp = self.serve()
        self.collect_first(sp, jid)
        self.post("/api/v2/search/delete", f"id={jid}")
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual(reply, {"type": "search", "id": jid, "error": "gone"})
        count = len(self.search_reads())
        self.no_search_reply_for(sp, 2.2)
        self.assertEqual(len(self.search_reads()), count)

    def test_an_unknown_job_and_an_offset_past_the_end_are_gone(self):
        sp = self.serve()
        self.assertEqual(self.collect_first(sp, 424242), {"type": "search", "id": 424242, "error": "gone"})
        jid = self.start_job({"total": 3})
        count = len(self.search_reads())
        self.assertEqual(self.collect_first(sp, jid, offset=4), {"type": "search", "id": jid, "error": "gone"})
        # A 409 is not a session miss: no reload, no retry.
        self.assertEqual(len(self.search_reads()) - count, 1)

    def test_other_failures_send_nothing_and_retry(self):
        jid = self.start_job({"total": 4})
        sp = self.serve()
        self.control({"search_results": "500"})
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        self.no_search_reply_for(sp, 2.2)
        self.control({"search_results": "unreadable"})
        self.no_search_reply_for(sp, 1.2)
        self.control({})
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual((reply["offset"], len(reply["rows"]), reply["status"]), (0, 4, "Stopped"))

    def test_a_null_id_drops_the_watch_without_a_reply(self):
        jid = self.start_job({"total": 1, "finish": None})
        sp = self.serve()
        self.collect_first(sp, jid, offset=1)
        sp.send({"cmd": "search", "id": None})
        time.sleep(0.3)
        count = len(self.search_reads())
        self.no_search_reply_for(sp, 2.2)
        self.assertEqual(len(self.search_reads()), count)

    def test_a_new_command_replaces_the_watch(self):
        a = self.start_job({"total": 2, "finish": None})
        b = self.start_job({"total": 3, "finish": None})
        sp = self.serve()
        sp.send({"cmd": "search", "id": a, "offset": 0})
        sp.send({"cmd": "search", "id": b, "offset": 1})
        reply = sp.read_until(is_search, timeout=3)
        if reply["id"] == a:
            reply = sp.read_until(is_search, timeout=3)
        self.assertEqual((reply["id"], reply["offset"], len(reply["rows"])), (b, 1, 2))
        # The same command again is answered again (a reply after every command).
        sp.send({"cmd": "search", "id": b, "offset": 3})
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual((reply["id"], reply["offset"], reply["rows"]), (b, 3, []))

    def test_a_search_command_without_an_id_is_bad_and_keeps_the_watch(self):
        # The id key must be present (null or an int): a bare {"cmd":"search"}
        # is not id:null, so it never drops the watch.
        jid = self.start_job({"total": 5, "rate": 1, "finish": None})
        sp = self.serve()
        self.collect_first(sp, jid)
        sp.send({"cmd": "search"})
        reply = sp.read_until(lambda o: o.get("type") == "error", timeout=3)
        self.assertEqual(reply, {"type": "error", "id": None, "error": "bad command"})
        before = len(self.search_reads())
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual(reply["id"], jid)
        self.assertGreater(len(self.search_reads()), before, "the watch is still polling")

    def test_bad_commands(self):
        sp = self.serve()
        for cmd in ({"cmd": "search", "id": "5", "offset": 0},
                    {"cmd": "search", "id": True, "offset": 0},
                    {"cmd": "search", "id": 0, "offset": 0},
                    {"cmd": "search", "id": 2147483648, "offset": 0},
                    {"cmd": "search", "id": 5},
                    {"cmd": "search", "id": 5, "offset": -1},
                    {"cmd": "search", "id": 5, "offset": 2001},
                    {"cmd": "search", "id": 5, "offset": 1.5},
                    {"cmd": "search", "id": 5, "offset": False},
                    {"cmd": "search", "offset": 0},
                    {"cmd": "search"}):
            with self.subTest(cmd=cmd):
                sp.send(cmd)
                reply = sp.read_until(lambda o: o.get("type") in ("error", "search"), timeout=3)
                self.assertEqual(reply, {"type": "error", "id": cmd.get("id"), "error": "bad command"})
        self.assertEqual(self.search_reads(), [])




class SearchSessionTest(SearchWatchCase):
    """Ruling FH, under the API key: qBittorrent 5.2.3 keeps search jobs per
    WebUI session (webapplication.cpp:844, a SearchController per
    WebSession), and an API-key session's id is the key. qbt and the
    sidecar both send the key, so they share one session and the sidecar
    reads qbt's jobs whatever qbt's cookie file holds (qBittorrent sets no
    cookie under the key). The cookie file is still loaded read-only at
    watch-set time and reloaded once on a 404 before `gone`, and a load
    that fails (a half-written file) is still transient: nothing is sent
    and the next tick tries again."""

    def qbt_start(self, spec):
        """`qbt search start`, in the key's session."""
        self.control({"search": spec})
        r = subprocess.run([str(ROOT / "qbt"), "search", "start", "--pattern", "debian", "--category", "all"],
                           env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        return json.loads(r.stdout)["id"]

    def cookie_file(self, name, sid=None):
        """A curl cookie file, holding `sid` (a session the fixture doesn't
        know) or no cookie at all."""
        path = Path(self.env["QBT_STATE_DIR"]).parent / name
        text = "# Netscape HTTP Cookie File\n"
        if sid:
            text += f"#HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\tSID\t{sid}\n"
        path.write_text(text)
        return path

    def serve_on(self, cookie_path=None):
        env = dict(self.env)
        if cookie_path is not None:
            # `qbt probe` reports this file as cookieFile.
            env["QBT_COOKIE_FILE"] = str(cookie_path)
        sp = ServeProcess(env)
        self.addCleanup(sp.cleanup)
        seen = []
        readline = sp.readline

        def recording_readline(timeout=5):
            obj = readline(timeout=timeout)
            seen.append(obj)
            return obj
        sp.readline = recording_readline
        sp.seen = seen
        sp.readline(timeout=5)  # the first status line
        return sp

    def job_reads(self):
        return [e for e in self.search_reads() if e["path"] in ("/api/v2/search/results", "/api/v2/search/status")]

    def assert_no_key(self, sp):
        out = json.dumps(sp.seen) + "".join(sp._stderr_lines)
        self.assertNotIn(harness.FIXTURE_API_KEY, out)

    def test_a_job_qbt_started_streams_through_the_keys_session(self):
        jid = self.qbt_start({"total": 30, "rate": 20, "finish": 1.5})
        sp = self.serve_on()
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        replies = self.collect_until_final(sp, jid)
        rows = [row for r in replies for row in r["rows"]]
        self.assertEqual(rows, [expected_row(i) for i in range(30)])
        self.assertGreater(len(replies), 1, "it streamed while the job ran")
        self.assertTrue(self.job_reads())
        self.assert_no_key(sp)

    def test_any_cookie_file_reads_the_keys_jobs(self):
        jid = self.start_job({"total": 3, "finish": None})
        stranger = self.cookie_file("other-cookies", sid="fixture-999")
        header_only = self.cookie_file("empty-cookies")
        missing = Path(self.env["QBT_STATE_DIR"]).parent / "no-such-cookies"
        for path in (stranger, header_only, missing):
            with self.subTest(jar=path.name):
                before = path.read_bytes() if path.exists() else None
                sp = self.serve_on(path)
                try:
                    sp.send({"cmd": "search", "id": jid, "offset": 0})
                    reply = sp.read_until(is_search, timeout=3)
                    self.assertEqual((reply["status"], reply["offset"], len(reply["rows"])), ("Running", 0, 3))
                finally:
                    sp.cleanup()
                # Read-only: the sidecar never writes curl's file.
                self.assertEqual(path.read_bytes() if path.exists() else None, before)
                self.assert_no_key(sp)

    def test_a_job_outside_the_session_is_gone_after_one_reload(self):
        sp = self.serve_on(self.cookie_file("other-cookies", sid="fixture-999"))
        sp.send({"cmd": "search", "id": 424242, "offset": 0})
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual(reply, {"type": "search", "id": 424242, "error": "gone"})
        # One read, one reload of the file, one retry: then gone.
        self.assertEqual(len(self.job_reads()), 2, self.job_reads())

    def test_a_half_written_cookie_file_is_transient(self):
        jid = self.start_job({"total": 5, "finish": None})
        good = self.cookie_file("good-cookies", sid="fixture-999").read_bytes()
        path = Path(self.env["QBT_STATE_DIR"]).parent / "half-cookies"
        path.write_bytes(b"")
        sp = self.serve_on(path)
        sp.send({"cmd": "search", "id": jid, "offset": 0})
        # An empty file, then one cut off mid-line (a field short):
        # nothing is sent, the watch stays and no job read goes out.
        self.no_search_reply_for(sp, 1.6)
        path.write_bytes(good.rsplit(b"\t", 1)[0])
        self.no_search_reply_for(sp, 1.6)
        self.assertEqual(self.job_reads(), [])
        path.write_bytes(good)
        reply = sp.read_until(is_search, timeout=3)
        self.assertEqual((reply["status"], reply["offset"], len(reply["rows"])), ("Running", 0, 5))
        self.assertEqual(path.read_bytes(), good)
        self.assert_no_key(sp)
        # Not even the stdlib's "cookiejar bug!" warning reaches stderr.
        self.assertEqual(sp._stderr_lines, [])

if __name__ == "__main__":
    unittest.main()
