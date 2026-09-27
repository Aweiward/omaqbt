#!/usr/bin/env python3
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote_plus, urlparse

ROOT = Path(__file__).resolve().parent
LOG = Path(os.environ["QBT_FIXTURE_LOG"])
COOKIE = "SID=leaked-secret-value"
FULL = json.loads((ROOT / "maindata-full.json").read_text())
DELTA = json.loads((ROOT / "maindata-delta.json").read_text())
FILES = json.loads((ROOT / "files.json").read_text())
PROPERTIES = json.loads((ROOT / "properties.json").read_text())
PIECESTATES = json.loads((ROOT / "piecestates.json").read_text())
TRACKERS = json.loads((ROOT / "trackers.json").read_text())
PEERS = json.loads((ROOT / "peers.json").read_text())
ADDED = []
# Real qBittorrent keeps sync rid state per WebUI session: a request without a
# known SID cookie opens a new session and always gets a full update.
SESSIONS = set()

# Extra torrents/info rows for the fetch-metadata (Task 2, slice 2b) tests,
# independent of the maindata-shaped FULL/DELTA fixtures above (torrents/info
# uses different field names, e.g. total_size not size). Keyed by lowercase
# hash; POST torrents/delete removes the matching entry (unless the control
# file says the delete "noop"s, simulating qBittorrent not having applied it
# yet) and POST torrents/add can put a hash back via the regex match below.
HASH_NOMETA = "d" * 40
HASH_META = "e" * 40
HASH_RUNNING = "f" * 40
HASH_NOMAGNET = "9" * 40
HASH_BADSIZE = "8" * 40
EXTRA_TORRENTS = {
    HASH_NOMETA: {
        "state": "stoppedDL",
        "total_size": 0,
        "magnet_uri": f"magnet:?xt=urn:btih:{HASH_NOMETA}&dn=nometa",
        "save_path": "/home/user/Downloads/nometa",
        "category": "linux",
        # qBittorrent joins tags with ", "; qbt must normalise this to a bare
        # comma list before re-adding.
        "tags": "iso, nometa",
    },
    HASH_META: {
        "state": "pausedDL",
        "total_size": 123456,
        "magnet_uri": f"magnet:?xt=urn:btih:{HASH_META}",
        "save_path": "/home/user/Downloads/meta",
        "category": "",
        "tags": "",
    },
    HASH_RUNNING: {
        "state": "downloading",
        "total_size": 0,
        "magnet_uri": f"magnet:?xt=urn:btih:{HASH_RUNNING}",
        "save_path": "/home/user/Downloads/running",
        "category": "",
        "tags": "",
    },
    HASH_NOMAGNET: {
        "state": "stoppedDL",
        "total_size": 0,
        "magnet_uri": "",
        "save_path": "/home/user/Downloads/nomagnet",
        "category": "",
        "tags": "",
    },
    # total_size must fail closed: anything qbt can't read as a clean
    # integer <= 0 has to refuse, not assume "no metadata".
    HASH_BADSIZE: {
        "state": "stoppedDL",
        "total_size": "unknown",
        "magnet_uri": f"magnet:?xt=urn:btih:{HASH_BADSIZE}",
        "save_path": "/home/user/Downloads/badsize",
        "category": "",
        "tags": "",
    },
}

# Serving each request on its own thread (ThreadingHTTPServer, below) means
# more than one handler can be inside record() at once, and a naive
# read-modify-write of LOG would drop entries under that race. This lock
# makes the whole read-modify-write atomic.
_LOG_LOCK = threading.Lock()


def record(method, path, body, query, cookie=""):
    entry = {"method": method, "path": path, "body": body, "query": query, "cookie": cookie}
    with _LOG_LOCK:
        entries = []
        if LOG.exists():
            entries = json.loads(LOG.read_text() or "[]")
        entries.append(entry)
        LOG.write_text(json.dumps(entries))


