#!/usr/bin/env python3
import copy
import email.utils
import json
import os
import posixpath
import re
import sys
import threading
import time
from datetime import timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, unquote_plus, urlparse

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
# qBittorrent 5.2.3's API key (webapplication.cpp apiKeySessionInitialize):
# "Authorization: Bearer <key>" opens or reuses the session whose id is the
# key itself, and never sets a cookie. Every /api/v2/ route answers 403
# without it, as real qBittorrent does once the localhost bypass is off.
# QBT_FIXTURE_NO_AUTH=1 turns the gate off (the bypass, for the migration
# tests). The key matches tests/fixtures/qBittorrent.conf.
FIXTURE_API_KEY = "qbt_FixtureKey23456789abcdefghjk"
API_KEY = os.environ.get("QBT_FIXTURE_API_KEY") or FIXTURE_API_KEY
# Real qBittorrent keeps sync rid state per WebUI session: a request without a
# known session opens a new one and always gets a full update.
SESSIONS = set()
_SESSIONS_LOCK = threading.Lock()

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
    # "202": qBittorrent's Async status, which only torrents/add may treat
    # as success (Ruling FG, B1); on any other route it must be refused.
    return fault if fault in ("202", "404", "409", "500", "409secret", "noop", "unreadable", "sleep7") else None


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
# makes the whole read-modify-write atomic. Tests read LOG from another
# process while it's written, so the new log goes to a temp file and is
# renamed over LOG: a reader sees the old list or the new one, never an
# empty or half-written file.
_LOG_LOCK = threading.Lock()


def record(method, path, body, query, cookie=""):
    entry = {"method": method, "path": path, "body": body, "query": query, "cookie": cookie}
    with _LOG_LOCK:
        entries = []
        if LOG.exists():
            entries = json.loads(LOG.read_text() or "[]")
        entries.append(entry)
        tmp = LOG.with_name(LOG.name + ".tmp")
        tmp.write_text(json.dumps(entries))
        os.replace(tmp, LOG)


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
# Whether the last /app/preferences request was a setPreferences POST.
_PREFS_POSTED = [False]
_SCHEDULE_PAIRS = (("schedule_from_hour", "schedule_from_min"), ("schedule_to_hour", "schedule_to_min"))
_INT_TYPES = ("int", "choice-int", "speed")


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# The only keys 5.2.3 trims before storing (appcontroller.cpp:696, :701,
# :1019, :1178); every other string is stored as sent.
_TRIMMED = ("autorun_program", "autorun_on_torrent_added_program", "announce_ip", "current_interface_address")
# Keys 5.2.3 derives on every GET (:237, :316-321) from the key they gate.
_DERIVED = {
    "random_port": ("listen_port", lambda v: v == 0),
    "max_ratio_enabled": ("max_ratio", lambda v: v >= 0),
    "max_seeding_time_enabled": ("max_seeding_time", lambda v: v >= 0),
    "max_inactive_seeding_time_enabled": ("max_inactive_seeding_time", lambda v: v >= 0),
}


def _clean_path(p):
    """Path(): QDir::cleanPath on Unix. "//" collapses, "." and ".." parts
    resolve, a trailing slash goes; "" stays ""."""
    if p == "":
        return p
    cleaned = posixpath.normpath(p)
    # POSIX keeps a leading "//"; Qt on Unix doesn't.
    return "/" + cleaned.lstrip("/") if cleaned.startswith("//") else cleaned


def _qt_address(text):
    """QHostAddress{text}.toString(), or "" when it doesn't parse: IPv6
    lowercased and compressed (RFC 5952), a v4-mapped address kept dotted,
    and so is one whose first 96 bits are zero while its 7th group isn't
    (::1.2.3.4, but ::1 and ::100): checked against Qt 6.11's QHostAddress
    over 6000 addresses. (Qt also takes 127.1 or a padded address; qbt
    never sends those.)"""
    import ipaddress
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return ""
    if isinstance(addr, ipaddress.IPv6Address):
        if addr.ipv4_mapped is not None:
            return f"::ffff:{addr.ipv4_mapped}"
        packed = addr.packed
        if packed[:12] == bytes(12) and packed[12:14] != bytes(2):
            return f"::{ipaddress.IPv4Address(packed[12:])}"
    return str(addr)


def _banned_ips(text):
    """setBannedIPs (sessionimpl.cpp:4167) after appcontroller.cpp:783's
    split(SkipEmptyParts): invalid addresses dropped, QHostAddress form,
    sorted as strings, de-duplicated, joined back with newlines."""
    kept = {_qt_address(part) for part in text.split("\n") if part != ""}
    kept.discard("")
    return "\n".join(sorted(kept))


def _utf16_len(text):
    return len(text.encode("utf-16-le")) // 2


def _pref_value(key, value):
    """5.2.3's setter for one key: (True, stored) when it applies, (False,
    None) when the fixture drops it. Only _TRIMMED keys are trimmed, paths
    are cleaned (Path(), :560-617), global speeds are stored in whole KiB
    (sessionimpl.cpp:3480), announce_ip must be an IP address or becomes
    "" (:1178)."""
    entry = _SCHEMA.get(key)
    if entry is None:
        current = PREFS_STATE[key]
        if isinstance(current, bool):
            return (True, value) if isinstance(value, bool) else (False, None)
        if _is_number(current):
            return (True, value) if _is_number(value) else (False, None)
        if isinstance(current, str):
            return (True, value) if isinstance(value, str) else (False, None)
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
    if key in _TRIMMED:
        value = value.strip()
    if kind == "path":
        return True, _clean_path(value)
    if key in ("announce_ip", "current_interface_address"):
        return True, _qt_address(value)
    if key == "banned_IPs":
        return True, _banned_ips(value)
    return True, value


