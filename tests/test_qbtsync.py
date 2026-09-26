#!/usr/bin/env python3
import http.cookiejar
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import qbtsync  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class SanitizeTests(unittest.TestCase):
    def test_redacts_sid(self):
        self.assertEqual(qbtsync.sanitize("set SID=abc123; other"), "set SID=<redacted>; other")

    def test_redacts_sid_case_insensitive(self):
        # Detection is case-insensitive; the replacement text is always the
        # fixed-case "SID=<redacted>", same as bash sanitize().
        self.assertEqual(qbtsync.sanitize("sid=ABC123 done"), "SID=<redacted> done")

    def test_redacts_password(self):
        # The value runs up to the next ";" or whitespace only -- "&" is not
        # a boundary, matching bash sanitize()'s [^;[:space:]]* class.
        self.assertEqual(qbtsync.sanitize("password=hunter2;x=1"), "password=<redacted>;x=1")

    def test_leaves_other_text_alone(self):
        self.assertEqual(qbtsync.sanitize("HTTP 404 not found"), "HTTP 404 not found")


class AssertLocalTests(unittest.TestCase):
    def test_accepts_127001(self):
        qbtsync.assert_local("http://127.0.0.1:8080")  # must not raise

    def test_rejects_lookalike_host(self):
        with self.assertRaises(ValueError) as ctx:
            qbtsync.assert_local("http://127.0.0.1.evil.com")
        self.assertIn("refusing non-localhost host: 127.0.0.1.evil.com", str(ctx.exception))

    def test_rejects_localhost(self):
        with self.assertRaises(ValueError) as ctx:
            qbtsync.assert_local("http://localhost")
        self.assertIn("refusing non-localhost host: localhost", str(ctx.exception))


