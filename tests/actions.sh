#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

HASH_A = "a" * 40
HASH_B = "b" * 40
HASH_NOMETA = "d" * 40
HASH_META = "e" * 40
HASH_RUNNING = "f" * 40
HASH_NOMAGNET = "9" * 40
HASH_BADSIZE = "8" * 40
HASH_NOTFOUND = "0" * 40
MAGNET_NOMETA = f"magnet:?xt=urn:btih:{HASH_NOMETA}&dn=nometa"
TRACKER_URL = "http://tracker.example.com:6969/announce"
TRACKER_URL2 = "https://tracker2.example.com:443/announce"
PEER = "203.0.113.5:6881"
EXPECTED_PATH = Path("tests/fixtures/actions-expected.json")


def make_stub_bin():
    """A temp bin dir with fake omarchy-shell/notify-send, the way
    tests/magnet-handler.sh stubs them, so a fetch-metadata re-add failure
    never calls the real shell or notify-send. The stub shell always exits
    non-zero (no live IPC function), so magnet-inbox falls through to
    notify + leaves the magnet in the inbox file."""
    root = Path(tempfile.mkdtemp(prefix="qbt-actions-fm-"))
    raise_log = root / "raise.log"
    notify_log = root / "notify.log"
    raise_log.write_text("")
    notify_log.write_text("")
    raise_cmd = root / "omarchy-shell"
    raise_cmd.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>{raise_log}\nexit 1\n")
    raise_cmd.chmod(0o755)
    notify_cmd = root / "notify-send"
    notify_cmd.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >>{notify_log}\n")
    notify_cmd.chmod(0o755)
    return root, raise_cmd, notify_cmd, raise_log, notify_log


def fetch_metadata_env(timeout=None):
    """extra_env for a fetch-metadata fixture_server() block: its own magnet
    state dir plus the raise/notify stubs, on every block (not just the
    add-fails ones) so an unexpected failure never reaches the real shell."""
    stub_root, raise_cmd, notify_cmd, raise_log, notify_log = make_stub_bin()
    magnet_state = tempfile.mkdtemp(prefix="qbt-actions-fm-state-")
    extra_env = {
        "QBT_MAGNET_STATE": magnet_state,
        "QBT_RAISE_CMD": str(raise_cmd),
        "QBT_NOTIFY_CMD": str(notify_cmd),
    }
    if timeout is not None:
        extra_env["QBT_FETCH_METADATA_TIMEOUT"] = str(timeout)
    return extra_env, Path(magnet_state), raise_log, notify_log, stub_root

# Same fixed order and args as the pre-change baseline capture that produced
# tests/fixtures/actions-expected.json. Do not add a `status` call anywhere
# in this file: it would mint a session cookie and make the recorded
# requests diverge from the baseline (which never calls `status`).
# Slice 3b re-baselined the one `sharelimit` entry on purpose: 5.2.3's
# setShareLimits answers 400 without all four limits, so the widget's call
# now reads info, categories and preferences first and sends all four.
SINGLE_HASH_CALLS = [
    ["start", HASH_A],
    ["stop", HASH_A],
    ["recheck", HASH_A],
    ["delete", HASH_A, "--files"],
    ["limit", HASH_A, "dl", "1048576"],
    ["sequential", HASH_A],
    ["sharelimit", HASH_A, "1"],
    ["prio", HASH_A, "1", "0"],
    ["files", HASH_A],
    ["set-location", HASH_A, "/dl/iso"],
]

MULTI_HASH_CALLS = [
    (["start", f"{HASH_A}|{HASH_B}"], "/api/v2/torrents/start"),
    (["stop", f"{HASH_A}|{HASH_B}"], "/api/v2/torrents/stop"),
    (["recheck", f"{HASH_A}|{HASH_B}"], "/api/v2/torrents/recheck"),
    (["delete", f"{HASH_A}|{HASH_B}", "--files"], "/api/v2/torrents/delete"),
]

failures = []


def check(label, cond):
    if cond:
        print(f"ok - {label}")
    else:
        print(f"FAIL - {label}", file=sys.stderr)
        failures.append(label)


def run(env, *args):
    return subprocess.run(["./qbt", *args], env=env, text=True, capture_output=True)


def read_log(env):
    path = Path(env["QBT_FIXTURE_LOG"])
    return json.loads(path.read_text()) if path.exists() else []


def drop_readiness_probe(entries):
    # harness.fixture_server() itself polls sync/maindata to detect that the
    # server is up before handing control back; that probe lands in the same
    # log. It is harness overhead, not a qbt request, and a slow runner can
    # in principle cause the client to retry it, so exclude it rather than
    # bake its exact count into the expected fixture.
    return [e for e in entries if e["path"] != "/api/v2/sync/maindata"]


# 1. Regression: single-hash forms of every hardened command must produce
#    the exact same request sequence they produced at the base commit.
with harness.fixture_server() as (port, env):
    for args in SINGLE_HASH_CALLS:
        result = run(env, *args)
        check(f"regression call succeeds: {' '.join(args)}", result.returncode == 0)
    actual = drop_readiness_probe(read_log(env))
    expected = drop_readiness_probe(json.loads(EXPECTED_PATH.read_text()))
    check("single-hash regression matches base-commit request log", actual == expected)
    if actual != expected:
        print("expected:", json.dumps(expected, indent=2), file=sys.stderr)
        print("actual:", json.dumps(actual, indent=2), file=sys.stderr)

# 2. Multi-hash: each command produces exactly one POST with hashes=a|b
#    (URL-encoding of "|" is acceptable; decode before comparing).
with harness.fixture_server() as (port, env):
    for args, path in MULTI_HASH_CALLS:
        before = len(read_log(env))
        result = run(env, *args)
        check(f"multi-hash call succeeds: {' '.join(args)}", result.returncode == 0)
        entries = read_log(env)
        new_entries = entries[before:]
        posts = [e for e in new_entries if e["method"] == "POST" and e["path"] == path]
        check(f"exactly one POST to {path}", len(posts) == 1)
        if posts:
            from urllib.parse import parse_qs

            qs = parse_qs(posts[0]["body"])
            hashes = (qs.get("hashes") or [""])[0]
            check(f"{path} hashes body decodes to a|b", hashes == f"{HASH_A}|{HASH_B}")