def _set_preferences(body):
    """setPreferencesAction (:513): 200, or 400 for a web_ui_username under
    3 UTF-16 units or with a colon (:907-913). 5.2.3 throws mid-loop, after
    the keys its code handles earlier have applied; qbt sends one key per
    request, so the fixture applies nothing on a 400. Unknown keys and
    malformed JSON are dropped without a word. 5.2.3 converts every value
    with QVariant's toBool/toInt/toReal/toString, so a value of the wrong
    kind is coerced (a string "yes" becomes false, "abc" becomes 0) rather
    than dropped; the fixture drops it instead, since qbt always sends the
    schema's kind and a coerced value would read back as "ignored" anyway.
    A scheduler time applies only when its hour and minute arrive together
    (:807-812). A write of a derived key is its setter (random_port true
    sets the port to 0, :705; a *_enabled false sets its limit to -1,
    :849-858), and every derived key is recomputed after the write, as
    5.2.3's GET does. The control file's "prefs_override" ({key: value}) is
    applied last, simulating qBittorrent changing a value on its own.
    Returns (HTTP status, body)."""
    raw = (parse_qs(body, keep_blank_values=True).get("json") or [""])[0]
    try:
        m = json.loads(raw)
    except ValueError:
        m = None
    if not isinstance(m, dict):
        m = {}
    name = m.get("web_ui_username")
    if isinstance(name, str) and _utf16_len(name) < 3:
        return 400, "WebUI username must be at least 3 characters long"
    if isinstance(name, str) and ":" in name:
        return 400, "WebUI username cannot contain a colon"
    with _PREFS_LOCK:
        for key, value in m.items():
            if key not in PREFS_STATE or key in _DERIVED or any(key in pair for pair in _SCHEDULE_PAIRS):
                continue
            if any(m.get(flag) is False and gated == key for flag, (gated, _) in _DERIVED.items()
                   if flag != "random_port"):
                continue
            if key == "listen_port" and m.get("random_port") is True:
                continue
            ok, stored = _pref_value(key, value)
            if ok:
                PREFS_STATE[key] = stored
        if m.get("random_port") is True and "listen_port" in PREFS_STATE:
            PREFS_STATE["listen_port"] = 0
        for flag, (gated, _) in _DERIVED.items():
            if flag != "random_port" and m.get(flag) is False and gated in PREFS_STATE:
                PREFS_STATE[gated] = -1
        for flag, (gated, derive) in _DERIVED.items():
            if flag in PREFS_STATE and _is_number(PREFS_STATE.get(gated)):
                PREFS_STATE[flag] = derive(PREFS_STATE[gated])
        for hour, minute in _SCHEDULE_PAIRS:
            if hour in m and minute in m and _is_int(m[hour]) and _is_int(m[minute]):
                PREFS_STATE[hour], PREFS_STATE[minute] = m[hour], m[minute]
        override = _control().get("prefs_override")
        if isinstance(override, dict):
            PREFS_STATE.update(override)
    return 200, ""


# Slice 5a: qBittorrent 5.2.3's search API (searchcontroller.cpp,
# searchpluginmanager.cpp, searchhandler.cpp), backed by state the write
# routes really change. Jobs and plugins are shared by every handler thread,
# so one lock guards both.
#
# A job's shape comes from the control file's "search" object when it
# starts: {"total": rows (default 3), "rate": rows per second (default: all
# at once), "finish": seconds until it finishes on its own (default 0; null
# = never), "rows": explicit result objects (then total = their count)}.
# Time is time.monotonic() plus the control file's "search_clock" seconds,
# a fake clock a test moves forward: at 180 s qBittorrent cancels the search
# process (m_searchTimeout) and the job reads Stopped with what it found.
# "search_python": "missing" makes start answer 409 the way it does without
# Python. Each route's faults use _write_fault's key "search_<action>".
#
# Jobs belong to one WebUI session, as in 5.2.3 (webapplication.cpp:844
# registers a SearchController per WebSession): SEARCH_SESSIONS maps a SID
# to that session's {id: job}. A search request with no or an unknown SID
# gets a fresh session and cookie (bypass_local_auth's sessionStart), so a
# job started in qbt's session reads 404 from any other one. Plugins are
# global (one SearchPluginManager), and ids are unique across sessions.
_SEARCH_LOCK = threading.Lock()
SEARCH_SESSIONS = {}
_SEARCH_IDS = [1000]
MAX_CONCURRENT_SEARCHES = 5
SEARCH_TIMEOUT = 180
_SEARCH_CATEGORY_NAMES = {
    "all": "All categories", "anime": "Anime", "books": "Books", "games": "Games", "movies": "Movies",
    "music": "Music", "pictures": "Pictures", "software": "Software", "tv": "TV shows",
}


def _search_plugin(name, full_name, version, enabled, url, categories):
    """One /search/plugins entry as getPluginsInfo builds it: "all" first,
    then the plugin's categories sorted case-insensitively."""
    cats = [{"id": "all", "name": _SEARCH_CATEGORY_NAMES["all"]}]
    cats += [{"id": c, "name": _SEARCH_CATEGORY_NAMES.get(c, "")} for c in sorted(categories, key=str.lower)]
    return {"name": name, "version": version, "fullName": full_name, "url": url,
            "supportedCategories": cats, "enabled": enabled}


def _default_plugins():
    return [
        _search_plugin("piratebay", "The Pirate Bay", "3.3", True, "https://thepiratebay.org",
                       ["movies", "tv", "music", "software", "games", "books", "anime"]),
        _search_plugin("eztv", "EZTV", "1.16", False, "https://eztvx.to", ["tv"]),
    ]


SEARCH_PLUGINS = _default_plugins()


def _search_now():
    try:
        return time.monotonic() + float(_control().get("search_clock") or 0)
    except (TypeError, ValueError):
        return time.monotonic()


def _qt_int(values):
    """QString::toInt of a query/form value: 0 when missing or not an int."""
    text = (values or [""])[0]
    return int(text) if re.fullmatch(r"[+-]?[0-9]{1,10}", text) else 0


def _plugin_version(text):
    try:
        return tuple(int(p) for p in str(text).split("."))
    except ValueError:
        return ()


def _search_row(job, i):
    """Row i of a generated job: deterministic, so a test can name row k."""
    if job["rows"] is not None:
        return job["rows"][i]
    h = format(i, "040x")
    return {
        "fileName": f"{job['pattern']} result {i}",
        "fileUrl": f"magnet:?xt=urn:btih:{h}&dn=r{i}",
        "fileSize": 1000 * (i + 1),
        "nbSeeders": i,
        "nbLeechers": 1,
        "engineName": "piratebay",
        "siteUrl": "https://thepiratebay.org",
        "descrLink": f"https://thepiratebay.org/t/{i}",
        "pubDate": 1757894400 + i,
    }


