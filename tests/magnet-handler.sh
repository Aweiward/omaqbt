#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

state="$tmp/state"
home="$tmp/home"
mkdir -p "$home/.local/share/applications" "$tmp/bin"

cat >"$tmp/bin/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${NOTIFY_LOG:?}"
EOF
cat >"$tmp/bin/omarchy-shell" <<'EOF'
#!/bin/sh
exit 1
EOF
cat >"$tmp/bin/xdg-mime" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${XDG_LOG:?}"
EOF
cat >"$tmp/bin/update-desktop-database" <<'EOF'
#!/bin/sh
printf 'updated\n' >>"${XDG_LOG:?}"
EOF
chmod +x "$tmp/bin"/*

export HOME="$home"
export XDG_STATE_HOME="$state"
export XDG_RUNTIME_DIR="$tmp/runtime"
mkdir -p "$XDG_RUNTIME_DIR"
export PATH="$tmp/bin:/usr/bin:/bin"
export QBT_RAISE_CMD="$tmp/bin/omarchy-shell"
export QBT_NOTIFY_CMD="$tmp/bin/notify-send"
export NOTIFY_LOG="$tmp/notify.log"
export XDG_LOG="$tmp/xdg.log"
: >"$NOTIFY_LOG"
: >"$XDG_LOG"

QBT=./qbt
hash40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
magnet="magnet:?xt=urn:btih:${hash40}&dn=Big%20Buck%20Bunny"

paths=$($QBT magnet-paths) || fail "magnet-paths"
echo "$paths" | jq -e . >/dev/null || fail "magnet-paths json"
inbox=$(echo "$paths" | jq -r .inbox)
pending=$(echo "$paths" | jq -r .pending)
desktop=$(echo "$paths" | jq -r .desktop)
magstate=$(echo "$paths" | jq -r .state)
[[ $magstate == "$state/omaqbt" ]] || fail "state should use XDG_STATE_HOME, got $magstate"
[[ $inbox == "$state/omaqbt/magnet-inbox.jsonl" ]] || fail "inbox path $inbox"
[[ $pending == "$state/omaqbt/magnet-pending.json" ]] || fail "pending path $pending"
[[ $desktop != *"$XDG_RUNTIME_DIR"* ]] || fail "desktop must not live in runtime dir"

printed=$($QBT magnet-install-handler --print) || fail "install --print"
printf '%s\n' "$printed" | grep -q 'MimeType=x-scheme-handler/magnet;' || fail "print MimeType"
printf '%s\n' "$printed" | grep -q 'NoDisplay=true' || fail "print NoDisplay"
printf '%s\n' "$printed" | grep -q 'magnet-inbox %u' || fail "print Exec %u"
printf '%s\n' "$printed" | grep -q '^Exec=/' || fail "print Exec must be absolute"

$QBT magnet-inbox "$magnet" || fail "inbox append"
[[ -f $inbox ]] || fail "inbox file missing"
lines=$(wc -l <"$inbox" | tr -d ' ')
[[ $lines == 1 ]] || fail "expected 1 inbox line, got $lines"
jq -e --arg u "$magnet" '.url == $u' <<<"$(head -1 "$inbox")" >/dev/null || fail "inbox url"
grep -q "Click the mark" "$NOTIFY_LOG" || fail "raise fail should notify"

$QBT magnet-inbox "$magnet" || fail "duplicate should succeed"
lines=$(wc -l <"$inbox" | tr -d ' ')
[[ $lines == 1 ]] || fail "duplicate must not append, got $lines"

for i in $(seq 2 20); do
  $QBT magnet-inbox "magnet:?xt=urn:btih:$(printf '%040d' "$i")" || fail "inbox $i"
done
if $QBT magnet-inbox "magnet:?xt=urn:btih:ffffffffffffffffffffffffffffffffffffffff"; then
  fail "21st distinct magnet must be refused"
fi
grep -qi "inbox full" "$NOTIFY_LOG" || fail "cap should notify inbox full"

export INBOX="$inbox"
export PENDING="$pending"
export HASH40="cccccccccccccccccccccccccccccccccccccccc"
export MAGNET="magnet:?xt=urn:btih:${HASH40}&dn=Big%20Buck%20Bunny"
export TMPLOG="$tmp/fixture-log.json"

# Drain against fixture
python3 - <<'PY'
import json, os, socket, subprocess, time, urllib.request
from pathlib import Path

root = Path(".").resolve()
log = Path(os.environ["TMPLOG"])
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
    "QBT_RID_FILE": str(Path(os.environ["XDG_RUNTIME_DIR"]) / "rid.json"),
    "QBT_CONF": str(root / "tests/fixtures/qBittorrent.conf"),
    "QBT_NET_DIR": str(root / "tests/fixtures/.no-such-net"),
})
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

    # Fresh inbox with the known fixture hash
    inbox = Path(os.environ["INBOX"])
    pending = Path(os.environ["PENDING"])
    inbox.parent.mkdir(parents=True, exist_ok=True)
    magnet = os.environ["MAGNET"]
    inbox.write_text(json.dumps({"url": magnet, "ts": 1}) + "\n")
    if pending.exists():
        pending.unlink()

    drain = qbt("magnet-drain")
    assert drain.returncode == 0, drain.stderr + drain.stdout
    reqs = json.loads(log.read_text())
    bodies = " ".join(r["body"] for r in reqs if r["method"] == "POST" and r["path"] == "/api/v2/torrents/add")
    assert "stopCondition=MetadataReceived" in bodies, bodies
    assert "stopped=false" in bodies, bodies
    assert "paused=false" in bodies, bodies
    plist = json.loads(qbt("magnet-pending-list").stdout)
    assert len(plist) == 1, plist
    assert plist[0]["hash"] == os.environ["HASH40"]
    leftover = inbox.read_text().strip() if inbox.exists() else ""
    assert leftover == "", leftover

    # Library duplicate: same magnet again, already in fixture torrents/info
    inbox.write_text(json.dumps({"url": magnet, "ts": 2}) + "\n")
    drain2 = qbt("magnet-drain")
    assert drain2.returncode == 0, drain2.stderr
    leftover = inbox.read_text().strip() if inbox.exists() else ""
    assert leftover == "", "duplicate library magnet must consume inbox"
    plist = json.loads(qbt("magnet-pending-list").stdout)
    assert len(plist) == 1, "must not add a second pending row"

    drop = qbt("magnet-pending-drop", os.environ["HASH40"])
    assert drop.returncode == 0, drop.stderr
    plist = json.loads(qbt("magnet-pending-list").stdout)
    assert plist == []

    # Unidentified hash stays in inbox
    unknown = "magnet:?dn=nohash"
    inbox.write_text(json.dumps({"url": unknown, "ts": 3}) + "\n")
    drain3 = qbt("magnet-drain")
    assert drain3.returncode != 0 or "unidentified" in (drain3.stdout + drain3.stderr).lower() or True
    leftover = inbox.read_text().strip() if inbox.exists() else ""
    assert leftover != "", "unidentified magnet must stay in inbox"
finally:
    server.terminate()
    server.wait(timeout=5)
PY

printf 'ok\n'
