#!/usr/bin/env python3
import copy
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote_plus, urlparse

ROOT = Path(__file__).resolve().parent
LOG = Path(os.environ["QBT_FIXTURE_LOG"])
COOKIE = "SID=leaked-secret-value"
# /app/preferences' fixed save_path/relocation defaults, matching the shape
# (not the values) live-probed against qBittorrent 5.2.3 on 2026-09-27.
DEFAULT_SAVE_PATH = "/home/user/Downloads"
FULL = json.loads((ROOT / "maindata-full.json").read_text())
DELTA = json.loads((ROOT / "maindata-delta.json").read_text())
FILES = json.loads((ROOT / "files.json").read_text())
PROPERTIES = json.loads((ROOT / "properties.json").read_text())
PIECESTATES = json.loads((ROOT / "piecestates.json").read_text())
TRACKERS = json.loads((ROOT / "trackers.json").read_text())
PEERS = json.loads((ROOT / "peers.json").read_text())
ADDED = []
# An error body carrying a tracker URL with a passkey, for the F12 tests:
# nothing in it may ever reach qbt's stderr.
SECRET_ERROR_BODY = b"Conflict: udp://tracker.example:1337/SECRETPASSKEY123/announce 203.0.113.9:6881"
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
HASH_BADSIZE_NONASCII = "7" * 40
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
    # Fix round 2, item 2: a total_size that is only a "digit" under a
    # UTF-8 locale's collation (a fullwidth "1"), not under [:digit:]. Must
    # refuse cleanly, never reach `((...))` with it.
    HASH_BADSIZE_NONASCII: {
        "state": "stoppedDL",
        "total_size": "１",  # fullwidth "1"
        "magnet_uri": f"magnet:?xt=urn:btih:{HASH_BADSIZE_NONASCII}",
        "save_path": "/home/user/Downloads/badsize-nonascii",
        "category": "",
        "tags": "",
    },
}

# Slice 3a: category and tag state that the write routes really change.
# Categories/tags start as maindata-full.json's, in the torrents/categories
# shape qBittorrent 5.2.3 serves (savePath, snake_case download_path that is
# a path, false or null, and name). QBT_FIXTURE_LIBRARY may name a JSON file
# {"categories": {...}, "tags": [...], "torrents": {hash: {"category": "",
# "tags": "a, b"}}, "preferences": {...}} that replaces the starting
# categories/tags, adds torrents (listed by torrents/info), so a test can
# seed thousands of rows, and overrides /app/preferences keys.
def _category_defaults():
    """A fresh CategoryOptions as 5.2.3's toJSON shows it: no save path, the
    global download path, and every share limit on "use global"."""
    return {
        "savePath": "",
        "download_path": None,
        "ratio_limit": -2,
        "seeding_time_limit": -2,
        "inactive_seeding_time_limit": -2,
        "share_limit_action": "Default",
    }


def _load_library():
    categories = copy.deepcopy(FULL.get("categories") or {})
    tags = list(FULL.get("tags") or [])
    torrents = {}
    preferences = {}
    path = os.environ.get("QBT_FIXTURE_LIBRARY")
    if path:
        data = json.loads(Path(path).read_text())
        preferences = dict(data.get("preferences") or {})
        if "categories" in data:
            categories = data["categories"]
        if "tags" in data:
            tags = list(data["tags"])
        for h, t in (data.get("torrents") or {}).items():
            row = {"name": h[:8], "category": "", "tags": ""}
            row.update(t)
            torrents[h.lower()] = row
    for name, c in categories.items():
        c.setdefault("name", name)
        for key, value in _category_defaults().items():
            c.setdefault(key, value)
    return categories, tags, torrents, preferences


CATEGORIES, TAGS, LIBRARY, PREFERENCES = _load_library()
# qBittorrent's Session::isValidCategoryName.
_CATEGORY_RE = re.compile(r"^([^\\/]|[^\\/]([^\\/]|/(?=[^/]))*[^\\/])$")
# Per-route call counters for "<fault>@N" (fail only the Nth call).
_CALLS = {}


def _write_fault(key):
    """The slice-3a routes' fault for this call, per the control file:
    "404", "409", "500", "409secret" (an error body carrying a passkey),
    "noop" (answer 200 but change nothing), each optionally "@N" to hit
    only the route's Nth call (1-based, counted per fixture process)."""
    with _LOG_LOCK:
        _CALLS[key] = _CALLS.get(key, 0) + 1
        n = _CALLS[key]
    value = _control().get(key)
    if not isinstance(value, str):
        return None
    fault, _, nth = value.partition("@")
    if nth and (not nth.isdigit() or int(nth) != n):
        return None
    return fault if fault in ("404", "409", "500", "409secret", "noop", "unreadable") else None