def _search_view(job, now):
    """(running, rows) at fake time `now`. A job stops at the first of: an
    explicit stop, its own finish, and the 3-minute cancel; its rows freeze
    there. Rows only grow."""
    ends = [SEARCH_TIMEOUT]
    if job["finish"] is not None:
        ends.append(job["finish"])
    if job["stopped_at"] is not None:
        ends.append(job["stopped_at"] - job["started"])
    end = min(ends)
    elapsed = now - job["started"]
    running = elapsed < end
    t = elapsed if running else end
    n = job["total"] if job["rate"] is None else min(job["total"], max(0, int(job["rate"] * t)))
    return running, [_search_row(job, i) for i in range(n)]


def _search_running(jobs):
    now = _search_now()
    return [j for j in jobs.values() if _search_view(j, now)[0]]


def _search_start(form, jobs):
    """-> (code, body). The Python check comes before the cap, as in
    startAction."""
    for key in ("pattern", "category", "plugins"):
        if key not in form:
            return 400, b"Missing required parameters"
    if _control().get("search_python") == "missing":
        return 409, b"Python must be installed to use the Search Engine."
    spec = _control().get("search")
    spec = spec if isinstance(spec, dict) else {}
    with _SEARCH_LOCK:
        if len(_search_running(jobs)) >= MAX_CONCURRENT_SEARCHES:
            return 409, b"Unable to create more than 5 concurrent searches."
        _SEARCH_IDS[0] += 1
        jid = _SEARCH_IDS[0]
        rows = spec.get("rows") if isinstance(spec.get("rows"), list) else None
        jobs[jid] = {
            "id": jid,
            "pattern": form["pattern"][0].strip(),
            "category": form["category"][0].strip(),
            "plugins": form["plugins"][0].split("|"),
            "started": _search_now(),
            "stopped_at": None,
            "rows": rows,
            "total": len(rows) if rows is not None else int(spec.get("total", 3)),
            "rate": spec.get("rate"),
            "finish": spec.get("finish", 0),
        }
    return 200, json.dumps({"id": jid}).encode()


def _search_get(path, query, jobs):
    """GET status / results / plugins -> (code, body); `jobs` is the
    request's session's."""
    q = parse_qs(query, keep_blank_values=True)
    with _SEARCH_LOCK:
        if path == "/api/v2/search/plugins":
            return 200, json.dumps(SEARCH_PLUGINS).encode()
        now = _search_now()
        jid = _qt_int(q.get("id"))
        if path == "/api/v2/search/status":
            if jid != 0 and jid not in jobs:
                return 404, b""
            ids = list(jobs) if jid == 0 else [jid]
            out = []
            for i in ids:
                running, rows = _search_view(jobs[i], now)
                out.append({"id": i, "status": "Running" if running else "Stopped", "total": len(rows)})
            return 200, json.dumps(out).encode()
        if path == "/api/v2/search/results":
            if "id" not in q:
                return 400, b"Missing required parameters"
            job = jobs.get(jid)
            if job is None:
                return 404, b""
            running, rows = _search_view(job, now)
            size = len(rows)
            limit, offset = _qt_int(q.get("limit")), _qt_int(q.get("offset"))
            if offset > size:
                return 409, b"Offset is out of range"
            if offset < 0:
                offset = size + offset
            if offset < 0:
                return 409, b"Offset is out of range"
            page = rows[offset:] if limit <= 0 else rows[offset:offset + limit]
            return 200, json.dumps({"status": "Running" if running else "Stopped",
                                    "results": page, "total": size}).encode()
    return 404, b""


def _search_finish_install(source, spec):
    """installPlugin's download finishing: the plugin is named after the
    URL path's file name with its extension dropped, and a version that
    isn't newer than the installed one is refused silently
    (installPlugin_impl). No spec = the download failed."""
    if not isinstance(spec, dict):
        return
    name = unquote(posixpath.splitext(posixpath.basename(urlparse(source).path))[0])
    version = str(spec.get("version", "1.0"))
    with _SEARCH_LOCK:
        current = next((p for p in SEARCH_PLUGINS if p["name"] == name), None)
        if current is not None and not (_plugin_version(current["version"]) < _plugin_version(version)):
            return
        if spec.get("broken"):
            return
        if current is None:
            plugin = _search_plugin(name, spec.get("fullName", name), version, True,
                                    spec.get("url", "https://example.org"), spec.get("categories", ["movies"]))
        else:
            # An update keeps the plugin's enabled state (and, in the
            # fixture, the rest of its entry).
            plugin = dict(current, version=version)
        if current is None:
            SEARCH_PLUGINS.append(plugin)
        else:
            SEARCH_PLUGINS[SEARCH_PLUGINS.index(current)] = plugin


def _search_post(path, body, jobs):
    """POST start / stop / delete / downloadTorrent and the plugin writes
    -> (code, body). Unknown ids (in this session's `jobs`) are 404; plugin
    writes always answer 200."""
    form = parse_qs(body, keep_blank_values=True)
    action = path.rsplit("/", 1)[1]
    if path == "/api/v2/search/start":
        return _search_start(form, jobs)
    if action in ("stop", "delete"):
        if "id" not in form:
            return 400, b"Missing required parameters"
        jid = _qt_int(form.get("id"))
        with _SEARCH_LOCK:
            job = jobs.get(jid)
            if job is None:
                return 404, b""
            if action == "delete":
                del jobs[jid]
            elif _search_view(job, _search_now())[0]:
                job["stopped_at"] = _search_now()
        return 200, b""
    if action == "downloadTorrent":
        if "torrentUrl" not in form or "pluginName" not in form:
            return 400, b"Missing required parameters"
        url = form["torrentUrl"][0]
        if url.lower().startswith("magnet:"):
            m = re.search(r"xt=urn:btih:([0-9A-Fa-f]{40})", url)
            if m:
                h = m.group(1).lower()
                ADDED.append({"hash": h, "infohash_v1": h, "name": h, "size": 0, "total_size": 0})
        return 200, b""
    if action == "installPlugin":
        if "sources" not in form:
            return 400, b"Missing required parameters"
        sources = _control().get("plugin_sources")
        sources = sources if isinstance(sources, dict) else {}
        delay = float(_control().get("plugin_install_delay", 0.3))
        for source in form["sources"][0].split("|"):
            threading.Timer(delay, _search_finish_install, (source, sources.get(source))).start()
        return 200, b""
    if action in ("uninstallPlugin", "enablePlugin"):
        if "names" not in form or (action == "enablePlugin" and "enable" not in form):
            return 400, b"Missing required parameters"
        names = [n.strip() for n in form["names"][0].split("|")]
        enable = form.get("enable", [""])[0].strip().lower() == "true"
        with _SEARCH_LOCK:
            if action == "uninstallPlugin":
                SEARCH_PLUGINS[:] = [p for p in SEARCH_PLUGINS if p["name"] not in names]
            else:
                for p in SEARCH_PLUGINS:
                    if p["name"] in names:
                        p["enabled"] = enable
        return 200, b""
    if action == "updatePlugins":
        updates = _control().get("plugin_updates")
        for name, version in (updates if isinstance(updates, dict) else {}).items():
            source = f"https://updates.example/{name}.py"
            threading.Timer(0.2, _search_finish_install, (source, {"version": version})).start()
        return 200, b""
    return 404, b""


