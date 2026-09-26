#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

HASH_A = "a" * 40
HASH_B = "b" * 40
EXPECTED_PATH = Path("tests/fixtures/actions-expected.json")

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

if failures:
    print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
    sys.exit(1)
print("\nactions ok")
PY
