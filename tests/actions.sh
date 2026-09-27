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

if failures:
    print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nactions ok")
PY
