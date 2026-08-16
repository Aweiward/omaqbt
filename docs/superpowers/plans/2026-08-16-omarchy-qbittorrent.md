# Omarchy qBittorrent Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `aweiward.omaqbt`, a themed Omarchy bar widget that runs `qbittorrent-nox` on the existing library and handles the daily loop (live list, magnets, start/stop, remove, file priorities) without opening the Qt window.

**Architecture:** Mullvad-shaped plugin. `Panel.qml` is the bar button and `KeyboardPanel`. `Service.qml` is the only QML object that runs processes. `qbt` (bash, curl + jq) owns the localhost Web API and the user systemd unit. `Model.js` is pure and unit-tested. Desktop `qbittorrent` stays installed as an escape hatch and must not run at the same time as nox.

**Tech Stack:** QML / Quickshell (`qs.Commons`, `qs.Ui`), bash, curl, jq, python3 (fixture server + tests only), Node `node:test` for `Model.js`, systemd --user, qBittorrent Web API v2 (5.2, start/stop not pause/resume).

**Spec:** `docs/superpowers/specs/2026-08-16-omarchy-qbittorrent-design.md`

---

## File map

Create these files. Do not edit `omarchy-mullvad` or anything under `/usr/share/omarchy/`.

| File | Responsibility |
|------|----------------|
| `package.json` | `node --test` runner |
| `LICENSE` | MIT, Copyright 2026 Aweiward |
| `manifest.json` | Plugin contract (`aweiward.omaqbt`) |
| `Model.js` | Pure classify/filter/format/parse/sanitize |
| `qbt` | Helper: Web API, lock, unit, conf, install |
| `Service.qml` | Runs `qbt`, holds live state |
| `QbittorrentIcon.qml` | Themed mark |
| `Panel.qml` | Bar button + list + detail + confirm |
| `README.md` | Install, use, clicks, keys, remove |
| `tests/model.test.js` | Node tests for `Model.js` |
| `tests/api-contract.sh` | Fixture HTTP server, never the real daemon |
| `tests/fixtures/server.py` | Records requests, serves canned Web API |
| `tests/fixtures/maindata-full.json` | First `/sync/maindata` body |
| `tests/fixtures/maindata-delta.json` | Later `/sync/maindata` body |
| `tests/fixtures/files.json` | `/torrents/files` body |
| `tests/fixtures/qBittorrent.conf` | Sample conf for port-read tests |

Already present: `.gitignore`, the spec, this plan. Leave `.superpowers/` untracked.

---

### Task 1: Scaffold

