"""Test harness for `tests/fixtures/server.py`, for `qbt-serve` tests.

`fixture_server()` gives each test its own throwaway qBittorrent WebUI
fixture plus a matching env for `./qbt` / `./qbt-serve`: a free port, a
fresh 0700 state dir (rid file + cookie jar live under it), an empty
request log, no VPN interface, and a temp magnet inbox plus stub
raise/notify commands (never the real inbox or bar). Everything it
creates is removed again on exit.
"""
import contextlib
import os
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

FIXTURES_DIR = Path(__file__).resolve().parent
SERVER_SCRIPT = FIXTURES_DIR / "server.py"
CONF_PATH = FIXTURES_DIR / "qBittorrent.conf"


def _free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def start_fixture_server(extra_env=None):
    """Start the fixture WebUI server. Returns (proc, port, env, cleanup).

    `cleanup()` terminates the server and removes every temp path this
    created; call it exactly once, typically in a try/finally. Most
    callers should use `fixture_server()` below instead, which does that
    for them -- this lower-level entry point exists for tests that need
    to keep a handle on the server process itself (for example, to kill
    it mid-test and assert `qbt-serve` copes).
    """
    port = _free_port()

    tmp_root = Path(tempfile.mkdtemp(prefix="qbt-serve-test-"))
    state_dir = tmp_root / "state"
    state_dir.mkdir(mode=0o700)
    # Never created: qbt's vpn_iface() finds no such directory, so probes
    # report no VPN interface, matching the harness's documented default.
    net_dir = tmp_root / "no-such-net"

    log_fd, log_path = tempfile.mkstemp(prefix="qbt-fixture-log-", dir=str(tmp_root))
    os.close(log_fd)

    # Left absent: the fixture server treats a missing bind file as
    # "no bound interface", same as a real unbound daemon.
    bind_path = tmp_root / "bind-iface"

    # Left absent: the fixture server treats a missing (or unset) control
    # file as "no per-route faults". A test that wants a route to sleep or
    # 404 writes JSON here (e.g. {"trackers": "sleep3"}), and the server
    # re-reads it on every request, so a test can flip it mid-run.
    control_path = tmp_root / "control.json"

    # Safe defaults for anything that could reach outside the test: the
    # browser-magnet inbox (qbt magnet-inbox, a fetch-metadata rescue)
    # lives under tmp_root, and the bar raise / notify-send are stubs that
    # only log their arguments (the raise stub exits 1, "no IPC function",
    # the way tests/actions.sh's does). A caller's extra_env still wins.
    magnet_state = tmp_root / "magnet-state"
    raise_log = tmp_root / "raise.log"
    notify_log = tmp_root / "notify.log"
    raise_log.write_text("")
    notify_log.write_text("")
    raise_cmd = tmp_root / "omarchy-shell"
    raise_cmd.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{raise_log}'\nexit 1\n")
    raise_cmd.chmod(0o755)
    notify_cmd = tmp_root / "notify-send"
    notify_cmd.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{notify_log}'\n")
    notify_cmd.chmod(0o755)

    env = os.environ.copy()
    env.pop("QBT_FIXTURE_FORBIDDEN", None)
    env.pop("QBT_BIND_IFACE", None)
    env.update({
        "QBT_FIXTURE_PORT": str(port),
        "QBT_FIXTURE_LOG": str(log_path),
        "QBT_BASE": f"http://127.0.0.1:{port}",
        "QBT_INSTALLED": "1",
        "QBT_DAEMON": "1",
        "QBT_LOCK": "nox",
        "QBT_NET_DIR": str(net_dir),
        "QBT_CONF": str(CONF_PATH),
        "QBT_RID_FILE": str(state_dir / "rid.json"),
        "QBT_STATE_DIR": str(state_dir),
        "QBT_FIXTURE_BIND_FILE": str(bind_path),
        "QBT_FIXTURE_CONTROL": str(control_path),
        "QBT_MAGNET_STATE": str(magnet_state),
        "QBT_RAISE_CMD": str(raise_cmd),
        "QBT_NOTIFY_CMD": str(notify_cmd),
    })
    if extra_env:
        env.update(extra_env)

    proc = subprocess.Popen(["python3", str(SERVER_SCRIPT)], env=env)

    def cleanup():
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        shutil.rmtree(tmp_root, ignore_errors=True)

    ready = False
    deadline = time.monotonic() + 5.0
    url = f"http://127.0.0.1:{port}/api/v2/sync/maindata?rid=0"
    while time.monotonic() < deadline:
        try:
            urllib.request.urlopen(url, timeout=0.2)
            ready = True
            break
        except Exception:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
    if not ready:
        cleanup()
        raise RuntimeError("fixture server did not start")

    return proc, port, env, cleanup


@contextlib.contextmanager
def fixture_server(extra_env=None):
    proc, port, env, cleanup = start_fixture_server(extra_env)
    try:
        yield port, env
    finally:
        cleanup()
