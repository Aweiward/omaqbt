#!/usr/bin/env python3
import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent / "fixtures"))
import harness  # noqa: E402

QBT_SERVE = str(ROOT / "qbt-serve")


class ServeProcess:
    """Wraps a `./qbt-serve` subprocess: a background thread pumps stdout
    lines (parsed as JSON) onto a queue, and stderr is drained onto a list
    so a slow/chatty child never blocks on a full pipe and so failures can
    show what the sidecar printed. Only the test thread sends commands and
    only `cleanup()` tears the process down, always via try/finally."""

    def __init__(self, env, args=None):
        self.proc = subprocess.Popen(
            [QBT_SERVE, *(args or [])],
            cwd=str(ROOT),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self._lines = queue.Queue()
        self._stderr_lines = []
        self._out_thread = threading.Thread(target=self._pump_stdout, daemon=True)
        self._err_thread = threading.Thread(target=self._pump_stderr, daemon=True)
        self._out_thread.start()
        self._err_thread.start()

    def _pump_stdout(self):
        try:
            for line in self.proc.stdout:
                self._lines.put(line)
        except Exception:
            pass

    def _pump_stderr(self):
        try:
            for line in self.proc.stderr:
                self._stderr_lines.append(line)
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self.cleanup()

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def readline(self, timeout=5):
        try:
            raw = self._lines.get(timeout=timeout)
        except queue.Empty:
            raise AssertionError(
                f"qbt-serve produced no output within {timeout}s; "
                f"stderr so far: {''.join(self._stderr_lines)!r}"
            )
        return json.loads(raw)

    def read_until(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(
                    f"condition not met within {timeout}s; "
                    f"stderr so far: {''.join(self._stderr_lines)!r}"
                )
            obj = self.readline(timeout=remaining)
            if predicate(obj):
                return obj

    def close_stdin(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass

    def cleanup(self):
        self.close_stdin()
        try:
            self.proc.terminate()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
                self.proc.wait(timeout=5)
            except Exception:
                pass
        for stream in (self.proc.stdout, self.proc.stderr):
            try:
                stream.close()
            except Exception:
                pass
        self._out_thread.join(timeout=2)
        self._err_thread.join(timeout=2)


def _write_control(path, mapping):
    """Write the fixture's per-route fault map atomically (write-then-
    rename), so the fixture server -- which re-reads this file on every
    request -- never observes a half-written file."""
    tmp = str(path) + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(mapping))
    os.replace(tmp, str(path))


def _read_log(path, tries=20, delay=0.05):
    """Read the fixture's JSON request log, retrying briefly on a
    malformed (or transiently truncated-empty) read: `record()`'s
    read-modify-write isn't atomic on disk, so a reader landing between
    its truncate and its write can see "" or a partial document. Every
    caller here reads the log only after at least one request has already
    landed, so an empty read is always that race, never a legitimate empty
    log -- retry it instead of returning `[]` and masking a missed entry."""
    last_exc = None
    for _ in range(tries):
        text = Path(path).read_text()
        if not text:
            last_exc = ValueError("empty read")
            time.sleep(delay)
            continue
        try:
            return json.loads(text)
        except ValueError as exc:
            last_exc = exc
            time.sleep(delay)
    raise AssertionError(f"could not read a well-formed, non-empty log at {path}: {last_exc}")


class FirstStatusLineTests(unittest.TestCase):
    def test_first_line_is_full_status(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                line = sp.readline(timeout=5)
                self.assertEqual(line["type"], "status")
                self.assertTrue(line["api"])
                self.assertEqual(len(line["torrents"]), 2)
                self.assertEqual(line["dlSpeed"], 2202009)
                # "type" first, then the status keys in build_status's order.
                self.assertEqual(
                    list(line.keys()),
                    ["type", "installed", "daemon", "lockHolder", "api", "altSpeed",
                     "dlSpeed", "upSpeed", "torrents", "vpnIface", "bindIface",
                     "categories", "tags"],
                )


class RefreshTests(unittest.TestCase):
    def test_refresh_reuses_session_and_gets_delta(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertEqual(first["dlSpeed"], 2202009)
                sp.send({"cmd": "refresh"})
                second = sp.read_until(lambda o: o.get("type") == "status", timeout=5)
                self.assertEqual(second["dlSpeed"], 100)


class CadenceTests(unittest.TestCase):
    def test_cadence_speeds_up_ticks(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()  # first status, at the default cadence
                sp.send({"cmd": "cadence", "ms": 200})
                deadline = time.monotonic() + 1.5
                count = 0
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "status":
                        count += 1
                self.assertGreaterEqual(count, 3)


class HeartbeatTests(unittest.TestCase):
    def test_heartbeat_within_six_seconds(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                hb = sp.read_until(lambda o: o.get("type") == "heartbeat", timeout=6)
                self.assertEqual(hb, {"type": "heartbeat"})


class FilesCommandTests(unittest.TestCase):
    def test_valid_hash_returns_files(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"id": 1, "cmd": "files", "hash": h})
                resp = sp.read_until(lambda o: o.get("type") == "files", timeout=5)
                self.assertEqual(resp["id"], 1)
                self.assertEqual(resp["hash"], h)
                self.assertIsInstance(resp["files"], list)
                self.assertTrue(resp["files"])

    def test_invalid_hash_is_bad_command(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                sp.send({"id": 2, "cmd": "files", "hash": "not-a-hash"})
                resp = sp.read_until(lambda o: o.get("type") == "error", timeout=5)
                self.assertEqual(resp["id"], 2)
                self.assertEqual(resp["error"], "bad command")


class UnknownCommandTests(unittest.TestCase):
    def test_unknown_cmd_is_bad_command(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                sp.send({"cmd": "bogus"})
                resp = sp.read_until(lambda o: o.get("type") == "error", timeout=5)
                self.assertIsNone(resp["id"])
                self.assertEqual(resp["error"], "bad command")

    def test_invalid_json_is_bad_command(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                sp.proc.stdin.write("{not json}\n")
                sp.proc.stdin.flush()
                resp = sp.read_until(lambda o: o.get("type") == "error", timeout=5)
                self.assertIsNone(resp["id"])
                self.assertEqual(resp["error"], "bad command")


class ShutdownTests(unittest.TestCase):
    def test_stdin_eof_exits_quickly(self):
        with harness.fixture_server() as (port, env):
            sp = ServeProcess(env)
            try:
                sp.readline()
                start = time.monotonic()
                sp.close_stdin()
                sp.proc.wait(timeout=2)
                elapsed = time.monotonic() - start
                self.assertEqual(sp.proc.returncode, 0)
                self.assertLess(elapsed, 1.0)
            finally:
                sp.cleanup()


class BrokenPipeTests(unittest.TestCase):
    """A dead stdout reader (BrokenPipeError on write) must exit 0 without
    tripping interpreter finalization over the daemon reader thread."""

    def test_closed_stdout_exits_cleanly(self):
        with harness.fixture_server() as (port, env):
            proc = subprocess.Popen(
                [QBT_SERVE],
                cwd=str(ROOT),
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            try:
                line = proc.stdout.readline()
                self.assertTrue(line)
                proc.stdout.close()
                # Force an immediate write attempt against the now-closed
                # pipe instead of waiting out the default 5s cadence.
                proc.stdin.write(json.dumps({"cmd": "refresh"}) + "\n")
                proc.stdin.flush()
                proc.wait(timeout=5)
                self.assertEqual(proc.returncode, 0)
                stderr_text = proc.stderr.read()
                self.assertNotIn("Fatal", stderr_text)
            finally:
                for closer in (proc.stdin, proc.stderr):
                    try:
                        closer.close()
                    except Exception:
                        pass
                try:
                    proc.terminate()
                    proc.wait(timeout=5)
                except Exception:
                    pass


class LockTests(unittest.TestCase):
    def test_second_instance_reports_locked(self):
        with harness.fixture_server() as (port, env):
            first = ServeProcess(env)
            try:
                first.readline()  # up and holding the lock
                start = time.monotonic()
                second = ServeProcess(env)
                try:
                    fatal = second.read_until(lambda o: o.get("type") == "fatal", timeout=4)
                    second.proc.wait(timeout=4)
                    elapsed = time.monotonic() - start
                    self.assertEqual(fatal["error"], "locked")
                    self.assertEqual(second.proc.returncode, 3)
                    self.assertLess(elapsed, 4.0)
                finally:
                    second.cleanup()
            finally:
                first.cleanup()


class ApiDownTests(unittest.TestCase):
    def test_api_goes_false_when_fixture_stops(self):
        proc, port, env, cleanup = harness.start_fixture_server()
        try:
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertTrue(first["api"])
                proc.terminate()
                proc.wait(timeout=5)
                sp.send({"cmd": "refresh"})
                second = sp.read_until(lambda o: o.get("type") == "status", timeout=5)
                self.assertFalse(second["api"])
                self.assertIsNone(sp.proc.poll())
        finally:
            cleanup()


# Every proxy variable points at the discard port, where nothing listens:
# a request that honours any of them fails instead of reaching the fixture.
_DEAD_PROXY_ENV = {
    "http_proxy": "http://127.0.0.1:9",
    "HTTP_PROXY": "http://127.0.0.1:9",
    "all_proxy": "http://127.0.0.1:9",
    "ALL_PROXY": "http://127.0.0.1:9",
    "no_proxy": "",
    "NO_PROXY": "",
}


class ProxyBypassTests(unittest.TestCase):
    def test_status_ignores_http_proxy(self):
        with harness.fixture_server(extra_env=_DEAD_PROXY_ENV) as (port, env):
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertEqual(first["type"], "status")
                self.assertTrue(first["api"])

    def test_bash_api_ignores_http_proxy(self):
        with harness.fixture_server(extra_env=_DEAD_PROXY_ENV) as (port, env):
            result = subprocess.run(
                [str(ROOT / "qbt"), "files", "a" * 40],
                cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsInstance(json.loads(result.stdout), list)


class RefreshReprobeTests(unittest.TestCase):
    def test_refresh_reprobes_before_probe_interval(self):
        with harness.fixture_server() as (port, env):
            tmp = Path(env["QBT_STATE_DIR"]).parent
            daemon_file = tmp / "daemon-flag"
            daemon_file.write_text("0")
            # Stands in for `qbt` so the test controls what `qbt probe`
            # reports for the daemon, the way Start daemon flips it live.
            stub = tmp / "qbt-stub"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                f"QBT_DAEMON=$(cat '{daemon_file}') exec '{ROOT / 'qbt'}' \"$@\"\n"
            )
            stub.chmod(0o700)
            env = dict(env, QBT_HELPER=str(stub))
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertFalse(first["daemon"])
                self.assertFalse(first["api"])
                daemon_file.write_text("1")
                sp.send({"cmd": "refresh"})
                second = sp.read_until(lambda o: o.get("type") == "status", timeout=2)
                self.assertTrue(second["daemon"])
                self.assertTrue(second["api"])


class LocalhostGuardTests(unittest.TestCase):
    def test_non_local_base_is_fatal(self):
        with harness.fixture_server(extra_env={"QBT_BASE": "http://10.0.0.1:1"}) as (port, env):
            with ServeProcess(env) as sp:
                fatal = sp.read_until(lambda o: o.get("type") == "fatal", timeout=5)
                sp.proc.wait(timeout=5)
                self.assertEqual(sp.proc.returncode, 2)
                self.assertIn("refusing non-localhost host", fatal["error"])


class HarnessSafeDefaultsTests(unittest.TestCase):
    """harness.fixture_server() must point the magnet inbox, the bar raise
    and notify-send at throwaway stubs by default, so a regression in a
    test can never write the real inbox or raise the real bar."""

    MAGNET = "magnet:?xt=urn:btih:" + "c" * 40

    def test_defaults_are_temp_stubs(self):
        with harness.fixture_server() as (port, env):
            tmp_root = Path(env["QBT_STATE_DIR"]).parent
            for name in ("QBT_MAGNET_STATE", "QBT_RAISE_CMD", "QBT_NOTIFY_CMD"):
                self.assertIn(name, env)
                self.assertTrue(Path(env[name]).is_relative_to(tmp_root), (name, env[name]))
            result = subprocess.run(
                [str(ROOT / "qbt"), "magnet-inbox", self.MAGNET],
                cwd=str(ROOT), env=env, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            inbox = Path(env["QBT_MAGNET_STATE"]) / "magnet-inbox.jsonl"
            self.assertIn(self.MAGNET, inbox.read_text())
            self.assertNotEqual((tmp_root / "raise.log").read_text(), "")
        self.assertFalse(tmp_root.exists())

    def test_callers_can_still_override(self):
        other = tempfile.mkdtemp(prefix="qbt-harness-override-")
        try:
            with harness.fixture_server(extra_env={"QBT_MAGNET_STATE": other}) as (port, env):
                self.assertEqual(env["QBT_MAGNET_STATE"], other)
        finally:
            import shutil
            shutil.rmtree(other, ignore_errors=True)


class NoPreferencesCallTests(unittest.TestCase):
    def test_no_vpn_iface_skips_preferences(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertEqual(first["vpnIface"], "")
                log_path = Path(env["QBT_FIXTURE_LOG"])
                entries = json.loads(log_path.read_text() or "[]")
                paths = {e["path"] for e in entries}
                self.assertNotIn("/api/v2/app/preferences", paths)


def _stalling_socket():
    """A TCP listener that accepts a connection and then never writes a
    byte or closes it -- simulating a qBittorrent daemon that accepted
    the socket but is stuck. Returns (port, cleanup)."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    port = srv.getsockname()[1]
    stop = threading.Event()
    held = []

    def run():
        srv.settimeout(0.2)
        while not stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            held.append(conn)  # accept and hold forever; never respond

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def cleanup():
        stop.set()
        thread.join(timeout=2)
        for conn in held:
            try:
                conn.close()
            except Exception:
                pass
        try:
            srv.close()
        except Exception:
            pass

    return port, cleanup


class StalledDaemonTests(unittest.TestCase):
    """Regression test: a daemon that accepts a connection and then never
    answers must not starve the heartbeat, and stdin EOF must still exit
    the process quickly even while the main thread is blocked in that
    HTTP call (or a `qbt probe` reprobe)."""

    def test_heartbeat_and_shutdown_survive_a_stalled_daemon(self):
        port, stalling_cleanup = _stalling_socket()
        try:
            with harness.fixture_server(extra_env={"QBT_BASE": f"http://127.0.0.1:{port}"}) as (_, env):
                start = time.monotonic()
                sp = ServeProcess(env)
                try:
                    hb = sp.read_until(lambda o: o.get("type") == "heartbeat", timeout=6)
                    self.assertEqual(hb, {"type": "heartbeat"})
                    self.assertLess(time.monotonic() - start, 6.0)

                    # Start a fresh blocking call and give it time to
                    # actually land inside client.get() against the
                    # stalling socket, so closing stdin next is provably
                    # racing a main thread stuck in HTTP, not an idle one.
                    sp.send({"cmd": "refresh"})
                    time.sleep(0.3)

                    eof_start = time.monotonic()
                    sp.close_stdin()
                    sp.proc.wait(timeout=2)
                    elapsed = time.monotonic() - eof_start
                    self.assertEqual(sp.proc.returncode, 0)
                    self.assertLess(elapsed, 1.0)
                finally:
                    sp.cleanup()
        finally:
            stalling_cleanup()


class WatchInfoTests(unittest.TestCase):
    def test_watch_info_returns_props_and_pieces_then_pieces_null_next_tick(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()  # first status
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "info"})
                first = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(first["hash"], h)
                self.assertEqual(first["tab"], "info")
                self.assertNotIn("error", first)
                self.assertIsInstance(first["props"], dict)
                self.assertTrue(first["props"])
                self.assertIsInstance(first["pieces"], list)
                self.assertTrue(first["pieces"])

                # Speed up ticking so the *next* tick (well inside the 5s
                # pieceStates interval) lands soon.
                sp.send({"cmd": "cadence", "ms": 1000})
                second = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(second["tab"], "info")
                self.assertNotIn("error", second)
                self.assertIsInstance(second["props"], dict)
                self.assertIsNone(second["pieces"])

    def test_pieces_are_reread_about_every_five_seconds(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()  # first status
                h = "a" * 40
                start = time.monotonic()
                sp.send({"cmd": "watch", "hash": h, "tab": "info"})
                first = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertIsInstance(first["pieces"], list)  # the immediate read always has it

                # Tick fast enough that a null-pieces tick would show up
                # well before a true 5s reread could, so its arrival time
                # actually reflects the pieceStates interval, not the
                # cadence.
                sp.send({"cmd": "cadence", "ms": 1000})
                elapsed_at_next_pieces = None
                deadline = start + 9.0
                while time.monotonic() < deadline:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    obj = sp.readline(timeout=remaining)
                    if (
                        obj.get("type") == "inspect"
                        and obj.get("tab") == "info"
                        and obj.get("pieces") is not None
                    ):
                        elapsed_at_next_pieces = time.monotonic() - start
                        break
                self.assertIsNotNone(elapsed_at_next_pieces, "no reread within 9s")
                self.assertGreater(elapsed_at_next_pieces, 3.5)
                self.assertLess(elapsed_at_next_pieces, 7.5)


class WatchTrackersTests(unittest.TestCase):
    def test_watch_trackers_returns_trackers_payload(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "trackers"})
                resp = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(resp["hash"], h)
                self.assertEqual(resp["tab"], "trackers")
                self.assertNotIn("error", resp)
                self.assertIsInstance(resp["trackers"], list)
                self.assertEqual(resp["trackers"][0]["url"], "** [DHT] **")
                self.assertEqual(resp["trackers"][1]["url"], "** [PeX] **")
                self.assertEqual(resp["trackers"][2]["url"], "** [LSD] **")

                entries = _read_log(env["QBT_FIXTURE_LOG"])
                tracker_reqs = [e for e in entries if e["path"] == "/api/v2/torrents/trackers"]
                self.assertTrue(tracker_reqs)
                self.assertEqual(tracker_reqs[-1]["query"].get("hash"), [h])


class WatchPeersTests(unittest.TestCase):
    def test_watch_peers_returns_peers_object_with_rid0(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "peers"})
                resp = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(resp["hash"], h)
                self.assertEqual(resp["tab"], "peers")
                self.assertNotIn("error", resp)
                self.assertIsInstance(resp["peers"], dict)
                self.assertIn("203.0.113.5:51413", resp["peers"])

                entries = _read_log(env["QBT_FIXTURE_LOG"])
                peer_reqs = [e for e in entries if e["path"] == "/api/v2/sync/torrentPeers"]
                self.assertTrue(peer_reqs)
                self.assertEqual(peer_reqs[-1]["query"].get("rid"), ["0"])
                self.assertEqual(peer_reqs[-1]["query"].get("hash"), [h])


class WatchChartTests(unittest.TestCase):
    """The chart tab reads Task 8's speedhist buffer, never the network
    (F9): the buffer is fed from maindata in do_tick, so watching chart
    itself makes no HTTP call at all, whichever hash it's for."""

    def _assert_no_chart_http_calls(self, env):
        entries = _read_log(env["QBT_FIXTURE_LOG"])
        paths = {e["path"] for e in entries}
        self.assertNotIn("/api/v2/torrents/properties", paths)
        self.assertNotIn("/api/v2/torrents/pieceStates", paths)
        self.assertNotIn("/api/v2/torrents/trackers", paths)
        self.assertNotIn("/api/v2/sync/torrentPeers", paths)

    def test_watch_chart_returns_points_for_a_torrent_with_traffic(self):
        # "a" * 40 is maindata-full.json's debian.iso (infohash_v1), whose
        # dlspeed (1887436, upspeed 0) is non-zero on the very first tick --
        # so by the time this watch is answered, its buffer already holds
        # that sample.
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "chart"})
                resp = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(resp["hash"], h)
                self.assertEqual(resp["tab"], "chart")
                self.assertNotIn("error", resp)
                self.assertIsInstance(resp["points"], list)
                self.assertGreater(len(resp["points"]), 0)
                last = resp["points"][-1]
                self.assertEqual(last[1], 1887436)
                self.assertEqual(last[2], 0)

                self._assert_no_chart_http_calls(env)

    def test_watch_chart_returns_empty_points_for_a_torrent_with_no_samples(self):
        # Not in maindata at all, so it never gets a buffer.
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "c" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "chart"})
                resp = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(
                    resp, {"type": "inspect", "hash": h, "tab": "chart", "points": []}
                )

                self._assert_no_chart_http_calls(env)


class SpeedHistApiGuardTests(unittest.TestCase):
    """do_tick only feeds the speedhist buffer when maindata was actually
    re-fetched this tick (`status["api"]` true) -- a failed fetch must
    neither grow the buffer with a stale replay nor wipe it outright."""

    def test_a_failed_maindata_fetch_neither_grows_nor_wipes_the_buffer(self):
        # do_tick calls read_inspect() -- and so emits one "inspect" line
        # for the active watch -- on *every* tick, not just when a watch
        # command arrives; at a 200ms cadence that is many lines during a
        # ~1s fault window. Reading every one of them (rather than
        # resending "watch" and taking whatever inspect line happens to be
        # sitting oldest in the backlog) checks the buffer is untouched on
        # each individual tick while maindata fails, not just at a single
        # sampled instant.
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()  # the first tick already sampled debian.iso
                h = "a" * 40
                sp.send({"cmd": "cadence", "ms": 200})
                sp.send({"cmd": "watch", "hash": h, "tab": "chart"})
                first = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                baseline = first["points"]
                self.assertGreater(len(baseline), 0)

                _write_control(env["QBT_FIXTURE_CONTROL"], {"maindata": "404"})
                deadline = time.monotonic() + 1.2
                saw_any = False
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "inspect" and obj.get("tab") == "chart":
                        saw_any = True
                        self.assertEqual(
                            obj["points"], baseline,
                            "no growth, no wipe, no duplication while maindata fails",
                        )
                self.assertTrue(saw_any, "no chart inspect line arrived during the fault window")

                # Restore the route; the next tick that lands in a new
                # whole second grows the buffer again, with the earlier
                # samples still exactly as they were.
                _write_control(env["QBT_FIXTURE_CONTROL"], {"maindata": "ok"})
                grown = sp.read_until(
                    lambda o: o.get("type") == "inspect" and o.get("tab") == "chart"
                    and len(o.get("points") or []) > len(baseline),
                    timeout=5,
                )
                self.assertEqual(
                    grown["points"][: len(baseline)], baseline,
                    "the samples taken before the failure are untouched",
                )

    def test_gui_lock_holder_never_calls_maindata_or_creates_a_buffer(self):
        # lockHolder "gui" makes build_status skip the maindata fetch
        # outright (api always False), the other, cheaper way to reach the
        # same guard: record() must never run, so a torrent that would
        # otherwise get a buffer (debian.iso, dlspeed 1887436) never does.
        with harness.fixture_server(extra_env={"QBT_LOCK": "gui"}) as (port, env):
            with ServeProcess(env) as sp:
                first = sp.readline()
                self.assertEqual(first.get("api"), False)
                h = "a" * 40
                sp.send({"cmd": "cadence", "ms": 200})
                sp.send({"cmd": "watch", "hash": h, "tab": "chart"})
                deadline = time.monotonic() + 0.8
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "inspect" and obj.get("tab") == "chart":
                        self.assertEqual(obj["points"], [], "no buffer while api is always false")

                # The harness's own readiness probe (start_fixture_server)
                # makes exactly one maindata GET before the sidecar even
                # starts; qbt-serve itself must add no more.
                entries = _read_log(env["QBT_FIXTURE_LOG"])
                maindata_reqs = [e for e in entries if e["path"] == "/api/v2/sync/maindata"]
                self.assertEqual(len(maindata_reqs), 1, "only the harness's readiness check")


class WatchCollapseTests(unittest.TestCase):
    def test_five_queued_watches_collapse_to_the_last(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                hashes = [c * 40 for c in "abcde"]
                # Written and flushed in one shot, before reading anything,
                # so the reader thread has queued all five before the main
                # thread (busy with the first tick) gets to drain them --
                # the same race the batch collapse has to survive live.
                payload = "".join(
                    json.dumps({"cmd": "watch", "hash": h, "tab": "trackers"}) + "\n"
                    for h in hashes
                )
                sp.proc.stdin.write(payload)
                sp.proc.stdin.flush()

                sp.readline()  # first status
                resp = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertEqual(resp["hash"], hashes[-1])

                # No other inspect line should follow for the dropped watches.
                extra_inspects = []
                deadline = time.monotonic() + 1.0
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "inspect":
                        extra_inspects.append(obj)
                self.assertEqual(extra_inspects, [])

                entries = _read_log(env["QBT_FIXTURE_LOG"])
                seen_hashes = {
                    e["query"].get("hash", [None])[0]
                    for e in entries
                    if e["path"] == "/api/v2/torrents/trackers"
                }
                self.assertEqual(seen_hashes, {hashes[-1]})


class WatchClearTests(unittest.TestCase):
    def test_hash_null_stops_inspect_lines(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "info"})
                sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)

                sp.send({"cmd": "watch", "hash": None, "tab": "info"})
                sp.send({"cmd": "cadence", "ms": 300})

                deadline = time.monotonic() + 2.0
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    self.assertNotEqual(obj.get("type"), "inspect")


class WatchBadCommandTests(unittest.TestCase):
    def test_bad_hash_is_bad_command(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                sp.send({"id": 21, "cmd": "watch", "hash": "not-a-hash", "tab": "info"})
                resp = sp.read_until(lambda o: o.get("type") == "error", timeout=5)
                self.assertEqual(resp["id"], 21)
                self.assertEqual(resp["error"], "bad command")

    def test_bad_tab_is_bad_command(self):
        with harness.fixture_server() as (port, env):
            with ServeProcess(env) as sp:
                sp.readline()
                sp.send({"id": 22, "cmd": "watch", "hash": "a" * 40, "tab": "bogus"})
                resp = sp.read_until(lambda o: o.get("type") == "error", timeout=5)
                self.assertEqual(resp["id"], 22)
                self.assertEqual(resp["error"], "bad command")


class StatusFirstTests(unittest.TestCase):
    """A stalled inspect route (trackers, sleeping 3s -- longer than the
    fixture's HTTP handling of any other route, in particular
    sync/maindata) must never delay the status stream: the inspect read
    uses its own 1s-timeout client, and status keeps arriving on (roughly)
    its cadence regardless. This is also the regression test for Ruling E
    (ThreadingHTTPServer): with the old single-threaded HTTPServer, the
    sleeping trackers handler would hold the whole fixture process, and
    maindata (hence every status line) would stall behind it too."""

    def test_status_keeps_cadence_while_trackers_stall(self):
        with harness.fixture_server() as (port, env):
            _write_control(env["QBT_FIXTURE_CONTROL"], {"trackers": "sleep3"})
            with ServeProcess(env) as sp:
                sp.readline()
                sp.send({"cmd": "cadence", "ms": 1000})
                h = "a" * 40
                start = time.monotonic()
                sp.send({"cmd": "watch", "hash": h, "tab": "trackers"})
                err = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                elapsed = time.monotonic() - start
                self.assertIn("error", err)
                # An error line still carries hash/tab: Task 3's Service
                # keys replies by (hash, tab) to drop a stale one, and that
                # guard needs these fields on an error line too.
                self.assertEqual(err["hash"], h)
                self.assertEqual(err["tab"], "trackers")
                # The inspect client's own timeout is ~1s: tight enough to
                # tell "timed out at 1s" apart from "the fixture answered
                # after its 3s sleep", without pinning an exact number.
                self.assertGreater(elapsed, 0.5)
                self.assertLess(elapsed, 2.5)

                # Status keeps arriving with no gap anywhere near the 3s
                # stall: measure the time between consecutive status
                # lines over several seconds, not just their count (a
                # single-threaded fixture can fall behind and then emit a
                # burst of status lines back-to-back once it catches up,
                # which would pass a bare count check).
                timestamps = []
                deadline = time.monotonic() + 9.0
                while len(timestamps) < 7 and time.monotonic() < deadline:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    obj = sp.readline(timeout=remaining)
                    if obj.get("type") == "status":
                        timestamps.append(time.monotonic())
                self.assertGreaterEqual(len(timestamps), 5)
                gaps = [b - a for a, b in zip(timestamps, timestamps[1:])]
                self.assertLess(max(gaps), 2.5, gaps)


class WatchBackoffTests(unittest.TestCase):
    def test_errors_are_rate_limited_and_recover(self):
        with harness.fixture_server() as (port, env):
            _write_control(env["QBT_FIXTURE_CONTROL"], {"trackers": "404"})
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "trackers"})
                first_err = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertIn("error", first_err)

                sp.send({"cmd": "cadence", "ms": 200})
                # Well inside the 5s back-off window: no further inspect
                # line should appear at all, even though ticks now fire
                # every 200ms.
                extra = []
                deadline = time.monotonic() + 3.0
                while time.monotonic() < deadline:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "inspect":
                        extra.append(obj)
                self.assertEqual(extra, [])

                # Recover the route; once the back-off window elapses the
                # next read succeeds.
                _write_control(env["QBT_FIXTURE_CONTROL"], {"trackers": "ok"})
                recovered = sp.read_until(
                    lambda o: o.get("type") == "inspect" and "trackers" in o, timeout=10
                )
                self.assertNotIn("error", recovered)
                self.assertIsInstance(recovered["trackers"], list)

    def test_identical_watch_during_backoff_produces_no_line(self):
        with harness.fixture_server() as (port, env):
            _write_control(env["QBT_FIXTURE_CONTROL"], {"trackers": "404"})
            with ServeProcess(env) as sp:
                sp.readline()
                h = "a" * 40
                sp.send({"cmd": "watch", "hash": h, "tab": "trackers"})
                first_err = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertIn("error", first_err)

                # Re-sending the *identical* watch (same hash, same tab)
                # must not reset the still-running back-off: no line at
                # all within 1s, well short of the 5s window.
                sp.send({"cmd": "watch", "hash": h, "tab": "trackers"})
                seen = []
                deadline = time.monotonic() + 1.0
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        obj = sp.readline(timeout=remaining)
                    except AssertionError:
                        break
                    if obj.get("type") == "inspect":
                        seen.append(obj)
                self.assertEqual(seen, [])

    def test_a_new_watch_resets_the_backoff(self):
        with harness.fixture_server() as (port, env):
            _write_control(env["QBT_FIXTURE_CONTROL"], {"trackers": "404"})
            with ServeProcess(env) as sp:
                sp.readline()
                h1 = "a" * 40
                h2 = "b" * 40
                sp.send({"cmd": "watch", "hash": h1, "tab": "trackers"})
                first_err = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                self.assertIn("error", first_err)

                # A *different* hash is a changed watch: it resets the
                # back-off and is answered at once (F3), rather than
                # being silently held behind h1's still-running back-off.
                start = time.monotonic()
                sp.send({"cmd": "watch", "hash": h2, "tab": "trackers"})
                second = sp.read_until(lambda o: o.get("type") == "inspect", timeout=5)
                elapsed = time.monotonic() - start
                self.assertEqual(second["hash"], h2)
                self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