**Files:**
- Create: `package.json`
- Create: `LICENSE`
- Create: `manifest.json`

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "aweiward-qbittorrent",
  "private": true,
  "scripts": {
    "test": "node --test tests/*.test.js"
  }
}
```

- [ ] **Step 2: Write `LICENSE`**

Copy `/home/ethos/Projects/omarchy-mullvad/LICENSE` verbatim (MIT, Copyright (c) 2026 Aweiward).

- [ ] **Step 3: Write `manifest.json`**

```json
{
  "schemaVersion": 1,
  "id": "aweiward.omaqbt",
  "name": "qBittorrent",
  "version": "1.0.0",
  "author": "Aweiward",
  "license": "MIT",
  "description": "qBittorrent transfers, magnets, start/stop, remove, and file priorities in the Omarchy bar.",
  "kinds": ["bar-widget"],
  "entryPoints": {
    "barWidget": "Panel.qml"
  },
  "barWidget": {
    "displayName": "qBittorrent",
    "description": "Watch transfers, add magnets, start or stop, remove, and set file priorities.",
    "category": "Network",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": {
      "refreshIntervalSec": 5
    },
    "schema": [
      {
        "key": "refreshIntervalSec",
        "type": "integer",
        "label": "Fallback refresh interval (seconds)",
        "min": 5,
        "max": 3600,
        "step": 5,
        "defaultValue": 5
      }
    ]
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add package.json LICENSE manifest.json
git commit -m "chore: scaffold plugin manifest and package metadata"
```

---

### Task 2: Model — classify, filter, id

**Files:**
- Create: `Model.js`
- Create: `tests/model.test.js`

- [ ] **Step 1: Write the failing tests**

Create `tests/model.test.js`:

```javascript
const { test } = require("node:test");
const assert = require("node:assert/strict");
const Model = require("../Model.js");

test("classifyState maps downloading family to downloading", () => {
  for (const state of [
    "downloading", "metaDL", "stalledDL", "queuedDL", "forcedDL", "allocating", "checkingDL"
  ]) {
    assert.equal(Model.classifyState(state, 0.2), "downloading", state);
  }
});

test("classifyState maps uploading family to seeding", () => {
  for (const state of ["uploading", "stalledUP", "queuedUP", "forcedUP", "checkingUP"]) {
    assert.equal(Model.classifyState(state, 1), "seeding", state);
  }
});

test("classifyState maps paused/stopped under 100% to paused", () => {
  for (const state of ["pausedDL", "pausedUP", "stoppedDL", "stoppedUP"]) {
    assert.equal(Model.classifyState(state, 0.4), "paused", state);
  }
});

test("classifyState maps paused/stopped at 100% to completed", () => {
  assert.equal(Model.classifyState("stoppedUP", 1), "completed");
  assert.equal(Model.classifyState("pausedDL", 1.0), "completed");
});

test("classifyState maps error family to error", () => {
  assert.equal(Model.classifyState("error", 0), "error");
  assert.equal(Model.classifyState("missingFiles", 0.5), "error");
  assert.equal(Model.classifyState("unknown", 0), "error");
});

test("classifyState maps checkingResumeData and moving to other", () => {
  assert.equal(Model.classifyState("checkingResumeData", 0.5), "other");
  assert.equal(Model.classifyState("moving", 0.9), "other");
});

const sample = [
  { name: "dl", state: "downloading", progress: 0.2 },
  { name: "seed", state: "uploading", progress: 1 },
  { name: "paused", state: "stoppedDL", progress: 0.3 },
  { name: "done", state: "stoppedUP", progress: 1 },
  { name: "err", state: "missingFiles", progress: 0.1 },
  { name: "move", state: "moving", progress: 0.5 }
];

test("filterTorrents active keeps downloading and seeding only", () => {
  const got = Model.filterTorrents(sample, "active").map((t) => t.name);
  assert.deepEqual(got, ["dl", "seed"]);
});

test("filterTorrents paused excludes completed", () => {
  const got = Model.filterTorrents(sample, "paused").map((t) => t.name);
  assert.deepEqual(got, ["paused"]);
});

test("filterTorrents completed is finished and not seeding", () => {
  const got = Model.filterTorrents(sample, "completed").map((t) => t.name);
  assert.deepEqual(got, ["done"]);
});

test("filterTorrents all keeps every row", () => {
  assert.equal(Model.filterTorrents(sample, "all").length, sample.length);
});

test("filterTorrents defaults to active", () => {
  const got = Model.filterTorrents(sample).map((t) => t.name);
  assert.deepEqual(got, ["dl", "seed"]);
});

test("torrentId prefers hash, then infohash_v1, then infohash_v2", () => {
  assert.equal(Model.torrentId({ hash: "aaa", infohash_v1: "bbb" }), "aaa");
  assert.equal(Model.torrentId({ hash: "", infohash_v1: "bbb" }), "bbb");
  assert.equal(Model.torrentId({ infohash_v2: "ccc" }), "ccc");
  assert.equal(Model.torrentId({}), "");
});

test("anyActive is true only when something is downloading or seeding", () => {
  assert.equal(Model.anyActive(sample), true);
  assert.equal(Model.anyActive(Model.filterTorrents(sample, "paused")), false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test tests/model.test.js`

Expected: FAIL with `Cannot find module '../Model.js'` (or `classifyState` is not a function).

- [ ] **Step 3: Write `Model.js` with those functions**

```javascript
function normalizeState(state) {
  return String(state || "").toLowerCase();
}

function classifyState(state, progress) {
  var s = normalizeState(state);
  var p = Number(progress);
  if (!isFinite(p)) p = 0;
  if (s === "error" || s === "missingfiles" || s === "unknown") return "error";
  if (
    s === "uploading" || s === "stalledup" || s === "queuedup" ||
    s === "forcedup" || s === "checkingup"
  ) return "seeding";
  if (
    s === "downloading" || s === "metadl" || s === "stalleddl" ||
    s === "queueddl" || s === "forceddl" || s === "allocating" || s === "checkingdl"
  ) return "downloading";
  if (
    s === "pauseddl" || s === "pausedup" || s === "stoppeddl" || s === "stoppedup"
  ) return p >= 1 ? "completed" : "paused";
  return "other";
}

function filterTorrents(list, mode) {
  var rows = list || [];
  var want = mode || "active";
  if (want === "all") return rows.slice();
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var bucket = classifyState(rows[i].state, rows[i].progress);
    if (want === "active" && (bucket === "downloading" || bucket === "seeding")) out.push(rows[i]);
    else if (want === "paused" && bucket === "paused") out.push(rows[i]);
    else if (want === "completed" && bucket === "completed") out.push(rows[i]);
  }
  return out;
}

function torrentId(row) {
  var r = row || {};
  var hash = String(r.hash || "");
  if (hash !== "") return hash;
  var v1 = String(r.infohash_v1 || "");
  if (v1 !== "") return v1;
  return String(r.infohash_v2 || "");
}

function anyActive(list) {
  return filterTorrents(list, "active").length > 0;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    classifyState: classifyState,
    filterTorrents: filterTorrents,
    torrentId: torrentId,
    anyActive: anyActive
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test tests/model.test.js`

Expected: PASS, all tests.

- [ ] **Step 5: Commit**

```bash
git add Model.js tests/model.test.js
git commit -m "feat: classify and filter qBittorrent torrent states"
```

---

### Task 3: Model — format, URLs, priority, parse, sanitize

**Files:**
- Modify: `Model.js`
- Modify: `tests/model.test.js`

- [ ] **Step 1: Append failing tests to `tests/model.test.js`**

```javascript
test("formatSize uses 1024 units", () => {
  assert.equal(Model.formatSize(0), "0 B");
  assert.equal(Model.formatSize(512), "512 B");
  assert.equal(Model.formatSize(1024), "1.0 KiB");
  assert.equal(Model.formatSize(1536), "1.5 KiB");
  assert.equal(Model.formatSize(1048576), "1.0 MiB");
  assert.equal(Model.formatSize(2202009), "2.1 MiB");
});

test("formatRate appends /s", () => {
  assert.equal(Model.formatRate(0), "0 B/s");
  assert.equal(Model.formatRate(143360), "140 KiB/s");
});

test("formatEta treats missing or 8640000 as em dash", () => {
  assert.equal(Model.formatEta(-1), "—");
  assert.equal(Model.formatEta(8640000), "—");
  assert.equal(Model.formatEta(45), "45s");
  assert.equal(Model.formatEta(125), "2m");
  assert.equal(Model.formatEta(7200), "2h");
});

test("formatPercent rounds a 0-1 fraction", () => {
  assert.equal(Model.formatPercent(0.42), "42%");
  assert.equal(Model.formatPercent(1), "100%");
});

test("isAddableUrl accepts magnets and http .torrent URLs", () => {
  assert.equal(Model.isAddableUrl("magnet:?xt=urn:btih:abc"), true);
  assert.equal(
    Model.isAddableUrl("https://example.com/debian.torrent"),
    true
  );
  assert.equal(
    Model.isAddableUrl("https://example.com/debian.torrent?token=1"),
    true
  );
  assert.equal(Model.isAddableUrl("https://example.com/debian.iso"), false);
  assert.equal(Model.isAddableUrl("not a url"), false);
  assert.equal(Model.isAddableUrl(""), false);
});

test("priorityLabel and cycle walk Skip Low Normal High", () => {
  assert.equal(Model.priorityLabel(0), "Skip");
  assert.equal(Model.priorityLabel(1), "Low");
  assert.equal(Model.priorityLabel(6), "Normal");
  assert.equal(Model.priorityLabel(7), "High");
  assert.equal(Model.priorityLabel(99), "Low");
  assert.equal(Model.cyclePriority(0), 1);
  assert.equal(Model.cyclePriority(1), 6);
  assert.equal(Model.cyclePriority(6), 7);
  assert.equal(Model.cyclePriority(7), 0);
});

test("parseStatusJson reads helper snapshot and assigns torrentId", () => {
  const status = Model.parseStatusJson(JSON.stringify({
    installed: true,
    daemon: true,
    lockHolder: "nox",
    api: true,
    dlSpeed: 10,
    upSpeed: 2,
    torrents: [
      { hash: "", infohash_v1: "deadbeef", name: "iso", state: "downloading", progress: 0.2, dlSpeed: 1, upSpeed: 0, eta: 10, ratio: 0, size: 100 }
    ]
  }));
  assert.equal(status.ok, true);
  assert.equal(status.installed, true);
  assert.equal(status.torrents[0].hash, "deadbeef");
  assert.equal(status.torrents[0].bucket, "downloading");
});

test("parseStatusJson returns not-ok for garbage", () => {
  const status = Model.parseStatusJson("nope");
  assert.equal(status.ok, false);
  assert.equal(status.installed, false);
  assert.deepEqual(status.torrents, []);
});

test("sanitizeError strips SID cookies and password fields", () => {
  const cleaned = Model.sanitizeError("fail SID=abc+def/12; password=secret leftover");
  assert.equal(/SID=/i.test(cleaned), false);
  assert.equal(/password=secret/i.test(cleaned), false);
  assert.match(cleaned, /fail/);
  assert.match(cleaned, /leftover/);
});
```

- [ ] **Step 2: Run tests to verify new ones fail**

Run: `node --test tests/model.test.js`

Expected: FAIL on `formatSize is not a function` (classify tests still pass).

- [ ] **Step 3: Add the functions to `Model.js` and export them**

Append before the `module.exports` block, then extend the export object.

```javascript
function formatSize(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n < 0) n = 0;
  var units = ["B", "KiB", "MiB", "GiB", "TiB"];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n = n / 1024;
    i++;
  }
  if (i === 0) return Math.round(n) + " B";
  return n.toFixed(1) + " " + units[i];
}

function formatRate(bytesPerSec) {
  return formatSize(bytesPerSec) + "/s";
}

function formatEta(seconds) {
  var n = Number(seconds);
  if (!isFinite(n) || n < 0 || n >= 8640000) return "—";
  if (n < 60) return Math.round(n) + "s";
  if (n < 3600) return Math.round(n / 60) + "m";
  if (n < 86400) return Math.round(n / 3600) + "h";
  return Math.round(n / 86400) + "d";
}

function formatPercent(progress) {
  var n = Number(progress);
  if (!isFinite(n)) n = 0;
  return Math.round(n * 100) + "%";
}

function isAddableUrl(text) {
  var s = String(text || "").trim();
  if (s.indexOf("magnet:") === 0) return true;
  if (!/^https?:\/\//i.test(s)) return false;
  var path = s.split("?")[0].split("#")[0];
  return /\.torrent$/i.test(path);
}

var PRIORITY_ORDER = [0, 1, 6, 7];
var PRIORITY_LABELS = { 0: "Skip", 1: "Low", 6: "Normal", 7: "High" };

function priorityLabel(value) {
  var n = parseInt(String(value), 10);
  return PRIORITY_LABELS[n] || "Low";
}

function cyclePriority(value) {
  var n = parseInt(String(value), 10);
  var i = PRIORITY_ORDER.indexOf(n);
  if (i === -1) return 1;
  return PRIORITY_ORDER[(i + 1) % PRIORITY_ORDER.length];
}

function emptyStatus() {
  return {
    ok: false,
    installed: false,
    daemon: false,
    lockHolder: "none",
    api: false,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: [],
    error: ""
  };
}

function parseStatusJson(raw) {
  var parsed;
  try {
    parsed = JSON.parse(String(raw || ""));
  } catch (e) {
    return emptyStatus();
  }
  if (!parsed || typeof parsed !== "object") return emptyStatus();
  var rows = parsed.torrents || [];
  var torrents = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    var id = torrentId(row);
    torrents.push({
      hash: id,
      name: String(row.name || ""),
      state: String(row.state || ""),
      progress: Number(row.progress || 0),
      dlSpeed: Number(row.dlSpeed || 0),
      upSpeed: Number(row.upSpeed || 0),
      eta: Number(row.eta || 0),
      ratio: Number(row.ratio || 0),
      size: Number(row.size || 0),
      bucket: classifyState(row.state, row.progress)
    });
  }
  return {
    ok: true,
    installed: parsed.installed === true,
    daemon: parsed.daemon === true,
    lockHolder: String(parsed.lockHolder || "none"),
    api: parsed.api === true,
    dlSpeed: Number(parsed.dlSpeed || 0),
    upSpeed: Number(parsed.upSpeed || 0),
    torrents: torrents,
    error: String(parsed.error || "")
  };
}

function sanitizeError(raw) {
  return String(raw || "")
    .replace(/SID=[^;\s]*/gi, "SID=<redacted>")
    .replace(/password=[^;\s]*/gi, "password=<redacted>")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}
```

Add every new name to `module.exports`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `node --test tests/model.test.js`

Expected: PASS. If `formatRate(143360)` is `140.0 KiB/s` instead of `140 KiB/s`, adjust the test to accept `140.0 KiB/s` (the `toFixed(1)` implementation). Do not special-case integers.

- [ ] **Step 5: Commit**

```bash
git add Model.js tests/model.test.js
git commit -m "feat: format rates, detect magnets, parse helper status"
```

---

### Task 4: Fixture server and `qbt status`

**Files:**
- Create: `tests/fixtures/maindata-full.json`
- Create: `tests/fixtures/maindata-delta.json`
- Create: `tests/fixtures/files.json`
- Create: `tests/fixtures/qBittorrent.conf`
- Create: `tests/fixtures/server.py`
- Create: `qbt`
- Create: `tests/api-contract.sh`

- [ ] **Step 1: Write fixtures**

`tests/fixtures/maindata-full.json`:

```json
{
  "rid": 1,
  "full_update": true,
  "server_state": { "dl_info_speed": 2202009, "up_info_speed": 143360 },
  "torrents": {
    "": {
      "name": "debian.iso",
      "state": "downloading",
      "progress": 0.42,
      "dlspeed": 1887436,
      "upspeed": 0,
      "eta": 720,
      "ratio": 0.1,
      "size": 661651456,
      "infohash_v1": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
      "name": "arch.iso",
      "state": "uploading",
      "progress": 1,
      "dlspeed": 0,
      "upspeed": 143360,
      "eta": 8640000,
      "ratio": 1.2,
      "size": 1048576000
    }
  }
}
```

`tests/fixtures/maindata-delta.json`:

```json
{
  "rid": 2,
  "full_update": false,
  "server_state": { "dl_info_speed": 100, "up_info_speed": 0 },
  "torrents": {
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
      "progress": 0.5,
      "dlspeed": 100,
      "eta": 600
    }
  },
  "torrents_removed": ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]
}
```

`tests/fixtures/files.json`:

```json
[
  { "index": 0, "name": "debian.iso", "progress": 0.42, "priority": 1 },
  { "index": 1, "name": "MD5SUMS", "progress": 1, "priority": 0 }
]
```

`tests/fixtures/qBittorrent.conf`:

```
[BitTorrent]
Session\Port=35763