def _torrent_rows():
    """Every torrent dict torrents/info lists, keyed by lowercase hash, so
    setCategory/addTags/removeTags change what the next info GET returns."""
    rows = {}
    for h, t in FULL["torrents"].items():
        rows[(h or t.get("infohash_v1") or "").lower()] = t
    for h, t in EXTRA_TORRENTS.items():
        rows[h] = t
    for t in ADDED:
        rows[(t.get("hash") or "").lower()] = t
    rows.update(LIBRARY)
    return rows


def _targets(hashes_param):
    rows = _torrent_rows()
    if hashes_param == "all":
        return list(rows.values())
    wanted = [h.lower() for h in hashes_param.split("|") if h]
    return [rows[h] for h in wanted if h in rows]


def _tag_list(value):
    return [t for t in (value or "").split(", ") if t]


def _set_tags(row, tags):
    row["tags"] = ", ".join(sorted(set(tags)))


def _split_tags(value):
    # qBittorrent splits on "," (skipping empty parts) and trims each tag.
    return [t.strip() for t in (value or "").split(",") if t.strip()]


def _parse_bool(value):
    if value is None:
        return None
    v = value.strip().lower()
    if v in ("true", "1", "yes", "on"):
        return True
    if v in ("false", "0", "no", "off"):
        return False
    return None


def _category_options(form):
    """createCategory/editCategory's options, the way 5.2.3 reads them: the
    download path is only set when downloadPathEnabled parses as a bool,
    and editCategory without it resets the download path to null."""
    enabled = _parse_bool((form.get("downloadPathEnabled") or [None])[0])
    if enabled is None:
        download = None
    elif enabled:
        download = (form.get("downloadPath") or [""])[0]
    else:
        download = False
    return (form.get("savePath") or [""])[0], download


