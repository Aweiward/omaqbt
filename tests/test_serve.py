#!/usr/bin/env python3
import json
import queue
import socket
import subprocess
import sys
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
                     "dlSpeed", "upSpeed", "torrents", "vpnIface", "bindIface"],
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


class LocalhostGuardTests(unittest.TestCase):
    def test_non_local_base_is_fatal(self):
        with harness.fixture_server(extra_env={"QBT_BASE": "http://10.0.0.1:1"}) as (port, env):
            with ServeProcess(env) as sp:
                fatal = sp.read_until(lambda o: o.get("type") == "fatal", timeout=5)
                sp.proc.wait(timeout=5)
                self.assertEqual(sp.proc.returncode, 2)
                self.assertIn("refusing non-localhost host", fatal["error"])


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


if __name__ == "__main__":
    unittest.main()