[Preferences]
WebUI\Port=18080
```

`tests/fixtures/server.py`:

```python
#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
LOG = Path(os.environ["QBT_FIXTURE_LOG"])
COOKIE = "SID=leaked-secret-value"
FULL = json.loads((ROOT / "maindata-full.json").read_text())
DELTA = json.loads((ROOT / "maindata-delta.json").read_text())
FILES = json.loads((ROOT / "files.json").read_text())


def record(method, path, body, query):
    entries = []
    if LOG.exists():
        entries = json.loads(LOG.read_text() or "[]")
    entries.append({"method": method, "path": path, "body": body, "query": query})
    LOG.write_text(json.dumps(entries))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode("utf-8") if n else ""

    def _send(self, code, body=b"", content_type="application/json"):
        if os.environ.get("QBT_FIXTURE_FORBIDDEN") == "1":
            self.send_response(403)
            self.send_header("Set-Cookie", COOKIE)
            self.end_headers()
            self.wfile.write(b"SID=leaked-secret-value forbidden")
            return
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        record("GET", parsed.path, "", parse_qs(parsed.query))
        if parsed.path == "/api/v2/sync/maindata":
            rid = (parse_qs(parsed.query).get("rid") or ["0"])[0]
            payload = DELTA if rid not in ("", "0") else FULL
            self._send(200, json.dumps(payload).encode())
            return
        if parsed.path == "/api/v2/torrents/files":
            self._send(200, json.dumps(FILES).encode())
            return
        self._send(404, b"{}")

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read()
        record("POST", parsed.path, body, parse_qs(parsed.query))
        if parsed.path in (
            "/api/v2/torrents/add",
            "/api/v2/torrents/start",
            "/api/v2/torrents/stop",
            "/api/v2/torrents/delete",
            "/api/v2/torrents/filePrio",
        ):
            self._send(200, b"Ok.")
            return
        if parsed.path in ("/api/v2/torrents/pause", "/api/v2/torrents/resume"):
            self._send(404, b"gone")
            return
        self._send(404, b"{}")


if __name__ == "__main__":
    port = int(os.environ["QBT_FIXTURE_PORT"])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
```

- [ ] **Step 2: Write a failing contract that calls `./qbt status`**

Create `tests/api-contract.sh`:

```bash
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
finally:
    server.terminate()
    server.wait(timeout=5)

print("status-contract ok")
PY
```

`chmod +x tests/api-contract.sh`

- [ ] **Step 3: Run the contract to verify it fails**

Run: `tests/api-contract.sh`

Expected: FAIL with `./qbt: No such file or directory` (or similar).

- [ ] **Step 4: Write `qbt` with `status` (and shared HTTP helpers)**

Create executable `qbt`. It must:

- Use `QBT_BASE` when set, otherwise `http://127.0.0.1:<port from QBT_CONF or 8080>`
- Refuse any host other than `127.0.0.1`
- Honor `QBT_INSTALLED`, `QBT_DAEMON`, `QBT_LOCK` in tests
- Persist rid + torrent map in `QBT_RID_FILE` (default `$XDG_RUNTIME_DIR/omaqbt/rid.json`)
- Map API `dlspeed`/`upspeed` to `dlSpeed`/`upSpeed`
- Fill `hash` via hash, else infohash_v1, else infohash_v2, else the map key
- Print only JSON on stdout