# What torrents/info shows for a row that doesn't carry its own: 5.2.3's
# per-torrent share limits on "use default", no progress, toggles off.
_SHARE_DEFAULTS = {
    "ratio_limit": -2,
    "seeding_time_limit": -2,
    "inactive_seeding_time_limit": -2,
    "share_limit_action": "Default",
    "ratio": 0,
    "seeding_time": 0,
    "progress": 0,
    "seq_dl": False,
    "f_l_piece_prio": False,
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


def _create_category(form):
    name = (form.get("category") or [""])[0]
    if not name:
        return 400
    if not _CATEGORY_RE.fullmatch(name) or name in CATEGORIES:
        return 409
    # Like SessionImpl::addCategory: missing parents ("a" for "a/b") are
    # created too, with default options.
    parts = name.split("/")
    for i in range(1, len(parts)):
        parent = "/".join(parts[:i])
        if parent not in CATEGORIES:
            CATEGORIES[parent] = dict(_category_defaults(), name=parent)
    save, download = _category_options(form)
    CATEGORIES[name] = dict(_category_defaults(), name=name, savePath=save, download_path=download)
    return 200


def _edit_category(form):
    if "category" not in form or "savePath" not in form:
        return 400
    name = form["category"][0]
    if not name:
        return 400
    if name not in CATEGORIES:
        return 404
    # setCategoryOptions replaces the whole options: share limits too.
    save, download = _category_options(form)
    CATEGORIES[name] = dict(_category_defaults(), name=name, savePath=save, download_path=download)
    return 200


def _remove_categories(form):
    if "categories" not in form:
        return 400
    # Like SessionImpl::removeCategory: every torrent on the name or any
    # "name/..." subcategory moves to the parent category ("" at the top),
    # and the subcategories go too.
    for name in form["categories"][0].split("\n"):
        parent = name.rsplit("/", 1)[0] if "/" in name else ""
        sub = name + "/"
        for row in _torrent_rows().values():
            cat = row.get("category") or ""
            if cat == name or cat.startswith(sub):
                row["category"] = parent
        for key in [k for k in CATEGORIES if k == name or k.startswith(sub)]:
            del CATEGORIES[key]
    return 200


def _set_category(form):
    if "hashes" not in form or "category" not in form:
        return 400
    name = form["category"][0]
    if name and name not in CATEGORIES:
        return 409
    for row in _targets(form["hashes"][0]):
        row["category"] = name
    return 200


def _create_tags(form):
    if "tags" not in form:
        return 400
    for tag in _split_tags(form["tags"][0]):
        if tag not in TAGS:
            TAGS.append(tag)
    return 200


def _delete_tags(form):
    if "tags" not in form:
        return 400
    for tag in _split_tags(form["tags"][0]):
        if tag in TAGS:
            TAGS.remove(tag)
        for row in _torrent_rows().values():
            if tag in _tag_list(row.get("tags")):
                _set_tags(row, [t for t in _tag_list(row.get("tags")) if t != tag])
    return 200


def _add_tags(form):
    if "hashes" not in form or "tags" not in form:
        return 400
    tags = _split_tags(form["tags"][0])
    for tag in tags:
        if tag not in TAGS:
            TAGS.append(tag)
    for row in _targets(form["hashes"][0]):
        _set_tags(row, _tag_list(row.get("tags")) + tags)
    return 200


def _remove_tags(form):
    if "hashes" not in form:
        return 400
    tags = _split_tags((form.get("tags") or [""])[0])
    for row in _targets(form["hashes"][0]):
        # Like 5.2.3: no tags at all removes every tag from the torrents.
        _set_tags(row, [t for t in _tag_list(row.get("tags")) if tags and t not in tags])
    return 200


_SHARE_PARAMS = ("hashes", "ratioLimit", "seedingTimeLimit", "inactiveSeedingTimeLimit", "shareLimitAction")


_SHARE_ACTIONS = ("Default", "Stop", "Remove", "RemoveWithContent", "EnableSuperSeeding")


def _number(value):
    try:
        n = float(value)
    except ValueError:
        return 0
    return int(n) if n.is_integer() else n


def _set_share_limits(form):
    """5.2.3's setShareLimitsAction: all four limits plus the hashes are
    required (requireParams answers 400 otherwise). Each target keeps the
    four values; an unknown action string reads as Default (toEnum)."""
    if any(k not in form for k in _SHARE_PARAMS):
        return 400
    action = form["shareLimitAction"][0]
    for row in _targets(form["hashes"][0]):
        row["ratio_limit"] = _number(form["ratioLimit"][0])
        row["seeding_time_limit"] = int(_number(form["seedingTimeLimit"][0]))
        row["inactive_seeding_time_limit"] = int(_number(form["inactiveSeedingTimeLimit"][0]))
        row["share_limit_action"] = action if action in _SHARE_ACTIONS else "Default"
    return 200


def _toggle(field):
    """toggleSequentialDownload / toggleFirstLastPiecePrio: flip, per target."""
    def apply(form):
        if "hashes" not in form:
            return 400
        for row in _targets(form["hashes"][0]):
            row[field] = not bool(row.get(field, False))
        return 200
    return apply


_LIBRARY_WRITES = {
    "/api/v2/torrents/setShareLimits": _set_share_limits,
    "/api/v2/torrents/toggleSequentialDownload": _toggle("seq_dl"),
    "/api/v2/torrents/toggleFirstLastPiecePrio": _toggle("f_l_piece_prio"),
    "/api/v2/torrents/createCategory": _create_category,
    "/api/v2/torrents/editCategory": _edit_category,
    "/api/v2/torrents/removeCategories": _remove_categories,
    "/api/v2/torrents/setCategory": _set_category,
    "/api/v2/torrents/createTags": _create_tags,
    "/api/v2/torrents/deleteTags": _delete_tags,
    "/api/v2/torrents/addTags": _add_tags,
    "/api/v2/torrents/removeTags": _remove_tags,
}


# Slice 4a: /app/preferences backed by state. QBT_FIXTURE_PREFS names a
# preferences dump (tests/fixtures/preferences-5.2.3.json, or a test's copy
# with extra keys); QBT_FIXTURE_LIBRARY's "preferences" still override it.
# Without the env var the GET stays the old synthetic reply and
# setPreferences stays a 404, so no other suite sees a change.
_SCHEMA = json.loads((ROOT.parent.parent / "settings-schema.json").read_text())["keys"]
_PREFS_PATH = os.environ.get("QBT_FIXTURE_PREFS")
PREFS_STATE = None
if _PREFS_PATH:
    PREFS_STATE = json.loads(Path(_PREFS_PATH).read_text())
    PREFS_STATE.update(PREFERENCES)
_PREFS_LOCK = threading.Lock()
_SCHEDULE_PAIRS = (("schedule_from_hour", "schedule_from_min"), ("schedule_to_hour", "schedule_to_min"))
_INT_TYPES = ("int", "choice-int", "speed")


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _clean_path(p):
    """Path()'s normalisation, as far as the tests need: no trailing slash."""
    while len(p) > 1 and p.endswith("/"):
        p = p[:-1]
    return p


def _pref_value(key, value):
    """5.2.3's setter for one key: (True, stored) when it applies, (False,
    None) when qBittorrent would drop it. Strings are trimmed, global
    speeds are stored in whole KiB (sessionimpl.cpp:3480), announce_ip must
    be an IP address or becomes "" (appcontroller.cpp:1178)."""
    entry = _SCHEMA.get(key)
    if entry is None:
        current = PREFS_STATE[key]
        if isinstance(current, bool):
            return (True, value) if isinstance(value, bool) else (False, None)
        if _is_number(current):
            return (True, value) if _is_number(value) else (False, None)
        if isinstance(current, str):
            return (True, value.strip()) if isinstance(value, str) else (False, None)
        return False, None
    if entry.get("readOnly") or entry.get("composite"):
        return False, None
    kind = entry["type"]
    if kind == "bool":
        return (True, value) if isinstance(value, bool) else (False, None)
    if kind in _INT_TYPES:
        if not _is_int(value):
            return False, None
        if kind == "choice-int" and value not in [c["value"] for c in entry["choices"]]:
            return False, None
        if kind == "speed" and value > 0:
            value = max(1024, value // 1024 * 1024)
        return True, value
    if kind == "float":
        return (True, value) if _is_number(value) else (False, None)
    if not isinstance(value, str):
        return False, None
    if kind == "choice-string":
        return (True, value) if value in [c["value"] for c in entry["choices"]] else (False, None)
    value = value.strip()
    if kind == "path":
        return True, _clean_path(value)
    if key in ("announce_ip", "current_interface_address"):
        import ipaddress
        try:
            return True, str(ipaddress.ip_address(value))
        except ValueError:
            return True, ""
    return True, value


def _set_preferences(body):
    """setPreferencesAction (:513): always 200. Unknown keys, values of the
    wrong kind and malformed JSON are dropped without a word; a scheduler
    time applies only when its hour and minute arrive together (:807-812).
    The control file's "prefs_override" ({key: value}) is applied after the
    write, simulating qBittorrent changing a value on its own."""
    raw = (parse_qs(body, keep_blank_values=True).get("json") or [""])[0]
    try:
        m = json.loads(raw)
    except ValueError:
        m = None
    if not isinstance(m, dict):
        m = {}
    with _PREFS_LOCK:
        for key, value in m.items():
            if key not in PREFS_STATE or any(key in pair for pair in _SCHEDULE_PAIRS):
                continue
            ok, stored = _pref_value(key, value)
            if ok:
                PREFS_STATE[key] = stored
        for hour, minute in _SCHEDULE_PAIRS:
            if hour in m and minute in m and _is_int(m[hour]) and _is_int(m[minute]):
                PREFS_STATE[hour], PREFS_STATE[minute] = m[hour], m[minute]
        override = _control().get("prefs_override")
        if isinstance(override, dict):
            PREFS_STATE.update(override)


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

    def _fault_reply(self, fault):
        if fault == "409secret":
            self._send(409, SECRET_ERROR_BODY, content_type="text/plain")
        else:
            self._send(int(fault), b"boom")

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/fixture/state":
            # Test-only and unrecorded: the end state after a write.
            self._send(200, json.dumps({
                "categories": CATEGORIES,
                "tags": TAGS,
                "torrents": {h: {"category": t.get("category", ""), "tags": t.get("tags", "")} for h, t in LIBRARY.items()},
                # Every row's share limits and toggles (slice 3b).
                "limits": {h: {k: t.get(k, _SHARE_DEFAULTS[k]) for k in (
                    "ratio_limit", "seeding_time_limit", "inactive_seeding_time_limit",
                    "share_limit_action", "seq_dl", "f_l_piece_prio")} for h, t in _torrent_rows().items()},
            }).encode())
            return
        record("GET", parsed.path, "", parse_qs(parsed.query), self.headers.get("Cookie") or "")
        if parsed.path in ("/api/v2/torrents/categories", "/api/v2/torrents/tags"):
            key = parsed.path.rsplit("/", 1)[1]
            fault = _write_fault(key)
            if fault and fault != "noop":
                self._fault_reply(fault)
                return
            payload = CATEGORIES if key == "categories" else TAGS
            self._send(200, json.dumps(payload).encode())
            return
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
            if _control().get("info") == "409secret":
                self._send(409, SECRET_ERROR_BODY, content_type="text/plain")
                return
            if "@" in str(_control().get("info") or ""):
                fault = _write_fault("info")
                if fault and fault != "noop":
                    self._fault_reply(fault)
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
            for h, t in LIBRARY.items():
                row = dict(t)
                row["hash"] = h
                rows.append(row)
            for row in rows:
                for key, value in _SHARE_DEFAULTS.items():
                    row.setdefault(key, value)
            hashes_param = parse_qs(parsed.query).get("hashes")
            if hashes_param:
                wanted = set()
                for entry in hashes_param:
                    wanted.update(x.lower() for x in entry.split("|") if x)
                rows = [r for r in rows if (r.get("hash") or "").lower() in wanted]
            self._send(200, json.dumps(rows).encode())
            return
        if parsed.path == "/api/v2/app/preferences" and PREFS_STATE is not None:
            # "409state": an error body that carries every preference,
            # secrets included; qbt must report the code only.
            fault = _write_fault("preferences")
            if _control().get("preferences") == "409state":
                self._send(409, json.dumps(PREFS_STATE).encode(), content_type="text/plain")
                return
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>")
                return
            if fault and fault != "noop":
                self._fault_reply(fault)
                return
            with _PREFS_LOCK:
                payload = json.dumps(PREFS_STATE)
            self._send(200, payload.encode())
            return
        if parsed.path == "/api/v2/app/preferences":
            bind = ""
            bind_file = os.environ.get("QBT_FIXTURE_BIND_FILE")
            if bind_file and Path(bind_file).exists():
                bind = Path(bind_file).read_text().strip()
            self._send(200, json.dumps({
                "current_network_interface": bind,
                "save_path": DEFAULT_SAVE_PATH,
                "torrent_changed_tmm_enabled": True,
                "category_changed_tmm_enabled": False,
                # The global share limits, as 5.2.3 serves them: max_ratio_act
                # 0 Stop, 1 Remove, 2 EnableSuperSeeding, 3 RemoveWithContent.
                "max_ratio_enabled": False,
                "max_ratio": -1,
                "max_seeding_time_enabled": False,
                "max_seeding_time": -1,
                "max_inactive_seeding_time_enabled": False,
                "max_inactive_seeding_time": -1,
                "max_ratio_act": 0,
                **PREFERENCES,
            }).encode())
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
            # "silent": answers "Ok." but never adds. "fails": answers
            # "Fails." and never adds. "oddbody": adds, but answers 200 with
            # a body that isn't "Ok." (qBittorrent's success body for an
            # add isn't a confirmed contract, so qbt must not read it).
            if fault not in ("silent", "fails"):
                for raw in urls:
                    url = unquote_plus(raw)
                    m = re.search(r"xt=urn:btih:([A-Za-z0-9]+)", url, re.I)
                    if m and len(m.group(1)) == 40:
                        h = m.group(1).lower()
                        ADDED.append({"hash": h, "infohash_v1": h, "name": h, "size": 0, "total_size": 0})
            if fault == "fails":
                self._send(200, b"Fails.")
            elif fault == "oddbody":
                self._send(200, b'{"added":1}', content_type="application/json")
            else:
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
            "/api/v2/transfer/toggleSpeedLimitsMode",
        ):
            self._send(200, b"Ok.")
            return
        if parsed.path in (
            "/api/v2/torrents/reannounce",
            "/api/v2/torrents/addTrackers",
            "/api/v2/torrents/editTracker",
            "/api/v2/torrents/removeTrackers",
            "/api/v2/transfer/banPeers",
        ):
            # {"writes": "409secret"}: the slice-2b write routes refuse with
            # an error body that carries a tracker URL and passkey, which qbt
            # must never pass on (F12).
            if _control().get("writes") == "409secret":
                self._send(409, SECRET_ERROR_BODY, content_type="text/plain")
                return
            self._send(200, b"Ok.")
            return
        if parsed.path in _LIBRARY_WRITES:
            key = parsed.path.rsplit("/", 1)[1]
            fault = _write_fault(key)
            if fault == "noop":
                self._send(200, b"")
                return
            if fault:
                self._fault_reply(fault)
                return
            form = parse_qs(body, keep_blank_values=True)
            code = _LIBRARY_WRITES[parsed.path](form)
            if code == 400 and parsed.path == "/api/v2/torrents/setShareLimits":
                # 5.2.3's requireParams names what's missing.
                missing = ", ".join(k for k in _SHARE_PARAMS if k not in form)
                self._send(400, f"Missing required parameters: {missing}".encode(), content_type="text/plain")
                return
            self._send(code, b"" if code == 200 else b"refused")
            return
        if parsed.path == "/api/v2/app/setPreferences" and PREFS_STATE is not None:
            fault = _write_fault("setPreferences")
            if fault == "noop":
                self._send(200, b"")
                return
            if fault and fault != "unreadable":
                self._fault_reply(fault)
                return
            _set_preferences(body)
            self._send(200, b"")
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
