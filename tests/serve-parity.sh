#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

QBT_RAW=$(mktemp)
SERVE_RAW=$(mktemp)
QBT_NORM=$(mktemp)
SERVE_NORM=$(mktemp)
cleanup() { rm -f "$QBT_RAW" "$SERVE_RAW" "$QBT_NORM" "$SERVE_NORM"; }
trap cleanup EXIT

python3 - "$QBT_RAW" "$SERVE_RAW" <<'PY'
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "tests/fixtures")
import harness  # noqa: E402

qbt_raw_path, serve_raw_path = sys.argv[1:3]

# Two separate fixture servers (fresh rid + cookie dirs each): each
# process's first request is a brand-new WebUI session, so both get a
# FULL maindata update regardless of which order they run in.
with harness.fixture_server() as (port, env):
    result = subprocess.run(["./qbt", "status"], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    Path(qbt_raw_path).write_text(result.stdout)

with harness.fixture_server() as (port2, env2):
    proc = subprocess.Popen(
        ["./qbt-serve"],
        env=env2,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        line = proc.stdout.readline()
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        for stream in (proc.stdout, proc.stderr):
            try:
                stream.close()
            except Exception:
                pass
    Path(serve_raw_path).write_text(line)
PY

jq -S 'del(.type) | .torrents |= sort_by(.hash)' "$QBT_RAW" >"$QBT_NORM"
jq -S 'del(.type) | .torrents |= sort_by(.hash)' "$SERVE_RAW" >"$SERVE_NORM"

if diff -u "$QBT_NORM" "$SERVE_NORM"; then
  echo "serve-parity ok"
else
  echo "serve-parity mismatch" >&2
  exit 1
fi