```bash
#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="${QBT_HOME:-$HOME}"
CONF="${QBT_CONF:-$HOME_DIR/.config/qBittorrent/qBittorrent.conf}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/omaqbt"
RID_FILE="${QBT_RID_FILE:-$STATE_DIR/rid.json}"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
UNIT_FILE="$UNIT_DIR/omaqbt-nox.service"

sanitize() {
  sed -E 's/SID=[^;[:space:]]*/SID=<redacted>/gi; s/password=[^;[:space:]]*/password=<redacted>/gi'
}

die() {
  printf '%s\n' "$*" | sanitize >&2
  exit 1
}

read_port() {
  local port=""
  if [[ -f $CONF ]]; then
    port=$(grep -E '^WebUI\\Port=' "$CONF" | tail -n1 | cut -d= -f2 || true)
  fi
  if [[ -z ${port:-} ]]; then
    port=8080
  fi
  printf '%s' "$port"
}

base_url() {
  if [[ -n ${QBT_BASE:-} ]]; then
    printf '%s' "$QBT_BASE"
    return
  fi
  printf 'http://127.0.0.1:%s' "$(read_port)"
}

assert_local_base() {
  local base host
  base=$(base_url)
  host=$(printf '%s' "$base" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
  [[ $host == 127.0.0.1 ]] || die "refusing non-localhost host: $host"
}

lock_holder() {
  if [[ -n ${QBT_LOCK:-} ]]; then
    printf '%s' "$QBT_LOCK"
    return
  fi
  if pgrep -x qbittorrent >/dev/null 2>&1; then
    printf 'gui'
  elif pgrep -x qbittorrent-nox >/dev/null 2>&1; then
    printf 'nox'
  else
    printf 'none'
  fi
}

is_installed() {
  if [[ -n ${QBT_INSTALLED:-} ]]; then
    [[ $QBT_INSTALLED == 1 ]]
    return
  fi
  command -v qbittorrent-nox >/dev/null 2>&1
}

is_daemon() {
  if [[ -n ${QBT_DAEMON:-} ]]; then
    [[ $QBT_DAEMON == 1 ]]
    return
  fi
  pgrep -x qbittorrent-nox >/dev/null 2>&1
}

api() {
  assert_local_base
  local method=$1 path=$2
  local body=${3:-}
  local url
  url="$(base_url)$path"
  local args=(-sS -g --max-time 5 -X "$method" "$url")
  if [[ -n $body ]]; then
    args+=(-H "Content-Type: application/x-www-form-urlencoded" --data "$body")
  fi
  local tmp code
  tmp=$(mktemp)
  code=$(curl -o "$tmp" -w '%{http_code}' "${args[@]}" || true)
  local resp
  resp=$(cat "$tmp")
  rm -f "$tmp"
  if [[ $code == 403 ]]; then
    die "localhost auth is required"
  fi
  if [[ $code != 200 && $code != 204 ]]; then
    die "HTTP $code $(printf '%s' "$resp" | sanitize)"
  fi
  printf '%s' "$resp"
}

cmd_status() {
  local installed=false daemon=false api=false
  is_installed && installed=true
  is_daemon && daemon=true
  local lock
  lock=$(lock_holder)
  local torrents='[]' dl=0 up=0
  if [[ $installed == true && $daemon == true && $lock != gui ]]; then
    mkdir -p "$(dirname "$RID_FILE")"
    local rid=0 cache='{}'
    if [[ -f $RID_FILE ]]; then
      rid=$(jq -r '.rid // 0' "$RID_FILE")
      cache=$(jq -c '.torrents // {}' "$RID_FILE")
    fi
    local raw
    if raw=$(api GET "/api/v2/sync/maindata?rid=${rid}"); then
      api=true
      local merged
      merged=$(CACHE="$cache" python3 -c '
import json, os, sys
raw = json.loads(sys.stdin.read() or "{}")
cache = json.loads(os.environ["CACHE"] or "{}")
if raw.get("full_update"):
    torrents = raw.get("torrents") or {}
else:
    torrents = dict(cache)
    for k, v in (raw.get("torrents") or {}).items():
        cur = dict(torrents.get(k) or {})
        cur.update(v or {})
        torrents[k] = cur
    for k in raw.get("torrents_removed") or []:
        torrents.pop(k, None)
rows = []
for key, t in torrents.items():
    hid = t.get("hash") or t.get("infohash_v1") or t.get("infohash_v2") or key
    rows.append({
        "hash": hid,
        "name": t.get("name") or "",
        "state": t.get("state") or "",
        "progress": t.get("progress") or 0,
        "dlSpeed": t.get("dlspeed") if t.get("dlspeed") is not None else t.get("dlSpeed") or 0,
        "upSpeed": t.get("upspeed") if t.get("upspeed") is not None else t.get("upSpeed") or 0,
        "eta": t.get("eta") or 0,
        "ratio": t.get("ratio") or 0,
        "size": t.get("size") or 0,
    })
print(json.dumps({
    "rid": raw.get("rid") or 0,
    "torrents_map": torrents,
    "torrents": rows,
    "dlSpeed": (raw.get("server_state") or {}).get("dl_info_speed") or 0,
    "upSpeed": (raw.get("server_state") or {}).get("up_info_speed") or 0,
}))
' <<<"$raw")
      printf '%s' "$merged" | jq '{rid, torrents: .torrents_map}' >"$RID_FILE"
      torrents=$(printf '%s' "$merged" | jq -c '.torrents')
      dl=$(printf '%s' "$merged" | jq '.dlSpeed')
      up=$(printf '%s' "$merged" | jq '.upSpeed')
    else
      api=false
    fi
  fi
  jq -n \
    --argjson installed "$installed" \
    --argjson daemon "$daemon" \
    --arg lock "$lock" \
    --argjson api "$api" \
    --argjson dl "$dl" \
    --argjson up "$up" \
    --argjson torrents "$torrents" \
    '{installed:$installed, daemon:$daemon, lockHolder:$lock, api:$api, dlSpeed:$dl, upSpeed:$up, torrents:$torrents}'
}

cmd_status
```

Do **not** put `cmd_status` as the only dispatch yet if you prefer a `case` now. A `case ${1:-}` that only handles `status` is fine; later tasks add verbs. Make sure unknown verbs `die`.

`chmod +x qbt`

Important: `api GET` currently `die`s on failure, so the `if raw=$(api GET ...)` branch will abort the script. For `status`, catch HTTP failure and still print JSON with `api: false`:

```bash
set +e
raw=$(api GET "/api/v2/sync/maindata?rid=${rid}" 2>/tmp/qbt-api.err)
ok=$?
set -e
if [[ $ok -eq 0 ]]; then
  ...
else
  api=false
fi
```

Do not leak `/tmp/qbt-api.err` contents unless you `sanitize` them into the JSON `error` field. For v1, leave `error` off the success path.

- [ ] **Step 5: Run the status contract**

Run: `tests/api-contract.sh`

Expected: `status-contract ok` and exit 0.

If the empty-hash torrent is dropped, fix the merge python so the map key is used as the fallback id (the fixture’s first torrent has `"hash"` missing and uses `infohash_v1`).

- [ ] **Step 6: Commit**

```bash
git add qbt tests/api-contract.sh tests/fixtures
git commit -m "feat: add qbt status helper against a fixture Web API"
```

---

### Task 5: `qbt` mutations and SID stripping

**Files:**
- Modify: `qbt`
- Modify: `tests/api-contract.sh`

- [ ] **Step 1: Extend `tests/api-contract.sh` before `finally`**

Add after the second `status` assertion, still using the same `qbt()` helper and server:

```python
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
```

After the server is stopped, start a second forbidden server:

```python
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
```

Change the final print to `print("api-contract ok")`.

- [ ] **Step 2: Run to verify new assertions fail**

Run: `tests/api-contract.sh`

Expected: FAIL because `add` is not a verb.

- [ ] **Step 3: Add verbs to `qbt`**

Replace the trailing `cmd_status` with a dispatcher. Each mutation prints `{"ok":true}` on success.

