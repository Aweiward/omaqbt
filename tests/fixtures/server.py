#!/usr/bin/env python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote_plus, urlparse

ROOT = Path(__file__).resolve().parent
LOG = Path(os.environ["QBT_FIXTURE_LOG"])
COOKIE = "SID=leaked-secret-value"
FULL = json.loads((ROOT / "maindata-full.json").read_text())
DELTA = json.loads((ROOT / "maindata-delta.json").read_text())
FILES = json.loads((ROOT / "files.json").read_text())
ADDED = []


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
        if parsed.path == "/api/v2/transfer/speedLimitsMode":
            self._send(200, b"1")
            return
        if parsed.path == "/api/v2/torrents/info":
            rows = []
            for h, t in FULL["torrents"].items():
                row = dict(t)
                hid = h or t.get("infohash_v1") or ""
                row["hash"] = hid
                rows.append(row)
            rows.extend(ADDED)
            self._send(200, json.dumps(rows).encode())
            return
        if parsed.path == "/api/v2/app/preferences":
            bind = ""
            bind_file = os.environ.get("QBT_FIXTURE_BIND_FILE")
            if bind_file and Path(bind_file).exists():
                bind = Path(bind_file).read_text().strip()
            self._send(200, json.dumps({"current_network_interface": bind}).encode())
            return
        self._send(404, b"{}")

    def do_POST(self):
        parsed = urlparse(self.path)
        body = self._read()
        record("POST", parsed.path, body, parse_qs(parsed.query))
        if parsed.path == "/api/v2/torrents/add":
            import re
            qs = parse_qs(body)
            urls = qs.get("urls") or []
            for raw in urls:
                url = unquote_plus(raw)
                m = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", url, re.I)
                if m and len(m.group(1)) == 40:
                    h = m.group(1).lower()
                    ADDED.append({"hash": h, "infohash_v1": h, "name": h, "size": 0})
            self._send(200, b"Ok.")
            return
        if parsed.path in (
            "/api/v2/torrents/start",
            "/api/v2/torrents/stop",
            "/api/v2/torrents/delete",
            "/api/v2/torrents/filePrio",
            "/api/v2/torrents/setDownloadLimit",
            "/api/v2/torrents/setUploadLimit",
            "/api/v2/torrents/toggleSequentialDownload",
            "/api/v2/torrents/setShareLimits",
            "/api/v2/transfer/toggleSpeedLimitsMode",
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