# Slice 5b1: qBittorrent 5.2.3's RSS API (rsscontroller.cpp, rss_session.cpp,
# rss_feed.cpp, rss_folder.cpp) and its log (logcontroller.cpp), backed by
# state the write routes really change. RSS state is global: no SID keying.
#
# RSS_TREE is the rss/items?withData=true shape itself: a folder is
# {name: child}, a feed {uid, url, title, lastBuildDate, isLoading,
# hasError, articles}. Unread articles carry no isRead key (only
# markAsRead adds it). /fixture/rss-reset (test-only, unrecorded) sets the
# tree and the log from its JSON body ({"tree": {...}, "log": [{"message",
# "type"}], "logStart": first id}); an empty body empties both.
#
# A refresh makes a feed load for the control file's "rss_load_ticks"
# rss/items reads (default 1: the next read shows isLoading true, the one
# after that the result; 0 loads at once). A load applies the control
# file's "rss_sources" {url: {"title", "lastBuildDate", "articles": [...]}}
# (an article without torrentURL gets its link, as rss_parser.cpp does), or
# "rss_feed_errors" {url: reason}: hasError, and the WARNING log line
# rss_feed.cpp:247 writes. addFeed refreshes only while
# rss_processing_enabled is true (rss_session.cpp:166); refreshItem always
# does. "rss_ignore_move": true answers moveItem 200 and changes nothing.
# Each write route also takes _write_fault's key "rss_<action>".
_RSS_LOCK = threading.Lock()
RSS_TREE = {}
RSS_LOADING = {}
RSS_LOG = []
_RSS_IDS = {"uid": 0, "log": 0}
RSS_WRITES = ("addFolder", "addFeed", "removeItem", "moveItem", "markAsRead", "refreshItem")
_RSS_PATH = re.compile(r"\A[^\\]+(\\[^\\]+)*\Z")
LOG_TYPES = {"normal": 1, "info": 2, "warning": 4, "critical": 8}


def _rss_is_feed(node):
    return isinstance(node, dict) and isinstance(node.get("uid"), str) and isinstance(node.get("url"), str)


def _rss_item(path):
    """The node at path ("" is the root folder), or None."""
    node = RSS_TREE
    if path == "":
        return node
    for part in path.split("\\"):
        if _rss_is_feed(node) or not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def _rss_parent(path):
    return path.rpartition("\\")[0]


def _rss_name(path):
    return path.rpartition("\\")[2]


def _rss_feeds(node):
    if _rss_is_feed(node):
        yield node
    elif isinstance(node, dict):
        for child in node.values():
            yield from _rss_feeds(child)


def _rss_urls():
    return {f["url"] for f in _rss_feeds(RSS_TREE)}


def _rss_processing():
    return (PREFS_STATE or {}).get("rss_processing_enabled") is True


def _log_append(message, kind):
    RSS_LOG.append({"id": _RSS_IDS["log"], "message": message, "timestamp": int(time.time()),
                    "type": LOG_TYPES[kind]})
    _RSS_IDS["log"] += 1


def _rss_finish(feed):
    feed["isLoading"] = False
    url = feed["url"]
    errors = _control().get("rss_feed_errors")
    if isinstance(errors, dict) and isinstance(errors.get(url), str):
        feed["hasError"] = True
        _log_append(f"Failed to download RSS feed at '{url}'. Reason: {errors[url]}", "warning")
        return
    feed["hasError"] = False
    sources = _control().get("rss_sources")
    source = sources.get(url) if isinstance(sources, dict) else None
    if not isinstance(source, dict):
        return
    for key in ("title", "lastBuildDate"):
        if isinstance(source.get(key), str):
            feed[key] = source[key]
    known = {a.get("id") for a in feed["articles"]}
    added = 0
    for art in source.get("articles") or []:
        art = dict(art)
        if art.get("id") in known:
            continue
        art.pop("isRead", None)
        if not art.get("torrentURL"):
            art["torrentURL"] = art.get("link", "")
        feed["articles"].append(art)
        added += 1
    _log_append(f"RSS feed at '{url}' updated. Added {added} new articles.", "normal")


def _rss_refresh(node):
    ticks = _control().get("rss_load_ticks", 1)
    ticks = ticks if isinstance(ticks, int) and not isinstance(ticks, bool) and ticks >= 0 else 1
    for feed in _rss_feeds(node):
        if ticks == 0:
            _rss_finish(feed)
        else:
            feed["isLoading"] = True
            RSS_LOADING[feed["uid"]] = ticks


def _rss_tick():
    for feed in list(_rss_feeds(RSS_TREE)):
        left = RSS_LOADING.get(feed["uid"])
        if left is None:
            continue
        if left <= 1:
            del RSS_LOADING[feed["uid"]]
            _rss_finish(feed)
        else:
            RSS_LOADING[feed["uid"]] = left - 1


def _rss_items(query):
    """GET rss/items: withData shows titles, states and articles
    (rss_feed.cpp:483). The fixture clock ticks after the read."""
    with_data = (parse_qs(query).get("withData") or ["false"])[0].lower() in ("true", "1")

    def view(node):
        if _rss_is_feed(node):
            if with_data:
                return copy.deepcopy(node)
            return {"uid": node["uid"], "url": node["url"]}
        return {k: view(v) for k, v in node.items()}

    with _RSS_LOCK:
        # QJsonObject keeps its keys sorted.
        body = json.dumps(view(RSS_TREE), sort_keys=True).encode()
        _rss_tick()
    return 200, body