```bash
cmd_add() {
  local url=${1:-}
  [[ -n $url ]] || die "usage: qbt add <magnet-or-url>"
  api POST "/api/v2/torrents/add" "urls=${url}" >/dev/null
  printf '%s\n' '{"ok":true}'
}

cmd_start() {
  local hash=${1:-}
  [[ -n $hash ]] || die "usage: qbt start <hash|all>"
  api POST "/api/v2/torrents/start" "hashes=${hash}" >/dev/null
  printf '%s\n' '{"ok":true}'
}

cmd_stop() {
  local hash=${1:-}
  [[ -n $hash ]] || die "usage: qbt stop <hash|all>"
  api POST "/api/v2/torrents/stop" "hashes=${hash}" >/dev/null
  printf '%s\n' '{"ok":true}'
}

cmd_delete() {
  local hash=${1:-}
  local files=false
  shift || true
  if [[ ${1:-} == --files ]]; then files=true; fi
  [[ -n $hash ]] || die "usage: qbt delete <hash> [--files]"
  api POST "/api/v2/torrents/delete" "hashes=${hash}&deleteFiles=${files}" >/dev/null
  printf '%s\n' '{"ok":true}'
}

cmd_files() {
  local hash=${1:-}
  [[ -n $hash ]] || die "usage: qbt files <hash>"
  api GET "/api/v2/torrents/files?hash=${hash}"
  printf '\n'
}

cmd_prio() {
  local hash=${1:-} index=${2:-} prio=${3:-}
  [[ -n $hash && -n $index && -n $prio ]] || die "usage: qbt prio <hash> <index> <0|1|6|7>"
  api POST "/api/v2/torrents/filePrio" "hash=${hash}&id=${index}&priority=${prio}" >/dev/null
  printf '%s\n' '{"ok":true}'
}

case ${1:-} in
  status) shift; cmd_status "$@" ;;
  add) shift; cmd_add "$@" ;;
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  delete) shift; cmd_delete "$@" ;;
  files) shift; cmd_files "$@" ;;
  prio) shift; cmd_prio "$@" ;;
  *) die "usage: qbt status|add|start|stop|delete|files|prio|install|start-daemon|stop-daemon" ;;
esac
```

URL-encode `urls=` with `jq -nr --arg u "$url" '$u|@uri'` if the raw magnet assertion is awkward. Keep the contract assertion flexible (raw or encoded) as written above.

- [ ] **Step 4: Run the contract**

Run: `tests/api-contract.sh`

Expected: `api-contract ok`

- [ ] **Step 5: Commit**

```bash
git add qbt tests/api-contract.sh
git commit -m "feat: add start/stop/delete/files/prio verbs to qbt"
```

---

### Task 6: `qbt` daemon install, lock, conf, unit

**Files:**
- Modify: `qbt`
- Modify: `tests/api-contract.sh`

- [ ] **Step 1: Add a daemon-contract block at the end of `tests/api-contract.sh`**

This block does **not** start nox or call `systemctl` for real:

```python
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
assert "close qBittorrent" in (gui.stderr + gui.stdout).lower() or "qt" in (gui.stderr + gui.stdout).lower()

denv["QBT_LOCK"] = "none"
ok = subprocess.run(["./qbt", "start-daemon"], env=denv, text=True, capture_output=True)
assert ok.returncode == 0, ok.stderr
conf = (home / ".config/qBittorrent/qBittorrent.conf").read_text()
assert r"WebUI\Enabled=true" in conf
assert r"WebUI\Address=127.0.0.1" in conf
assert r"WebUI\LocalHostAuth=false" in conf
assert r"WebUI\Port=9001" in conf
unit = (home / ".config/systemd/user/omaqbt-nox.service").read_text()
assert "ExecStart=/usr/bin/qbittorrent-nox" in unit
assert "WantedBy=default.target" in unit
print("daemon-contract ok")
```

- [ ] **Step 2: Run to verify fail**

Run: `tests/api-contract.sh`

Expected: FAIL on unknown `start-daemon` or missing close-qBittorrent message.

- [ ] **Step 3: Implement `install`, `start-daemon`, `stop-daemon`**

```bash
set_key() {
  local file=$1 key=$2 value=$3
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -q "^\[Preferences\]" "$file"; then
    :
  else
    printf '\n[Preferences]\n' >>"$file"
  fi
  if grep -q "^${key}=" "$file"; then
    local tmp
    tmp=$(mktemp)
    sed "s|^${key}=.*|${key}=${value}|" "$file" >"$tmp"
    mv "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

ensure_port() {
  if ! grep -q '^WebUI\\Port=' "$CONF" 2>/dev/null; then
    set_key "$CONF" 'WebUI\Port' '8080'
  fi
}

write_unit() {
  mkdir -p "$UNIT_DIR"
  if [[ -f $UNIT_FILE ]]; then
    return
  fi
  cat >"$UNIT_FILE" <<'UNIT'
[Unit]
Description=qBittorrent-nox for the Omarchy bar plugin
After=network-online.target

[Service]
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
}

cmd_install() {
  omarchy pkg add qbittorrent-nox
  printf '%s\n' '{"ok":true}'
}

cmd_start_daemon() {
  local lock
  lock=$(lock_holder)
  if [[ $lock == gui ]]; then
    die "Close qBittorrent before starting the daemon."
  fi
  write_unit
  set_key "$CONF" 'WebUI\Enabled' 'true'
  set_key "$CONF" 'WebUI\Address' '127.0.0.1'
  set_key "$CONF" 'WebUI\LocalHostAuth' 'false'
  ensure_port
  if [[ ${QBT_SKIP_SYSTEMCTL:-} != 1 ]]; then
    systemctl --user daemon-reload
    systemctl --user enable --now omaqbt-nox.service
  fi
  printf '%s\n' '{"ok":true}'
}

cmd_stop_daemon() {
  if [[ ${QBT_SKIP_SYSTEMCTL:-} != 1 ]]; then
    systemctl --user stop omaqbt-nox.service
  fi
  printf '%s\n' '{"ok":true}'
}
```

Add the three verbs to the `case`. `install` is not covered by the fixture test; it is a thin wrapper around `omarchy pkg add`.

- [ ] **Step 4: Run the full contract**

Run: `tests/api-contract.sh`

Expected: `api-contract ok` then `daemon-contract ok`.

- [ ] **Step 5: Commit**

```bash
git add qbt tests/api-contract.sh
git commit -m "feat: start qbittorrent-nox user service and pin localhost Web UI"
```

---

### Task 7: `Service.qml`

**Files:**
- Create: `Service.qml`

No QML test harness. This task is done when the file loads mentally against the helper contract: every public function is a `qbt` verb, and `refresh` assigns `Model.parseStatusJson`.

- [ ] **Step 1: Write `Service.qml`**