def _control():
    """The per-route fault map from QBT_FIXTURE_CONTROL, re-read on every
    call so a test can flip it mid-run. Absent env, missing file, or
    unparsable/non-object JSON all mean "no faults"."""
    path = os.environ.get("QBT_FIXTURE_CONTROL")
    if not path:
        return {}
    try:
        data = json.loads(Path(path).read_text())
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def _fault(route_key):
    """"sleep3", "404", or None for `route_key` per the control file."""
    value = _control().get(route_key)
    return value if value in ("sleep3", "404") else None


# path -> (control-file key, canned payload). One shared handler below
# applies whatever fault the control file names, and otherwise serves the
# payload -- rather than four near-identical if-blocks.
_INSPECT_ROUTES = {
    "/api/v2/torrents/properties": ("properties", PROPERTIES),
    "/api/v2/torrents/pieceStates": ("pieceStates", PIECESTATES),
    "/api/v2/torrents/trackers": ("trackers", TRACKERS),
    "/api/v2/sync/torrentPeers": ("peers", PEERS),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode("utf-8") if n else ""

    def _session(self):
        """Return (sid, is_new) for this request, minting a SID when unknown."""
        for part in (self.headers.get("Cookie") or "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == "SID" and value in SESSIONS:
                return value, False
        sid = f"fixture-{len(SESSIONS) + 1}"
        SESSIONS.add(sid)
        return sid, True

    def _send(self, code, body=b"", content_type="application/json", sid=None):
        if os.environ.get("QBT_FIXTURE_FORBIDDEN") == "1":
            self.send_response(403)
            self.send_header("Set-Cookie", COOKIE)
            self.end_headers()
            self.wfile.write(b"SID=leaked-secret-value forbidden")
            return
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        if sid:
            self.send_header("Set-Cookie", f"SID={sid}; HttpOnly; path=/")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        record("GET", parsed.path, "", parse_qs(parsed.query), self.headers.get("Cookie") or "")
        if parsed.path == "/api/v2/sync/maindata":
            fault = _fault("maindata")
            if fault == "sleep3":
                time.sleep(3)
            elif fault == "404":
                self._send(404, b"{}")
                return
            rid = (parse_qs(parsed.query).get("rid") or ["0"])[0]
            sid, is_new = self._session()
            payload = DELTA if rid not in ("", "0") and not is_new else FULL
            self._send(200, json.dumps(payload).encode(), sid=sid if is_new else None)
            return
        if parsed.path == "/api/v2/torrents/files":
            self._send(200, json.dumps(FILES).encode())
            return
        if parsed.path == "/api/v2/transfer/speedLimitsMode":
            self._send(200, b"1")
            return
        if parsed.path == "/api/v2/torrents/info":
            # {"info": "500"} simulates torrents/info failing outright, for
            # any hashes= lookup. A test that wants the *initial* (pre-delete)
            # info check to still succeed should set {"info_after_delete":
            # "500"} instead (see the delete handler below), which only
            # flips this on once a delete has actually gone through.
            if _control().get("info") == "500" and "hashes=" in parsed.query:
                self._send(500, b"boom")
                return
            rows = []
            for h, t in FULL["torrents"].items():
                row = dict(t)
                hid = h or t.get("infohash_v1") or ""
                row["hash"] = hid
                rows.append(row)
            for h, t in EXTRA_TORRENTS.items():
                row = dict(t)
                row["hash"] = h
                rows.append(row)
            rows.extend(ADDED)
            hashes_param = parse_qs(parsed.query).get("hashes")
            if hashes_param:
                wanted = set()
                for entry in hashes_param:
                    wanted.update(x.lower() for x in entry.split("|") if x)
                rows = [r for r in rows if (r.get("hash") or "").lower() in wanted]
            self._send(200, json.dumps(rows).encode())
            return
        if parsed.path == "/api/v2/app/preferences":
            bind = ""
            bind_file = os.environ.get("QBT_FIXTURE_BIND_FILE")
            if bind_file and Path(bind_file).exists():
                bind = Path(bind_file).read_text().strip()
            self._send(200, json.dumps({"current_network_interface": bind}).encode())
            return
        if parsed.path in _INSPECT_ROUTES:
            control_key, payload = _INSPECT_ROUTES[parsed.path]
            fault = _fault(control_key)
            if fault == "sleep3":
                time.sleep(3)
            elif fault == "404":
                self._send(404, b"{}")
                return
            self._send(200, json.dumps(payload).encode())
            return
        self._send(404, b"{}")

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read()
        record("POST", parsed.path, body, parse_qs(parsed.query))
        if parsed.path == "/api/v2/torrents/add":
            import re
            fault = _control().get("add")
            if fault == "404":
                self._send(404, b"{}")
                return
            qs = parse_qs(body)
            urls = qs.get("urls") or []
            if fault != "silent":
                for raw in urls:
                    url = unquote_plus(raw)
                    m = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", url, re.I)
                    if m and len(m.group(1)) == 40:
                        h = m.group(1).lower()
                        ADDED.append({"hash": h, "infohash_v1": h, "name": h, "size": 0, "total_size": 0})
            self._send(200, b"Ok.")
            return
        if parsed.path == "/api/v2/torrents/delete":
            fault = _control().get("delete")
            qs = parse_qs(body)
            hashes = [h.lower() for h in (qs.get("hashes") or [""])[0].split("|") if h]

            def _apply_delete():
                for h in hashes:
                    EXTRA_TORRENTS.pop(h, None)
                    ADDED[:] = [r for r in ADDED if (r.get("hash") or "").lower() != h]
                if _control().get("info_after_delete") == "500":
                    # Simulates torrents/info starting to 500 only once a
                    # delete has actually gone through, so the poll that
                    # follows a real delete gets nothing but failures.
                    Path(os.environ["QBT_FIXTURE_CONTROL"]).write_text(json.dumps({"info": "500"}))

            if fault == "noop":
                pass  # Simulates a delete that never took effect.
            elif fault == "late":
                # Simulates a delete qBittorrent applies after the caller's
                # poll window has already given up on it.
                threading.Timer(1.5, _apply_delete).start()
            else:
                _apply_delete()

            if fault == "500":
                # Simulates a delete that DID apply (see _apply_delete above)
                # but whose HTTP response comes back as an error -- curl
                # dies, even though qBittorrent already did the work.
                self._send(500, b"boom")
                return
            self._send(200, b"Ok.")
            return
        if parsed.path in (
            "/api/v2/torrents/start",
            "/api/v2/torrents/stop",
            "/api/v2/torrents/recheck",
            "/api/v2/torrents/setLocation",
            "/api/v2/torrents/filePrio",
            "/api/v2/torrents/setDownloadLimit",
            "/api/v2/torrents/setUploadLimit",
            "/api/v2/torrents/toggleSequentialDownload",
            "/api/v2/torrents/setShareLimits",
            "/api/v2/transfer/toggleSpeedLimitsMode",
            "/api/v2/torrents/reannounce",
            "/api/v2/torrents/addTrackers",
            "/api/v2/torrents/editTracker",
            "/api/v2/torrents/removeTrackers",
            "/api/v2/transfer/banPeers",
        ):
            self._send(200, b"Ok.")
            return
        if parsed.path in ("/api/v2/torrents/pause", "/api/v2/torrents/resume"):
            self._send(404, b"gone")
            return
        self._send(404, b"{}")


class _Server(ThreadingHTTPServer):
    """A "sleep3"-faulted route's handler thread can find its client gone
    (timed out and moved on) by the time it wakes up and tries to write --
    a plain BrokenPipeError or ConnectionResetError, not a real fixture
    bug. Swallow just those two so test runs (which don't inspect this
    process's stderr) stay quiet; anything else still gets the default
    traceback."""

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


if __name__ == "__main__":
    port = int(os.environ["QBT_FIXTURE_PORT"])
    # ThreadingHTTPServer (not HTTPServer): a route stalled with "sleep3"
    # must not block every other route (in particular sync/maindata) on
    # the same fixture process -- see Ruling E.
    _Server(("127.0.0.1", port), Handler).serve_forever()