# 3. `start all` still works: single POST, hashes=all.
with harness.fixture_server() as (port, env):
    before = len(read_log(env))
    result = run(env, "start", "all")
    check("start all succeeds", result.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/start"]
    check("start all produces exactly one POST", len(posts) == 1)
    if posts:
        check("start all body is hashes=all", posts[0]["body"] == "hashes=all")

# 4. Invalid hash lists are rejected before any HTTP call is made.
with harness.fixture_server() as (port, env):
    before = len(read_log(env))
    bad_start = run(env, "start", "a&x=1")
    check("start with shell-metacharacter hash fails", bad_start.returncode != 0)
    check("start with shell-metacharacter hash makes no request", len(read_log(env)) == before)

    bad_stop = run(env, "stop", "zzz")
    check("stop with non-hex hash fails", bad_stop.returncode != 0)
    check("stop with non-hex hash makes no request", len(read_log(env)) == before)

    bad_multi = run(env, "recheck", f"{HASH_A}|not-a-hash")
    check("recheck with one invalid segment in a hash list fails", bad_multi.returncode != 0)
    check("recheck with one invalid segment makes no request", len(read_log(env)) == before)

# 5. magnet-pending-drop: applies the same validation, even though it makes
#    no HTTP call of its own. Magnet-inbox commands are untouched (out of
#    scope for this task).
with tempfile.TemporaryDirectory(prefix="qbt-actions-magnet-") as magnet_state:
    with harness.fixture_server(extra_env={"QBT_MAGNET_STATE": magnet_state}) as (port, env):
        pending = [{"hash": HASH_A, "hashes": [HASH_A], "url": "magnet:?xt=urn:btih:" + HASH_A}]
        pending_path = Path(magnet_state) / "magnet-pending.json"
        pending_path.parent.mkdir(parents=True, exist_ok=True)
        pending_path.write_text(json.dumps(pending))

        bad_drop = run(env, "magnet-pending-drop", "not-a-hash")
        check("magnet-pending-drop rejects a non-hex hash", bad_drop.returncode != 0)
        still_there = json.loads(run(env, "magnet-pending-list").stdout)
        check("magnet-pending-drop leaves pending list untouched on rejection", still_there == pending)

        good_drop = run(env, "magnet-pending-drop", HASH_A)
        check("magnet-pending-drop accepts a valid hash", good_drop.returncode == 0)
        after = json.loads(run(env, "magnet-pending-list").stdout)
        check("magnet-pending-drop removes the matching row", after == [])

# 6. reannounce, tracker-add/-edit/-remove, ban-peer: exact request shape.
with harness.fixture_server() as (port, env):
    before = len(read_log(env))
    r = run(env, "reannounce", HASH_A)
    check("reannounce succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/reannounce"]
    check("reannounce makes exactly one POST", len(posts) == 1)
    if posts:
        check("reannounce body is hashes=<hash>", posts[0]["body"] == f"hashes={HASH_A}")

    before = len(read_log(env))
    r = run(env, "tracker-add", HASH_A, TRACKER_URL)
    check("tracker-add succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/addTrackers"]
    check("tracker-add makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("tracker-add hash", (qs.get("hash") or [""])[0] == HASH_A)
        check("tracker-add urls decodes to the tracker url", (qs.get("urls") or [""])[0] == TRACKER_URL)
        check("tracker-add body has only hash and urls keys", set(qs.keys()) == {"hash", "urls"})

    before = len(read_log(env))
    r = run(env, "tracker-edit", HASH_A, TRACKER_URL, TRACKER_URL2)
    check("tracker-edit succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/editTracker"]
    check("tracker-edit makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("tracker-edit hash", (qs.get("hash") or [""])[0] == HASH_A)
        check("tracker-edit origUrl", (qs.get("origUrl") or [""])[0] == TRACKER_URL)
        check("tracker-edit newUrl", (qs.get("newUrl") or [""])[0] == TRACKER_URL2)

    before = len(read_log(env))
    r = run(env, "tracker-remove", HASH_A, TRACKER_URL)
    check("tracker-remove succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/removeTrackers"]
    check("tracker-remove makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("tracker-remove hash", (qs.get("hash") or [""])[0] == HASH_A)
        check("tracker-remove urls decodes to the tracker url", (qs.get("urls") or [""])[0] == TRACKER_URL)

    before = len(read_log(env))
    r = run(env, "ban-peer", PEER)
    check("ban-peer succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/transfer/banPeers"]
    check("ban-peer makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("ban-peer peers decodes to the peer", (qs.get("peers") or [""])[0] == PEER)

    ipv6_peer = "[2001:db8::1]:6881"
    before = len(read_log(env))
    r = run(env, "ban-peer", ipv6_peer)
    check("ban-peer accepts a bracketed IPv6 peer", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/transfer/banPeers"]
    check("ban-peer ipv6 makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("ban-peer ipv6 peers decodes verbatim", (qs.get("peers") or [""])[0] == ipv6_peer)

    # & and = are legal in tracker URLs (passkeys live in the query string).
    # They must survive round-trip through @uri encoding, never get treated
    # as extra form fields, and never break the request into more than one
    # key.
    tricky = "http://tracker.example.com:6969/announce?passkey=abc&x=1"
    before = len(read_log(env))
    r = run(env, "tracker-add", HASH_A, tricky)
    check("tracker-add with & and = in the url succeeds", r.returncode == 0)
    entries = read_log(env)[before:]
    posts = [e for e in entries if e["method"] == "POST" and e["path"] == "/api/v2/torrents/addTrackers"]
    check("tracker-add with & and = makes exactly one POST", len(posts) == 1)
    if posts:
        qs = parse_qs(posts[0]["body"])
        check("tracker-add with & and = body has only hash and urls keys", set(qs.keys()) == {"hash", "urls"})
        check("tracker-add with & and = urls decodes verbatim", (qs.get("urls") or [""])[0] == tricky)

# 7. fetch-metadata happy path: GET info -> POST delete -> GET info (poll,
#    resolves immediately) -> POST add -> GET info (poll, resolves
#    immediately). The saved fields (magnet, savepath, category, tags) ride
#    along on the add body.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env()
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        before = len(read_log(env))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata happy path succeeds", r.returncode == 0)
        entries = read_log(env)[before:]
        relevant = [e for e in entries if e["path"] in (
            "/api/v2/torrents/info", "/api/v2/torrents/delete", "/api/v2/torrents/add",
        )]
        shapes = [(e["method"], e["path"]) for e in relevant]
        expected_shapes = [
            ("GET", "/api/v2/torrents/info"),
            ("POST", "/api/v2/torrents/delete"),
            ("GET", "/api/v2/torrents/info"),
            ("POST", "/api/v2/torrents/add"),
            ("GET", "/api/v2/torrents/info"),
        ]
        check("fetch-metadata happy path request sequence", shapes == expected_shapes)
        if len(relevant) >= 2:
            delete_qs = parse_qs(relevant[1]["body"])
            check("fetch-metadata delete hashes", (delete_qs.get("hashes") or [""])[0] == HASH_NOMETA)
            check("fetch-metadata delete deleteFiles=false", (delete_qs.get("deleteFiles") or [""])[0] == "false")
        if len(relevant) >= 4:
            add_qs = parse_qs(relevant[3]["body"])
            check("fetch-metadata add urls is the magnet", (add_qs.get("urls") or [""])[0] == MAGNET_NOMETA)
            check("fetch-metadata add savepath", (add_qs.get("savepath") or [""])[0] == "/home/user/Downloads/nometa")
            check("fetch-metadata add category", (add_qs.get("category") or [""])[0] == "linux")
            check("fetch-metadata add tags", (add_qs.get("tags") or [""])[0] == "iso,nometa")
            check("fetch-metadata add stopCondition", (add_qs.get("stopCondition") or [""])[0] == "MetadataReceived")
            check("fetch-metadata add stopped=false", (add_qs.get("stopped") or [""])[0] == "false")
            check("fetch-metadata add paused=false", (add_qs.get("paused") or [""])[0] == "false")
        check("fetch-metadata happy path never touched the raise stub", raise_log.read_text() == "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 8. fetch-metadata refusals: each stops after the initial GET, before any
#    delete, with the documented message. total_size fails closed (a value
#    that isn't a clean integer must refuse, not be treated as "no
#    metadata"), and a hash absent from torrents/info entirely is refused
#    too.
REFUSALS = [
    (HASH_META, "It already has metadata."),
    (HASH_RUNNING, "Stop it first."),
    (HASH_NOMAGNET, "No magnet link for this torrent."),
    (HASH_BADSIZE, "It already has metadata."),
    (HASH_NOTFOUND, "torrent not found"),
]
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env()
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        for hash_, message in REFUSALS:
            before = len(read_log(env))
            r = run(env, "fetch-metadata", hash_)
            check(f"fetch-metadata refuses {hash_}: exit != 0", r.returncode != 0)
            check(f"fetch-metadata refuses {hash_}: message", message in r.stderr)
            entries = read_log(env)[before:]
            deletes = [e for e in entries if e["path"] == "/api/v2/torrents/delete"]
            check(f"fetch-metadata refuses {hash_}: no delete", len(deletes) == 0)
        check("fetch-metadata refusals never touched the raise stub", raise_log.read_text() == "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# Every failure from the moment the delete POST is sent must land the magnet
# in the inbox (with the 20-item cap bypassed) and report an honest failure
# -- never claim the torrent is still there, and never lose the magnet.
# Sections 9-12 cover the four ways that can happen (Review Focus 2 / the
# fix-round-1 CRITICAL).


def check_rescued(label, r, magnet_state, raise_log, magnet=MAGNET_NOMETA):
    check(f"{label}: exit != 0", r.returncode != 0)
    check(f"{label}: honest message", "the magnet is in your inbox" in r.stderr)
    check(f"{label}: message never claims the torrent is still there", "didn't remove it in time" not in r.stderr)
    inbox_path = magnet_state / "magnet-inbox.jsonl"
    check(f"{label}: inbox has the magnet", inbox_path.exists() and magnet in inbox_path.read_text())
    check(f"{label}: raise stub was exercised (never the real shell)", raise_log.read_text() != "")


# 9. delete never takes effect (the row stays listed forever): wait-for-gone
#    times out on a real, valid, unchanging count -- still a rescue, not the
#    old "didn't remove it in time" dead end. No add is ever attempted.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"delete": "noop"}))
        before = len(read_log(env))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata delete-noop", r, magnet_state, raise_log)
        entries = read_log(env)[before:]
        adds = [e for e in entries if e["path"] == "/api/v2/torrents/add"]
        check("fetch-metadata delete-noop: no add", len(adds) == 0)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 10. the delete is applied, but torrents/info starts 500ing on every poll
#     right after (CRITICAL repro: a GET failure must not read as "gone").
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"info_after_delete": "500"}))
        before = len(read_log(env))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata info-500-after-delete", r, magnet_state, raise_log)
        entries = read_log(env)[before:]
        adds = [e for e in entries if e["path"] == "/api/v2/torrents/add"]
        check("fetch-metadata info-500-after-delete: no add", len(adds) == 0)
        deletes = [e for e in entries if e["path"] == "/api/v2/torrents/delete"]
        check("fetch-metadata info-500-after-delete: the delete itself was still sent", len(deletes) == 1)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 11. the delete is applied (the torrent really is gone) but the response
#     itself comes back as an error -- curl/api() fails even though
#     qBittorrent already did the work. Must still rescue, not die outright.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"delete": "500"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata delete-applied-but-500", r, magnet_state, raise_log)
        import urllib.request
        rows = json.loads(urllib.request.urlopen(env["QBT_BASE"] + "/api/v2/torrents/info?hashes=" + HASH_NOMETA).read())
        check("fetch-metadata delete-applied-but-500: the torrent really is gone from qbt", len(rows) == 0)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 12. the delete is applied late: qBittorrent answers 200 immediately but
#     only actually removes the torrent after the poll window has already
#     given up. Must still rescue (magnet-drain's library dedupe makes an
#     unnecessary inbox entry harmless), never silently proceed to add.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"delete": "late"}))
        before = len(read_log(env))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata delete-applied-late", r, magnet_state, raise_log)
        entries = read_log(env)[before:]
        adds = [e for e in entries if e["path"] == "/api/v2/torrents/add"]
        check("fetch-metadata delete-applied-late: no add", len(adds) == 0)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 13. fetch-metadata add-fails (404 from add): the magnet lands in the
#     inbox, the raise stub (never the real shell) is exercised, exit != 0.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "404"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata add-404", r, magnet_state, raise_log)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 14. fetch-metadata add-fails (200 "Ok." but the hash never comes back):
#     same recovery as a hard add failure.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "silent"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata add-silent", r, magnet_state, raise_log)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 14b. the add answers 200 with a body that isn't "Ok." but does add the
#      torrent: success is proved by the wait-for-present poll, never by
#      the add's body (its format isn't a confirmed qBittorrent contract).
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=2)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        Path(env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps({"add": "oddbody"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata add-oddbody: succeeds", r.returncode == 0 and json.loads(r.stdout or "{}") == {"ok": True})
        inbox_path = magnet_state / "magnet-inbox.jsonl"
        check("fetch-metadata add-oddbody: nothing inboxed", not inbox_path.exists())
        check("fetch-metadata add-oddbody: raise stub untouched", raise_log.read_text() == "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 14c. the add answers 200 "Fails." and adds nothing: the hash never comes
#      back, so the present-poll rescues it.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        Path(env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps({"add": "fails"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check_rescued("fetch-metadata add-fails-body", r, magnet_state, raise_log)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 14d. F12: when qBittorrent refuses one of the slice-2b commands, qbt
#      reports the HTTP status only -- never the error body (it can carry a
#      tracker URL or passkey) nor any argument.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"writes": "409secret"}))
        secret_url = "udp://tracker.example:1337/SECRETPASSKEY123/announce"
        for args in (
            ["reannounce", HASH_A],
            ["tracker-add", HASH_A, secret_url],
            ["tracker-edit", HASH_A, secret_url, TRACKER_URL2],
            ["tracker-remove", HASH_A, secret_url],
            ["ban-peer", PEER],
        ):
            r = run(env, *args)
            label = f"F12 {args[0]} error"
            check(f"{label}: exit != 0", r.returncode != 0)
            check(f"{label}: names the HTTP status", "qBittorrent refused it (HTTP 409)" in r.stderr)
            check(f"{label}: no error body", "SECRETPASSKEY123" not in r.stderr and "Conflict" not in r.stderr and "tracker.example" not in r.stderr)
            check(f"{label}: no argument echoed", all(a not in r.stderr for a in args[1:]))
        control_path.write_text(json.dumps({"info": "409secret"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("F12 fetch-metadata info error: exit != 0", r.returncode != 0)
        check("F12 fetch-metadata info error: names the HTTP status", "qBittorrent refused it (HTTP 409)" in r.stderr)
        check("F12 fetch-metadata info error: no error body", "SECRETPASSKEY123" not in r.stderr and "Conflict" not in r.stderr)
        check("F12 fetch-metadata info error: no hash echoed", HASH_NOMETA not in r.stderr)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 14e. a signal mid-swap (TERM while blocked in a wait, after the delete
#      went out) must still land the magnet in the inbox.
import signal
import time
for fault, wait_path, why in (
    ({"delete": "noop"}, "/api/v2/torrents/delete", "wait-for-gone"),
    ({"add": "silent"}, "/api/v2/torrents/add", "wait-for-present"),
):
    extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=30)
    try:
        with harness.fixture_server(extra_env=extra_env) as (port, env):
            Path(env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(fault))
            proc = subprocess.Popen(["./qbt", "fetch-metadata", HASH_NOMETA], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not any(e["path"] == wait_path for e in read_log(env)):
                time.sleep(0.05)
            time.sleep(0.3)
            proc.send_signal(signal.SIGTERM)
            try:
                out, err = proc.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                out, err = proc.communicate()
            label = f"fetch-metadata TERM during {why}"
            check(f"{label}: exit != 0", proc.returncode != 0)
            inbox_path = magnet_state / "magnet-inbox.jsonl"
            check(f"{label}: inbox has the magnet", inbox_path.exists() and MAGNET_NOMETA in inbox_path.read_text())
            check(f"{label}: never printed the magnet", MAGNET_NOMETA not in err)
            if inbox_path.exists():
                lines = [ln for ln in inbox_path.read_text().splitlines() if ln.strip()]
                check(f"{label}: inboxed exactly once", len(lines) == 1)
    finally:
        shutil.rmtree(magnet_state, ignore_errors=True)
        shutil.rmtree(stub_root, ignore_errors=True)

# 15. the inbox cap must not apply to a rescue: with 20 unrelated magnets
#     already queued (the ordinary cap threshold), fetch-metadata's own
#     rescue must still land its magnet as entry 21, not fail as "inbox
#     full" and fall through to printing the raw magnet.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        inbox_path = magnet_state / "magnet-inbox.jsonl"
        inbox_path.parent.mkdir(parents=True, exist_ok=True)
        filler = [
            {"url": f"magnet:?xt=urn:btih:{i:040d}", "ts": 1, "notified": True, "ids": [f"{i:040d}"], "dn": ""}
            for i in range(20)
        ]
        with open(inbox_path, "w") as f:
            for row in filler:
                f.write(json.dumps(row) + "\n")
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "404"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata rescue bypasses the inbox cap: exit != 0", r.returncode != 0)
        check("fetch-metadata rescue bypasses the inbox cap: honest message", "the magnet is in your inbox" in r.stderr)
        check("fetch-metadata rescue bypasses the inbox cap: never printed the raw magnet", MAGNET_NOMETA not in r.stderr)
        lines = [ln for ln in inbox_path.read_text().splitlines() if ln.strip()]
        check("fetch-metadata rescue bypasses the inbox cap: 21 entries now", len(lines) == 21)
        check(
            "fetch-metadata rescue bypasses the inbox cap: the rescued magnet is in there",
            any(json.loads(ln).get("url") == MAGNET_NOMETA for ln in lines),
        )
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 16. If even the inbox rescue can't be written (state dir totally broken),
#     fetch-metadata must still never print the magnet -- only name the
#     hash, after genuinely trying the inbox (and the 0600-file fallback)
#     first.
blocked_state = tempfile.NamedTemporaryFile(prefix="qbt-actions-fm-blocked-", delete=False)
blocked_state.close()
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
extra_env["QBT_MAGNET_STATE"] = blocked_state.name  # a file, not a dir: ensure_state_dir must refuse it
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "404"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata totally-blocked rescue: exit != 0", r.returncode != 0)
        check("fetch-metadata totally-blocked rescue: names the hash", f"hash {HASH_NOMETA}" in r.stderr)
        check("fetch-metadata totally-blocked rescue: never prints the magnet", MAGNET_NOMETA not in r.stderr)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)
    Path(blocked_state.name).unlink(missing_ok=True)

# 17. If the state dir itself is fine but the inbox write specifically
#     fails (a corrupt existing inbox file, so cmd_magnet_inbox's own
#     python script dies for a reason other than the 20-item cap), the
#     rescue must fall through to the 0600 file and name only its path --
#     one tier short of totally blocked (section 16 above).
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    magnet_state.mkdir(parents=True, exist_ok=True)
    (magnet_state / "magnet-inbox.jsonl").write_text("not json\n")
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "404"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata corrupt-inbox rescue: exit != 0", r.returncode != 0)
        check("fetch-metadata corrupt-inbox rescue: names a lost-magnet file path", "lost-magnet-" in r.stderr)
        check("fetch-metadata corrupt-inbox rescue: never prints the magnet", MAGNET_NOMETA not in r.stderr)
        lost_files = list(magnet_state.glob("lost-magnet-*"))
        check("fetch-metadata corrupt-inbox rescue: exactly one lost-magnet file", len(lost_files) == 1)
        if lost_files:
            mode = oct(lost_files[0].stat().st_mode & 0o777)
            check("fetch-metadata corrupt-inbox rescue: lost-magnet file is 0600", mode == "0o600")
            check("fetch-metadata corrupt-inbox rescue: lost-magnet file holds the magnet", lost_files[0].read_text().strip() == MAGNET_NOMETA)
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# ---------------------------------------------------------------------------
# Slice 3a, Task 2: category and tag commands.
# ---------------------------------------------------------------------------
import os
import urllib.request as _ur

CAT_SECRET_WORDS = ("SECRETPASSKEY123", "Conflict", "tracker.example", "refused\n")
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}


def hashes_n(n, start=0):
    return [f"{i:040x}" for i in range(start, start + n)]


def library_env(library):
    """extra_env seeding the fixture's categories/tags/torrents."""
    fd, path = tempfile.mkstemp(prefix="qbt-actions-lib-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(library, f)
    env = dict(UTF8_ENV)
    env["QBT_FIXTURE_LIBRARY"] = path
    return env


def state(port):
    with _ur.urlopen(f"http://127.0.0.1:{port}/fixture/state", timeout=5) as r:
        return json.loads(r.read())


def control(env, value):
    Path(env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(value))


def new_entries(env, before):
    return read_log(env)[before:]


def posts_to(entries, name=None):
    return [e for e in entries if e["method"] == "POST" and (name is None or e["path"] == f"/api/v2/torrents/{name}")]


def first_body(entries):
    p = posts_to(entries)
    return p[0]["body"] if p else None


def form(entry):
    return parse_qs(entry["body"], keep_blank_values=True)


# 18. Exact request of every command, against the default fixture state
#     (categories linux [savePath ""], os [/data/os, download /data/os-dl];
#     tags iso, linux, extra; torrents HASH_A, HASH_B).
with harness.fixture_server(extra_env=UTF8_ENV) as (port, env):
    def one(args, label):
        before = len(read_log(env))
        r = run(env, *args)
        check(f"{label}: succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
        return new_entries(env, before)

    e = one(["category-add", "anime"], "category-add without a path")
    check("category-add: one POST, category=anime&savePath=", [x["body"] for x in posts_to(e)] == ["category=anime&savePath="])
    check("category-add: to createCategory, no GET", [x["path"] for x in e] == ["/api/v2/torrents/createCategory"])

    e = one(["category-add", "anime 2026", "/srv/anime"], "category-add with a path")
    check("category-add with a path: exact body", [x["body"] for x in e] == ["category=anime%202026&savePath=%2Fsrv%2Fanime"])

    e = one(["category-add", "home", "~/dl/home"], "category-add with ~/")
    home = os.environ["HOME"]
    check("category-add expands ~/", [form(x) for x in e] == [{"category": ["home"], "savePath": [f"{home}/dl/home"]}])

    e = one(["category-path", "os", "/data/os2"], "category-path keeping a download path")
    check("category-path: GET categories then one editCategory", [x["path"] for x in e] == ["/api/v2/torrents/categories", "/api/v2/torrents/editCategory"])
    check("category-path: resends the download path (editCategory resets it otherwise)",
          first_body(e) == "category=os&savePath=%2Fdata%2Fos2&downloadPathEnabled=true&downloadPath=%2Fdata%2Fos-dl")
    check("category-path: fixture keeps the download path", state(port)["categories"]["os"]["download_path"] == "/data/os-dl")

    e = one(["category-path", "linux", ""], "category-path reset to default")
    check("category-path \"\": savePath= and no download path fields", first_body(e) == "category=linux&savePath=")

    e = one(["set-category", f"{HASH_A}|{HASH_B}", "os"], "set-category")
    check("set-category: GET categories then one setCategory",
          [x["path"] for x in e] == ["/api/v2/torrents/categories", "/api/v2/torrents/setCategory"])
    check("set-category: exact body", first_body(e) == f"hashes={HASH_A}|{HASH_B}&category=os")

    e = one(["set-category", HASH_A, ""], "set-category to none")
    check("set-category \"\": no GET, category=", [x["body"] for x in e] == [f"hashes={HASH_A}&category="])

    e = one(["tag-add", "new tag"], "tag-add")
    check("tag-add: exact createTags body", [(x["path"], x["body"]) for x in e] == [("/api/v2/torrents/createTags", "tags=new%20tag")])

    e = one(["tag-add", "+plus"], "tag-add +plus")
    e = one(["tags", f"{HASH_A}|{HASH_B}", "--add", "iso", "--add", "+plus", "--remove", "extra"], "tags add/remove")
    check("tags: GET tags, then addTags per tag, then removeTags",
          [(x["path"], x["body"]) for x in e] == [
              ("/api/v2/torrents/tags", ""),
              ("/api/v2/torrents/addTags", f"hashes={HASH_A}|{HASH_B}&tags=iso"),
              ("/api/v2/torrents/addTags", f"hashes={HASH_A}|{HASH_B}&tags=%2Bplus"),
              ("/api/v2/torrents/removeTags", f"hashes={HASH_A}|{HASH_B}&tags=extra"),
          ])

    e = one(["tag-remove", "extra"], "tag-remove")
    check("tag-remove: GET tags then deleteTags", [(x["path"], x["body"]) for x in e] == [
        ("/api/v2/torrents/tags", ""), ("/api/v2/torrents/deleteTags", "tags=extra")])

    e = one(["category-remove", "linux"], "category-remove")
    check("category-remove: GET categories then removeCategories", [(x["path"], x["body"]) for x in e] == [
        ("/api/v2/torrents/categories", ""), ("/api/v2/torrents/removeCategories", "categories=linux")])
    check("category-remove: gone from the fixture", "linux" not in state(port)["categories"])

# 19. Rename: exact requests, copying save and download paths.
lib = {
    "categories": {
        "os": {"savePath": "/data/os", "download_path": "/data/os-dl"},
        "off": {"savePath": "", "download_path": False},
        "emptydl": {"savePath": "/srv/e", "download_path": ""},
    },
    "tags": ["old", "keep"],
    "torrents": {h: {"category": "os", "tags": "keep, old"} for h in hashes_n(2)},
}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    hs = hashes_n(2)
    before = len(read_log(env))
    r = run(env, "category-rename", "os", "os2")
    check("category-rename: succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
    e = new_entries(env, before)
    check("category-rename: exact request sequence", [(x["method"], x["path"], x["body"]) for x in e] == [
        ("GET", "/api/v2/torrents/categories", ""),
        ("GET", "/api/v2/torrents/info", ""),
        ("POST", "/api/v2/torrents/createCategory", "category=os2&savePath=%2Fdata%2Fos&downloadPathEnabled=true&downloadPath=%2Fdata%2Fos-dl"),
        ("POST", "/api/v2/torrents/setCategory", f"hashes={hs[0]}|{hs[1]}&category=os2"),
        ("GET", "/api/v2/torrents/info", ""),
        ("POST", "/api/v2/torrents/removeCategories", "categories=os"),
    ])
    st = state(port)
    check("category-rename: old gone, new has the paths", "os" not in st["categories"]
          and st["categories"]["os2"]["savePath"] == "/data/os" and st["categories"]["os2"]["download_path"] == "/data/os-dl")

    before = len(read_log(env))
    r = run(env, "category-path", "off", "/srv/off")
    check("category-path keeps a disabled download path",
          r.returncode == 0 and [x["body"] for x in posts_to(new_entries(env, before))] == ["category=off&savePath=%2Fsrv%2Foff&downloadPathEnabled=false"])
    before = len(read_log(env))
    r = run(env, "category-path", "emptydl", "/srv/e2")
    check("category-path keeps an enabled empty download path",
          r.returncode == 0 and [x["body"] for x in posts_to(new_entries(env, before))] == ["category=emptydl&savePath=%2Fsrv%2Fe2&downloadPathEnabled=true&downloadPath="])
    before = len(read_log(env))
    r = run(env, "category-rename", "off", "off2")
    check("category-rename of a disabled download path: succeeds", r.returncode == 0)
    creates = posts_to(new_entries(env, before), "createCategory")
    check("category-rename copies a disabled download path as downloadPathEnabled=false",
          [x["body"] for x in creates] == ["category=off2&savePath=%2Fsrv%2Foff&downloadPathEnabled=false"])

    before = len(read_log(env))
    r = run(env, "tag-rename", "old", "new")
    check("tag-rename: succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
    e = new_entries(env, before)
    check("tag-rename: exact request sequence", [(x["method"], x["path"], x["body"]) for x in e] == [
        ("GET", "/api/v2/torrents/tags", ""),
        ("GET", "/api/v2/torrents/info", ""),
        ("POST", "/api/v2/torrents/createTags", "tags=new"),
        ("POST", "/api/v2/torrents/addTags", f"hashes={hs[0]}|{hs[1]}&tags=new"),
        ("POST", "/api/v2/torrents/removeTags", f"hashes={hs[0]}|{hs[1]}&tags=old"),
        ("GET", "/api/v2/torrents/info", ""),
        ("POST", "/api/v2/torrents/deleteTags", "tags=old"),
    ])
    st = state(port)
    check("tag-rename: old gone, every torrent keeps its other tags", "old" not in st["tags"]
          and all(t["tags"] == "keep, new" for t in st["torrents"].values()))

# 20. Rejections: nothing is sent (not even a GET), under en_US.UTF-8.
with harness.fixture_server(extra_env=UTF8_ENV) as (port, env):
    REJECTS = [
        (["category-add"], "usage"),
        (["category-add", ""], "Type a name."),
        (["category-add", "a//b"], "No // in a category."),
        (["category-add", "anime", "relative/dir"], "The save path must be absolute or start with ~/."),
        (["category-path", "os"], "usage"),
        (["category-path", "os", "relative"], "The save path must be absolute or start with ~/."),
        (["category-path", "", "/x"], "Type a name."),
        (["category-remove"], "usage"),
        (["category-remove", "a\nb"], "This category's name can't be sent through the WebUI API."),
        (["set-category", "zzz", "os"], "invalid hash list"),
        (["set-category", HASH_A], "usage"),
        (["set-category", "a&x=1", ""], "invalid hash list"),
        (["tag-add", "a,b"], "No commas in a tag."),
        (["tag-add", "a\x7fb"], "No control characters in a name."),
        (["tag-add", "bad\udcffutf8"], "Use valid UTF-8 text in a name."),
        (["tag-remove", "a,b"], "No commas in a tag."),
        (["tag-remove", ""], "Type a name."),
        (["tags", HASH_A], "usage"),
        (["tags", HASH_A, "--add"], "usage"),
        (["tags", HASH_A, "--bogus", "x"], "usage"),
        (["tags", "nothex", "--add", "iso"], "invalid hash list"),
        (["tags", HASH_A, "--add", "a,b"], "No commas in a tag."),
        (["tags", HASH_A, "--add", "iso", "--remove", "iso"], "Can't add and remove iso at once."),
        (["category-rename", "os"], "usage"),
        (["category-rename", "os", "os2", "--force"], "usage"),
        (["category-rename", "os", "os2", "--merge", "x"], "usage"),
        (["category-rename", "os", "os"], "It already has that name."),
        (["category-rename", "os", "/os"], "A category can't start or end with /."),
        (["category-rename", "os", "a" * 65], "Keep it to 64 characters."),
        (["category-rename", "", "x"], "Type a name."),
        (["category-rename", "a\nb", "x"], "This category's name can't be sent through the WebUI API."),
        (["tag-rename", "iso", "a,b"], "No commas in a tag."),
        (["tag-rename", "a,b", "x"], "No commas in a tag."),
        (["tag-rename", "iso", " iso"], "No spaces at the start or end."),
        (["tag-add", "a\u0085b"], "No control characters in a name."),
        (["category-rename", "os", "os/sub"], "Can't rename os into its own subcategory."),
        (["category-rename", "os", "os/sub/deeper", "--merge"], "Can't rename os into its own subcategory."),
    ]
    for args, want in REJECTS:
        before = len(read_log(env))
        argv = [a.encode("utf-8", "surrogateescape") for a in ["./qbt", *args]]
        r = subprocess.run(argv, env=env, capture_output=True)
        err = r.stderr.decode("utf-8", "replace").strip()
        label = f"rejects {args!r}"
        check(f"{label}: exit != 0", r.returncode != 0)
        check(f"{label}: no request", len(read_log(env)) == before)
        if want == "usage":
            check(f"{label}: usage message", err.startswith("usage: qbt "))
        else:
            check(f"{label}: says {want!r}", err == want)
        check(f"{label}: no raw bash error", "unbound variable" not in err and "syntax error" not in err)

# 21. Existing names must exist: only the read goes out, never a write.
with harness.fixture_server(extra_env=UTF8_ENV) as (port, env):
    for args, want in (
        (["category-path", "nosuch", "/x"], "nosuch doesn't exist."),
        (["category-remove", "nosuch"], "nosuch doesn't exist."),
        (["set-category", HASH_A, "nosuch"], "nosuch doesn't exist."),
        (["tag-remove", "nosuch"], "nosuch doesn't exist."),
        (["tags", HASH_A, "--add", "nosuch"], "nosuch doesn't exist."),
        (["tags", HASH_A, "--remove", "nosuch"], "nosuch doesn't exist."),
        (["category-rename", "nosuch", "x"], "nosuch doesn't exist."),
        (["tag-rename", "nosuch", "x"], "nosuch doesn't exist."),
        (["category-rename", "linux", "os"], "os already exists."),
        (["tag-rename", "iso", "linux"], "linux already exists."),
        (["category-rename", "linux", "os", "--merge"], "os already exists with a different save path."),
    ):
        before = len(read_log(env))
        r = run(env, *args)
        e = new_entries(env, before)
        label = f"refuses {args!r}"
        check(f"{label}: exit != 0 with {want!r}", r.returncode != 0 and r.stderr.strip() == want)
        check(f"{label}: no write", not posts_to(e))

# 22. A merge target with a different download path (same save path) is
#     refused even with --merge; a matching one merges.
lib = {
    "categories": {
        "anime": {"savePath": "/srv/a", "download_path": None},
        "dl-false": {"savePath": "/srv/a", "download_path": False},
        "dl-path": {"savePath": "/srv/a", "download_path": "/tmp/a"},
        "same": {"savePath": "/srv/a", "download_path": None},
    },
    "tags": [],
    "torrents": {h: {"category": "anime"} for h in hashes_n(3)},
}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    for target in ("dl-false", "dl-path"):
        before = len(read_log(env))
        r = run(env, "category-rename", "anime", target, "--merge")
        check(f"merge into {target}: refused (different download path)",
              r.returncode != 0 and r.stderr.strip() == f"{target} already exists with a different save path.")
        check(f"merge into {target}: no write", not posts_to(new_entries(env, before)))
    before = len(read_log(env))
    r = run(env, "category-rename", "anime", "same", "--merge")
    check("merge into a same-path category: succeeds", r.returncode == 0)
    check("merge: no createCategory", not posts_to(new_entries(env, before), "createCategory"))
    st = state(port)
    check("merge: every torrent on the target, source gone",
          "anime" not in st["categories"] and all(t["category"] == "same" for t in st["torrents"].values()))

# 23. Review Focus 2: a rename interrupted at each step, then re-run. The
#     re-run without --merge is refused (the window raises the merge
#     confirm); with --merge it finishes, and nothing is lost. 2001 torrents
#     on the old name make three move chunks (1000, 1000, 1).
MOVED = hashes_n(2001)
BYSTANDER = "c" * 40
def rename_library(kind, anime_dl=False):
    torrents = {h: ({"category": "anime", "tags": "keep"} if kind == "category" else {"category": "x", "tags": "anime, keep"}) for h in MOVED}
    torrents[BYSTANDER] = {"category": "other", "tags": "keep"}
    return {
        "categories": {
            "anime": {"savePath": "/srv/anime", "download_path": anime_dl},
            "other": {"savePath": "", "download_path": None},
            "x": {"savePath": "", "download_path": None},
        },
        "tags": ["anime", "keep"],
        "torrents": torrents,
    }


def finished(kind, st, anime_dl=False):
    t = st["torrents"]
    if kind == "category":
        return ("anime" not in st["categories"]
                and st["categories"]["animation"]["savePath"] == "/srv/anime"
                and st["categories"]["animation"]["download_path"] == anime_dl
                and type(st["categories"]["animation"]["download_path"]) is type(anime_dl)
                and all(t[h]["category"] == "animation" and t[h]["tags"] == "keep" for h in MOVED)
                and t[BYSTANDER] == {"category": "other", "tags": "keep"})
    return ("anime" not in st["tags"] and "animation" in st["tags"]
            and all(t[h]["tags"] == "animation, keep" and t[h]["category"] == "x" for h in MOVED)
            and t[BYSTANDER] == {"category": "other", "tags": "keep"})


CASES_RF2 = [
    # (kind, fault, expected stderr, label)
    ("category", {"setCategory": "409@1"}, "Rename incomplete (0 of 2001 moved); press c on anime again to finish.", "after create"),
    ("category-emptydl", {"setCategory": "409@1"}, "Rename incomplete (0 of 2001 moved); press c on anime again to finish.", "after create, enabled empty download path"),
    ("category", {"setCategory": "409@2"}, "Rename incomplete (1000 of 2001 moved); press c on anime again to finish.", "mid-move (chunk 2 of 3)"),
    ("category", {"removeCategories": "409"}, "Rename incomplete (2001 of 2001 moved); press c on anime again to finish.", "before delete"),
    ("category", {"setCategory": "noop@3"}, "Rename incomplete (2000 of 2001 moved); press c on anime again to finish.", "a chunk that didn't take (re-check before delete)"),
    ("category", {"info": "500@2"}, "Rename incomplete (2001 of 2001 moved); press c on anime again to finish.", "re-check read fails"),
    ("tag", {"addTags": "409@1"}, "Rename incomplete (0 of 2001 moved); press c on anime again to finish.", "after create"),
    ("tag", {"addTags": "409@2"}, "Rename incomplete (1000 of 2001 moved); press c on anime again to finish.", "mid-move add (chunk 2 of 3)"),
    ("tag", {"removeTags": "409@2"}, "Rename incomplete (1000 of 2001 moved); press c on anime again to finish.", "mid-move remove (chunk 2 of 3)"),
    ("tag", {"deleteTags": "409"}, "Rename incomplete (2001 of 2001 moved); press c on anime again to finish.", "before delete"),
]
for kind, fault, want, why in CASES_RF2:
    anime_dl = False
    if kind == "category-emptydl":
        kind, anime_dl = "category", ""
    with harness.fixture_server(extra_env=library_env(rename_library(kind, anime_dl))) as (port, env):
        cmd = f"{kind}-rename"
        control(env, fault)
        r = run(env, cmd, "anime", "animation")
        label = f"{cmd} interrupted {why}"
        check(f"{label}: exit != 0 with the incomplete copy", r.returncode != 0 and r.stderr.strip() == want)
        if r.stderr.strip() != want:
            print("  got:", r.stderr.strip(), file=sys.stderr)
        st = state(port)
        names = st["categories"] if kind == "category" else st["tags"]
        check(f"{label}: both names exist", "anime" in names and "animation" in names)
        check(f"{label}: no torrent lost its {kind}",
              all((st["torrents"][h]["category"] in ("anime", "animation")) if kind == "category"
                  else ("anime" in st["torrents"][h]["tags"] or "animation" in st["torrents"][h]["tags"]) for h in MOVED))
        control(env, {})
        r = run(env, cmd, "anime", "animation")
        check(f"{label}: re-run without --merge is refused", r.returncode != 0 and r.stderr.strip() == "animation already exists.")
        r = run(env, cmd, "anime", "animation", "--merge")
        check(f"{label}: re-run with --merge finishes", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
        if r.returncode != 0:
            print("  got:", r.stderr.strip(), file=sys.stderr)
        check(f"{label}: nothing lost", finished(kind, state(port), anime_dl))

# 23b. Steps 1-3 failing: nothing changes, "Rename didn't start".
for kind, fault, want in (
    ("category", {"createCategory": "409secret"}, "Rename didn't start: HTTP 409"),
    ("category", {"categories": "500"}, "Rename didn't start: HTTP 500"),
    ("category", {"info": "409secret"}, "Rename didn't start: HTTP 409"),
    ("tag", {"createTags": "409secret"}, "Rename didn't start: HTTP 409"),
    ("tag", {"tags": "409secret"}, "Rename didn't start: HTTP 409"),
):
    with harness.fixture_server(extra_env=library_env(rename_library(kind))) as (port, env):
        control(env, fault)
        before = len(read_log(env))
        r = run(env, f"{kind}-rename", "anime", "animation")
        label = f"{kind}-rename with {fault}"
        check(f"{label}: {want!r}", r.returncode != 0 and r.stderr.strip() == want)
        check(f"{label}: no error body", not any(w in r.stderr for w in CAT_SECRET_WORDS))
        check(f"{label}: no move or delete sent",
              not [x for x in posts_to(new_entries(env, before)) if not x["path"].endswith(("createCategory", "createTags"))])

# 24. Review Focus 3: legacy names that break the new-name rules can still
#     be removed, renamed away from, and assigned.
LONG_CAT = "c" * 70
LONG_TAG = "t" * 70
lib = {
    "categories": {
        LONG_CAT: {"savePath": "", "download_path": None},
        "a//b": {"savePath": "", "download_path": None},
        " lead": {"savePath": "", "download_path": None},
        "trail ": {"savePath": "", "download_path": None},
    },
    "tags": [LONG_TAG, "two//slash", "legacy2"],
    "torrents": {HASH_A: {"category": LONG_CAT, "tags": LONG_TAG}, HASH_B: {"category": "a//b", "tags": "two//slash"}},
}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    for args in (
        ["category-rename", LONG_CAT, "short"],
        ["category-rename", "a//b", "fixed"],
        ["category-remove", " lead"],
        ["category-path", "trail ", "/srv/t"],
        ["set-category", HASH_A, "trail "],
        ["tag-rename", LONG_TAG, "short-tag"],
        ["tags", HASH_B, "--remove", "two//slash", "--add", "legacy2"],
        ["tag-remove", "legacy2"],
    ):
        r = run(env, *args)
        check(f"legacy name: {args[0]} {args[1][:12]!r}… works", r.returncode == 0)
        if r.returncode != 0:
            print("  got:", r.stderr.strip(), file=sys.stderr)
    st = state(port)
    check("legacy: renamed and removed names are gone",
          all(n not in st["categories"] for n in (LONG_CAT, "a//b", " lead")) and LONG_TAG not in st["tags"])
    check("legacy: torrents followed", st["torrents"][HASH_A] == {"category": "trail ", "tags": "short-tag"}
          and st["torrents"][HASH_B] == {"category": "fixed", "tags": ""})

# 25. Chunking at 1001 hashes: two requests, 1000 then 1.
many = hashes_n(1001)
lib = {"categories": {"os": {"savePath": ""}}, "tags": ["iso"], "torrents": {h: {} for h in many}}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    joined = "|".join(many)
    for args, route in (
        (["set-category", joined, "os"], "setCategory"),
        (["tags", joined, "--add", "iso"], "addTags"),
        (["tags", joined, "--remove", "iso"], "removeTags"),
    ):
        before = len(read_log(env))
        r = run(env, *args)
        p = posts_to(new_entries(env, before), route)
        check(f"{route} at 1001 hashes: succeeds", r.returncode == 0)
        check(f"{route} at 1001 hashes: two POSTs", len(p) == 2)
        if len(p) == 2:
            check(f"{route} at 1001 hashes: 1000 then 1",
                  [len(form(x)["hashes"][0].split("|")) for x in p] == [1000, 1]
                  and form(p[0])["hashes"][0].split("|") + form(p[1])["hashes"][0].split("|") == many)
    st = state(port)
    check("chunked writes reached every torrent", all(t == {"category": "os", "tags": ""} for t in st["torrents"].values()))
    before = len(read_log(env))
    r = run(env, "set-category", "all", "")
    check("set-category all: one request, hashes=all", [x["body"] for x in posts_to(new_entries(env, before))] == ["hashes=all&category="])

# 26. Partial failures and API errors: only the HTTP code, never a body or
#     an argument other than the names the copy is about.
lib = {"categories": {"os": {"savePath": ""}}, "tags": ["keep", "seedbox", "more"], "torrents": {h: {} for h in many}}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    control(env, {"removeTags": "409secret"})
    r = run(env, "tags", HASH_A, "--add", "keep", "--remove", "seedbox")
    check("tags partial failure: OV7 copy", r.returncode != 0 and r.stderr.strip() == "Tags: added keep; removing seedbox failed (HTTP 409)")
    # Call counters run per fixture process: addTags call 1 was "keep" just
    # above, so this run's "keep" is call 2 and "more" call 3.
    control(env, {"addTags": "409@3"})
    r = run(env, "tags", HASH_A, "--add", "keep", "--add", "more", "--remove", "seedbox")
    check("tags failure on the second add: stops there",
          r.returncode != 0 and r.stderr.strip() == "Tags: added keep; adding more failed (HTTP 409)")
    control(env, {"addTags": "409secret"})
    r = run(env, "tags", HASH_A, "--add", "keep")
    check("tags failure on the first change", r.returncode != 0 and r.stderr.strip() == "Tags: adding keep failed (HTTP 409)")
    joined = "|".join(many)
    before = len(read_log(env))
    control(env, {"setCategory": "409secret@2"})
    r = run(env, "set-category", joined, "os")
    check("set-category partial failure copy",
          r.returncode != 0 and r.stderr.strip() == "Category set on 1000 of 1001 torrents; qBittorrent refused the rest (HTTP 409)")
    control(env, {w: "409secret" for w in ("createCategory", "editCategory", "removeCategories", "setCategory", "createTags", "deleteTags")})
    for args in (
        ["category-add", "zz"],
        ["category-path", "os", "/srv/SECRET-ARG"],
        ["category-remove", "os"],
        ["set-category", HASH_A, "os"],
        ["tag-add", "zz"],
        ["tag-remove", "keep"],
    ):
        r = run(env, *args)
        label = f"{args[0]} API error"
        check(f"{label}: HTTP code only", r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 409)")
        check(f"{label}: no body", not any(w in r.stderr for w in CAT_SECRET_WORDS))
    for args in (["category-rename", "os", "zz"], ["tag-rename", "keep", "zz"]):
        control(env, {"setCategory": "409secret", "addTags": "409secret"})
        r = run(env, *args)
        check(f"{args[0]} move error: no body", r.returncode != 0 and not any(w in r.stderr for w in CAT_SECRET_WORDS)
              and "SECRET" not in r.stderr)

# 27. Fix round 1: qBittorrent 5.2.3's removeCategory also removes every
#     "name/..." subcategory and moves their torrents to the parent, and
#     createCategory/editCategory can't carry share limits.
LIMITED = {
    "ratio": {"savePath": "", "ratio_limit": 2.0},
    "seed-time": {"savePath": "", "seeding_time_limit": 60},
    "idle-time": {"savePath": "", "inactive_seeding_time_limit": 0},
    "action": {"savePath": "", "share_limit_action": "Stop"},
}
lib = {
    "categories": dict({
        "anime": {"savePath": "/srv/anime"},
        "anime/2026": {"savePath": ""},
        "anime/2026/deep": {"savePath": ""},
        "a": {"savePath": ""},
        "a/b": {"savePath": ""},
        "a/b/c": {"savePath": ""},
        "defaults": {"savePath": "", "ratio_limit": -2, "seeding_time_limit": -2,
                     "inactive_seeding_time_limit": -2, "share_limit_action": "Default"},
    }, **LIMITED),
    "tags": [],
    "torrents": {
        HASH_A: {"category": "anime"},
        HASH_B: {"category": "anime/2026"},
        "1" * 40: {"category": "a/b"},
        "2" * 40: {"category": "a/b/c"},
        "3" * 40: {"category": "ratio"},
    },
}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    for args, want in (
        (["category-rename", "anime", "animation"], "anime has subcategories; rename or remove them first."),
        (["category-rename", "anime", "animation", "--merge"], "anime has subcategories; rename or remove them first."),
    ) + tuple(
        (["category-rename", name, name + "-2"], f"{name} has its own share limits, which the WebUI can't copy; change them in qBittorrent first.")
        for name in LIMITED
    ) + tuple(
        (["category-path", name, "/srv/x"], f"{name} has its own share limits, which the WebUI can't copy; change them in qBittorrent first.")
        for name in LIMITED
    ):
        before = len(read_log(env))
        r = run(env, *args)
        e = new_entries(env, before)
        check(f"refuses {args!r}: {want!r}", r.returncode != 0 and r.stderr.strip() == want)
        check(f"refuses {args!r}: no write", not posts_to(e))
    st = state(port)
    check("refusals left anime and its subcategories alone",
          all(n in st["categories"] for n in ("anime", "anime/2026", "anime/2026/deep"))
          and st["torrents"][HASH_A]["category"] == "anime" and st["torrents"][HASH_B]["category"] == "anime/2026")

    r = run(env, "category-rename", "defaults", "defaults-2")
    check("share limits spelled out as the defaults don't block a rename", r.returncode == 0)
    r = run(env, "category-path", "defaults-2", "/srv/d")
    check("…nor a save path change", r.returncode == 0)

    r = run(env, "category-rename", "anime/2026/deep", "deep")
    check("a leaf subcategory renames fine", r.returncode == 0 and "anime/2026/deep" not in state(port)["categories"])

    r = run(env, "category-remove", "a/b")
    st = state(port)
    check("category-remove a/b: succeeds", r.returncode == 0)
    check("category-remove a/b: its torrents (and a/b/c's) move to a",
          st["torrents"]["1" * 40]["category"] == "a" and st["torrents"]["2" * 40]["category"] == "a")
    check("category-remove a/b: a/b and a/b/c are gone, a stays",
          "a/b" not in st["categories"] and "a/b/c" not in st["categories"] and "a" in st["categories"])

    r = run(env, "category-add", "new-parent/child")
    st = state(port)
    check("category-add of x/y also creates the missing parent x (addCategory)",
          r.returncode == 0 and "new-parent" in st["categories"] and "new-parent/child" in st["categories"])

    # "Doesn't exist" only echoes a name that is safe to print.
    for args, want in (
        (["category-remove", "nosuch\x1b[31m"], "That category doesn't exist."),
        (["category-remove", "no\u0085such"], "That category doesn't exist."),
        (["set-category", HASH_A, "nosuch\x07"], "That category doesn't exist."),
        (["tag-remove", "no\x1bsuch"], "That tag doesn't exist."),
        (["tags", HASH_A, "--add", "no\u009bsuch"], "That tag doesn't exist."),
        (["category-rename", "gone\x1b", "x"], "That category doesn't exist."),
        (["category-remove", "nosuch é"], "nosuch é doesn't exist."),
    ):
        r = run(env, *args)
        check(f"doesn't-exist copy for {args[1:]!r}: {want!r}", r.returncode != 0 and r.stderr.strip() == want)
    argv = [a.encode("utf-8", "surrogateescape") for a in ["./qbt", "tag-remove", "bad\udcffutf8"]]
    r = subprocess.run(argv, env=env, capture_output=True)
    check("doesn't-exist copy for invalid UTF-8", r.returncode != 0 and r.stderr.decode("utf-8", "replace").strip() == "That tag doesn't exist.")

# 28. Fix round 2: every message that shows a name which only passed the
#     existing-name check (a legacy name may carry ESC/ANSI sequences)
#     falls back to "that category"/"that tag". Exact stderr bytes.
ESC_CAT = "legacy\x1b[31mFAKE\x1b[0m"
ESC_TAG = "tag\x1b[31mFAKE\x1b[0m"
lib = {
    "categories": {
        ESC_CAT: {"savePath": ""},
        ESC_CAT + "/sub": {"savePath": ""},
        "esc-limits\x1b[0m": {"savePath": "", "ratio_limit": 1.5},
        "esc-move\x1b[2J": {"savePath": ""},
    },
    "tags": [ESC_TAG, "ok-tag"],
    "torrents": {HASH_A: {"category": "esc-move\x1b[2J", "tags": ESC_TAG}},
}
with harness.fixture_server(extra_env=library_env(lib)) as (port, env):
    def raw(*args):
        r = subprocess.run(["./qbt", *args], env=env, capture_output=True)
        return r.returncode, r.stderr
    for args, want in (
        (["category-rename", ESC_CAT, "clean"], b"That category has subcategories; rename or remove them first.\n"),
        (["category-rename", "esc-limits\x1b[0m", "clean"], b"That category has its own share limits, which the WebUI can't copy; change them in qBittorrent first.\n"),
        (["category-path", "esc-limits\x1b[0m", "/srv/x"], b"That category has its own share limits, which the WebUI can't copy; change them in qBittorrent first.\n"),
    ):
        before = len(read_log(env))
        rc, err = raw(*args)
        check(f"ESC name {args[0]}: exact stderr {want!r}", rc != 0 and err == want)
        check(f"ESC name {args[0]}: no write", not posts_to(new_entries(env, before)))
    control(env, {"setCategory": "409"})
    rc, err = raw("category-rename", "esc-move\x1b[2J", "clean-move")
    check("ESC name in the incomplete-rename copy: exact stderr",
          rc != 0 and err == b"Rename incomplete (0 of 1 moved); press c on that category again to finish.\n")
    control(env, {"removeTags": "409"})
    rc, err = raw("tags", HASH_A, "--add", "ok-tag", "--remove", ESC_TAG)
    check("ESC tag in the tags failure copy: exact stderr",
          rc != 0 and err == b"Tags: added ok-tag; removing that tag failed (HTTP 409)\n")
    control(env, {"deleteTags": "409"})
    rc, err = raw("tag-rename", ESC_TAG, "clean-tag")
    check("ESC tag in the incomplete tag-rename copy: exact stderr",
          rc != 0 and err == b"Rename incomplete (1 of 1 moved); press c on that tag again to finish.\n")
    control(env, {"removeTags": "409"})
    rc, err = raw("tags", HASH_A, "--add", ESC_TAG, "--remove", "ok-tag")
    check("ESC tag in the added list: exact stderr",
          rc != 0 and err == b"Tags: added that tag; removing ok-tag failed (HTTP 409)\n")


# ---------------------------------------------------------------------------
# Slice 3b, Task 1: share-limits (D2/D8) and the widget's sharelimit alias.
# ---------------------------------------------------------------------------
SL = {  # torrents/info rows; the fixture fills any missing share field.
    "finished": {"progress": 1, "state": "stalledUP", "ratio": 2.0, "seeding_time": 7200},
    "unfinished": {"progress": 0.5, "state": "downloading", "ratio": 2.0, "seeding_time": 7200},
    "forced": {"progress": 1, "state": "forcedUP", "ratio": 2.0, "seeding_time": 7200},
}
SL_CATS = {
    "plain": {"savePath": ""},
    "rmc": {"savePath": "", "share_limit_action": "RemoveWithContent"},
    "rm": {"savePath": "", "share_limit_action": "Remove"},
    "stopcat": {"savePath": "", "share_limit_action": "Stop"},
    "parent": {"savePath": "", "share_limit_action": "RemoveWithContent", "ratio_limit": 1},
    "sparent": {"savePath": "", "share_limit_action": "RemoveWithContent", "seeding_time_limit": 60},
    "sparent/child": {"savePath": ""},
    "parent/child": {"savePath": ""},
    "parent/stopchild": {"savePath": "", "share_limit_action": "Stop"},
    "ratio1": {"savePath": "", "share_limit_action": "RemoveWithContent", "ratio_limit": 1},
    "badact": {"savePath": "", "share_limit_action": 3},
}
# Where the effective action comes from: (torrent action, category).
SL_SOURCES = {
    "torrent": ("RemoveWithContent", ""),
    "category": ("Default", "rmc"),
    "parent category": ("Default", "parent/child"),
    "global": ("Default", "plain"),
}


def sl_hash(n):
    return f"{0x3b000 + n:040x}"


def sl_library(torrents, preferences=None):
    lib = {"categories": json.loads(json.dumps(SL_CATS)), "tags": [], "torrents": torrents}
    if preferences is not None:
        lib["preferences"] = preferences
    return library_env(lib)


def sl_limits(port, h):
    return state(port)["limits"][h]


# 29. The regression: the widget's `sharelimit <hash> <ratio>` succeeds
#     against a setShareLimits that answers 400 without all four limits,
#     and sends each one.
with harness.fixture_server(extra_env=UTF8_ENV) as (port, env):
    before = len(read_log(env))
    r = run(env, "sharelimit", HASH_A, "1")
    check("widget sharelimit succeeds against the 400-strict fixture", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
    e = new_entries(env, before)
    check("widget sharelimit: reads info, categories, preferences, then one write",
          [x["path"] for x in e] == ["/api/v2/torrents/info", "/api/v2/torrents/categories", "/api/v2/app/preferences", "/api/v2/torrents/setShareLimits"])
    check("widget sharelimit: all four limits, the action as read",
          first_body(e) == f"hashes={HASH_A}&ratioLimit=1&seedingTimeLimit=-2&inactiveSeedingTimeLimit=-2&shareLimitAction=Default")
    for ratio in ("-2", "-1", "2"):
        r = run(env, "sharelimit", HASH_A, ratio)
        check(f"widget sharelimit {ratio} succeeds", r.returncode == 0)
    check("widget sharelimit: the fixture holds the last ratio", sl_limits(port, HASH_A)["ratio_limit"] == 2)
    try:
        _ur.urlopen(_ur.Request(f"http://127.0.0.1:{port}/api/v2/torrents/setShareLimits", method="POST",
                                data=f"hashes={HASH_A}&ratioLimit=1&seedingTimeLimit=-2&inactiveSeedingTimeLimit=-2".encode()), timeout=5)
        fixture_400 = None
    except _ur.HTTPError as err:
        fixture_400 = (err.code, err.read())
    check("fixture: setShareLimits without the action is 5.2.3's 400",
          fixture_400 == (400, b"Missing required parameters: shareLimitAction"))
    for bad in (["sharelimit", HASH_A], ["sharelimit", HASH_A, "1", "2"], ["sharelimit", HASH_A, "1.234"], ["sharelimit", "zz", "1"]):
        before = len(read_log(env))
        r = run(env, *bad)
        check(f"sharelimit refuses {bad[1:]!r} with no request", r.returncode != 0 and len(read_log(env)) == before)

# 30. D2: a ratio keeps every target's other limits and its exact action
#     string, across a range with mixed values; one POST per distinct
#     (ratio, seed, inactive, action).
mixed = {
    sl_hash(1): dict(SL["unfinished"]),
    sl_hash(2): dict(SL["unfinished"], ratio_limit=1.25, seeding_time_limit=30, inactive_seeding_time_limit=-1, share_limit_action="RemoveWithContent"),
    sl_hash(3): dict(SL["unfinished"], ratio_limit=0.5, seeding_time_limit=30, inactive_seeding_time_limit=-1, share_limit_action="RemoveWithContent"),
    sl_hash(4): dict(SL["unfinished"], ratio_limit=-1, seeding_time_limit=-1, inactive_seeding_time_limit=15, share_limit_action="EnableSuperSeeding"),
    sl_hash(5): dict(SL["unfinished"], ratio_limit=3, seeding_time_limit=-2, inactive_seeding_time_limit=-2, share_limit_action="Stop"),
}
with harness.fixture_server(extra_env=sl_library(mixed)) as (port, env):
    targets = "|".join(mixed)
    before = len(read_log(env))
    r = run(env, "share-limits", targets, "--ratio", "2")
    check("share-limits --ratio over a mixed range succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
    posts = posts_to(new_entries(env, before), "setShareLimits")
    check("share-limits --ratio: one POST per distinct group (4 for 5 targets)", len(posts) == 4)
    check("share-limits --ratio: the groups, in target order, with exact bodies", [x["body"] for x in posts] == [
        f"hashes={sl_hash(1)}&ratioLimit=2&seedingTimeLimit=-2&inactiveSeedingTimeLimit=-2&shareLimitAction=Default",
        f"hashes={sl_hash(2)}|{sl_hash(3)}&ratioLimit=2&seedingTimeLimit=30&inactiveSeedingTimeLimit=-1&shareLimitAction=RemoveWithContent",
        f"hashes={sl_hash(4)}&ratioLimit=2&seedingTimeLimit=-1&inactiveSeedingTimeLimit=15&shareLimitAction=EnableSuperSeeding",
        f"hashes={sl_hash(5)}&ratioLimit=2&seedingTimeLimit=-2&inactiveSeedingTimeLimit=-2&shareLimitAction=Stop",
    ])
    after = state(port)["limits"]
    for h, t in mixed.items():
        want = {"ratio_limit": 2, "seeding_time_limit": t.get("seeding_time_limit", -2),
                "inactive_seeding_time_limit": t.get("inactive_seeding_time_limit", -2),
                "share_limit_action": t.get("share_limit_action", "Default")}
        got = {k: after[h][k] for k in want}
        check(f"share-limits --ratio keeps {h[-2:]}'s other limits and action exactly", got == want)
    before = len(read_log(env))
    r = run(env, "share-limits", targets, "--seed-time", "45")
    posts = posts_to(new_entries(env, before), "setShareLimits")
    check("share-limits --seed-time: all ratios now 2, so 4 groups again", r.returncode == 0 and len(posts) == 4)
    after = state(port)["limits"]
    check("share-limits --seed-time keeps the ratio and actions",
          all(after[h]["ratio_limit"] == 2 and after[h]["seeding_time_limit"] == 45 for h in mixed)
          and after[sl_hash(2)]["share_limit_action"] == "RemoveWithContent"
          and after[sl_hash(4)]["inactive_seeding_time_limit"] == 15)
    before = len(read_log(env))
    r = run(env, "share-limits", targets, "--ratio", "1.5", "--seed-time", "-1")
    posts = posts_to(new_entries(env, before), "setShareLimits")
    check("share-limits with both: 4 groups (inactive/action still differ)", r.returncode == 0 and len(posts) == 4)
    check("share-limits with both: a decimal ratio is sent as given", all("&ratioLimit=1.5&seedingTimeLimit=-1&" in x["body"] for x in posts))
    # A repeated hash is one target.
    before = len(read_log(env))
    r = run(env, "share-limits", f"{sl_hash(1)}|{sl_hash(1)}", "--ratio", "-1")
    posts = posts_to(new_entries(env, before), "setShareLimits")
    check("share-limits: a repeated hash is sent once", r.returncode == 0 and [x["body"].split("&")[0] for x in posts] == [f"hashes={sl_hash(1)}"])

    # A first failure gives only the HTTP code.
    control(env, {"setShareLimits": "409secret"})
    r = run(env, "share-limits", targets, "--ratio", "3")
    check("share-limits first failure: the HTTP code only",
          r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 409)")
    control(env, {"info": "409secret"})
    before = len(read_log(env))
    r = run(env, "share-limits", targets, "--ratio", "3")
    check("share-limits: an info failure gives the HTTP code only, never the body",
          r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 409)" and "SECRET" not in r.stderr
          and not posts_to(new_entries(env, before)))
    control(env, {"categories": "500"})
    before = len(read_log(env))
    r = run(env, "share-limits", targets, "--ratio", "3")
    check("share-limits: a categories failure writes nothing",
          r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 500)" and not posts_to(new_entries(env, before)))
    control(env, {})

    # Gone targets and bad input: refused before any write.
    for args, want in (
        (["share-limits", HASH_NOTFOUND, "--ratio", "1"], "That torrent is gone."),
        (["share-limits", f"{sl_hash(1)}|{HASH_NOTFOUND}", "--ratio", "1"], "That torrent is gone."),
        (["share-limits", f"{HASH_NOTFOUND}|{'1' * 40}", "--ratio", "1"], "2 of those torrents are gone."),
    ):
        before = len(read_log(env))
        r = run(env, *args)
        check(f"share-limits {args[1][-6:]}: {want!r}", r.returncode != 0 and r.stderr.strip() == want and not posts_to(new_entries(env, before)))
    usage = "usage: qbt share-limits <hash|list|all> [--ratio <-2|-1|0-9998>] [--seed-time <-2|-1|0-525600 minutes>] [--force]"
    for args, want in (
        (["share-limits", sl_hash(1)], usage),
        (["share-limits", sl_hash(1), "--force"], usage),
        (["share-limits", sl_hash(1), "--ratio"], usage),
        (["share-limits", sl_hash(1), "--ratio", "1", "--ratio", "2"], usage),
        (["share-limits", sl_hash(1), "--bogus", "1"], usage),
        (["share-limits", "nothex", "--ratio", "1"], "invalid hash list"),
        (["share-limits", sl_hash(1), "--ratio", "1.234"], "invalid ratio limit"),
        (["share-limits", sl_hash(1), "--seed-time", "525601"], "invalid seed time limit"),
    ):
        before = len(read_log(env))
        r = run(env, *args)
        check(f"share-limits refuses {args[1:]!r} with no request", r.returncode != 0 and r.stderr.strip() == want and len(read_log(env)) == before)

# Partial failure names how far it got ("@3": the fixture counts calls per
# process, so this one starts fresh). Groups: {1}, {2,3}, {4}, {5}.
with harness.fixture_server(extra_env=sl_library(mixed)) as (port, env):
    control(env, {"setShareLimits": "409@3"})
    r = run(env, "share-limits", "|".join(mixed), "--ratio", "3")
    check("share-limits partial failure: exact message",
          r.returncode != 0 and r.stderr.strip() == "Share limits set on 3 of 5 torrents; qBittorrent refused the rest (HTTP 409)")

# 31. `all`: the unfiltered info, every row written by hash.
with harness.fixture_server(extra_env=UTF8_ENV) as (port, env):
    before = len(read_log(env))
    r = run(env, "share-limits", "all", "--ratio", "5")
    e = new_entries(env, before)
    check("share-limits all: succeeds", r.returncode == 0)
    check("share-limits all: info read unfiltered", e[0]["path"] == "/api/v2/torrents/info" and e[0]["query"] == {})
    check("share-limits all: never sends hashes=all", all("hashes=all" not in x["body"] for x in posts_to(e)))
    check("share-limits all: every row now has ratio 5", all(v["ratio_limit"] == 5 for v in state(port)["limits"].values()))

# 32. D8 guard: every source of the action x met/unmet x finished/
#     unfinished/forcedUP. Only a finished torrent that meets the new limit
#     and would be removed is refused; --force sends it anyway.
REFUSE_1_FILES = "1 torrent already meets that limit, and qBittorrent would remove it with its files."
for source, (action, category) in SL_SOURCES.items():
    act = 3 if source == "global" else 0
    torrents = {}
    for i, (kind, row) in enumerate(SL.items()):
        torrents[sl_hash(10 + i)] = dict(row, share_limit_action=action, category=category)
    with harness.fixture_server(extra_env=sl_library(torrents, {"max_ratio_act": act})) as (port, env):
        for i, kind in enumerate(SL):
            h = sl_hash(10 + i)
            for ratio, met in (("1", True), ("3", False)):
                before = len(read_log(env))
                r = run(env, "share-limits", h, "--ratio", ratio)
                refused = met and kind == "finished"
                wrote = bool(posts_to(new_entries(env, before), "setShareLimits"))
                if refused:
                    ok = r.returncode != 0 and r.stderr.strip() == REFUSE_1_FILES and not wrote
                else:
                    ok = r.returncode == 0 and wrote
                check(f"guard, action from {source}, {'met' if met else 'unmet'}, {kind}: {'refused' if refused else 'written'}", ok)
        h = sl_hash(10)
        before = len(read_log(env))
        r = run(env, "share-limits", h, "--ratio", "1", "--force")
        check(f"guard, action from {source}: --force writes", r.returncode == 0 and len(posts_to(new_entries(env, before), "setShareLimits")) == 1)

# Seed time, -2 resolution, Remove without files, Stop, the widget alias,
# and counts.
guard_rows = {
    sl_hash(20): dict(SL["finished"], share_limit_action="Remove"),
    sl_hash(21): dict(SL["finished"], share_limit_action="RemoveWithContent"),
    sl_hash(22): dict(SL["finished"], share_limit_action="Stop", category="rmc"),
    sl_hash(23): dict(SL["finished"], share_limit_action="EnableSuperSeeding"),
    sl_hash(24): dict(SL["finished"], category="ratio1"),
    sl_hash(25): dict(SL["finished"], category="parent/child"),
    sl_hash(26): dict(SL["finished"], category="parent/stopchild"),
    sl_hash(27): dict(SL["finished"], category="rm"),
    sl_hash(28): dict(SL["unfinished"], share_limit_action="RemoveWithContent"),
    sl_hash(29): dict(SL["finished"], share_limit_action="Remove", seeding_time_limit=60),
    sl_hash(30): dict(SL["finished"], category="sparent/child"),
    # Fix round 1: maindata's ratio -1 means "at or above MAX_RATIO".
    sl_hash(31): dict(SL["finished"], ratio=-1, share_limit_action="Remove"),
    # Ruling CC: every file unwanted reports progress 0, yet it seeds.
    sl_hash(32): dict(SL["finished"], progress=0, share_limit_action="RemoveWithContent"),
    sl_hash(33): dict(SL["unfinished"], progress=0, state="UP", share_limit_action="RemoveWithContent"),
    sl_hash(34): dict(SL["unfinished"], progress=0, share_limit_action="RemoveWithContent"),
    sl_hash(35): dict(SL["forced"], progress=0, share_limit_action="RemoveWithContent"),
}
with harness.fixture_server(extra_env=sl_library(guard_rows, {"max_ratio_act": 3})) as (port, env):
    def guard(args, want, label):
        before = len(read_log(env))
        r = run(env, *args)
        wrote = bool(posts_to(new_entries(env, before), "setShareLimits"))
        if want is None:
            ok = r.returncode == 0 and wrote
        else:
            ok = r.returncode != 0 and r.stderr.strip() == want and not wrote
        check(label, ok)
        if not ok:
            print(r.returncode, r.stderr, file=sys.stderr)

    guard(["share-limits", sl_hash(20), "--ratio", "2"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: Remove (no files), ratio met at equality, singular copy")
    guard(["share-limits", sl_hash(20), "--ratio", "2.01"], None, "guard: ratio just above the torrent's is written")
    guard(["share-limits", sl_hash(20), "--ratio", "0"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: ratio 0 is met")
    guard(["share-limits", sl_hash(20), "--ratio", "-1"], None, "guard: ratio -1 (none) is written")
    guard(["share-limits", sl_hash(20), "--seed-time", "120"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: seed time met at equality (7200 s = 120 min)")
    guard(["share-limits", sl_hash(20), "--seed-time", "121"], None, "guard: seed time above the seeding minutes is written")
    guard(["share-limits", sl_hash(29), "--ratio", "3"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: a new ratio with the kept seed time already met is refused")
    guard(["share-limits", sl_hash(22), "--ratio", "1"], None, "guard: the torrent's own Stop beats a RemoveWithContent category")
    guard(["share-limits", sl_hash(23), "--ratio", "1"], None, "guard: EnableSuperSeeding is not refused")
    guard(["share-limits", sl_hash(24), "--ratio", "-2"], REFUSE_1_FILES, "guard: -2 resolving to the category's ratio 1 is met")
    guard(["share-limits", sl_hash(25), "--ratio", "-2"], REFUSE_1_FILES, "guard: -2 resolving through the parent category is met")
    guard(["share-limits", sl_hash(30), "--seed-time", "-2"], REFUSE_1_FILES, "guard: seed -2 resolving to the parent's 60 min is met")
    guard(["share-limits", sl_hash(30), "--seed-time", "121"], None, "guard: a seed time above the seeding minutes is written")
    guard(["share-limits", sl_hash(26), "--ratio", "-2"], None, "guard: a child's Stop beats its parent's RemoveWithContent")
    guard(["share-limits", sl_hash(27), "--ratio", "1"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: a Remove category (no files)")
    guard(["share-limits", sl_hash(21), "--ratio", "-2"], None, "guard: -2 resolving to a disabled global ratio (-1) is written")
    guard(["sharelimit", sl_hash(21), "1"], REFUSE_1_FILES, "guard: the widget alias gets the refusal")
    guard(["share-limits", sl_hash(31), "--ratio", "5"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: a ratio of -1 (above MAX_RATIO) meets any ratio limit")
    guard(["sharelimit", sl_hash(31), "2"], "1 torrent already meets that limit, and qBittorrent would remove it.",
          "guard: the widget alias on a ratio of -1")
    guard(["share-limits", sl_hash(31), "--ratio", "-1"], None, "guard: a ratio of -1 with no ratio limit is written")
    guard(["share-limits", sl_hash(32), "--seed-time", "60"], REFUSE_1_FILES,
          "guard: progress 0 but stalledUP (every file unwanted) counts as finished")
    guard(["share-limits", sl_hash(33), "--seed-time", "60"], None, "guard: a state that only contains a seeding state's letters isn't finished")
    guard(["share-limits", sl_hash(34), "--seed-time", "60"], None, "guard: progress 0 and downloading isn't finished")
    guard(["share-limits", sl_hash(35), "--seed-time", "60"], None, "guard: progress 0 and forcedUP isn't finished")
    guard(["share-limits", f"{sl_hash(20)}|{sl_hash(27)}", "--ratio", "1"],
          "2 torrents already meet that limit, and qBittorrent would remove them.", "guard: plural, no files")
    guard(["share-limits", f"{sl_hash(20)}|{sl_hash(21)}|{sl_hash(22)}|{sl_hash(28)}", "--ratio", "1"],
          "2 torrents already meet that limit, and qBittorrent would remove them with their files.",
          "guard: a VISUAL range counts only the finished removals; any with files says so")
    before = len(read_log(env))
    r = run(env, "share-limits", f"{sl_hash(20)}|{sl_hash(21)}|{sl_hash(22)}|{sl_hash(28)}", "--ratio", "1", "--force")
    check("guard: --force writes the whole range, 3 groups", r.returncode == 0 and len(posts_to(new_entries(env, before), "setShareLimits")) == 3)

# Ruling CC: each seeding state counts as finished at progress 0.
cc_rows = {sl_hash(60 + i): dict(SL["finished"], progress=0, state=st, share_limit_action="Remove")
           for i, st in enumerate(("uploading", "stalledUP", "queuedUP", "stoppedUP", "checkingUP"))}
with harness.fixture_server(extra_env=sl_library(cc_rows)) as (port, env):
    for h, row in cc_rows.items():
        before = len(read_log(env))
        r = run(env, "share-limits", h, "--seed-time", "60")
        check(f"guard: progress 0 and {row['state']} is finished",
              r.returncode != 0 and r.stderr.strip() == "1 torrent already meets that limit, and qBittorrent would remove it."
              and not posts_to(new_entries(env, before)))

# Global limits: -2 resolves to max_ratio / max_seeding_time only when enabled.
glob_rows = {sl_hash(40): dict(SL["finished"], category="plain")}
for prefs, args, refused, label in (
    ({"max_ratio_act": 1, "max_ratio_enabled": True, "max_ratio": 1.5}, ["--ratio", "-2"], True, "enabled global ratio 1.5"),
    ({"max_ratio_act": 1, "max_ratio_enabled": False, "max_ratio": 1.5}, ["--ratio", "-2"], False, "disabled global ratio"),
    ({"max_ratio_act": 1, "max_ratio_enabled": True, "max_ratio": 2.5}, ["--ratio", "-2"], False, "enabled global ratio 2.5, unmet"),
    ({"max_ratio_act": 1, "max_seeding_time_enabled": True, "max_seeding_time": 100}, ["--seed-time", "-2"], True, "enabled global seed time 100"),
    ({"max_ratio_act": 1, "max_seeding_time_enabled": False, "max_seeding_time": 100}, ["--seed-time", "-2"], False, "disabled global seed time"),
    ({"max_ratio_act": 0, "max_ratio_enabled": True, "max_ratio": 1.5}, ["--ratio", "-2"], False, "global Stop"),
    ({"max_ratio_act": 2, "max_ratio_enabled": True, "max_ratio": 1.5}, ["--ratio", "-2"], False, "global EnableSuperSeeding"),
):
    with harness.fixture_server(extra_env=sl_library(glob_rows, prefs)) as (port, env):
        before = len(read_log(env))
        r = run(env, "share-limits", sl_hash(40), *args)
        wrote = bool(posts_to(new_entries(env, before), "setShareLimits"))
        if refused:
            ok = r.returncode != 0 and r.stderr.strip() == "1 torrent already meets that limit, and qBittorrent would remove it." and not wrote
        else:
            ok = r.returncode == 0 and wrote
        check(f"guard, {label}: {'refused' if refused else 'written'}", ok)

# Fails closed on anything the guard or the write depends on.
for label, prefs, rows in (
    ("max_ratio_act out of range", {"max_ratio_act": 7}, glob_rows),
    ("max_ratio_act -1", {"max_ratio_act": -1}, glob_rows),
    ("max_ratio_act a string", {"max_ratio_act": "Remove"}, glob_rows),
    ("an enabled max_ratio that isn't a number", {"max_ratio_enabled": True, "max_ratio": "x"}, glob_rows),
    ("a seed limit that isn't a number", {}, {sl_hash(41): dict(SL["unfinished"], seeding_time_limit="30")}),
    ("an action that isn't a string", {}, {sl_hash(42): dict(SL["unfinished"], share_limit_action=3)}),
    ("a category action that isn't a string", {}, {sl_hash(43): dict(SL["unfinished"], category="badact")}),
):
    with harness.fixture_server(extra_env=sl_library(rows, prefs)) as (port, env):
        before = len(read_log(env))
        r = run(env, "share-limits", next(iter(rows)), "--ratio", "3")
        check(f"share-limits fails closed on {label}",
              r.returncode != 0 and r.stderr.strip() == "qBittorrent sent something unreadable" and not posts_to(new_entries(env, before)))


# 33. D4: `sequential|first-last <hashes> on|off` read fresh state and
#     toggle only the targets that differ; nothing to change sends nothing.
#     The bare `sequential <hash>` stays the old single toggle.
for command, field, route in (("sequential", "seq_dl", "toggleSequentialDownload"),
                              ("first-last", "f_l_piece_prio", "toggleFirstLastPiecePrio")):
    rows = {sl_hash(50): {field: True}, sl_hash(51): {field: False}, sl_hash(52): {}}
    targets = "|".join(rows)
    with harness.fixture_server(extra_env=sl_library(rows)) as (port, env):
        def toggles(args):
            before = len(read_log(env))
            r = run(env, *args)
            e = new_entries(env, before)
            return r, e, posts_to(e, route)

        r, e, posts = toggles([command, targets, "on"])
        check(f"{command} on: succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
        check(f"{command} on: reads info for the targets first", e[0]["path"] == "/api/v2/torrents/info" and e[0]["query"] == {"hashes": [targets]})
        check(f"{command} on: toggles only the two that were off, in one POST", [x["body"] for x in posts] == [f"hashes={sl_hash(51)}|{sl_hash(52)}"])
        check(f"{command} on: every target is on", all(state(port)["limits"][h][field] is True for h in rows))
        r, e, posts = toggles([command, targets, "on"])
        check(f"{command} on twice: no write the second time", r.returncode == 0 and not posts)
        check(f"{command} on twice: still on", all(state(port)["limits"][h][field] is True for h in rows))
        r, e, posts = toggles([command, sl_hash(50), "off"])
        check(f"{command} off: one POST for the one target", r.returncode == 0 and [x["body"] for x in posts] == [f"hashes={sl_hash(50)}"])
        r, e, posts = toggles([command, targets, "off"])
        check(f"{command} off over a mixed range converges", r.returncode == 0 and [x["body"] for x in posts] == [f"hashes={sl_hash(51)}|{sl_hash(52)}"]
              and all(state(port)["limits"][h][field] is False for h in rows))
        r, e, posts = toggles([command, "all", "on"])
        check(f"{command} all on: info unfiltered, hashes listed, never hashes=all",
              r.returncode == 0 and e[0]["query"] == {} and posts and all("hashes=all" not in x["body"] for x in posts)
              and all(v[field] is True for v in state(port)["limits"].values()))
        for args, want in (
            ([command, HASH_NOTFOUND, "on"], "That torrent is gone."),
            ([command, f"{HASH_NOTFOUND}|{'1' * 40}", "off"], "2 of those torrents are gone."),
        ):
            r, e, posts = toggles(args)
            check(f"{command} {want!r}", r.returncode != 0 and r.stderr.strip() == want and not posts)
        control(env, {route: "409secret"})
        r, e, posts = toggles([command, sl_hash(50), "off"])
        check(f"{command}: a refused toggle gives the HTTP code only", r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 409)")
        control(env, {"info": "409secret"})
        r, e, posts = toggles([command, sl_hash(50), "off"])
        check(f"{command}: an info failure gives the HTTP code only, and no write",
              r.returncode != 0 and r.stderr.strip() == "qBittorrent refused it (HTTP 409)" and not posts)
        control(env, {})
        bad = [[command, sl_hash(50), "maybe"], [command, sl_hash(50), "on", "extra"], [command, "nothex", "on"], [command]]
        if command == "first-last":
            bad.append([command, sl_hash(50)])
        for args in bad:
            before = len(read_log(env))
            r = run(env, *args)
            check(f"{command} refuses {args[1:]!r} with no request", r.returncode != 0 and len(read_log(env)) == before)

    with harness.fixture_server(extra_env=sl_library({sl_hash(53): {field: "yes"}})) as (port, env):
        before = len(read_log(env))
        r = run(env, command, sl_hash(53), "on")
        check(f"{command} fails closed on a {field} that isn't a boolean",
              r.returncode != 0 and r.stderr.strip() == "qBittorrent sent something unreadable" and not posts_to(new_entries(env, before)))

with harness.fixture_server(extra_env=sl_library({sl_hash(54): {"seq_dl": True}})) as (port, env):
    before = len(read_log(env))
    r = run(env, "sequential", sl_hash(54))
    e = new_entries(env, before)
    check("bare sequential: the old toggle, one POST and no read",
          r.returncode == 0 and [(x["method"], x["path"], x["body"]) for x in e] == [("POST", "/api/v2/torrents/toggleSequentialDownload", f"hashes={sl_hash(54)}")])
    check("bare sequential: flips", state(port)["limits"][sl_hash(54)]["seq_dl"] is False)

# ---------------------------------------------------------------------------
# Slice 4a, Task 2: pref-set's exact requests (the full gate is in
# tests/test_prefs.py). A schema key: one POST, then the re-read. A
# composite: both members in one POST. Other: a read first for the type.
# ---------------------------------------------------------------------------
_prefs_fd, _prefs_path = tempfile.mkstemp(prefix="qbt-actions-prefs-", suffix=".json")
with os.fdopen(_prefs_fd, "w") as f:
    json.dump(dict(json.loads(Path("tests/fixtures/preferences-5.2.3.json").read_text()), future_flag=False), f)
try:
    with harness.fixture_server(extra_env=dict(UTF8_ENV, QBT_FIXTURE_PREFS=_prefs_path)) as (port, env):
        for args, want in (
            (["dht", "--", "false"], [("POST", "/api/v2/app/setPreferences", "json=%7B%22dht%22%3Afalse%7D"),
                                      ("GET", "/api/v2/app/preferences", "")]),
            (["schedule_to", "--", "06:05"], [("POST", "/api/v2/app/setPreferences",
                                               "json=%7B%22schedule_to_hour%22%3A6%2C%22schedule_to_min%22%3A5%7D"),
                                              ("GET", "/api/v2/app/preferences", "")]),
            (["app_instance_name", "--", "a&b+c%d"], [("POST", "/api/v2/app/setPreferences",
                                                        "json=%7B%22app_instance_name%22%3A%22a%26b%2Bc%25d%22%7D"),
                                                       ("GET", "/api/v2/app/preferences", "")]),
            (["future_flag", "--", "true"], [("GET", "/api/v2/app/preferences", ""),
                                             ("POST", "/api/v2/app/setPreferences", "json=%7B%22future_flag%22%3Atrue%7D"),
                                             ("GET", "/api/v2/app/preferences", "")]),
        ):
            before = len(read_log(env))
            r = run(env, "pref-set", *args)
            e = new_entries(env, before)
            check(f"pref-set {args[0]}: succeeds", r.returncode == 0 and r.stdout.strip() == '{"ok":true}')
            check(f"pref-set {args[0]}: exact requests", [(x["method"], x["path"], x["body"]) for x in e] == want)
        before = len(read_log(env))
        r = run(env, "pref-set", "web_ui_port", "--", "8081")
        check("pref-set web_ui_port: refused before any request",
              r.returncode != 0 and r.stderr.strip() == "OmaqBT needs this as it is." and read_log(env)[before:] == [])
finally:
    os.unlink(_prefs_path)

if failures:
    print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nactions ok")
PY
