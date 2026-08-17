#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, socket, subprocess, time, urllib.request
from pathlib import Path

root = Path(".").resolve()
log = root / "tests/fixtures/.requests.json"
if log.exists():
    log.unlink()

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()

env = os.environ.copy()
env.update({
    "QBT_FIXTURE_PORT": str(port),
    "QBT_FIXTURE_LOG": str(log),
    "QBT_BASE": f"http://127.0.0.1:{port}",
    "QBT_INSTALLED": "1",
    "QBT_DAEMON": "1",
    "QBT_LOCK": "nox",
    "QBT_RID_FILE": str(root / "tests/fixtures/.rid"),
    "QBT_CONF": str(root / "tests/fixtures/qBittorrent.conf"),
})
rid = Path(env["QBT_RID_FILE"])
if rid.exists():
    rid.unlink()

server = subprocess.Popen(["python3", "tests/fixtures/server.py"], env=env)
try:
    for _ in range(50):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v2/sync/maindata?rid=0", timeout=0.1)
            break
        except Exception:
            time.sleep(0.05)
    else:
        raise SystemExit("fixture server did not start")

    def qbt(*args):
        return subprocess.run(["./qbt", *args], env=env, text=True, capture_output=True)

    first = qbt("status")
    assert first.returncode == 0, first.stderr
    data = json.loads(first.stdout)
    assert data["installed"] is True
    assert data["daemon"] is True
    assert data["lockHolder"] == "nox"
    assert data["api"] is True
    assert data["dlSpeed"] == 2202009
    assert len(data["torrents"]) == 2
    hashes = {t["hash"] for t in data["torrents"]}
    assert "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in hashes
    assert "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" in hashes

    second = qbt("status")
    assert second.returncode == 0, second.stderr
    data2 = json.loads(second.stdout)
    assert data2["dlSpeed"] == 100
    names = {t["name"] for t in data2["torrents"]}
    assert names == {"debian.iso"}
    assert abs(data2["torrents"][0]["progress"] - 0.5) < 1e-9

    add = qbt("add", "magnet:?xt=urn:btih:abc")
    assert add.returncode == 0, add.stderr
    start = qbt("start", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert start.returncode == 0, start.stderr
    stop = qbt("stop", "all")
    assert stop.returncode == 0, stop.stderr
    delete = qbt("delete", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert delete.returncode == 0, delete.stderr
    delete_files = qbt("delete", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "--files")
    assert delete_files.returncode == 0, delete_files.stderr
    files = qbt("files", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert files.returncode == 0, files.stderr
    file_rows = json.loads(files.stdout)
    assert file_rows[0]["name"] == "debian.iso"
    prio = qbt("prio", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1", "0")
    assert prio.returncode == 0, prio.stderr

    reqs = json.loads(log.read_text())
    posts = [r["path"] for r in reqs if r["method"] == "POST"]
    assert "/api/v2/torrents/add" in posts
    assert "/api/v2/torrents/start" in posts
    assert "/api/v2/torrents/stop" in posts
    assert "/api/v2/torrents/delete" in posts
    assert "/api/v2/torrents/filePrio" in posts
    assert "/api/v2/torrents/pause" not in posts
    assert "/api/v2/torrents/resume" not in posts
    bodies = " ".join(r["body"] for r in reqs if r["method"] == "POST")
    assert "urls=magnet:?xt=urn:btih:abc" in bodies or "urls=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc" in bodies
    assert "deleteFiles=true" in bodies
    assert "deleteFiles=false" in bodies
    assert "hashes=all" in bodies
finally:
    server.terminate()
    server.wait(timeout=5)

env["QBT_FIXTURE_FORBIDDEN"] = "1"
server2 = subprocess.Popen(["python3", "tests/fixtures/server.py"], env=env)
try:
    for _ in range(50):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v2/sync/maindata?rid=0", timeout=0.1)
            break
        except Exception as exc:
            if "403" in str(exc):
                break
            time.sleep(0.05)
    bad = qbt("status")
    text = bad.stdout + bad.stderr
    assert "leaked-secret-value" not in text
    assert "SID=<redacted>" in text or "localhost auth is required" in text
finally:
    server2.terminate()
    server2.wait(timeout=5)

print("api-contract ok")

import tempfile, pathlib
home = pathlib.Path(tempfile.mkdtemp(prefix="qbt-home-"))
denv = env.copy()
denv.update({
    "QBT_HOME": str(home),
    "QBT_CONF": str(home / ".config/qBittorrent/qBittorrent.conf"),
    "QBT_SKIP_SYSTEMCTL": "1",
    "QBT_LOCK": "gui",
})
(home / ".config/qBittorrent").mkdir(parents=True)
(home / ".config/qBittorrent/qBittorrent.conf").write_text("[Preferences]\nWebUI\\Port=9001\n")

gui = subprocess.run(["./qbt", "start-daemon"], env=denv, text=True, capture_output=True)
assert gui.returncode != 0
assert "close qbittorrent" in (gui.stderr + gui.stdout).lower()

denv["QBT_LOCK"] = "none"
denv["QBT_BIND_IFACE"] = "wg0-mullvad"
ok = subprocess.run(["./qbt", "start-daemon"], env=denv, text=True, capture_output=True)
assert ok.returncode == 0, ok.stderr
conf = (home / ".config/qBittorrent/qBittorrent.conf").read_text()
assert r"WebUI\Enabled=true" in conf
assert r"WebUI\Address=127.0.0.1" in conf
assert r"WebUI\LocalHostAuth=false" in conf
assert r"WebUI\Port=9001" in conf
assert r"Session\Interface=wg0-mullvad" in conf
assert r"Session\InterfaceName=wg0-mullvad" in conf
bittorrent = conf.split("[BitTorrent]", 1)
assert len(bittorrent) == 2
assert r"Session\Interface=wg0-mullvad" in bittorrent[1].split("[", 1)[0]
unit = (home / ".config/systemd/user/omaqbt-nox.service").read_text()
assert "ExecStart=/usr/bin/qbittorrent-nox" in unit
assert "WantedBy=default.target" in unit
print("daemon-contract ok")

# Keys must land under [Preferences], not after a later section.
home2 = pathlib.Path(tempfile.mkdtemp(prefix="qbt-home2-"))
denv2 = denv.copy()
denv2.update({
    "QBT_HOME": str(home2),
    "QBT_CONF": str(home2 / ".config/qBittorrent/qBittorrent.conf"),
    "QBT_LOCK": "none",
})
(home2 / ".config/qBittorrent").mkdir(parents=True)
(home2 / ".config/qBittorrent/qBittorrent.conf").write_text(
    "[Preferences]\n"
    "General\\CloseToTrayNotified=true\n"
    "\n"
    "[TorrentProperties]\n"
    "Visible=true\n"
    "WebUI\\Port=9001\n"
)
ok2 = subprocess.run(["./qbt", "start-daemon"], env=denv2, text=True, capture_output=True)
assert ok2.returncode == 0, ok2.stderr
conf2 = (home2 / ".config/qBittorrent/qBittorrent.conf").read_text()
prefs = conf2.split("[TorrentProperties]", 1)[0]
assert "[Preferences]" in prefs
assert r"WebUI\LocalHostAuth=false" in prefs
assert r"WebUI\Enabled=true" in prefs
assert r"WebUI\Address=127.0.0.1" in prefs
assert r"WebUI\Port=9001" in prefs
later = conf2.split("[TorrentProperties]", 1)[1]
assert r"WebUI\LocalHostAuth=false" not in later
assert r"WebUI\Port=9001" not in later
print("prefs-section-contract ok")

# State dir hardening: refuse a symlinked state dir, and create the real one 0700.
# The fixture server is stopped, so the API call fails gracefully; ensure_state_dir
# runs before that call, which is what we are exercising here.
sbase = pathlib.Path(tempfile.mkdtemp(prefix="qbt-state-"))
real = sbase / "real"
real.mkdir()
link = sbase / "link"
link.symlink_to(real)
senv = env.copy()
senv["QBT_RID_FILE"] = str(link / "rid.json")
bad_state = subprocess.run(["./qbt", "status"], env=senv, text=True, capture_output=True)
assert bad_state.returncode != 0
assert "refusing symlinked state dir" in (bad_state.stderr + bad_state.stdout).lower()

fresh = sbase / "fresh" / "omaqbt"
senv2 = env.copy()
senv2["QBT_RID_FILE"] = str(fresh / "rid.json")
ok_state = subprocess.run(["./qbt", "status"], env=senv2, text=True, capture_output=True)
assert ok_state.returncode == 0, ok_state.stderr
assert fresh.is_dir()
mode = oct(fresh.stat().st_mode & 0o777)
assert mode == "0o700", mode
print("state-dir-contract ok")
PY
