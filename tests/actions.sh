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
#    delete, with the documented message.
REFUSALS = [
    (HASH_META, "It already has metadata."),
    (HASH_RUNNING, "Stop it first."),
    (HASH_NOMAGNET, "No magnet link for this torrent."),
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

# 9. fetch-metadata delete-didn't-take: the row stays listed, so the poll
#    times out. No add is ever attempted, and (since the torrent was never
#    actually lost) the magnet never goes anywhere near the inbox.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"delete": "noop"}))
        before = len(read_log(env))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata delete-didn't-take: exit != 0", r.returncode != 0)
        check("fetch-metadata delete-didn't-take: message", "didn't remove it in time" in r.stderr)
        entries = read_log(env)[before:]
        adds = [e for e in entries if e["path"] == "/api/v2/torrents/add"]
        check("fetch-metadata delete-didn't-take: no add", len(adds) == 0)
        check("fetch-metadata delete-didn't-take: never touched the raise stub", raise_log.read_text() == "")
        inbox_path = magnet_state / "magnet-inbox.jsonl"
        check("fetch-metadata delete-didn't-take: nothing in the inbox", not inbox_path.exists() or inbox_path.read_text().strip() == "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 10. fetch-metadata add-fails (404 from add): the magnet lands in the
#     inbox, the raise stub (never the real shell) is exercised, exit != 0.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "404"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata add-404: exit != 0", r.returncode != 0)
        check("fetch-metadata add-404: message", "back in your inbox" in r.stderr)
        inbox_path = magnet_state / "magnet-inbox.jsonl"
        check("fetch-metadata add-404: inbox has the magnet", inbox_path.exists() and MAGNET_NOMETA in inbox_path.read_text())
        check("fetch-metadata add-404: raise stub was exercised", raise_log.read_text() != "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

# 11. fetch-metadata add-fails (200 "Ok." but the hash never comes back):
#     same recovery as a hard add failure.
extra_env, magnet_state, raise_log, notify_log, stub_root = fetch_metadata_env(timeout=1)
try:
    with harness.fixture_server(extra_env=extra_env) as (port, env):
        control_path = Path(env["QBT_FIXTURE_CONTROL"])
        control_path.write_text(json.dumps({"add": "silent"}))
        r = run(env, "fetch-metadata", HASH_NOMETA)
        check("fetch-metadata add-silent: exit != 0", r.returncode != 0)
        check("fetch-metadata add-silent: message", "back in your inbox" in r.stderr)
        inbox_path = magnet_state / "magnet-inbox.jsonl"
        check("fetch-metadata add-silent: inbox has the magnet", inbox_path.exists() and MAGNET_NOMETA in inbox_path.read_text())
        check("fetch-metadata add-silent: raise stub was exercised", raise_log.read_text() != "")
finally:
    shutil.rmtree(magnet_state, ignore_errors=True)
    shutil.rmtree(stub_root, ignore_errors=True)

if failures:
    print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nactions ok")
PY
