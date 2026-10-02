#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, re, socket, subprocess, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

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
    # Point iface detection at a dir with no wg0-mullvad so the host's real
    # VPN state cannot leak into the assertions below.
    "QBT_NET_DIR": str(root / "tests/fixtures/.no-such-net"),
    "QBT_FIXTURE_BIND_FILE": str(root / "tests/fixtures/.bind"),
    "XDG_STATE_HOME": str(root / "tests/fixtures/.magnet-state"),
})
magnet_state = Path(env["XDG_STATE_HOME"])
if magnet_state.exists():
    import shutil
    shutil.rmtree(magnet_state)
bind_file = Path(env["QBT_FIXTURE_BIND_FILE"])
if bind_file.exists():
    bind_file.unlink()
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
    assert data["altSpeed"] is True
    debian = next(t for t in data["torrents"] if t["name"] == "debian.iso")
    assert debian["dlLimit"] == 1048576
    assert debian["upLimit"] == 0
    assert debian["seqDl"] is True
    assert debian["ratioLimit"] == -2
    assert debian["savePath"] == "/home/user/Downloads"
    assert debian["magnetUri"] == "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    arch = next(t for t in data["torrents"] if t["name"] == "arch.iso")
    assert arch["magnetUri"] == ""
    assert debian["contentPath"] == "/home/user/Downloads/debian.iso"
    assert debian["numSeeds"] == 14
    assert debian["numLeechs"] == 3
    assert debian["addedOn"] == 1755300000
    assert debian["autoTmm"] is True
    assert arch["autoTmm"] is False
    assert data["categoryPaths"] == {
        "linux": {"savePath": "", "downloadPath": ""},
        "os": {"savePath": "/data/os", "downloadPath": "/data/os-dl"},
    }
    assert data["defaultSavePath"] == "/home/user/Downloads"
    assert data["relocation"] == {"torrentChanged": True, "categoryPathChanged": False}

    # No VPN iface detected: no warning fields. Preferences is still fetched
    # (it feeds defaultSavePath/relocation above), just not vpnIface/bindIface.
    assert data["vpnIface"] == ""
    assert data["bindIface"] == ""

    second = qbt("status")
    assert second.returncode == 0, second.stderr
    data2 = json.loads(second.stdout)
    assert data2["dlSpeed"] == 100
    names = {t["name"] for t in data2["torrents"]}
    assert names == {"debian.iso"}
    assert abs(data2["torrents"][0]["progress"] - 0.5) < 1e-9
    # The second poll must reuse the WebUI session: qBittorrent only sends a
    # delta to the session that holds the rid.
    maindata = [r for r in json.loads(log.read_text()) if r["path"] == "/api/v2/sync/maindata"]
    assert "SID=fixture-" in maindata[-1]["cookie"], maindata[-1]
    jar = Path(env["QBT_RID_FILE"]).parent / "cookies"
    assert jar.exists()
    assert oct(jar.stat().st_mode & 0o777) == "0o600", oct(jar.stat().st_mode & 0o777)
    # The delta does not resend detail fields; they must survive via the rid cache.
    assert data2["torrents"][0]["savePath"] == "/home/user/Downloads"
    assert data2["torrents"][0]["magnetUri"] == "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    assert data2["torrents"][0]["numSeeds"] == 14
    assert data2["torrents"][0]["addedOn"] == 1755300000

    # Preferences is fetched on every poll (bash's SlowCache uses interval=0),
    # regardless of whether a VPN interface is configured.
    reqs_before = json.loads(log.read_text())
    assert "/api/v2/app/preferences" in [r["path"] for r in reqs_before]

    # With the VPN iface up: report where the running daemon is bound.

    venv = env.copy()
    venv["QBT_BIND_IFACE"] = "wg0-mullvad"
    bind_file.write_text("wg0-mullvad")
    bound = subprocess.run(["./qbt", "status"], env=venv, text=True, capture_output=True)
    assert bound.returncode == 0, bound.stderr
    bdata = json.loads(bound.stdout)
    assert bdata["vpnIface"] == "wg0-mullvad"
    assert bdata["bindIface"] == "wg0-mullvad"

    bind_file.write_text("")
    unbound = subprocess.run(["./qbt", "status"], env=venv, text=True, capture_output=True)
    assert unbound.returncode == 0, unbound.stderr
    udata = json.loads(unbound.stdout)
    assert udata["vpnIface"] == "wg0-mullvad"
    assert udata["bindIface"] == ""

    add = qbt("add", "magnet:?xt=urn:btih:abc")
    assert add.returncode == 0, add.stderr

    import tempfile as tf
    updir = Path(tf.mkdtemp(prefix="qbt-upload-"))
    torrent_file = updir / "upload me.torrent"
    torrent_file.write_bytes(b"d8:announce4:teste")
    addf = qbt("add", str(torrent_file))
    assert addf.returncode == 0, addf.stderr
    addfu = qbt("add", "file://" + str(torrent_file))
    assert addfu.returncode == 0, addfu.stderr
    magnet_hash = "c" * 40
    magnet_url = f"magnet:?xt=urn:btih:{magnet_hash}"
    inbox = Path(env["XDG_STATE_HOME"]) / "omaqbt" / "magnet-inbox.jsonl"
    inbox.parent.mkdir(parents=True, exist_ok=True)
    inbox.write_text(json.dumps({"url": magnet_url, "ts": 1}) + "\n")
    drain = qbt("magnet-drain")
    assert drain.returncode == 0, drain.stderr
    addflags = qbt("add", "--stopped", "--savepath", "/dl/iso", "magnet:?xt=urn:btih:def")
    assert addflags.returncode == 0, addflags.stderr
    addfstop = qbt("add", "--stopped", str(torrent_file))
    assert addfstop.returncode == 0, addfstop.stderr
    missing = qbt("add", "/no/such/file.torrent")
    assert missing.returncode != 0
    assert "no such" in (missing.stderr + missing.stdout).lower() or "not" in (missing.stderr + missing.stdout).lower()
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
    turtle = qbt("turtle")
    assert turtle.returncode == 0, turtle.stderr
    lim = qbt("limit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "dl", "1048576")
    assert lim.returncode == 0, lim.stderr
    limu = qbt("limit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "up", "262144")
    assert limu.returncode == 0, limu.stderr
    badlim = qbt("limit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "sideways", "1")
    assert badlim.returncode != 0
    seq = qbt("sequential", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert seq.returncode == 0, seq.stderr
    share = qbt("sharelimit", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "1")
    assert share.returncode == 0, share.stderr
    recheck = qbt("recheck", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert recheck.returncode == 0, recheck.stderr
    bad_recheck = qbt("recheck")
    assert bad_recheck.returncode != 0
    moved = qbt("set-location", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "/dl/iso")
    assert moved.returncode == 0, moved.stderr
    home_move = qbt("set-location", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "~/iso")
    assert home_move.returncode == 0, home_move.stderr
    rel = qbt("set-location", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "relative/path")
    assert rel.returncode != 0
    missing_loc = qbt("set-location", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert missing_loc.returncode != 0

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
    assert "/api/v2/transfer/toggleSpeedLimitsMode" in posts
    assert "/api/v2/torrents/setDownloadLimit" in posts
    assert "/api/v2/torrents/setUploadLimit" in posts
    assert "/api/v2/torrents/toggleSequentialDownload" in posts
    assert "/api/v2/torrents/setShareLimits" in posts
    assert "/api/v2/torrents/recheck" in posts
    assert "/api/v2/torrents/setLocation" in posts
    assert "limit=1048576" in bodies
    assert "limit=262144" in bodies
    assert "ratioLimit=1" in bodies
    assert "seedingTimeLimit=-2" in bodies
    assert "inactiveSeedingTimeLimit=-2" in bodies
    # 5.2.3 answers 400 without it (the fixture does too): slice 3b's fix.
    assert "shareLimitAction=Default" in bodies
    # .torrent uploads go multipart with the file under "torrents".
    assert 'name="torrents"' in bodies
    assert 'filename="upload me.torrent"' in bodies
    # Browser magnet drain must fetch metadata, not inherit add-stopped.
    assert "stopCondition=MetadataReceived" in bodies
    assert "stopped=false" in bodies
    assert "paused=false" in bodies
    # Flag adds carry qBittorrent 5 field names.
    assert "stopped=true" in bodies
    assert "savepath=%2Fdl%2Fiso" in bodies or "savepath=/dl/iso" in bodies
    assert "location=%2Fdl%2Fiso" in bodies or "location=/dl/iso" in bodies
    home_loc = os.path.expanduser("~/iso")
    import urllib.parse
    assert f"location={urllib.parse.quote(home_loc, safe='')}" in bodies or f"location={home_loc}" in bodies
    assert 'name="stopped"' in bodies
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
    assert "SID=<redacted>" in text or "qBittorrent refused OmaqBT's API key" in text
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
    # start-daemon takes its lock in the state dir: keep it out of tests/fixtures.
    "QBT_RID_FILE": str(home / "state/omaqbt/rid.json"),
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
# The localhost login bypass is off: OmaqBT signs in with the API key.
assert r"WebUI\LocalHostAuth=true" in conf
assert r"WebUI\AuthSubnetWhitelistEnabled=false" in conf
assert r"WebUI\LocalHostAuth=false" not in conf
assert r"WebUI\AuthSubnetWhitelistEnabled=true" not in conf
assert re.search(r"^WebUI\\APIKey=qbt_[A-Za-z0-9]{28}$", conf, re.M), "start-daemon generates a key"
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
    "QBT_RID_FILE": str(home2 / "state/omaqbt/rid.json"),
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
assert r"WebUI\LocalHostAuth=true" in prefs
assert r"WebUI\AuthSubnetWhitelistEnabled=false" in prefs
assert r"WebUI\APIKey=qbt_" in prefs
assert r"WebUI\Enabled=true" in prefs
assert r"WebUI\Address=127.0.0.1" in prefs
assert r"WebUI\Port=9001" in prefs
later = conf2.split("[TorrentProperties]", 1)[1]
assert r"WebUI\LocalHostAuth=true" not in later
assert r"WebUI\APIKey=" not in later
assert r"WebUI\Port=9001" not in later
print("prefs-section-contract ok")

# Auth (marketplace review, 2026-10-02): OmaqBT signs every request with
# qBittorrent's API key, and the setup turns the localhost login bypass off.
# The key must never reach a process's argv, the probe or an error message.
import fcntl, shutil, stat
API_KEY_MESSAGE = "qBittorrent refused OmaqBT's API key"
KEY_LINE_RE = re.compile(r"^WebUI\\APIKey=(.*)$", re.M)
KEPT_KEY = "qbt_KeepMe23456789abcdefghjkmnpq"
assert re.fullmatch(r"qbt_[A-Za-z0-9]{28}", KEPT_KEY)
REAL_PYTHON = shutil.which("python3")
REAL_CURL = shutil.which("curl")
auth_failures = []


def auth_check(label, cond):
    print(("ok - " if cond else "FAIL - ") + label)
    if not cond:
        auth_failures.append(label)


def auth_home(prefs):
    """A throwaway home whose qBittorrent.conf holds `prefs` under
    [Preferences], plus a fresh state dir. Returns (home, conf, env)."""
    h = pathlib.Path(tempfile.mkdtemp(prefix="qbt-auth-"))
    c = h / ".config/qBittorrent/qBittorrent.conf"
    c.parent.mkdir(parents=True)
    c.write_text("[Preferences]\n" + "".join(f"{line}\n" for line in prefs) + "WebUI\\Port=9001\n")
    e = env.copy()
    e.pop("QBT_BIND_IFACE", None)
    e.update({
        "QBT_HOME": str(h),
        "QBT_CONF": str(c),
        "QBT_RID_FILE": str(h / "state/omaqbt/rid.json"),
        "QBT_SKIP_SYSTEMCTL": "1",
        "QBT_INSTALLED": "1",
        "QBT_DAEMON": "1",
        "QBT_LOCK": "none",
    })
    return h, c, e


def keys_in(conf_path):
    return KEY_LINE_RE.findall(conf_path.read_text())


def shim(dirpath, name, real, log_path):
    """A `name` first on PATH that logs its argv and environment, then execs
    the real one."""
    dirpath.mkdir(exist_ok=True)
    s = dirpath / name
    s.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{log_path}'\n"
                 f"tr '\\0' '\\n' </proc/$$/environ >>'{log_path}'\nexec '{real}' \"$@\"\n")
    s.chmod(0o755)
    return str(dirpath)


BYPASS = ["WebUI\\LocalHostAuth=false", "WebUI\\AuthSubnetWhitelistEnabled=true",
          "WebUI\\AuthSubnetWhitelist=127.0.0.1, ::1"]

# start-daemon keeps an existing valid key and turns the bypass off.
h, c, e = auth_home(BYPASS + [f"WebUI\\APIKey={KEPT_KEY}"])
r = subprocess.run(["./qbt", "start-daemon"], env=e, text=True, capture_output=True)
text = c.read_text()
auth_check("start-daemon with a valid key succeeds", r.returncode == 0)
auth_check("start-daemon keeps an existing valid key", keys_in(c) == [KEPT_KEY])
auth_check("start-daemon turns LocalHostAuth on",
           "WebUI\\LocalHostAuth=true" in text and "WebUI\\LocalHostAuth=false" not in text)
auth_check("start-daemon turns the subnet whitelist off",
           "WebUI\\AuthSubnetWhitelistEnabled=false" in text and "WebUI\\AuthSubnetWhitelistEnabled=true" not in text)
auth_check("start-daemon prints no key", KEPT_KEY not in r.stdout + r.stderr)

# An invalid key is replaced, and a generated key never reaches an argv
# (python3 is how qbt writes the conf).
h, c, e = auth_home(["WebUI\\APIKey=qbt_short"])
argv_log = h / "argv.log"
argv_log.write_text("")
e["PATH"] = shim(h / "bin", "python3", REAL_PYTHON, argv_log) + os.pathsep + e["PATH"]
r = subprocess.run(["./qbt", "start-daemon"], env=e, text=True, capture_output=True)
got = keys_in(c)
auth_check("start-daemon replaces an invalid key", r.returncode == 0 and len(got) == 1
           and re.fullmatch(r"qbt_[23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz]{28}", got[0]) is not None)
logged = argv_log.read_text()
auth_check("start-daemon ran python3 through the argv shim", logged != "")
auth_check("the generated key is on no python3 argv or environment", bool(got) and got[0] not in logged)
auth_check("the generated key is not printed", bool(got) and got[0] not in r.stdout + r.stderr)
h, c, e = auth_home([])
subprocess.run(["./qbt", "start-daemon"], env=e, text=True, capture_output=True)
first = keys_in(c)
subprocess.run(["./qbt", "start-daemon"], env=e, text=True, capture_output=True)
auth_check("a conf without a key gets one, and a second start-daemon keeps it",
           len(first) == 1 and keys_in(c) == first)

# The probe's conf and auth fields, in all three states.
for label, prefs, want in (
    ("ok", ["WebUI\\LocalHostAuth=true", "WebUI\\AuthSubnetWhitelistEnabled=false", f"WebUI\\APIKey={KEPT_KEY}"], "ok"),
    ("qBittorrent's defaults with a key", [f"WebUI\\APIKey={KEPT_KEY}"], "ok"),
    ("LocalHostAuth=false", ["WebUI\\LocalHostAuth=false", f"WebUI\\APIKey={KEPT_KEY}"], "bypass"),
    ("the subnet whitelist on", ["WebUI\\AuthSubnetWhitelistEnabled=true", f"WebUI\\APIKey={KEPT_KEY}"], "bypass"),
    ("bypass wins over nokey", BYPASS, "bypass"),
    ("no key", ["WebUI\\LocalHostAuth=true"], "nokey"),
    ("an invalid key", ["WebUI\\APIKey=qbt_tooShort"], "nokey"),
):
    h, c, e = auth_home(prefs)
    r = subprocess.run(["./qbt", "probe"], env=e, text=True, capture_output=True)
    p = json.loads(r.stdout)
    auth_check(f"probe auth is {want!r} for {label}", p.get("auth") == want)
    auth_check(f"probe conf is the conf path ({label})", p.get("conf") == str(c))
    auth_check(f"probe holds no key ({label})", KEPT_KEY not in r.stdout)

# secure-daemon: a no-op on a secured conf, else the start-daemon flow.
h, c, e = auth_home(["WebUI\\LocalHostAuth=true", "WebUI\\AuthSubnetWhitelistEnabled=false", f"WebUI\\APIKey={KEPT_KEY}"])
before = c.read_bytes()
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
auth_check("secure-daemon on a secured conf is a no-op",
           r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "changed": False} and c.read_bytes() == before)
auth_check("secure-daemon writes no unit when nothing changes",
           not (h / ".config/systemd/user/omaqbt-nox.service").exists())

h, c, e = auth_home(BYPASS + [f"WebUI\\APIKey={KEPT_KEY}"])
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
text = c.read_text()
auth_check("secure-daemon on a bypass conf changes it",
           r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "changed": True})
auth_check("secure-daemon keeps the existing key", keys_in(c) == [KEPT_KEY])
auth_check("secure-daemon turns the bypass off",
           "WebUI\\LocalHostAuth=true" in text and "WebUI\\AuthSubnetWhitelistEnabled=false" in text)
auth_check("secure-daemon runs the start-daemon setup",
           "WebUI\\Enabled=true" in text and "WebUI\\Address=127.0.0.1" in text and "WebUI\\Port=9001" in text
           and (h / ".config/systemd/user/omaqbt-nox.service").exists())
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
auth_check("a second secure-daemon is a no-op",
           r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "changed": False})

h, c, e = auth_home(["WebUI\\LocalHostAuth=true"])
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
auth_check("secure-daemon on a conf without a key generates one",
           r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "changed": True} and len(keys_in(c)) == 1)
auth_check("secure-daemon prints no key", keys_in(c)[0] not in r.stdout + r.stderr)

for label, extra, want in (("the GUI holds the lock", {"QBT_LOCK": "gui"}, "close qbittorrent"),
                           ("qbittorrent-nox isn't installed", {"QBT_INSTALLED": "0"}, "not installed")):
    h, c, e = auth_home(BYPASS)
    e.update(extra)
    before = c.read_bytes()
    r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
    auth_check(f"secure-daemon refuses when {label}",
               r.returncode != 0 and r.stdout == "" and want in r.stderr.lower() and c.read_bytes() == before)

# Two callers (the popup's and the window's Service) may both ask: while one
# holds the lock, secure-daemon is a no-op that writes nothing (the holder is
# already securing it), and start-daemon, a click, waits for its turn.
h, c, e = auth_home(BYPASS)
state = h / "state/omaqbt"
state.mkdir(parents=True, mode=0o700)
with open(state / "secure.lock", "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    before = c.read_bytes()
    r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True, timeout=10)
    auth_check("secure-daemon is a no-op while another holds the lock",
               r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "changed": False}
               and c.read_bytes() == before)
    waiting = subprocess.Popen(["./qbt", "start-daemon"], env=e, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.6)
    auth_check("start-daemon waits while another holds the lock",
               waiting.poll() is None and c.read_bytes() == before)
    fcntl.flock(held, fcntl.LOCK_UN)