def _rss_dest(path):
    """prepareItemDest (rss_session.cpp:428): (parent folder, None) or
    (None, 409 text)."""
    if not _RSS_PATH.match(path):
        return None, f"Incorrect RSS Item path: {path}."
    if _rss_item(path) is not None:
        return None, f"RSS item with given path already exists: {path}."
    parent = _rss_item(_rss_parent(path))
    if parent is None or _rss_is_feed(parent):
        return None, f"Parent folder doesn't exist: {_rss_parent(path)}."
    return parent, None


def _rss_post(action, body):
    form = parse_qs(body, keep_blank_values=True)

    def arg(name):
        return (form.get(name) or [None])[0]

    required = {"addFolder": ("path",), "addFeed": ("url", "path"), "removeItem": ("path",),
                "moveItem": ("itemPath", "destPath"), "markAsRead": ("itemPath",), "refreshItem": ("itemPath",)}
    missing = [p for p in required[action] if arg(p) is None]
    if missing:
        return 400, ("Missing required parameters: " + ", ".join(missing)).encode()
    with _RSS_LOCK:
        if action == "addFolder":
            path = arg("path")
            parent, err = _rss_dest(path)
            if err:
                return 409, err.encode()
            parent[_rss_name(path)] = {}
        elif action == "addFeed":
            url, path = arg("url"), arg("path")
            path = path or url
            if url in _rss_urls():
                return 409, f"RSS feed with given URL already exists: {url}.".encode()
            parent, err = _rss_dest(path)
            if err:
                return 409, err.encode()
            _RSS_IDS["uid"] += 1
            feed = {"uid": "{%08x-0000-4000-8000-000000000000}" % _RSS_IDS["uid"], "url": url, "title": "",
                    "lastBuildDate": "", "isLoading": False, "hasError": False, "articles": []}
            parent[_rss_name(path)] = feed
            if _rss_processing():
                _rss_refresh(RSS_TREE)
        elif action == "removeItem":
            path = arg("path")
            if path == "":
                return 409, b"Cannot delete root folder."
            if _rss_item(path) is None:
                return 409, f"Item doesn't exist: {path}.".encode()
            for feed in _rss_feeds(_rss_item(path)):
                RSS_LOADING.pop(feed["uid"], None)
            del _rss_item(_rss_parent(path))[_rss_name(path)]
        elif action == "moveItem":
            src, dest = arg("itemPath"), arg("destPath")
            if src == "":
                return 409, b"Cannot move root folder."
            item = _rss_item(src)
            if item is None:
                return 409, f"Item doesn't exist: {src}.".encode()
            if src == dest or _control().get("rss_ignore_move") is True:
                return 200, b""
            if not _rss_is_feed(item) and dest.startswith(src + "\\"):
                return 409, b"Can't move a folder into itself or its subfolders."
            parent, err = _rss_dest(dest)
            if err:
                return 409, err.encode()
            del _rss_item(_rss_parent(src))[_rss_name(src)]
            parent[_rss_name(dest)] = item
        elif action == "markAsRead":
            item = _rss_item(arg("itemPath"))
            if item is None:
                # rsscontroller.cpp: `if (!item) return;` before setResult,
                # so a missing path answers 204 with no content.
                return 204, b""
            article_id = arg("articleId")
            if article_id is not None:
                # rsscontroller.cpp:143: an articleId, even an empty one,
                # names one article of a feed.
                if _rss_is_feed(item):
                    for art in item["articles"]:
                        if art.get("id") == article_id:
                            art["isRead"] = True
            else:
                for feed in _rss_feeds(item):
                    for art in feed["articles"]:
                        art["isRead"] = True
        elif action == "refreshItem":
            item = _rss_item(arg("itemPath"))
            if item is not None:
                _rss_refresh(item)
    return 200, b""


def _rss_reset(body):
    spec = json.loads(body) if body else {}
    with _RSS_LOCK:
        RSS_TREE.clear()
        RSS_TREE.update(copy.deepcopy(spec.get("tree") or {}))
        RSS_LOADING.clear()
        RSS_LOG[:] = []
        _RSS_IDS["log"] = int(spec.get("logStart") or 0)
        for row in spec.get("log") or []:
            _log_append(row["message"], row.get("type", "warning"))
        RSS_RULES.clear()
        RSS_RULES.update(copy.deepcopy(spec.get("rules") or {}))
        _RSS_RULE_CALLS["setRule"] = 0


def _log_main(query):
    """GET log/main (logcontroller.cpp): the rows of the asked types with
    an id above last_known_id (default -1)."""
    qs = parse_qs(query)

    def flag(name):
        return (qs.get(name) or ["true"])[0].lower() in ("true", "1")

    try:
        last = int((qs.get("last_known_id") or ["-1"])[0])
    except ValueError:
        last = -1
    wanted = sum(bit for name, bit in LOG_TYPES.items() if flag(name))
    with _RSS_LOCK:
        rows = [dict(r) for r in RSS_LOG if r["id"] > last and r["type"] & wanted]
    return 200, json.dumps(rows).encode()


# Slice 5b2: qBittorrent 5.2.3's auto-download rules (rsscontroller.cpp,
# rss_autodownloader.cpp, rss_autodownloadrule.cpp, addtorrentparams.cpp).
# RSS_RULES maps a name to the rule as rss/rules shows it: setRule stores
# toJsonObject(fromJsonObject(ruleDef)) (_rss_rule_canon), so a missing
# key takes its default (`{}`, or a ruleDef that isn't JSON, makes an
# enabled blank rule), a torrentParams key of any value hides the flat
# savePath/assignedCategory/addPaused, and the flat keys and torrentParams
# are both emitted. /fixture/rss-reset seeds its "rules" exactly as given
# (so a test can plant an odd rule) and clears them otherwise.
# renameRule answers 200 and changes nothing on a clash or a missing rule;
# removeRule answers 200 for an unknown name. matchingArticles answers
# {feedName: [titles]} for a saved rule: the control file's "rss_matching"
# {ruleName: {feedName: [titles]}} verbatim when it names the rule, else a
# case-insensitive substring match of mustContain on every article (read
# or not) of each affectedFeeds URL, keyed by the feed's name, a later
# same-named feed overwriting (rsscontroller.cpp:242), no key for a feed
# with no match. The control file's "rss_setrule_inject" {"at": N
# (default 1), "every": bool, "append": [episodes], "drop": [episodes],
# "lastMatch": str, "remove": bool} changes the stored rule right after
# the Nth setRule since the reset (or every one), as the auto-downloader
# does when a save re-runs its queue (OV9). Each write also takes
# _write_fault's "rss_<action>", and the reads "rss_rules" and
# "rss_matchingArticles".
RSS_RULES = {}
_RSS_RULE_CALLS = {"setRule": 0}
RSS_RULE_WRITES = ("setRule", "renameRule", "removeRule")
_CONTENT_LAYOUTS = ("Original", "Subfolder", "NoSubfolder")
_STOP_CONDITIONS = ("None", "MetadataReceived", "FilesChecked")
_SHARE_ACTIONS = ("Default", "Stop", "Remove", "RemoveWithContent", "EnableSuperSeeding")