Follow `omarchy-mullvad/Service.qml` process style. Required surface:

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  property var settings: ({})

  property bool installed: false
  property bool daemon: false
  property string lockHolder: "none"
  property bool api: false
  property real dlSpeed: 0
  property real upSpeed: 0
  property var torrents: []
  property var files: []
  property string lastError: ""
  property string actionStatus: ""
  property string clipboardText: ""

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(settings && settings.refreshIntervalSec != null ? settings.refreshIntervalSec : 5), 10)
    if (!isFinite(n)) n = 5
    if (n < 5) n = 5
    if (n > 3600) n = 3600
    return n
  }
  readonly property string helperPath: {
    var s = Qt.resolvedUrl("qbt").toString()
    if (s.indexOf("file://") === 0) return decodeURIComponent(s.substring(7))
    return s
  }
  readonly property bool busy: statusProcess.running || actionProcess.running || installProcess.running || daemonProcess.running || clipProcess.running
  readonly property bool ready: installed && daemon && lockHolder !== "gui" && api
  readonly property bool transferring: Model.anyActive(torrents)
  readonly property bool warning: !installed || !daemon || lockHolder === "gui" || !api

  function clearError() { lastError = "" }

  function applyStatus(raw) {
    var parsed = Model.parseStatusJson(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Failed to read qBittorrent status"
      return
    }
    installed = parsed.installed
    daemon = parsed.daemon
    lockHolder = parsed.lockHolder
    api = parsed.api
    dlSpeed = parsed.dlSpeed
    upSpeed = parsed.upSpeed
    torrents = parsed.torrents
    if (parsed.error) lastError = parsed.error
    else lastError = ""
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = [helperPath, "status"]
    statusProcess.running = true
  }

  function readClipboard() {
    clipboardText = ""
    clipProcess.command = ["wl-paste", "--no-newline"]
    clipProcess.running = true
  }

  function addUrl(url) {
    if (!Model.isAddableUrl(url) || actionProcess.running) {
      if (!Model.isAddableUrl(url)) lastError = "Paste a magnet or a .torrent URL."
      return
    }
    clearError()
    actionStatus = "Adding torrent…"
    actionProcess.command = [helperPath, "add", String(url).trim()]
    actionProcess.running = true
  }

  function startHash(hash) {
    if (actionProcess.running) return
    clearError()
    actionProcess.command = [helperPath, "start", hash]
    actionProcess.running = true
  }

  function stopHash(hash) {
    if (actionProcess.running) return
    clearError()
    actionProcess.command = [helperPath, "stop", hash]
    actionProcess.running = true
  }

  function toggleHash(hash) {
    var row = null
    for (var i = 0; i < torrents.length; i++) if (torrents[i].hash === hash) row = torrents[i]
    if (!row) return
    var bucket = Model.classifyState(row.state, row.progress)
    if (bucket === "paused" || bucket === "completed") startHash(hash)
    else stopHash(hash)
  }

  function toggleAll() {
    if (Model.anyActive(torrents)) stopHash("all")
    else startHash("all")
  }

  function deleteHash(hash, withFiles) {
    if (actionProcess.running) return
    clearError()
    actionStatus = withFiles ? "Deleting torrent and files…" : "Removing torrent…"
    if (withFiles) actionProcess.command = [helperPath, "delete", hash, "--files"]
    else actionProcess.command = [helperPath, "delete", hash]
    actionProcess.running = true
  }

  function loadFiles(hash) {
    files = []
    actionProcess.command = [helperPath, "files", hash]
    actionProcess._kind = "files"
    actionProcess.running = true
  }

  function setPrio(hash, index, prio) {
    if (actionProcess.running) return
    actionProcess.command = [helperPath, "prio", hash, String(index), String(prio)]
    actionProcess.running = true
  }

  function installDaemon() {
    clearError()
    actionStatus = "Installing qbittorrent-nox…"
    installProcess.command = [helperPath, "install"]
    installProcess.running = true
  }

  function startDaemon() {
    clearError()
    actionStatus = "Starting qBittorrent daemon…"
    daemonProcess.command = [helperPath, "start-daemon"]
    daemonProcess.running = true
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.lastError = Model.sanitizeError(statusErr.text || "qBittorrent is not reachable")
    }
  }

  Process {
    id: clipProcess
    running: false
    command: []
    stdout: StdioCollector { id: clipOut; waitForEnd: true }
    onExited: function() { root.clipboardText = String(clipOut.text || "") }
  }

  Process {
    id: actionProcess
    property string _kind: ""
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var kind = actionProcess._kind
      actionProcess._kind = ""
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(actionErr.text || actionOut.text || "qBittorrent command failed")
        return
      }
      if (kind === "files") {
        try { root.files = JSON.parse(String(actionOut.text || "[]")) }
        catch (e) { root.files = [] }
        return
      }
      root.refresh()
    }
  }

  Process {
    id: installProcess
    running: false
    command: []
    stdout: StdioCollector { id: installOut; waitForEnd: true }
    stderr: StdioCollector { id: installErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(installErr.text || "Install failed")
        return
      }
      root.startDaemon()
    }
  }

  Process {
    id: daemonProcess
    running: false
    command: []
    stdout: StdioCollector { id: daemonOut; waitForEnd: true }
    stderr: StdioCollector { id: daemonErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0)
        root.lastError = Model.sanitizeError(daemonErr.text || "Could not start qbittorrent-nox")
      root.refresh()
    }
  }
}
```

Fix `loadFiles`: do not share `actionProcess` with mutations without `_kind`, or a `prio` response will be parsed as files. Keep `filesProcess` as its own `Process` if that is clearer — preferred. If you split it, `loadFiles` must not set `_kind` on `actionProcess`.

- [ ] **Step 2: Commit**

```bash
git add Service.qml
git commit -m "feat: add Service that runs qbt and holds transfer state"
```

---

### Task 8: Themed mark

**Files:**
- Create: `QbittorrentIcon.qml`

- [ ] **Step 1: Write `QbittorrentIcon.qml`**

Match `MullvadIcon.qml`: `iconSize`, `color`, `badgeColor`, `warning`. No `busy` color logic inside the icon — the panel passes dim vs bright as `color`.

Circle + downward chevron, stroke from `iconSize`, warning badge copied from Mullvad (`BorderSurface` + `!`).

```qml
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1.6, iconSize * 0.12)
  readonly property real pad: iconSize * 0.08

  Rectangle {
    id: ring
    anchors.fill: parent
    anchors.margins: root.pad
    radius: width / 2
    color: "transparent"
    border.color: root.color
    border.width: root.stroke
  }

  Rectangle {
    width: root.stroke
    height: ring.height * 0.34
    radius: width / 2
    color: root.color
    anchors.horizontalCenter: ring.horizontalCenter
    anchors.bottom: ring.verticalCenter
    anchors.bottomMargin: -root.stroke
  }

  Canvas {
    anchors.fill: ring
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.strokeStyle = root.color
      ctx.lineWidth = root.stroke
      ctx.lineCap = "round"
      ctx.lineJoin = "round"
      var cx = width / 2
      var y = height * 0.58
      var w = width * 0.28
      ctx.beginPath()
      ctx.moveTo(cx - w, y - w * 0.45)
      ctx.lineTo(cx, y + w * 0.35)
      ctx.lineTo(cx + w, y - w * 0.45)
      ctx.stroke()
    }
    onVisibleChanged: requestPaint()
    Component.onCompleted: requestPaint()
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)
    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