out, err = waiting.communicate(timeout=20)
auth_check("start-daemon goes ahead once the lock is free",
           waiting.returncode == 0 and "WebUI\\LocalHostAuth=true" in c.read_text())

# QSettings reads booleans the QVariant way (trimmed, any case, 0 and 1), so
# a hand-edited bypass must still read as one, and set_key must replace it.
for label, prefs in (("LocalHostAuth = 0", ["WebUI\\LocalHostAuth = 0"]),
                     ("LocalHostAuth=False", ["WebUI\\LocalHostAuth=False"]),
                     ("AuthSubnetWhitelistEnabled=1", ["WebUI\\AuthSubnetWhitelistEnabled=1"])):
    h, c, e = auth_home(prefs + [f"WebUI\\APIKey={KEPT_KEY}"])
    p = json.loads(subprocess.run(["./qbt", "probe"], env=e, text=True, capture_output=True).stdout)
    auth_check(f"probe reads {label} as the bypass", p.get("auth") == "bypass")
    subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
    p = json.loads(subprocess.run(["./qbt", "probe"], env=e, text=True, capture_output=True).stdout)
    auth_check(f"secure-daemon replaces {label}", p.get("auth") == "ok")
h, c, e = auth_home([f"WebUI\\APIKey = {KEPT_KEY}"])
p = json.loads(subprocess.run(["./qbt", "probe"], env=e, text=True, capture_output=True).stdout)
auth_check("a key written with spaces around = still reads", p.get("auth") == "ok")