def _rule_int(value, default):
    if isinstance(value, int) and not isinstance(value, bool):
        return value if -2 ** 31 <= value < 2 ** 31 else default
    if isinstance(value, float) and value.is_integer() and -2 ** 31 <= value < 2 ** 31:
        return int(value)
    return default


def _rule_str(value):
    return value if isinstance(value, str) else ""


def _rule_str_list(value):
    if isinstance(value, str):
        return [value]
    return [_rule_str(v) for v in value] if isinstance(value, list) else []


def _rule_path(value):
    """Path(text).data(): cleaned (a trailing / goes)."""
    text = _rule_str(value)
    return _clean_path(text) if text else ""


def _rule_optional_bool(obj, key):
    """getOptionalBool: absent or null is unset; anything else toBool()."""
    value = obj.get(key)
    if value is None:
        return None
    return value is True


def _rule_rfc2822(value):
    """QDateTime::fromString(.., Qt::RFC2822Date).toString(Qt::RFC2822Date)."""
    if not isinstance(value, str) or not value:
        return ""
    try:
        when = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError, IndexError, OverflowError):
        return ""
    if when is None:
        return ""
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.strftime("%d %b %Y %H:%M:%S %z")


def _rss_rule_canon(obj):
    """toJsonObject(fromJsonObject(obj)) (rss_autodownloadrule.cpp:462-559)."""
    o = obj if isinstance(obj, dict) else {}
    if "torrentParams" in o:
        tp = o["torrentParams"] if isinstance(o["torrentParams"], dict) else {}
        layout = tp.get("content_layout")
        cond = tp.get("stop_condition")
        tags = sorted({t for t in _rule_str_list(tp.get("tags")) if t})
        ratio = tp.get("ratio_limit")
        params = {
            "category": _rule_str(tp.get("category")), "tags": tags,
            "save_path": _rule_path(tp.get("save_path")), "download_path": _rule_path(tp.get("download_path")),
            "operating_mode": "Forced" if tp.get("operating_mode") == "Forced" else "AutoManaged",
            "skip_checking": tp.get("skip_checking") is True,
            "upload_limit": _rule_int(tp.get("upload_limit"), -1),
            "download_limit": _rule_int(tp.get("download_limit"), -1),
            "seeding_time_limit": _rule_int(tp.get("seeding_time_limit"), -2),
            "inactive_seeding_time_limit": _rule_int(tp.get("inactive_seeding_time_limit"), -2),
            "share_limit_action": tp.get("share_limit_action") if tp.get("share_limit_action") in _SHARE_ACTIONS else "Default",
            "ratio_limit": ratio if isinstance(ratio, (int, float)) and not isinstance(ratio, bool) else -2,
            "ssl_certificate": _rule_str(tp.get("ssl_certificate")),
            "ssl_private_key": _rule_str(tp.get("ssl_private_key")),
            "ssl_dh_params": _rule_str(tp.get("ssl_dh_params")),
        }
        optional = {
            "add_to_top_of_queue": _rule_optional_bool(tp, "add_to_top_of_queue"),
            "stopped": _rule_optional_bool(tp, "stopped"),
            "stop_condition": None if cond is None else (cond if cond in _STOP_CONDITIONS else "None"),
            "content_layout": None if layout is None else (layout if layout in _CONTENT_LAYOUTS else "Original"),
            "use_auto_tmm": _rule_optional_bool(tp, "use_auto_tmm"),
            "use_download_path": _rule_optional_bool(tp, "use_download_path"),
        }
    else:
        # The deprecated flat keys (rss_autodownloadrule.cpp:535-557).
        path = _rule_path(o.get("savePath"))
        params = {
            "category": _rule_str(o.get("assignedCategory")), "tags": [], "save_path": path, "download_path": "",
            "operating_mode": "AutoManaged", "skip_checking": False, "upload_limit": -1, "download_limit": -1,
            "seeding_time_limit": -2, "inactive_seeding_time_limit": -2, "share_limit_action": "Default",
            "ratio_limit": -2, "ssl_certificate": "", "ssl_private_key": "", "ssl_dh_params": "",
        }
        layout = None
        if "torrentContentLayout" in o:
            text = _rule_str(o.get("torrentContentLayout"))
            layout = (text if text in _CONTENT_LAYOUTS else "Original") if text else None
        elif isinstance(o.get("createSubfolder"), bool):
            layout = "Original" if o["createSubfolder"] else "NoSubfolder"
        paused = o.get("addPaused")
        optional = {"add_to_top_of_queue": None, "stopped": paused if isinstance(paused, bool) else None,
                    "stop_condition": None, "content_layout": layout,
                    "use_auto_tmm": False if path else None, "use_download_path": None}
    for key, value in optional.items():
        if value is not None:
            params[key] = value
    enabled = o.get("enabled")
    return {
        "enabled": enabled if isinstance(enabled, bool) else True,
        "priority": _rule_int(o.get("priority"), 0),
        "useRegex": o.get("useRegex") is True,
        "mustContain": _rule_str(o.get("mustContain")),
        "mustNotContain": _rule_str(o.get("mustNotContain")),
        "episodeFilter": _rule_str(o.get("episodeFilter")),
        "affectedFeeds": _rule_str_list(o.get("affectedFeeds")),
        "lastMatch": _rule_rfc2822(o.get("lastMatch")),
        "ignoreDays": _rule_int(o.get("ignoreDays"), 0),
        "smartFilter": o.get("smartFilter") is True,
        "previouslyMatchedEpisodes": _rule_str_list(o.get("previouslyMatchedEpisodes")),
        "addPaused": optional["stopped"],
        "torrentContentLayout": optional["content_layout"],
        "savePath": params["save_path"],
        "assignedCategory": params["category"],
        "torrentParams": params,
    }


