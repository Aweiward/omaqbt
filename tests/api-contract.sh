#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, socket, subprocess, sys, time, urllib.request
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

    # No VPN iface detected: no warning fields, and no preferences call at all.
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

    # With the VPN iface up: report where the running daemon is bound.
    reqs_before = json.loads(log.read_text())
    assert "/api/v2/app/preferences" not in [r["path"] for r in reqs_before]

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
PY