# The conf holds the key, so the setup leaves it owner-only.
h, c, e = auth_home(BYPASS)
c.chmod(0o644)
c.parent.chmod(0o755)
subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True)
auth_check("secure-daemon leaves the conf owner-only", stat.S_IMODE(c.stat().st_mode) == 0o600)
auth_check("secure-daemon leaves the conf dir owner-only", stat.S_IMODE(c.parent.stat().st_mode) == 0o700)

# qBittorrent rewrites its conf at 0644 on exit (seen live with 5.2.3), so
# every probe puts a key-holding conf back to owner-only.
h, c, e = auth_home([f"WebUI\\APIKey={KEPT_KEY}"])
c.chmod(0o644)
subprocess.run(["./qbt", "probe"], env=e, text=True, capture_output=True)
auth_check("a probe puts a key-holding conf back to owner-only", stat.S_IMODE(c.stat().st_mode) == 0o600)

# The restart path, with a systemctl shim that logs its calls (and starts
# nothing): a key that can't be made, or a nox that won't stop, leaves the
# conf as it was and the daemon running.
def daemon_env(prefs, still_running, extra_shims=()):
    h, c, e = auth_home(prefs)
    e.pop("QBT_SKIP_SYSTEMCTL", None)
    log = h / "systemctl.log"
    log.write_text("")
    b = h / "bin"
    b.mkdir()
    (b / "systemctl").write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{log}'\n")
    (b / "systemctl").chmod(0o755)
    for name, body in extra_shims:
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    e["PATH"] = str(b) + os.pathsep + e["PATH"]
    e["QBT_DAEMON"] = "1" if still_running else "0"
    return h, c, e, log

h, c, e, log = daemon_env(BYPASS, still_running=True)
e["QBT_DAEMON"] = "1"
before = c.read_bytes()
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True, timeout=30)
calls = log.read_text()
auth_check("a nox that won't stop fails secure-daemon", r.returncode != 0 and "still running" in r.stderr)
auth_check("a nox that won't stop leaves the conf as it was", c.read_bytes() == before)
auth_check("a nox that won't stop gets omaqbt-nox started again",
           "stop omaqbt-nox.service" in calls and "start omaqbt-nox.service" in calls.split("stop omaqbt-nox.service", 1)[1])

fail_py = ("#!/bin/sh\nfor a in \"$@\"; do case $a in *secrets*) exit 1 ;; esac; done\n"
           f"exec '{REAL_PYTHON}' \"$@\"\n")
h, c, e, log = daemon_env(["WebUI\\LocalHostAuth=true"], still_running=True,
                          extra_shims=(("python3", fail_py),))
before = c.read_bytes()
r = subprocess.run(["./qbt", "secure-daemon"], env=e, text=True, capture_output=True, timeout=30)
auth_check("a key that can't be generated fails secure-daemon",
           r.returncode != 0 and "cannot generate an API key" in r.stderr and r.stdout == "")
auth_check("a key that can't be generated stops nothing", "stop" not in log.read_text())
auth_check("a key that can't be generated leaves the conf as it was", c.read_bytes() == before)