class MergeMaindataTests(unittest.TestCase):
    def setUp(self):
        self.full = json.loads((FIXTURES / "maindata-full.json").read_text())
        self.delta = json.loads((FIXTURES / "maindata-delta.json").read_text())

    def test_full_update_replaces_cache(self):
        torrents, rows = qbtsync.merge_maindata(self.full, {"stale": {"name": "old"}})
        self.assertNotIn("stale", torrents)
        self.assertEqual(len(rows), 2)
        names = {r["name"] for r in rows}
        self.assertEqual(names, {"debian.iso", "arch.iso"})

    def test_v2_only_torrent_keyed_by_infohash_v2(self):
        raw = {
            "full_update": True,
            "torrents": {
                "somekey": {
                    "name": "v2only",
                    "infohash_v2": "deadbeef" * 8,
                }
            },
        }
        torrents, rows = qbtsync.merge_maindata(raw, {})
        self.assertIn("deadbeef" * 8, torrents)
        self.assertEqual(rows[0]["hash"], "deadbeef" * 8)

    def test_delta_merges_and_keeps_unresent_fields(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        torrents, rows = qbtsync.merge_maindata(self.delta, cache_map)
        debian_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        self.assertIn(debian_hash, torrents)
        row = next(r for r in rows if r["hash"] == debian_hash)
        # delta resent progress/dlspeed/eta only
        self.assertAlmostEqual(row["progress"], 0.5)
        self.assertEqual(row["dlSpeed"], 100)
        self.assertEqual(row["eta"], 600)
        # fields the delta didn't resend must survive from the cache
        self.assertEqual(row["savePath"], "/home/user/Downloads")
        self.assertEqual(row["numSeeds"], 14)
        self.assertEqual(row["addedOn"], 1755300000)

    def test_torrents_removed_drops_keys(self):
        cache_map, _ = qbtsync.merge_maindata(self.full, {})
        torrents, rows = qbtsync.merge_maindata(self.delta, cache_map)
        self.assertNotIn("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", torrents)
        self.assertEqual({r["hash"] for r in rows}, {"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})

    def test_defaults_for_missing_fields(self):
        raw = {
            "full_update": True,
            "torrents": {
                "cccccccccccccccccccccccccccccccccccccccc": {
                    "name": "bare",
                }
            },
        }
        torrents, rows = qbtsync.merge_maindata(raw, {})
        row = rows[0]
        self.assertEqual(row["ratioLimit"], -2)
        self.assertIs(row["seqDl"], False)
        self.assertEqual(row["dlSpeed"], 0)
        self.assertEqual(row["upSpeed"], 0)
        self.assertEqual(row["dlLimit"], 0)
        self.assertEqual(row["upLimit"], 0)
        self.assertEqual(row["numSeeds"], 0)
        self.assertEqual(row["numLeechs"], 0)
        self.assertEqual(row["addedOn"], 0)
        self.assertEqual(row["savePath"], "")
        self.assertEqual(row["magnetUri"], "")
        self.assertEqual(row["contentPath"], "")

    def test_ratio_limit_zero_is_not_default(self):
        raw = {
            "full_update": True,
            "torrents": {
                "dddddddddddddddddddddddddddddddddddddddd": {
                    "name": "zero-ratio",
                    "ratio_limit": 0,
                }
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["ratioLimit"], 0)

    def test_camel_case_speed_fallback(self):
        raw = {
            "full_update": True,
            "torrents": {
                "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": {
                    "name": "camel",
                    "dlSpeed": 55,
                    "upSpeed": 77,
                }
            },
        }
        _, rows = qbtsync.merge_maindata(raw, {})
        self.assertEqual(rows[0]["dlSpeed"], 55)
        self.assertEqual(rows[0]["upSpeed"], 77)


class SyncStateTests(unittest.TestCase):
    def test_load_missing_file_is_empty(self):
        state = qbtsync.SyncState.load("/no/such/path/rid.json")
        self.assertEqual(state.rid, 0)
        self.assertEqual(state.torrents, {})

    def test_load_corrupt_file_is_empty(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                f.write("{not json")
            state = qbtsync.SyncState.load(path)
            self.assertEqual(state.rid, 0)
            self.assertEqual(state.torrents, {})

    def test_save_and_load_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            state = qbtsync.SyncState(rid=5, torrents={"h": {"name": "x"}})
            state.save(path)
            mode = oct(os.stat(path).st_mode & 0o777)
            self.assertEqual(mode, "0o600")
            loaded = qbtsync.SyncState.load(path)
            self.assertEqual(loaded.rid, 5)
            self.assertEqual(loaded.torrents, {"h": {"name": "x"}})

    def test_save_fixes_permissions_on_preexisting_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rid.json")
            with open(path, "w") as f:
                f.write("{}")
            os.chmod(path, 0o644)
            state = qbtsync.SyncState(rid=1, torrents={})
            state.save(path)
            mode = oct(os.stat(path).st_mode & 0o777)
            self.assertEqual(mode, "0o600")


class SlowCacheTests(unittest.TestCase):
    def test_due_when_never_fetched(self):
        cache = qbtsync.SlowCache(interval=30)
        self.assertTrue(cache.due(1000.0))

    def test_due_respects_interval(self):
        cache = qbtsync.SlowCache(interval=30, fetched_at=1000.0)
        self.assertFalse(cache.due(1010.0))
        self.assertTrue(cache.due(1030.0))

    def test_zero_interval_always_due(self):
        cache = qbtsync.SlowCache(interval=0, fetched_at=1000.0)
        self.assertTrue(cache.due(1000.0))
        self.assertTrue(cache.due(1000.5))


class CookieJarRoundTripTests(unittest.TestCase):
    def test_curl_httponly_session_cookie_survives_load_and_save(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cookies")
            with open(path, "w") as f:
                f.write("# Netscape HTTP Cookie File\n")
                f.write("#HttpOnly_127.0.0.1\tFALSE\t/\tFALSE\t0\tSID\tfixture-1\n")

            jar = qbtsync.CurlCookieJar(path)
            jar.load(ignore_discard=True, ignore_expires=True)

            cookies = list(jar)
            self.assertEqual(len(cookies), 1)
            self.assertEqual(cookies[0].value, "fixture-1")

            # The cookie must actually be attachable to a real request, not
            # merely survive as text. curl writes "0" as its no-expiry
            # marker; stock MozillaCookieJar treats that as the Unix epoch
            # and refuses to ever send it again.
            req = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            jar.add_cookie_header(req)
            self.assertEqual(req.get_header("Cookie"), "SID=fixture-1")

            jar.save(ignore_discard=True, ignore_expires=True)
            text = Path(path).read_text()
            self.assertIn("SID\tfixture-1", text)
            self.assertIn("#HttpOnly_127.0.0.1", text)
            # Re-saved file must still be sendable by curl: an empty
            # expires field is dropped by curl's parser, so it must come
            # back out as "0", not "".
            self.assertRegex(text, r"#HttpOnly_127\.0\.0\.1\tFALSE\t/\tFALSE\t0\tSID\tfixture-1")

            reloaded = qbtsync.CurlCookieJar(path)
            reloaded.load(ignore_discard=True, ignore_expires=True)
            req2 = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            reloaded.add_cookie_header(req2)
            self.assertEqual(req2.get_header("Cookie"), "SID=fixture-1")

    def test_new_cookie_from_response_is_saved_as_session(self):
        import email.message

        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cookies")
            jar = qbtsync.CurlCookieJar(path)
            # Simulate receiving a Set-Cookie header, as HTTPCookieProcessor would.
            headers = email.message.Message()
            headers["Set-Cookie"] = "SID=newsid; HttpOnly; Path=/"

            class FakeResponse:
                def info(self):
                    return headers

            req = urllib.request.Request("http://127.0.0.1:8080/api/v2/sync/maindata")
            jar.extract_cookies(FakeResponse(), req)
            jar.save(ignore_discard=True, ignore_expires=True)
            text = Path(path).read_text()
            self.assertIn("0\tSID\tnewsid", text)


class ApiErrorTests(unittest.TestCase):
    def test_carries_code_and_message(self):
        err = qbtsync.ApiError(404, "HTTP 404 not found")
        self.assertEqual(err.code, 404)
        self.assertEqual(err.message, "HTTP 404 not found")

    def test_code_can_be_none(self):
        err = qbtsync.ApiError(None, "connection refused")
        self.assertIsNone(err.code)


class ClientTests(unittest.TestCase):
    def test_refuses_non_local_base(self):
        jar = http.cookiejar.CookieJar()
        with self.assertRaises(ValueError):
            qbtsync.Client("http://example.com", jar)

    @staticmethod
    def _serve_once(handler):
        """Accept exactly one connection on a free localhost port, run
        `handler(conn)` against it, then close. Returns (srv_socket, port,
        thread) so the caller can shut everything down afterward."""
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def run():
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            try:
                handler(conn)
            except OSError:
                pass
            finally:
                conn.close()

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return srv, port, thread

    def test_connection_closed_without_response_raises_api_error(self):
        # The server reads the request, then closes without ever writing a
        # status line: http.client raises RemoteDisconnected from
        # getresponse(), not urllib.error.URLError.
        def handler(conn):
            conn.recv(65536)
            conn.close()

        srv, port, thread = self._serve_once(handler)
        try:
            jar = http.cookiejar.CookieJar()
            client = qbtsync.Client(f"http://127.0.0.1:{port}", jar, timeout=2)
            with self.assertRaises(qbtsync.ApiError) as ctx:
                client.get("/api/v2/sync/maindata?rid=0")
            self.assertIsNone(ctx.exception.code)
            self.assertTrue(ctx.exception.message)
        finally:
            srv.close()
            thread.join(timeout=2)

    def test_connection_hang_past_timeout_raises_api_error(self):
        # The server accepts and reads the request but never responds:
        # resp.read()/getresponse() times out with a raw TimeoutError, not
        # urllib.error.URLError.
        release = threading.Event()

        def handler(conn):
            conn.recv(65536)
            release.wait(2)

        srv, port, thread = self._serve_once(handler)
        try:
            jar = http.cookiejar.CookieJar()
            client = qbtsync.Client(f"http://127.0.0.1:{port}", jar, timeout=0.2)
            with self.assertRaises(qbtsync.ApiError) as ctx:
                client.get("/api/v2/sync/maindata?rid=0")
            self.assertIsNone(ctx.exception.code)
            self.assertTrue(ctx.exception.message)
        finally:
            release.set()
            srv.close()
            thread.join(timeout=2)


class BuildStatusTests(unittest.TestCase):
    """Exercises build_status against a fake Client so no network is used."""

    class FakeClient:
        def __init__(self, responses):
            # responses: dict path -> (str body) or ApiError instance to raise
            self.responses = responses
            self.calls = []

        def get(self, path):
            self.calls.append(path)
            resp = self.responses.get(path)
            if isinstance(resp, qbtsync.ApiError):
                raise resp
            if resp is None:
                raise qbtsync.ApiError(404, "HTTP 404 not found")
            return resp

    def base_probe(self, **overrides):
        probe = {
            "installed": True,
            "daemon": True,
            "lockHolder": "nox",
            "vpnIface": "",
        }
        probe.update(overrides)
        return probe

    def test_skips_maindata_when_not_installed(self):
        probe = self.base_probe(installed=False)
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["api"], False)
        self.assertEqual(status["torrents"], [])
        self.assertEqual(errors, [])
        self.assertEqual(client.calls, [])

    def test_skips_maindata_when_lock_holder_is_gui(self):
        probe = self.base_probe(lockHolder="gui")
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["api"], False)
        self.assertEqual(client.calls, [])

    def test_successful_maindata_sets_api_true_and_speeds(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["dlSpeed"], 2202009)
        self.assertEqual(len(status["torrents"]), 2)
        self.assertTrue(status["altSpeed"])
        self.assertEqual(errors, [])
        self.assertEqual(sync.rid, 1)
        # no VPN iface configured: no preferences call at all
        self.assertNotIn("/api/v2/app/preferences", client.calls)
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")

    def test_maindata_failure_leaves_api_false_and_reports_error(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": qbtsync.ApiError(403, "localhost auth is required"),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(status["dlSpeed"], 0)
        self.assertEqual(status["torrents"], [])
        self.assertEqual(errors, ["localhost auth is required"])
        # slow-poll calls never happen when maindata itself failed
        self.assertNotIn("/api/v2/transfer/speedLimitsMode", client.calls)

    def test_maindata_failure_does_not_reset_existing_rid(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=7": qbtsync.ApiError(None, "connection refused"),
        })
        sync = qbtsync.SyncState(rid=7, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(sync.rid, 7)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})

    def test_vpn_iface_reports_bind_iface_on_success(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "0",
            "/api/v2/app/preferences": json.dumps({"current_network_interface": "wg0-mullvad"}),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["vpnIface"], "wg0-mullvad")
        self.assertEqual(status["bindIface"], "wg0-mullvad")
        self.assertFalse(status["altSpeed"])
        self.assertEqual(errors, [])

    def test_vpn_iface_clears_on_preferences_failure(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": qbtsync.ApiError(None, "connection refused"),
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertIn("connection refused", errors)

    def test_maindata_non_json_body_is_treated_as_failed_call(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": "<html",
        })
        sync = qbtsync.SyncState(rid=3, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(status["torrents"], [])
        # sync must stay exactly as it was: never partially applied.
        self.assertEqual(sync.rid, 3)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})
        self.assertTrue(errors)
        # the slow-poll calls are gated on api being True, so a malformed
        # maindata body must not trigger them either.
        self.assertNotIn("/api/v2/transfer/speedLimitsMode", client.calls)

    def test_maindata_non_object_json_is_treated_as_failed_call(self):
        probe = self.base_probe()
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": "[]",
        })
        sync = qbtsync.SyncState(rid=3, torrents={"h": {"name": "x"}})
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertFalse(status["api"])
        self.assertEqual(sync.rid, 3)
        self.assertEqual(sync.torrents, {"h": {"name": "x"}})
        self.assertTrue(errors)

    def test_preferences_non_json_body_clears_vpn_iface(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": "<html",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertTrue(errors)

    def test_preferences_non_object_json_clears_vpn_iface(self):
        full = json.loads((FIXTURES / "maindata-full.json").read_text())
        probe = self.base_probe(vpnIface="wg0-mullvad")
        client = self.FakeClient({
            "/api/v2/sync/maindata?rid=0": json.dumps(full),
            "/api/v2/transfer/speedLimitsMode": "1",
            "/api/v2/app/preferences": "[]",
        })
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, errors = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertTrue(status["api"])
        self.assertEqual(status["vpnIface"], "")
        self.assertEqual(status["bindIface"], "")
        self.assertTrue(errors)

    def test_key_order(self):
        probe = self.base_probe(installed=False)
        client = self.FakeClient({})
        sync = qbtsync.SyncState()
        slow = qbtsync.SlowCache(interval=0)
        status, _ = qbtsync.build_status(probe, client, sync, slow, 1000.0)
        self.assertEqual(
            list(status.keys()),
            ["installed", "daemon", "lockHolder", "api", "altSpeed", "dlSpeed",
             "upSpeed", "torrents", "vpnIface", "bindIface"],
        )


if __name__ == "__main__":
    unittest.main()