def _rss_feed_paths(node, prefix=""):
    """(path, feed) for every feed under node, in the tree's order."""
    for name, child in node.items():
        path = name if prefix == "" else prefix + "\\" + name
        if _rss_is_feed(child):
            yield path, child
        elif isinstance(child, dict):
            yield from _rss_feed_paths(child, path)


def _rss_setrule_inject(name):
    spec = _control().get("rss_setrule_inject")
    if not isinstance(spec, dict) or name not in RSS_RULES:
        return
    at = spec.get("at", 1)
    if spec.get("every") is not True and _RSS_RULE_CALLS["setRule"] != at:
        return
    if spec.get("remove") is True:
        del RSS_RULES[name]
        return
    rule = RSS_RULES[name]
    eps = [e for e in rule["previouslyMatchedEpisodes"] if e not in (spec.get("drop") or [])]
    rule["previouslyMatchedEpisodes"] = eps + [e for e in spec.get("append") or [] if e not in eps]
    if isinstance(spec.get("lastMatch"), str):
        rule["lastMatch"] = spec["lastMatch"]


def _rss_rule_post(action, body):
    form = parse_qs(body, keep_blank_values=True)

    def arg(name):
        return (form.get(name) or [None])[0]

    required = {"setRule": ("ruleName", "ruleDef"), "renameRule": ("ruleName", "newRuleName"), "removeRule": ("ruleName",)}
    missing = [p for p in required[action] if arg(p) is None]
    if missing:
        return 400, ("Missing required parameters: " + ", ".join(missing)).encode()
    name = arg("ruleName")
    with _RSS_LOCK:
        if action == "setRule":
            try:
                rule_def = json.loads(arg("ruleDef"))
            except ValueError:
                rule_def = {}
            RSS_RULES[name] = _rss_rule_canon(rule_def)
            _RSS_RULE_CALLS["setRule"] += 1
            _rss_setrule_inject(name)
        elif action == "renameRule":
            new = arg("newRuleName")
            if name in RSS_RULES and new not in RSS_RULES:
                renamed = {}
                for k, v in RSS_RULES.items():
                    renamed[new if k == name else k] = v
                RSS_RULES.clear()
                RSS_RULES.update(renamed)
        else:
            RSS_RULES.pop(name, None)
    return 200, b""