# A server that still honours the bypass (an old daemon): status works
# unsigned and reports it, and secure-daemon moves the conf to the key.
with harness.fixture_server(extra_env={"QBT_FIXTURE_NO_AUTH": "1"}) as (bport, benv):
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="qbt-bypass-"))
    old = tmpd / "qBittorrent.conf"
    old.write_text("[Preferences]\n" + "".join(f"{x}\n" for x in BYPASS) + f"WebUI\\Port={bport}\n")
    benv2 = dict(benv, QBT_CONF=str(old), QBT_SKIP_SYSTEMCTL="1", QBT_HOME=str(tmpd))
    st = json.loads(subprocess.run(["./qbt", "status"], env=benv2, text=True, capture_output=True).stdout)
    auth_check("an old daemon's status works and reports the bypass",
               st.get("api") is True and st.get("auth") == "bypass" and st.get("authRefused") is False)
    r = subprocess.run(["./qbt", "secure-daemon"], env=benv2, text=True, capture_output=True)
    p = json.loads(subprocess.run(["./qbt", "probe"], env=benv2, text=True, capture_output=True).stdout)
    auth_check("secure-daemon moves an old daemon's conf to the key",
               r.returncode == 0 and p.get("auth") == "ok" and len(keys_in(old)) == 1)
    shutil.rmtree(tmpd, ignore_errors=True)

# A rotated key is picked up on the next run, and a symlink planted at the
# header file is replaced, not followed.
with harness.fixture_server(extra_env={"QBT_FIXTURE_API_KEY": KEPT_KEY}) as (kport, kenv):
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="qbt-rotate-"))
    rot = tmpd / "qBittorrent.conf"
    rot.write_text(f"[Preferences]\nWebUI\\APIKey={harness.FIXTURE_API_KEY}\nWebUI\\Port={kport}\n")
    kenv2 = dict(kenv, QBT_CONF=str(rot))
    r = subprocess.run(["./qbt", "start", "a" * 40], env=kenv2, text=True, capture_output=True)
    auth_check("the old key is refused by a daemon that rotated it", r.returncode != 0)
    rot.write_text(f"[Preferences]\nWebUI\\APIKey={KEPT_KEY}\nWebUI\\Port={kport}\n")
    r = subprocess.run(["./qbt", "start", "a" * 40], env=kenv2, text=True, capture_output=True)
    hdr = pathlib.Path(kenv["QBT_STATE_DIR"]) / "auth-header"
    auth_check("the rotated key is picked up on the next run",
               r.returncode == 0 and KEPT_KEY in hdr.read_text())
    target = tmpd / "elsewhere"
    target.write_text("untouched\n")
    hdr.unlink()
    hdr.symlink_to(target)
    r = subprocess.run(["./qbt", "start", "a" * 40], env=kenv2, text=True, capture_output=True)
    auth_check("a symlinked header file is replaced, not followed",
               r.returncode == 0 and target.read_text() == "untouched\n" and hdr.is_file() and not hdr.is_symlink()
               and stat.S_IMODE(hdr.stat().st_mode) == 0o600)
    shutil.rmtree(tmpd, ignore_errors=True)

# With the fixture server: every curl site signs with the key through a
# header file, never with the key on curl's argv, and a conf without a key
# gets the API key message.
with harness.fixture_server(extra_env={"QBT_FIXTURE_PREFS": "tests/fixtures/preferences-5.2.3.json"}) as (aport, aenv):
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="qbt-curl-"))
    curl_log = tmpd / "curl.log"
    curl_log.write_text("")
    senv = dict(aenv, PATH=shim(tmpd / "bin", "curl", REAL_CURL, curl_log) + os.pathsep + aenv["PATH"])
    flog = pathlib.Path(aenv["QBT_FIXTURE_LOG"])

    def nreq():
        return len(json.loads(flog.read_text() or "[]"))

    n0 = nreq()
    r = subprocess.run(["./qbt", "start", "a" * 40],
                       env=senv, text=True, capture_output=True)
    auth_check("qbt start succeeds against the key-enforcing fixture",
               r.returncode == 0 and json.loads(r.stdout) == {"ok": True} and nreq() > n0)
    r = subprocess.run(["./qbt", "rss", "items"], env=senv, capture_output=True, input=b"")
    auth_check("qbt rss items succeeds against the key-enforcing fixture", r.returncode == 0)
    logged = curl_log.read_text()
    key = harness.FIXTURE_API_KEY
    auth_check("curl ran through the argv shim", logged.count("\n") >= 2)
    auth_check("the API key is on no curl argv or environment", key not in logged)
    auth_check("curl reads the key from the header file", "@" in logged and "auth-header" in logged)
    hdr = pathlib.Path(aenv["QBT_STATE_DIR"]) / "auth-header"
    auth_check("the header file is owner-only",
               hdr.is_file() and stat.S_IMODE(hdr.stat().st_mode) == 0o600)

    nokey = tmpd / "nokey.conf"
    nokey.write_text("[Preferences]\nWebUI\\LocalHostAuth=true\nWebUI\\Port=18080\n")
    r = subprocess.run(["./qbt", "start", "a" * 40], env=dict(aenv, QBT_CONF=str(nokey)),
                       text=True, capture_output=True)
    auth_check("a conf without a key gets the API key message",
               r.returncode != 0 and r.stderr.strip() == API_KEY_MESSAGE)
    auth_check("a conf without a key leaves no header file behind", not hdr.exists())
    shutil.rmtree(tmpd, ignore_errors=True)

if auth_failures:
    raise SystemExit(f"{len(auth_failures)} auth-contract check(s) failed")
print("auth-contract ok")

# Private tracker URLs, private magnets and .torrent download links carry
# passkeys (marketplace review, 2026-10-02). They reach qbt on stdin
# (`--stdin`), and from qbt reach curl, jq and python3 on stdin or in the
# environment (owner-only), never on any argv (/proc/*/cmdline is world
# readable). Argv-only shims log every command line; the passkey must be on
# none while each request still arrives intact.
PASSKEY = "PASSKEYs3cr3t0123456789abcdef"
SECRET_TRACKER = f"https://tracker.example.com/{PASSKEY}/announce"
SECRET_TRACKER2 = f"https://tracker2.example.com/{PASSKEY}/announce"
SECRET_MAGNET = ("magnet:?xt=urn:btih:" + "e" * 40 + "&tr=" + urllib.parse.quote(SECRET_TRACKER, safe=""))
SECRET_DOWNLOAD = f"https://tracker.example.com/download.php?id=7&passkey={PASSKEY}"
SECRET_INBOX_MAGNET = ("magnet:?xt=urn:btih:" + "0123456789abcdef" * 2 + "01234567" + "&tr=" + urllib.parse.quote(SECRET_TRACKER2, safe=""))
argv_failures = []


def argv_check(label, cond):
    print(("ok - " if cond else "FAIL - ") + label)
    if not cond:
        argv_failures.append(label)


def argv_shim(dirpath, name, real, log_path):
    dirpath.mkdir(exist_ok=True)
    s = dirpath / name
    s.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >>'{log_path}'\nexec '{real}' \"$@\"\n")
    s.chmod(0o755)