```

Repaint when `color` changes (`onColorChanged: requestPaint()` on the Canvas).

- [ ] **Step 2: Commit**

```bash
git add QbittorrentIcon.qml
git commit -m "feat: add themed qBittorrent bar mark"
```

---

### Task 9: Panel — bar, list, detail, confirm

**Files:**
- Create: `Panel.qml`

- [ ] **Step 1: Write the complete `Panel.qml`**

Create `Panel.qml` with this exact file. Do not stub detail or confirm — they ship in this task.

```qml
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "aweiward.omaqbt"
  ipcTarget: "aweiward.omaqbt"
  manageIpc: false

  property string focusSection: "header"
  property int rowIndex: 0
  property int fileIndex: 0
  property bool cursorActive: false
  property string view: "list"
  property string filterMode: "active"
  property string detailHash: ""
  property string magnetField: ""
  property bool confirmOpen: false
  property string pendingDeleteHash: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color barIconColor: qbt.transferring ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool fieldFocused: magnetInput && magnetInput.activeFocus
  readonly property var visibleTorrents: Model.filterTorrents(qbt.torrents, filterMode)
  readonly property int activeCount: Model.filterTorrents(qbt.torrents, "active").length
  readonly property var selectedTorrent: {
    if (visibleTorrents.length === 0) return null
    return visibleTorrents[Math.max(0, Math.min(rowIndex, visibleTorrents.length - 1))]
  }
  readonly property var detailTorrent: {
    for (var i = 0; i < qbt.torrents.length; i++)
      if (qbt.torrents[i].hash === detailHash) return qbt.torrents[i]
    return null
  }
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && qbt.ready && view === "list"
  readonly property string heroTitle: {
    if (view === "detail" && detailTorrent) return detailTorrent.name
    return "qBittorrent"
  }
  readonly property string heroMeta: {
    if (view === "detail" && detailTorrent) {
      return Model.formatPercent(detailTorrent.progress) + " · " + Model.formatRate(detailTorrent.dlSpeed) + " · " + Model.formatEta(detailTorrent.eta)
    }
    if (!qbt.installed) return "qBittorrent-nox is not installed"
    if (qbt.lockHolder === "gui") return "Close qBittorrent first"
    if (!qbt.daemon) return "Daemon is not running"
    if (!qbt.api) return "Web API is not reachable"
    return Model.formatRate(qbt.dlSpeed) + " · " + Model.formatRate(qbt.upSpeed) + " · " + activeCount + " active"
  }
  readonly property string emptyListText: {
    if (filterMode === "paused") return "No paused torrents."
    if (filterMode === "completed") return "No completed torrents."
    if (filterMode === "all") return "No torrents."
    return "Nothing downloading or seeding."
  }
  readonly property string toggleHint: qbt.transferring ? "Stop all torrents" : "Start all torrents"
  readonly property bool showClipboard: qbt.ready && view === "list" && Model.isAddableUrl(qbt.clipboardText)

  function selectedFile() {
    if (!qbt.files || qbt.files.length === 0) return null
    return qbt.files[Math.max(0, Math.min(fileIndex, qbt.files.length - 1))]
  }

  function ensureCursor() {
    if (!qbt.installed) { focusSection = "install"; return }
    if (qbt.lockHolder === "gui") { focusSection = "lock"; return }
    if (!qbt.daemon) { focusSection = "daemon"; return }
    if (view === "detail") {
      focusSection = "files"
      if (fileIndex >= qbt.files.length) fileIndex = Math.max(0, qbt.files.length - 1)
      return
    }
    if (focusSection === "install" || focusSection === "daemon" || focusSection === "lock") focusSection = "header"
    if (rowIndex >= visibleTorrents.length) rowIndex = Math.max(0, visibleTorrents.length - 1)
    if (rowIndex < 0) rowIndex = 0
  }

  function syncFocus() {
    if (root.fieldFocused) return
    keyCatcher.forceActiveFocus()
  }

  function openDetail(row) {
    if (!row) return
    view = "detail"
    detailHash = row.hash
    fileIndex = 0
    focusSection = "files"
    qbt.loadFiles(row.hash)
  }

  function closeDetail() {
    view = "list"
    detailHash = ""
    fileIndex = 0
    focusSection = visibleTorrents.length ? "rows" : "header"
  }

  function askDeleteFiles(hash) {
    pendingDeleteHash = hash
    confirmOpen = true
  }

  function setFilter(mode) {
    filterMode = mode
    rowIndex = 0
    if (view === "list") focusSection = visibleTorrents.length ? "rows" : "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (view === "detail") {
      if (qbt.files.length === 0) return
      fileIndex = Math.max(0, Math.min(qbt.files.length - 1, fileIndex + dy))
      return
    }
    if (focusSection === "header") {
      if (dy > 0 && showClipboard) { focusSection = "clipboard"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "clipboard") {
      if (dy < 0) { focusSection = "header"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "rows") {
      if (dy < 0 && rowIndex === 0) {
        focusSection = showClipboard ? "clipboard" : "header"
        return
      }
      rowIndex = Math.max(0, Math.min(visibleTorrents.length - 1, rowIndex + dy))
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "install") qbt.installDaemon()
    else if (focusSection === "daemon") qbt.startDaemon()
    else if (focusSection === "header") qbt.toggleAll()
    else if (focusSection === "clipboard") qbt.addUrl(qbt.clipboardText)
    else if (focusSection === "rows") openDetail(selectedTorrent)
    else if (focusSection === "files") cycleSelectedFile()
  }

  function cycleSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    var next = Model.cyclePriority(file.priority)
    qbt.setPrio(detailHash, file.index, next)
    var copy = []
    for (var i = 0; i < qbt.files.length; i++) {
      var row = qbt.files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: next })
      } else {
        copy.push(row)
      }
    }
    qbt.files = copy
  }

  function skipSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    qbt.setPrio(detailHash, file.index, 0)
    var copy = []
    for (var i = 0; i < qbt.files.length; i++) {
      var row = qbt.files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: 0 })
      } else {
        copy.push(row)
      }
    }
    qbt.files = copy
  }

  function handleTextKey(t) {
    if (confirmOpen) return
    if (t === "t" || t === "T") {
      if (qbt.ready) qbt.toggleAll()
    } else if (t === "/") {
      if (qbt.ready && view === "list" && magnetInput) magnetInput.forceActiveFocus()
    } else if (t === "y" || t === "Y") {
      if (showClipboard) qbt.addUrl(qbt.clipboardText)
    } else if (t === "r" || t === "R") {
      qbt.refresh()
      if (view === "detail" && detailHash) qbt.loadFiles(detailHash)
    } else if (t === "a" || t === "A") {
      if (view === "list") setFilter("active")
    } else if (t === "p" || t === "P") {
      if (view === "list") setFilter("paused")
    } else if (t === "c" || t === "C") {
      if (view === "list") setFilter("completed")
    } else if (t === "*") {
      if (view === "list") setFilter("all")
    } else if (t === "x") {
      if (view === "detail") skipSelectedFile()
      else if (selectedTorrent) qbt.deleteHash(selectedTorrent.hash, false)
    } else if (t === "X") {
      var hash = view === "detail" ? detailHash : (selectedTorrent ? selectedTorrent.hash : "")
      if (hash) askDeleteFiles(hash)
    } else if (t === "h" || t === "H") {
      if (view === "detail") closeDetail()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    view = "list"
    filterMode = "active"
    magnetField = ""
    confirmOpen = false
    if (panelFlick) panelFlick.contentY = 0
    qbt.refresh()
    qbt.readClipboard()
    ensureCursor()
    Qt.callLater(syncFocus)
  }

  Service {
    id: qbt
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { qbt.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        QbittorrentIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          warning: qbt.warning
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (qbt.ready) qbt.toggleAll()
        else root.toggle()
      } else if (buttonCode === Qt.MiddleButton) {
        qbt.refresh()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.fieldFocused || root.confirmOpen
      Keys.onPressed: function(event) {
        if (!root.confirmOpen) return
        if (deleteConfirm.handleKey(event)) event.accepted = true
      }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            visible: root.view === "detail"
            width: parent.width
            implicitHeight: backLabel.implicitHeight
            Text {
              id: backLabel
              text: "← Torrents"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeDetail()
            }
          }

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "header"
            }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: qbt.transferring ? 1.0 : 0.5
              iconComponent: Component {
                QbittorrentIcon {
                  iconSize: Style.font.display
                  color: qbt.transferring ? root.foreground : root.dim
                  badgeColor: root.urgent
                  warning: qbt.warning
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: qbt.ready && root.view === "list"
                  checked: qbt.transferring
                  busy: qbt.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: qbt.toggleAll()
                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            visible: qbt.actionStatus !== "" || qbt.lastError !== ""
            width: parent.width
            text: qbt.actionStatus !== "" ? qbt.actionStatus : qbt.lastError
            color: qbt.lastError !== "" && qbt.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: !qbt.installed
            width: parent.width
            implicitHeight: installCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "install"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "install" }
              onClicked: qbt.installDaemon()
            }
            Column {
              id: installCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - installCol.leftPadding - installCol.rightPadding
                text: "qBittorrent-nox is not installed. Installs qbittorrent-nox from Arch extra. Leaves the desktop qBittorrent app alone."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: qbt.busy ? "Installing…" : "Install qBittorrent-nox"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: qbt.installed && qbt.lockHolder === "gui"
            width: parent.width
            implicitHeight: lockCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "lock"
            foreground: root.foreground
            fill: root.hoverFill
            onEntered: { root.cursorActive = true; root.focusSection = "lock" }
            Column {
              id: lockCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - lockCol.leftPadding - lockCol.rightPadding
                text: "Close qBittorrent before starting the daemon."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: qbt.installed && !qbt.daemon && qbt.lockHolder !== "gui"
            width: parent.width
            implicitHeight: daemonCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "daemon"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "daemon" }
              onClicked: qbt.startDaemon()
            }
            Column {
              id: daemonCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - daemonCol.leftPadding - daemonCol.rightPadding
                text: "qBittorrent daemon is not running"
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: qbt.busy ? "Starting…" : "Start daemon"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            visible: qbt.ready && root.view === "list"
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: magnetInput
              width: parent.width
              foreground: root.foreground
              placeholderText: "Paste a magnet or .torrent URL"
              text: root.magnetField
              onTextChanged: root.magnetField = text
              onAccepted: {
                qbt.addUrl(text)
                root.magnetField = ""
                text = ""
              }
              Keys.onEscapePressed: root.close()
            }

            CursorSurface {
              visible: root.showClipboard
              width: parent.width
              implicitHeight: Style.space(36)
              hasCursor: root.cursorActive && root.focusSection === "clipboard"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.focusSection = "clipboard" }
                onClicked: qbt.addUrl(qbt.clipboardText)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Add magnet from clipboard"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Text {
              visible: root.visibleTorrents.length === 0
              width: parent.width
              text: root.emptyListText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleTorrents
              delegate: CursorSurface {
                required property var modelData
                required property int index
                width: column.width
                implicitHeight: rowCol.implicitHeight + Style.spacing.rowPaddingX
                hasCursor: root.cursorActive && root.focusSection === "rows" && root.rowIndex === index
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "rows"
                    root.rowIndex = index
                  }
                  onClicked: root.openDetail(modelData)
                }
                Column {
                  id: rowCol
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(10)
                  rightPadding: Style.space(10)
                  spacing: Style.space(4)
                  Text {
                    width: parent.width - rowCol.leftPadding - rowCol.rightPadding
                    text: modelData.name
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: Model.formatPercent(modelData.progress) + "  ↓ " + Model.formatRate(modelData.dlSpeed) + "  ↑ " + Model.formatRate(modelData.upSpeed) + "  " + Model.formatEta(modelData.eta)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Rectangle {
                    width: parent.width - rowCol.leftPadding - rowCol.rightPadding
                    height: 2
                    color: Qt.darker(root.foreground, 2.2)
                    Rectangle {
                      height: parent.height
                      width: parent.width * Math.max(0, Math.min(1, Number(modelData.progress) || 0))
                      color: root.foreground
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: qbt.ready && root.view === "detail"
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: !qbt.files || qbt.files.length === 0
              width: parent.width
              text: "No files yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: qbt.files
              delegate: CursorSurface {
                required property var modelData
                required property int index
                width: column.width
                implicitHeight: Style.space(32)
                hasCursor: root.cursorActive && root.focusSection === "files" && root.fileIndex === index
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "files"
                    root.fileIndex = index
                  }
                  onClicked: {
                    root.fileIndex = index
                    root.cycleSelectedFile()
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: prioLabel.left
                  anchors.rightMargin: Style.space(8)
                  text: modelData.name
                  elide: Text.ElideMiddle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: prioLabel
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  text: Model.priorityLabel(modelData.priority)
                  color: Number(modelData.priority) === 0 ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Delete this torrent and its files?"
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: {
          root.confirmOpen = false
          root.pendingDeleteHash = ""
        }
        onConfirmed: {
          root.confirmOpen = false
          if (root.pendingDeleteHash !== "") qbt.deleteHash(root.pendingDeleteHash, true)
          root.pendingDeleteHash = ""
          root.closeDetail()
        }
      }
    }
  }

  Shortcut {
    sequences: ["Space"]
    enabled: root.opened && qbt.ready && !root.fieldFocused && !root.confirmOpen
    onActivated: {
      if (root.view === "detail" && root.detailHash) qbt.toggleHash(root.detailHash)
      else if (root.selectedTorrent) qbt.toggleHash(root.selectedTorrent.hash)
    }
  }

  Shortcut {
    sequences: ["Backspace"]
    enabled: root.opened && root.view === "detail" && !root.confirmOpen
    onActivated: root.closeDetail()
  }
}
```

Esc always closes the panel (spec). Backspace / `h` return from detail to the list. Delete-files uses `ConfirmDialog`. Space is a `Shortcut` so it is not swallowed as a text key.

- [ ] **Step 2: Commit**

```bash
git add Panel.qml
git commit -m "feat: add bar panel for transfers, magnets, files, and delete"
```

---

### Task 10: README and plugin validate

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# qBittorrent for Omarchy

A status-bar plugin for [Omarchy](https://omarchy.org) Quattro that puts qBittorrent on the desktop instead of in the Qt window.

Left-click the themed mark to see what is downloading or seeding, paste a magnet, start or stop transfers, remove a torrent, and set file priorities. Right-click starts or stops everything. It talks to `qbittorrent-nox` on your existing library, so the daemon you already trust is still what is running.

## Install

    omarchy plugin add https://github.com/Aweiward/omaqbt.git --enable

If `qbittorrent-nox` is missing, open the widget and click **Install qBittorrent-nox**. That runs `omarchy pkg add qbittorrent-nox` and starts `omaqbt-nox.service`. It will not remove the desktop qBittorrent app if you already have it.

Close the Qt qBittorrent window before starting the daemon. Stop the daemon (`systemctl --user stop omaqbt-nox.service`) before opening the Qt app. They share `~/.config/qBittorrent` and must not run at the same time.

## Remove

    omarchy plugin remove aweiward.omaqbt

That disables the widget and deletes the plugin checkout. It does **not** uninstall `qbittorrent-nox`, stop the user service, delete torrents, or change other Omarchy config.

## Use

- Left click: panel
- Right click: start / stop all torrents
- Middle click: refresh

Keys in the list: `j`/`k` move, Enter opens files, Space start/stop, `x` remove (keep files), `X` delete files, `t` start/stop all, `a`/`p`/`c`/`*` filter, `/` magnet field, `y` add clipboard magnet, `r` refresh, Esc close.

Keys in the file view: `j`/`k` move, Enter cycle priority, `x` skip, Space start/stop, `X` delete files, Backspace or `h` back, Esc close.

## Requirements

- Omarchy 4 (Quattro) / `omarchy-shell`
- qBittorrent 5.2+ Web API (`start`/`stop`, not `pause`/`resume`)

## Dev

    node --test tests/*.test.js
    tests/api-contract.sh

`tests/api-contract.sh` talks to a fixture HTTP server. It does not start `qbittorrent-nox`, add a real torrent, or delete files on disk.
```

- [ ] **Step 2: Validate the plugin folder**

Run: `omarchy plugin validate /home/ethos/Projects/omaqbt`

Expected: exit 0.

If it fails (missing entry point, bad id), fix and re-run.

- [ ] **Step 3: Run the full test suite**

```bash
node --test tests/*.test.js
tests/api-contract.sh
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add install, clicks, keys, and what remove does not touch"
```

---

## Self-review (plan vs spec)

| Spec requirement | Task |
|------------------|------|
| Plugin id, bar widget, refreshIntervalSec 5 | 1 |
| Classify / exclusive filters / torrentId | 2 |
| Format, magnet URL, priority 0/1/6/7, parse, sanitize | 3 |
| `qbt status` + `/sync/maindata` rid merge | 4 |
| add/start/stop/delete/files/prio, no pause/resume, no SID leak | 5 |
| User unit, localhost Web UI keys, GUI lock refuse | 6 |
| Service is the only process runner | 7 |
| Themed QML mark, dim/bright/warning | 8 |
| Left/right/middle clicks, list, clipboard, magnet field, filters | 9 |
| Drill-in files, cycle/skip, confirm only on delete-files | 9 |
| README + `omarchy plugin validate` | 10 |
| Non-goals (limits, RSS, .torrent files, remote hosts) | not implemented — correct |
| Tests never touch the real library | 4–6 fixtures only |

Type names used everywhere: `classifyState`, `filterTorrents`, `torrentId`, `anyActive`, `parseStatusJson`, `sanitizeError`, `lockHolder`, `toggleAll`, `deleteHash(hash, withFiles)`.