def _rss_matching(name):
    """GET rss/matchingArticles?ruleName= (rsscontroller.cpp:222)."""
    with _RSS_LOCK:
        rule = RSS_RULES.get(name)
        if rule is None:
            return {}
        scripted = _control().get("rss_matching")
        if isinstance(scripted, dict) and isinstance(scripted.get(name), dict):
            return scripted[name]
        feeds = {f["url"]: (path, f) for path, f in _rss_feed_paths(RSS_TREE)}
        must = _rule_str(rule.get("mustContain")).lower()
        out = {}
        for url in _rule_str_list(rule.get("affectedFeeds")):
            if url not in feeds:
                continue
            path, feed = feeds[url]
            titles = [a.get("title", "") for a in feed["articles"] if must in str(a.get("title", "")).lower()]
            if titles:
                out[path.rpartition("\\")[2]] = titles
        return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n).decode("utf-8") if n else ""

    def _bearer(self):
        """The request's API key when it is the right one, else None."""
        kind, _, key = (self.headers.get("Authorization") or "").partition(" ")
        return key.strip() if kind.lower() == "bearer" and key.strip() == API_KEY else None

    def _authorized(self, path):
        """False (after a 403) for an /api/v2/ route without the API key."""
        if not path.startswith("/api/v2/") or os.environ.get("QBT_FIXTURE_NO_AUTH") == "1":
            return True
        if self._bearer() is not None:
            return True
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Forbidden")
        return False

    def _session(self):
        """Return (sid, is_new) for this request, minting a SID when unknown.
        An API-key request's session id is the key. Locked: qbt and the
        sidecar can both be minting at once."""
        with _SESSIONS_LOCK:
            key = self._bearer()
            if key is not None:
                is_new = key not in SESSIONS
                SESSIONS.add(key)
                return key, is_new
            for part in (self.headers.get("Cookie") or "").split(";"):
                name, _, value = part.strip().partition("=")
                if name == "SID" and value in SESSIONS:
                    return value, False
            sid = f"fixture-{len(SESSIONS) + 1}"
            SESSIONS.add(sid)
            return sid, True

    def _search_session(self):
        """(sid to set or None, this session's jobs) for a search route."""
        sid, is_new = self._session()
        with _SEARCH_LOCK:
            jobs = SEARCH_SESSIONS.setdefault(sid, {})
        return (sid if is_new else None), jobs

    def _send(self, code, body=b"", content_type="application/json", sid=None):
        if os.environ.get("QBT_FIXTURE_FORBIDDEN") == "1" or _control().get("forbidden") is True:
            self.send_response(403)
            self.send_header("Set-Cookie", COOKIE)
            self.end_headers()
            self.wfile.write(b"SID=leaked-secret-value forbidden")
            return
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        if sid and self._bearer() is None:
            self.send_header("Set-Cookie", f"SID={sid}; HttpOnly; path=/")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _fault_reply(self, fault, sid=None):
        if fault == "409secret":
            self._send(409, SECRET_ERROR_BODY, content_type="text/plain", sid=sid)
        else:
            self._send(int(fault), b"boom", sid=sid)

    def _rss_route(self, method, parsed, body):
        """Slice 5b1: rss/* and log/main. The writes are POST only (a GET
        answers 405); items and log/main take either."""
        action = parsed.path.rsplit("/", 1)[1]
        if parsed.path == "/api/v2/log/main":
            fault = _write_fault("log_main")
            if fault and fault not in ("noop", "unreadable", "sleep7"):
                self._fault_reply(fault)
                return
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>")
                return
            code, payload = _log_main(parsed.query)
            self._send(code, payload)
            return
        if action == "items":
            fault = _write_fault("rss_items")
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>")
                return
            if fault == "sleep7":
                time.sleep(7)
            elif fault and fault != "noop":
                self._fault_reply(fault)
                return
            code, payload = _rss_items(parsed.query)
            self._send(code, payload)
            return
        if action in ("rules", "matchingArticles"):
            # Slice 5b2: the rules reads take either method.
            fault = _write_fault("rss_" + action)
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>")
                return
            if fault == "sleep7":
                time.sleep(7)
            elif fault and fault != "noop":
                self._fault_reply(fault)
                return
            if action == "rules":
                with _RSS_LOCK:
                    payload = json.dumps(RSS_RULES, sort_keys=True)
            else:
                qs = parse_qs(parsed.query, keep_blank_values=True)
                qs.update(parse_qs(body, keep_blank_values=True))
                if "ruleName" not in qs:
                    self._send(400, b"Missing required parameters: ruleName", content_type="text/plain")
                    return
                payload = json.dumps(_rss_matching(qs["ruleName"][0]), sort_keys=True)
            self._send(200, payload.encode())
            return
        if action not in RSS_WRITES and action not in RSS_RULE_WRITES:
            self._send(404, b"Not Found", content_type="text/plain")
            return
        if method != "POST":
            self._send(405, b"Method Not Allowed", content_type="text/plain")
            return
        fault = _write_fault("rss_" + action)
        if fault in ("sleep7", "unreadable"):
            fault = None
        if fault == "noop":
            self._send(200, b"")
            return
        if fault:
            self._fault_reply(fault)
            return
        if action in RSS_RULE_WRITES:
            code, payload = _rss_rule_post(action, body)
        else:
            code, payload = _rss_post(action, body)
        self._send(code, payload, content_type="text/plain")

    def do_GET(self):
        parsed = urlparse(self.path)
        if not self._authorized(parsed.path):
            return
        if parsed.path == "/fixture/rss-state":
            # Test-only and unrecorded: the tree as it is, without ticking
            # the RSS clock.
            with _RSS_LOCK:
                payload = json.dumps({"tree": RSS_TREE, "log": RSS_LOG, "loading": RSS_LOADING, "rules": RSS_RULES})
            self._send(200, payload.encode())
            return
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
        if parsed.path.startswith("/api/v2/rss/") or parsed.path == "/api/v2/log/main":
            self._rss_route("GET", parsed, "")
            return
        if parsed.path.startswith("/api/v2/search/"):
            sid, jobs = self._search_session()
            fault = _write_fault("search_" + parsed.path.rsplit("/", 1)[1])
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>", sid=sid)
                return
            if fault == "sleep7":
                time.sleep(7)
            elif fault and fault != "noop":
                self._fault_reply(fault, sid)
                return
            code, payload = _search_get(parsed.path, parsed.query, jobs)
            self._send(code, payload, content_type="application/json" if code == 200 else "text/plain", sid=sid)
            return
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
            # "preferences_after_post": the fault hits only a read that
            # follows a setPreferences POST (a write's read-back), so a
            # command that reads first and then writes can fail after it.
            with _PREFS_LOCK:
                after_post, _PREFS_POSTED[0] = _PREFS_POSTED[0], False
            if after_post and isinstance(_control().get("preferences_after_post"), str):
                fault = _control()["preferences_after_post"]
            if _control().get("preferences") == "409state":
                self._send(409, json.dumps(PREFS_STATE).encode(), content_type="text/plain")
                return
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>")
                return
            if fault == "sleep7":
                # Past qbt's 5 s curl limit, holding the read open.
                time.sleep(7)
            elif fault and fault != "noop":
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
        if not self._authorized(parsed.path):
            return
        if parsed.path == "/fixture/search-reset":
            # Test-only and unrecorded: every job gone, and the plugin list
            # set to the body's JSON list (empty body: the defaults).
            with _SEARCH_LOCK:
                for jobs in SEARCH_SESSIONS.values():
                    jobs.clear()
                SEARCH_PLUGINS[:] = json.loads(body) if body else _default_plugins()
            with _LOG_LOCK:
                # "<fault>@N" counts from here for the search routes.
                for key in [k for k in _CALLS if k.startswith("search_")]:
                    del _CALLS[key]
            self._send(200, b"")
            return
        if parsed.path == "/fixture/rss-reset":
            # Test-only and unrecorded (see _rss_reset).
            _rss_reset(body)
            with _LOG_LOCK:
                for key in [k for k in _CALLS if k.startswith("rss_")]:
                    del _CALLS[key]
            self._send(200, b"")
            return
        record("POST", parsed.path, body, parse_qs(parsed.query))
        if parsed.path.startswith("/api/v2/rss/") or parsed.path == "/api/v2/log/main":
            self._rss_route("POST", parsed, body)
            return
        if parsed.path.startswith("/api/v2/search/"):
            sid, jobs = self._search_session()
            fault = _write_fault("search_" + parsed.path.rsplit("/", 1)[1])
            if fault == "noop":
                self._send(200, b"", sid=sid)
                return
            if fault == "unreadable":
                self._send(200, b"<html>not json</html>", sid=sid)
                return
            if fault:
                self._fault_reply(fault, sid)
                return
            code, payload = _search_post(parsed.path, body, jobs)
            self._send(code, payload, content_type="application/json" if code == 200 and payload else "text/plain", sid=sid)
            return
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
            # qBittorrent 5.2.3 (torrentscontroller.cpp addAction) answers a
            # URL it must download first (anything that isn't a magnet,
            # e.g. an https .torrent) as pending: 202 (APIStatus::Async)
            # with the counts as JSON, and nothing is added yet.
            pending = sum(1 for raw in urls if not unquote_plus(raw).lower().startswith("magnet:"))
            if fault == "fails":
                self._send(200, b"Fails.")
            elif fault is None and pending:
                self._send(202, json.dumps({
                    "success_count": len(urls) - pending, "failure_count": 0,
                    "pending_count": pending, "added_torrent_ids": [],
                }).encode(), content_type="application/json")
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
            with _PREFS_LOCK:
                _PREFS_POSTED[0] = True
            fault = _write_fault("setPreferences")
            if fault == "sleep7":
                # Past qbt's 5 s curl limit; nothing applies.
                time.sleep(7)
                self._send(200, b"")
                return
            if fault == "noop":
                self._send(200, b"")
                return
            if fault and fault != "unreadable":
                self._fault_reply(fault)
                return
            code, text = _set_preferences(body)
            self._send(code, text.encode(), content_type="text/plain")
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