with harness.fixture_server() as (sport, senv0):
    tmpd = pathlib.Path(tempfile.mkdtemp(prefix="qbt-argv-"))
    alog = tmpd / "argv.log"
    alog.write_text("")
    for tool in ("curl", "jq", "python3"):
        argv_shim(tmpd / "bin", tool, shutil.which(tool), alog)
    senv = dict(senv0, PATH=str(tmpd / "bin") + os.pathsep + senv0["PATH"])
    slog = pathlib.Path(senv0["QBT_FIXTURE_LOG"])

    def posted(path):
        entries = json.loads(slog.read_text() or "[]")
        return [urllib.parse.parse_qs(e["body"]) for e in entries if e["method"] == "POST" and e["path"] == path]

    def via_stdin(args, data):
        return subprocess.run(["./qbt", *args, "--stdin"], env=senv, input=data.encode(), capture_output=True)

    r = via_stdin(["tracker-add", "a" * 40], SECRET_TRACKER)
    argv_check("tracker-add --stdin succeeds", r.returncode == 0)
    argv_check("tracker-add --stdin sends the url",
               any(q.get("urls") == [SECRET_TRACKER] for q in posted("/api/v2/torrents/addTrackers")))
    r = via_stdin(["tracker-edit", "a" * 40], SECRET_TRACKER + "\0" + SECRET_TRACKER2)
    argv_check("tracker-edit --stdin succeeds", r.returncode == 0)
    argv_check("tracker-edit --stdin sends both urls",
               any(q.get("url") == [SECRET_TRACKER] and q.get("newUrl") == [SECRET_TRACKER2]
                   for q in posted("/api/v2/torrents/editTracker")))
    r = via_stdin(["tracker-remove", "a" * 40], SECRET_TRACKER)
    argv_check("tracker-remove --stdin succeeds", r.returncode == 0)
    argv_check("tracker-remove --stdin sends the url",
               any(q.get("urls") == [SECRET_TRACKER] for q in posted("/api/v2/torrents/removeTrackers")))
    r = via_stdin(["add", "--stopped", "--category", "iso"], SECRET_MAGNET)
    argv_check("add --stdin a private magnet succeeds", r.returncode == 0)
    r = via_stdin(["add"], SECRET_DOWNLOAD)
    argv_check("add --stdin a passkey download url succeeds", r.returncode == 0)
    adds = posted("/api/v2/torrents/add")
    argv_check("add --stdin sends the magnet with its flags",
               any(q.get("urls") == [SECRET_MAGNET] and q.get("stopped") == ["true"] and q.get("category") == ["iso"]
                   for q in adds))
    argv_check("add --stdin sends the download url", any(q.get("urls") == [SECRET_DOWNLOAD] for q in adds))
    r = via_stdin(["tracker-add", "a" * 40], "")
    argv_check("tracker-add --stdin refuses an empty url", r.returncode != 0)
    r = via_stdin(["tracker-edit", "a" * 40], SECRET_TRACKER)
    argv_check("tracker-edit --stdin refuses a missing new url", r.returncode != 0)

    SEARCH_MAGNET = ("magnet:?xt=urn:btih:" + "fedcba9876543210" * 2 + "fedcba98" + "&tr="
                     + urllib.parse.quote(SECRET_TRACKER, safe=""))
    r = via_stdin(["search", "add"], SEARCH_MAGNET)
    argv_check("search add --stdin a private magnet succeeds", r.returncode == 0)
    argv_check("search add --stdin sends the magnet",
               any(q.get("urls") == [SEARCH_MAGNET] for q in posted("/api/v2/torrents/add")))

    # A --stdin run whose stdin never ends (Quickshell leaves the pipe open
    # when nothing is written) gives up, rather than holding a queue forever.
    held = subprocess.Popen(["./qbt", "tracker-add", "a" * 40, "--stdin"], env=senv,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # wait(), not communicate(), which would close stdin and send nothing.
    try:
        held.wait(timeout=25)
        argv_check("a --stdin run on a stdin that never ends gives up with the usage line",
                   held.returncode == 1 and b"usage:" in held.stderr.read())
    except subprocess.TimeoutExpired:
        held.kill()
        argv_check("a --stdin run on a stdin that never ends gives up with the usage line", False)
    finally:
        held.stdin.close()

    inbox = pathlib.Path(senv0["QBT_MAGNET_STATE"]) / "magnet-inbox.jsonl"
    inbox.parent.mkdir(parents=True, exist_ok=True)
    inbox.write_text(json.dumps({"url": SECRET_INBOX_MAGNET, "ts": 1}) + "\n")
    r = subprocess.run(["./qbt", "magnet-drain"], env=senv, text=True, capture_output=True)
    argv_check("magnet-drain of a private magnet succeeds", r.returncode == 0)
    argv_check("magnet-drain sends the magnet",
               any(q.get("urls") == [SECRET_INBOX_MAGNET] for q in posted("/api/v2/torrents/add")))

    logged = alog.read_text()
    argv_check("the shims saw curl, jq and python3 run",
               "/curl " in logged and "/jq " in logged and "/python3 " in logged)
    argv_check("no passkey on any curl, jq or python3 argv", PASSKEY not in logged)
    shutil.rmtree(tmpd, ignore_errors=True)

if argv_failures:
    raise SystemExit(f"{len(argv_failures)} argv-secrets-contract check(s) failed")
print("argv-secrets-contract ok")

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

# Review Focus 1: injection through qbt arguments for the Task 2 write
# commands. Every one of these must be rejected before any HTTP call --
# the fixture must record nothing at all.
HASH_A = "a" * 40
HASH_B = "b" * 40
TRACKER_URL = "http://tracker.example.com:6969/announce"


def _reject(env_, args, label):
    before = len(json.loads(Path(env_["QBT_FIXTURE_LOG"]).read_text() or "[]"))
    result = subprocess.run(["./qbt", *args], env=env_, text=True, capture_output=True)
    after = json.loads(Path(env_["QBT_FIXTURE_LOG"]).read_text() or "[]")
    # A leading-zero numeric argument (e.g. a port or octet) must be
    # rejected cleanly, never via a raw bash arithmetic error leaking to
    # stderr (bash reads a leading "0" as octal in `((...))`).
    no_crash = "value too great for base" not in result.stderr
    ok = result.returncode != 0 and len(after) == before and no_crash
    print(("ok - " if ok else "FAIL - ") + label)
    return ok, result


rej_failures = []
with harness.fixture_server() as (rport, renv):
    hash_cases = [
        ("all", "no lists/keywords accepted as a single hash"),
        (f"{HASH_A}|{HASH_B}", "no hash list accepted as a single hash"),
        (f"{HASH_A}&x=1", "shell/form metacharacter in hash"),
        ("zzz", "non-hex hash"),
    ]
    for hash_val, why in hash_cases:
        for args in (
            ["reannounce", hash_val],
            ["tracker-add", hash_val, TRACKER_URL],
            ["tracker-edit", hash_val, TRACKER_URL, TRACKER_URL],
            ["tracker-remove", hash_val, TRACKER_URL],
            ["fetch-metadata", hash_val],
        ):
            ok, _ = _reject(renv, args, f"{args[0]} rejects hash ({why}): {hash_val!r}")
            if not ok:
                rej_failures.append((args[0], hash_val))

    url_cases = [
        (f"{TRACKER_URL}|evil", "pipe in tracker url"),
        ("http://tracker.example.com/an nounce", "space in tracker url"),
        ("http://tracker.example.com/an\nnounce", "newline in tracker url"),
        ("ftp://tracker.example.com/announce", "disallowed scheme"),
        ("http://" + "a" * 2050 + ".example.com/announce", "over length limit"),
        ("not-a-url-at-all", "no scheme"),
    ]
    for url_val, why in url_cases:
        ok, _ = _reject(renv, ["tracker-add", HASH_A, url_val], f"tracker-add rejects url ({why})")
        if not ok:
            rej_failures.append(("tracker-add-url", why))

    # F13: an old tracker url containing "|" gets its own message and is
    # refused before any HTTP call, for both edit and remove.
    for args in (
        ["tracker-edit", HASH_A, f"{TRACKER_URL}|evil", TRACKER_URL],
        ["tracker-remove", HASH_A, f"{TRACKER_URL}|evil"],
    ):
        ok, result = _reject(renv, args, f"{args[0]} rejects a '|' old-url before any HTTP call")
        if not ok:
            rej_failures.append((args[0], "pipe-old-url-no-request"))
        msg_ok = "This tracker's URL can't be edited through the WebUI API" in result.stderr
        print(("ok - " if msg_ok else "FAIL - ") + f"{args[0]} '|' old-url gives the exact F13 message")
        if not msg_ok:
            rej_failures.append((args[0], "pipe-old-url-message"))

    peer_cases = [
        (f"1.2.3.4:1|{HASH_A}", "trailing garbage after ip:port"),
        ("1.2.3.4:0", "port below range"),
        ("1.2.3.4:65536", "port above range"),
        ("256.1.1.1:6881", "octet above 255"),
        ("2001:db8::1:6881", "unbracketed ipv6 is ambiguous"),
        ("1.2.3.4", "missing port"),
        ("1.2.3.4:", "empty port"),
        ("1.2.3.4:099999", "leading zero plus out-of-range port must not crash as octal"),
    ]
    for peer_val, why in peer_cases:
        ok, _ = _reject(renv, ["ban-peer", peer_val], f"ban-peer rejects peer ({why}): {peer_val!r}")
        if not ok:
            rej_failures.append(("ban-peer", peer_val))

if rej_failures:
    print(f"\n{len(rej_failures)} injection-rejection check(s) failed: {rej_failures}", file=sys.stderr)
    sys.exit(1)
print("injection-rejection-contract ok")

# Fix round 1, IMPORTANT 1: under a UTF-8 locale, bash's =~ collates a
# character *range* like [0-9a-fA-F] by LC_COLLATE order rather than raw
# code points, so it can accept non-ASCII characters that happen to collate
# inside that range (accented letters, fullwidth digits, superscripts).
# valid_hashes/valid_single_hash/valid_port/valid_ipv4 all switched to POSIX
# classes ([[:xdigit:]]/[[:digit:]]), which stay ASCII-only regardless of
# locale. Run this block under LANG=en_US.UTF-8 specifically, since that is
# the locale the bug reproduced under.
locale_failures = []
lenv = os.environ.copy()
lenv["LANG"] = "en_US.UTF-8"
lenv["LC_ALL"] = "en_US.UTF-8"
with harness.fixture_server(extra_env=lenv) as (lport, lenv2):
    non_ascii_hashes = [
        "a" * 39 + "á",   # accented a
        "a" * 39 + "Ä",
        "a" * 39 + "１",  # fullwidth digit 1
        "a" * 39 + "٣",   # arabic-indic digit
        "a" * 39 + "ｂ",  # fullwidth b
        "a" * 39 + "²",   # superscript 2
        "a" * 39 + "ß",
    ]
    for h in non_ascii_hashes:
        ok, result = _reject(lenv2, ["reannounce", h], f"reannounce rejects a non-ASCII hash under en_US.UTF-8: {h!r}")
        if not ok:
            locale_failures.append(("reannounce-nonascii-hash", h))

    non_ascii_peers = [
        "1.2.3.4:８0",   # fullwidth 8 in the port
        "1.2.3.4:٣",     # arabic-indic digit port
        "１.2.3.4:80",   # fullwidth digit in an octet
    ]
    for p in non_ascii_peers:
        before = len(json.loads(Path(lenv2["QBT_FIXTURE_LOG"]).read_text() or "[]"))
        result = subprocess.run(["./qbt", "ban-peer", p], env=lenv2, text=True, capture_output=True)
        after = json.loads(Path(lenv2["QBT_FIXTURE_LOG"]).read_text() or "[]")
        no_raw_bash_error = (
            "invalid integer constant" not in result.stderr
            and "value too great for base" not in result.stderr
        )
        ok = result.returncode != 0 and len(after) == before and no_raw_bash_error
        print(("ok - " if ok else "FAIL - ") + f"ban-peer rejects a non-ASCII peer under en_US.UTF-8 with no raw bash error: {p!r}")
        if not ok:
            locale_failures.append(("ban-peer-nonascii-peer", p, result.stderr))

    # Fix round 2, item 1: a QBT_FETCH_METADATA_TIMEOUT that's only a
    # "digit" under this locale's collation (a fullwidth "1") must be
    # rejected outright, before any request at all -- not silently
    # normalized to the default and left to blow up the wait-loop
    # arithmetic later, after the delete has already gone out.
    HASH_NOMETA_LOCALE = "d" * 40  # tests/fixtures/server.py's HASH_NOMETA
    fw_env = lenv2.copy()
    fw_env["QBT_FETCH_METADATA_TIMEOUT"] = "１"
    before = len(json.loads(Path(lenv2["QBT_FIXTURE_LOG"]).read_text() or "[]"))
    result = subprocess.run(["./qbt", "fetch-metadata", HASH_NOMETA_LOCALE], env=fw_env, text=True, capture_output=True)
    after = json.loads(Path(lenv2["QBT_FIXTURE_LOG"]).read_text() or "[]")
    no_raw_bash_error = "arithmetic syntax error" not in result.stderr and "operand expected" not in result.stderr
    ok = (
        result.returncode != 0
        and len(after) == before
        and "QBT_FETCH_METADATA_TIMEOUT" in result.stderr
        and no_raw_bash_error
    )
    print(("ok - " if ok else "FAIL - ") + "fetch-metadata rejects a fullwidth QBT_FETCH_METADATA_TIMEOUT under en_US.UTF-8, no request recorded")
    if not ok:
        locale_failures.append(("fetch-metadata-fullwidth-timeout", result.stderr))

    # Fix round 2, item 2: total_size containing a locale-collated "digit"
    # lookalike must refuse cleanly (It already has metadata.), never reach
    # `((...))` with it and print a raw bash arithmetic error first.
    HASH_BADSIZE_NONASCII = "7" * 40  # tests/fixtures/server.py's HASH_BADSIZE_NONASCII
    result = subprocess.run(["./qbt", "fetch-metadata", HASH_BADSIZE_NONASCII], env=lenv2, text=True, capture_output=True)
    no_raw_bash_error = "arithmetic syntax error" not in result.stderr and "operand expected" not in result.stderr
    ok = result.returncode != 0 and "already has metadata" in result.stderr and no_raw_bash_error
    print(("ok - " if ok else "FAIL - ") + "fetch-metadata refuses a non-ASCII total_size under en_US.UTF-8 with no raw bash error")
    if not ok:
        locale_failures.append(("fetch-metadata-nonascii-total-size", result.stderr))

if locale_failures:
    print(f"\n{len(locale_failures)} locale check(s) failed: {locale_failures}", file=sys.stderr)
    sys.exit(1)
print("locale-contract ok")

# Task 3 fix round 1 (Ruling AE): qbt and InspectorView accept exactly the
# same tracker URLs and peers. tests/inspector-view.test.js runs the same
# shared cases through InspectorView.trackerUrlError / peerError.
parity_failures = []
cases = json.loads(Path("tests/fixtures/validation-cases.json").read_text())
with harness.fixture_server(extra_env=lenv) as (pport, penv):
    def _parity(args, want_ok, label):
        before = len(json.loads(Path(penv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
        result = subprocess.run(["./qbt", *args], env=penv, text=True, capture_output=True)
        after = len(json.loads(Path(penv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
        raw_bash = any(t in result.stderr for t in ("value too great for base", "invalid integer constant", "arithmetic syntax error", "operand expected"))
        if want_ok:
            ok = result.returncode == 0 and after > before
        else:
            ok = result.returncode != 0 and after == before and not raw_bash
        print(("ok - " if ok else "FAIL - ") + label)
        if not ok:
            parity_failures.append((label, result.returncode, result.stderr.strip()))

    for c in cases["trackerUrls"]:
        _parity(["tracker-add", HASH_A, c["input"]], c["ok"], f"tracker-add parity ({'accepts' if c['ok'] else 'rejects'} {c['why']})")
    for c in cases["peers"]:
        _parity(["ban-peer", c["input"]], c["ok"], f"ban-peer parity ({'accepts' if c['ok'] else 'rejects'} {c['why']}): {c['input']!r}")

if parity_failures:
    print(f"\n{len(parity_failures)} validation parity check(s) failed: {parity_failures}", file=sys.stderr)
    sys.exit(1)
print("validation-parity-contract ok")

# Slice 3a, Task 2 (G4/OV5): qbt's new-name rules accept exactly the shared
# ok cases and give exactly the shared message for the rest, with no
# request on a rejection. Run under en_US.UTF-8 and again under C: the
# validator sets its own UTF-8 locale, so the bar's environment can't change
# how characters are counted.
name_failures = []
cenv = os.environ.copy()
cenv["LANG"] = "C"
cenv["LC_ALL"] = "C"
for label_locale, base_env in (("en_US.UTF-8", lenv), ("C", cenv)):
    with harness.fixture_server(extra_env=base_env) as (nport, nenv):
        for c in cases["names"]:
            command = "category-add" if c["kind"] == "category" else "tag-add"
            before = len(json.loads(Path(nenv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
            result = subprocess.run(["./qbt", command, c["input"]], env=nenv, text=True, capture_output=True)
            after = len(json.loads(Path(nenv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
            if c["ok"]:
                ok = result.returncode == 0 and after == before + 1
            else:
                ok = result.returncode != 0 and after == before and result.stderr.strip() == c["error"]
            label = f"{command} name rule under {label_locale} ({'accepts' if c['ok'] else 'rejects'} {c['why']})"
            print(("ok - " if ok else "FAIL - ") + label)
            if not ok:
                name_failures.append((label, result.returncode, result.stderr.strip()))

if name_failures:
    print(f"\n{len(name_failures)} name-rule check(s) failed: {name_failures}", file=sys.stderr)
    sys.exit(1)
print("name-rule-contract ok")

# Slice 3b (D5): qbt accepts exactly the shared canonical limit values, and
# refuses the rest with no request and no raw bash arithmetic error, under
# en_US.UTF-8 and C. HASH_A is unfinished, so the D8 guard never fires.
limit_failures = []
LIMIT_COMMANDS = {
    "ratios": lambda v: ["share-limits", HASH_A, "--ratio", v],
    "seedTimes": lambda v: ["share-limits", HASH_A, "--seed-time", v],
    "speeds": lambda v: ["limit", HASH_A, "up", v],
}
for label_locale, base_env in (("en_US.UTF-8", lenv), ("C", cenv)):
    with harness.fixture_server(extra_env=base_env) as (lport, lenv_):
        for key, command in LIMIT_COMMANDS.items():
            for c in cases[key]:
                log_path = Path(lenv_["QBT_FIXTURE_LOG"])
                before = len(json.loads(log_path.read_text() or "[]"))
                result = subprocess.run(["./qbt", *command(c["input"])], env=lenv_, text=True, capture_output=True)
                after = json.loads(log_path.read_text() or "[]")[before:]
                raw_bash = any(t in result.stderr for t in ("value too great for base", "invalid integer constant", "arithmetic syntax error", "operand expected", "syntax error"))
                writes = [e for e in after if e["method"] == "POST"]
                if c["ok"]:
                    ok = result.returncode == 0 and len(writes) == 1
                else:
                    ok = result.returncode != 0 and not after and not raw_bash
                label = f"{key} under {label_locale} ({'accepts' if c['ok'] else 'rejects'} {c['why']}): {c['input']!r}"
                print(("ok - " if ok else "FAIL - ") + label)
                if not ok:
                    limit_failures.append((label, result.returncode, result.stderr.strip()))

if limit_failures:
    print(f"\n{len(limit_failures)} limit-value check(s) failed: {limit_failures}", file=sys.stderr)
    sys.exit(1)
print("limit-value-contract ok")

# Whole-branch review CRITICAL: the localhost guard must look at the whole
# base, not a sed-extracted "host" (userinfo, backslash tricks, a foreign
# scheme) and must never splice an unchecked WebUI\Port from the conf.
guard_failures = []
free = socket.socket()
free.bind(("127.0.0.1", 0))
unused_port = free.getsockname()[1]
free.close()
with harness.fixture_server() as (gport, genv):
    def _guard(env_, label):
        before = len(json.loads(Path(genv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
        result = subprocess.run(["./qbt", "reannounce", HASH_A], env=env_, text=True, capture_output=True)
        after = len(json.loads(Path(genv["QBT_FIXTURE_LOG"]).read_text() or "[]"))
        ok = (
            result.returncode != 0
            and after == before
            and "refusing non-localhost host" in result.stderr
            and "example.invalid" not in result.stderr
            and "127.0.0.2" not in result.stderr
        )
        print(("ok - " if ok else "FAIL - ") + label)
        if not ok:
            guard_failures.append((label, result.returncode, result.stderr.strip()))

    for base in (
        f"http://127.0.0.1:80@127.0.0.2:{unused_port}",
        f"gopher://127.0.0.1:{gport}",
        f"http://127.0.0.1:{gport}\\@x",
    ):
        benv = genv.copy()
        benv["QBT_BASE"] = base
        _guard(benv, f"localhost guard refuses QBT_BASE={base!r}")

    conf_dir = Path(tempfile.mkdtemp(prefix="qbt-badport-"))
    try:
        (conf_dir / "qBittorrent.conf").write_text("[Preferences]\nWebUI\\Port=80@example.invalid\n")
        cenv = genv.copy()
        cenv.pop("QBT_BASE", None)
        cenv["QBT_CONF"] = str(conf_dir / "qBittorrent.conf")
        _guard(cenv, "localhost guard refuses a conf WebUI\\Port=80@example.invalid")
    finally:
        import shutil as _sh
        _sh.rmtree(conf_dir, ignore_errors=True)

    # The plain fixture base still works.
    ok_run = subprocess.run(["./qbt", "reannounce", HASH_A], env=genv, text=True, capture_output=True)
    good = ok_run.returncode == 0
    print(("ok - " if good else "FAIL - ") + "localhost guard still accepts http://127.0.0.1:<port>")
    if not good:
        guard_failures.append(("plain base", ok_run.stderr))

if guard_failures:
    print(f"\n{len(guard_failures)} localhost-guard check(s) failed: {guard_failures}", file=sys.stderr)
    sys.exit(1)
print("localhost-guard-contract ok")
PY

# Slice 4a: /app/preferences and setPreferences as 5.2.3 behaves (the
# fixture's contract that tests/test_prefs.py leans on), and qbt prefs'
# shape against the whole 223-key dump.
python3 - <<'PY'
import json, subprocess, sys, urllib.error, urllib.request
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

DUMP_PATH = Path("tests/fixtures/preferences-5.2.3.json")
DUMP = json.loads(DUMP_PATH.read_text())
failures = []


def check(label, cond):
    print(("ok - " if cond else "FAIL - ") + label)
    if not cond:
        failures.append(label)


with harness.fixture_server(extra_env={"QBT_FIXTURE_PREFS": str(DUMP_PATH)}) as (port, env):
    base = f"http://127.0.0.1:{port}/api/v2/app"

    def get():
        with urllib.request.urlopen(f"{base}/preferences", timeout=5) as r:
            return json.loads(r.read())

    def post(raw):
        req = urllib.request.Request(f"{base}/setPreferences", data=f"json={quote(raw)}".encode(), method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status

    check("preferences GET serves the 223-key dump", get() == DUMP and len(DUMP) == 223)
    check("setPreferences: malformed JSON is 200 and changes nothing", post("{not json") == 200 and get() == DUMP)
    check("setPreferences: an unknown key is 200 and ignored", post('{"no_such_key": 1}') == 200 and "no_such_key" not in get())
    check("setPreferences: a bad value is ignored", post('{"dht": "yes", "encryption": 9, "proxy_type": "socks5"}') == 200 and get() == DUMP)
    check("setPreferences: a read-only key is ignored", post('{"add_trackers_url_list": "x"}') == 200 and get() == DUMP)
    post('{"schedule_from_hour": 3}')
    check("setPreferences: an hour alone doesn't apply", get()["schedule_from_hour"] == DUMP["schedule_from_hour"])
    post('{"schedule_from_hour": 3, "schedule_from_min": 7}')
    got = get()
    check("setPreferences: hour and minute together apply", (got["schedule_from_hour"], got["schedule_from_min"]) == (3, 7))
    post('{"dl_limit": 1536, "app_instance_name": "  x  ", "autorun_program": "  y  ", "save_path": "/srv//t/./u/../"}')
    got = get()
    check("setPreferences: speeds store whole KiB, only 5.2.3's four keys are trimmed, paths are cleaned",
          (got["dl_limit"], got["app_instance_name"], got["autorun_program"], got["save_path"]) == (1024, "  x  ", "y", "/srv/t"))
    post('{"announce_ip": "2001:DB8:0:0:0:0:0:1"}')
    a = get()["announce_ip"]
    post('{"announce_ip": "not.an.ip"}')
    check("setPreferences: announce_ip stored as Qt writes it, \"\" when invalid", (a, get()["announce_ip"]) == ("2001:db8::1", ""))
    try:
        post('{"web_ui_username": "ab"}')
        code = 200
    except urllib.error.HTTPError as e:
        code = e.code
    check("setPreferences: a short web_ui_username is 400 and changes nothing", code == 400 and get()["web_ui_username"] == DUMP["web_ui_username"])
    post('{"max_ratio": 2, "listen_port": 0}')
    got = get()
    check("setPreferences: derived keys are recomputed", (got["max_ratio_enabled"], got["random_port"]) == (True, True))

    r = subprocess.run(["./qbt", "prefs"], env=env, text=True, capture_output=True)
    out = json.loads(r.stdout) if r.returncode == 0 else {}
    check("qbt prefs: one object with every key", r.returncode == 0 and set(out) == set(DUMP))
    check("qbt prefs: the four secrets as {set: bool}", all(out.get(k) == {"set": False} for k in (
        "proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key")))

    for bad in ("http://example.invalid:1", "http://127.0.0.1:80@127.0.0.2:1"):
        genv = dict(env, QBT_BASE=bad)
        log = Path(env["QBT_FIXTURE_LOG"])
        before = len(json.loads(log.read_text() or "[]"))
        r = subprocess.run(["./qbt", "pref-set", "dht", "--", "true"], env=genv, text=True, capture_output=True)
        check(f"qbt pref-set refuses QBT_BASE={bad!r} with no request",
              r.returncode != 0 and len(json.loads(log.read_text() or "[]")) == before and "example" not in r.stderr)

if failures:
    print(f"\n{len(failures)} preferences-contract check(s) failed", file=sys.stderr)
    sys.exit(1)
print("preferences-contract ok")
PY

# Slice 5b1: `qbt rss` (tests/fixtures/rss-contract.md) and the fixture's
# RSS routes as 5.2.3 behaves: the writes are POST only (GET is 405),
# markAsRead answers 204 and refreshItem 200 on a missing path, values
# travel on stdin, and a refused value or a usage error sends no request
# at all. Slice 5b2 adds the auto-download rules (rss-rules-contract.md):
# setRule/renameRule/removeRule are POST only, renameRule is a silent no-op
# on a clash, and a new rule is created disabled.
python3 - <<'PY'
import json, subprocess, sys, urllib.error, urllib.request
from pathlib import Path

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

CASES = json.loads(Path("tests/fixtures/rss-rules-cases.json").read_text())
S = CASES["sentences"]
failures = []


def check(label, cond):
    print(("ok - " if cond else "FAIL - ") + label)
    if not cond:
        failures.append(label)


with harness.fixture_server(extra_env={"QBT_FIXTURE_PREFS": "tests/fixtures/preferences-5.2.3.json"}) as (port, env):
    base = f"http://127.0.0.1:{port}"
    log = Path(env["QBT_FIXTURE_LOG"])

    def count():
        return len(json.loads(log.read_text() or "[]"))

    def rss(sub, *fields, env_=None, argv=None):
        return subprocess.run(["./qbt", *(argv or ["rss", sub])], env=env_ or env, capture_output=True,
                              input="\0".join(fields).encode())

    def post(path, body):
        req = urllib.request.Request(base + path, data=body.encode(), method="POST")
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status

    for action in ("addFolder", "addFeed", "removeItem", "moveItem", "markAsRead", "refreshItem"):
        try:
            urllib.request.urlopen(f"{base}/api/v2/rss/{action}?path=x", timeout=5)
            code = 200
        except urllib.error.HTTPError as e:
            code = e.code
        check(f"GET rss/{action} is 405", code == 405)
    # rsscontroller.cpp returns before setResult: 204, as the fixture since 58cc6f3.
    check("markAsRead on a missing path answers 204", post("/api/v2/rss/markAsRead", "itemPath=nope") == 204)
    check("refreshItem on a missing path answers 200", post("/api/v2/rss/refreshItem", "itemPath=nope") == 200)

    refusals = [
        (("add-feed", "javascript:alert(1)", "F"), S["feedUrlScheme"], 1),
        (("add-feed", "https://u:p@example.org/", "F"), S["feedUrlUser"], 1),
        (("add-feed", "https://example.org/a|b", "F"), S["feedUrlBad"], 1),
        (("add-feed", "https://example.org/", "a\nb"), S["nameControl"], 1),
        (("add-folder", " padded"), S["rssUsage"], 2),
        (("rename", "A\\x", "B\\x"), S["rssUsage"], 2),
        (("add", "javascript:alert(1)", ""), S["badTorrentLink"], 1),
        (("add", "https://example.org/n", "https://example.org/n"), S["noTorrent"], 1),
        (("mark-read", "A", "", "-1"), S["rssUsage"], 2),
        (("add-feed", "https://example.org/"), S["rssUsage"], 2),
        (("nope",), S["rssUsage"], 2),
    ]
    for (sub, *fields), message, code in refusals:
        before = count()
        r = rss(sub, *fields)
        check(f"rss {sub} {fields!r} refused with no request",
              (r.returncode, r.stderr.decode()) == (code, message + "\n") and count() == before)

    r = rss("items")
    out = json.loads(r.stdout) if r.returncode == 0 else {}
    check("rss items: the empty tree and the 5.2.3 preferences",
          out == {"processing": False, "refreshInterval": 30, "feeds": [], "articles": []})
    r = rss("add-folder", "Linux")
    check("rss add-folder", r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "path": "Linux"})
    r = rss("add-feed", "https://www.debian.org/security/dsa", "Linux\\Debian")
    check("rss add-feed", r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "path": "Linux\\Debian"})
    r = rss("add-feed", "https://www.debian.org/security/dsa", "Linux\\Again")
    check("rss add-feed: a 409 in plain words", (r.returncode, r.stderr.decode()) == (1, S["feedDup"] + "\n"))
    r = rss("remove", "Linux")
    check("rss remove", r.returncode == 0 and json.loads(r.stdout) == {"ok": True})

    # Slice 5b2: the rules.
    RS = json.loads(Path("tests/fixtures/rss-autorules-cases.json").read_text())["sentences"]
    for action in ("setRule", "renameRule", "removeRule"):
        try:
            urllib.request.urlopen(f"{base}/api/v2/rss/{action}?ruleName=x", timeout=5)
            code = 200
        except urllib.error.HTTPError as e:
            code = e.code
        check(f"GET rss/{action} is 405", code == 405)
    for (sub, *fields), message, code in [
        (("rule-create", " ", ""), RS["ruleNameEmpty"], 1),
        (("rule-check", "mustContain", "(", "true"), RS["badRegex"], 1),
        (("rule-set", "A", "{}", "{}", "keep"), RS["ruleUsage"], 2),
        (("rule-set", "A", "{}", "{}"), RS["ruleUsage"], 2),
    ]:
        before = count()
        r = rss(sub, *fields)
        check(f"rss {sub} {fields!r} refused with no request",
              (r.returncode, r.stderr.decode()) == (code, message + "\n") and count() == before)
    r = rss("rule-create", "A", "https://www.debian.org/security/dsa")
    check("rss rule-create", r.returncode == 0 and json.loads(r.stdout) == {"ok": True, "name": "A"})
    r = rss("rule-create", "B", "")
    rules = json.loads(rss("rules").stdout)
    check("rss rules: both disabled, sorted", [(x["name"], x["enabled"]) for x in rules["rules"]] == [("A", False), ("B", False)])
    check("renameRule on a clash answers 200 and changes nothing",
          post("/api/v2/rss/renameRule", "ruleName=A&newRuleName=B") == 200
          and [x["name"] for x in json.loads(rss("rules").stdout)["rules"]] == ["A", "B"])
    r = rss("rule-rename", "A", "B")
    check("rss rule-rename pre-checks the clash", (r.returncode, r.stderr.decode()) == (1, RS["ruleExists"].replace("<name>", "B") + "\n"))
    r = rss("rule-set", "A", '{"mustContain": "DSA"}', '{"mustContain": "", "enabled": false}', "keep")
    check("rss rule-set", r.returncode == 0 and json.loads(r.stdout) == {"ok": True})
    for name in ("A", "B"):
        r = rss("rule-remove", name)
        check(f"rss rule-remove {name}", r.returncode == 0 and json.loads(r.stdout) == {"ok": True})

    for bad in ("http://example.invalid:1", "http://127.0.0.1:80@127.0.0.2:1"):
        before = count()
        r = rss("items", env_=dict(env, QBT_BASE=bad))
        check(f"qbt rss refuses QBT_BASE={bad!r} with no request",
              r.returncode != 0 and count() == before and "example" not in r.stderr.decode())

if failures:
    print(f"\n{len(failures)} rss-contract check(s) failed", file=sys.stderr)
    sys.exit(1)
print("rss-contract ok")
PY
