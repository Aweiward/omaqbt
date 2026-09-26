#!/usr/bin/env python3
"""Shared status engine for OmaqBT.

`qbt status` (bash) pipes a probe (installed/daemon/lockHolder/vpnIface/
base/stateDir/ridFile/cookieFile) into `python3 lib/qbtsync.py status` on
stdin, and this module does the rest: talks to qbittorrent-nox's WebUI over
localhost, merges sync/maindata deltas into the on-disk rid cache, and
prints the same JSON object `qbt status` has always printed. `qbt-serve`
(a later task) reuses these same functions so there is exactly one
implementation of this logic.
"""
import http.client
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

_SID_RE = re.compile(r"SID=[^;\s]*", re.IGNORECASE)
_PASSWORD_RE = re.compile(r"password=[^;\s]*", re.IGNORECASE)


def sanitize(text):
    """Scrub session ids and passwords the same way bash `sanitize()` does."""
    text = _SID_RE.sub("SID=<redacted>", text)
    text = _PASSWORD_RE.sub("password=<redacted>", text)
    return text


def assert_local(base):
    """Raise ValueError unless `base`'s host is exactly 127.0.0.1."""
    host = urlparse(base).hostname or ""
    if host != "127.0.0.1":
        raise ValueError(f"refusing non-localhost host: {host}")


class ApiError(Exception):
    """A failed WebUI call. `.message` is already sanitized."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


class CurlCookieJar(http.cookiejar.MozillaCookieJar):
    """A MozillaCookieJar that stays compatible with curl's jar file.

    curl (and this project's bash `api()`) writes "0" in the expires column
    for a cookie with no explicit expiration, and treats that as "keep
    sending it, and keep it in the jar across runs". The stdlib parses "0"
    literally as the Unix epoch, so it looks permanently expired and is
    never sent again. On load, cookies with expires==0 are treated as
    session cookies with no expiration. On save, such cookies are written
    back out as curl's literal "0" rather than the stdlib's own "" marker:
    curl's cookie-file parser drops a cookie whose expires field is empty
    (verified against the system curl), so "" would silently break the
    next `qbt add`/`qbt start`/etc. that reads this same jar file.

    The whole point of this class is "persist session cookies like curl
    does", so `load`/`save` default `ignore_discard`/`ignore_expires` to
    True (the stdlib defaults to False for both): a bare `jar.load()` with
    the stdlib defaults would silently drop every curl-minted SID before
    the fixup below ever sees it, since the base `_really_load` filters
    cookies out before storing them, not after.
    """

    def load(self, filename=None, ignore_discard=True, ignore_expires=True):
        super().load(filename, ignore_discard, ignore_expires)

    def _really_load(self, f, filename, ignore_discard, ignore_expires):
        super()._really_load(f, filename, ignore_discard, ignore_expires)
        for cookie in self:
            if cookie.expires == 0:
                cookie.expires = None
                cookie.discard = True

    def save(self, filename=None, ignore_discard=True, ignore_expires=True):
        touched = [c for c in self if c.expires is None]
        for cookie in touched:
            cookie.expires = 0
        try:
            super().save(filename, ignore_discard, ignore_expires)
        finally:
            for cookie in touched:
                cookie.expires = None


class Client:
    """A tiny localhost-only HTTP GET client sharing a cookie jar with curl."""

    def __init__(self, base, cookiejar, timeout=5):
        assert_local(base)
        self.base = base
        self.cookiejar = cookiejar
        self.timeout = timeout
        # An empty ProxyHandler replaces urllib's default one, so http_proxy
        # and friends can never route a localhost request (or its SID
        # cookie) through a proxy.
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(cookiejar),
        )

    def get(self, path):
        url = self.base + path
        req = urllib.request.Request(url, method="GET")
        try:
            with self.opener.open(req, timeout=self.timeout) as resp:
                code = resp.status
                body = resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            code = exc.code
            try:
                body = exc.read().decode("utf-8", "replace")
            except Exception:
                body = ""
            if code == 403:
                raise ApiError(403, "localhost auth is required")
            raise ApiError(code, sanitize(f"HTTP {code} {body}"))
        except urllib.error.URLError as exc:
            raise ApiError(None, sanitize(str(exc)))
        except (OSError, http.client.HTTPException) as exc:
            # urllib only wraps failures in h.request() (connect/send) as
            # URLError. A connection that dies during h.getresponse()/
            # resp.read() -- the peer closes early, or the socket times out
            # waiting for a response -- raises the raw exception instead
            # (http.client.RemoteDisconnected, TimeoutError, etc.). Treat
            # those the same as any other transport failure.
            raise ApiError(None, sanitize(str(exc) or type(exc).__name__))
        if code not in (200, 204):
            raise ApiError(code, sanitize(f"HTTP {code} {body}"))
        return body


def _try_json_object(body):
    """Parse `body` as JSON, returning the dict, or None if it isn't one.

    A non-JSON body ("<html...") or a JSON value that isn't an object
    ("[]", "null", "5") both come back as None rather than raising, so
    callers can treat a malformed response as a failed call the same way
    they treat an ApiError, instead of crashing on json.JSONDecodeError or
    AttributeError from calling .get() on a list.
    """
    try:
        data = json.loads(body or "{}")
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def merge_maindata(raw, cache):
    """Faithful move of the inline python3 -c block from `qbt` cmd_status.

    Returns (torrents_map, rows): the merged/normalized torrent-by-hash map
    (to persist as the new cache) and the row list for the "torrents" field.
    """
    if raw.get("full_update"):
        torrents = dict(raw.get("torrents") or {})
    else:
        torrents = dict(cache)
        for k, v in (raw.get("torrents") or {}).items():
            cur = dict(torrents.get(k) or {})
            cur.update(v or {})
            torrents[k] = cur
        for k in raw.get("torrents_removed") or []:
            torrents.pop(k, None)

    normalized = {}
    for key, t in torrents.items():
        t = dict(t or {})
        hid = t.get("hash") or t.get("infohash_v1") or t.get("infohash_v2") or key
        t["hash"] = hid
        normalized[str(hid)] = t
    torrents = normalized

    rows = []
    for key, t in torrents.items():
        rows.append({
            "hash": key,
            "name": t.get("name") or "",
            "state": t.get("state") or "",
            "progress": t.get("progress") or 0,
            "dlSpeed": t.get("dlspeed") if t.get("dlspeed") is not None else t.get("dlSpeed") or 0,
            "upSpeed": t.get("upspeed") if t.get("upspeed") is not None else t.get("upSpeed") or 0,
            "eta": t.get("eta") or 0,
            "ratio": t.get("ratio") or 0,
            "size": t.get("size") or 0,
            "savePath": t.get("save_path") or "",
            "magnetUri": t.get("magnet_uri") or "",
            "contentPath": t.get("content_path") or "",
            "numSeeds": t.get("num_seeds") or 0,
            "numLeechs": t.get("num_leechs") or 0,
            "addedOn": t.get("added_on") or 0,
            "dlLimit": t.get("dl_limit") or 0,
            "upLimit": t.get("up_limit") or 0,
            "seqDl": t.get("seq_dl") is True,
            "ratioLimit": -2 if t.get("ratio_limit") is None else t.get("ratio_limit"),
        })
    return torrents, rows


class SyncState:
    """The on-disk rid cache: `{"rid":N,"torrents":{...}}`."""

    def __init__(self, rid=0, torrents=None):
        self.rid = rid
        self.torrents = torrents if torrents is not None else {}

    @classmethod
    def load(cls, path):
        try:
            with open(path, "r") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return cls()
        if not isinstance(data, dict):
            return cls()
        rid = data.get("rid") or 0
        torrents = data.get("torrents")
        if not isinstance(torrents, dict):
            torrents = {}
        return cls(rid=rid, torrents=torrents)

    def save(self, path):
        body = json.dumps({"rid": self.rid, "torrents": self.torrents}, separators=(",", ":"))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            with os.fdopen(fd, "w") as f:
                f.write(body)
        finally:
            os.chmod(path, 0o600)


class SlowCache:
    """Caches the speed-mode/bind-iface calls, which don't need every poll."""

    def __init__(self, alt_speed=False, bind_iface="", vpn_iface_ok=False, fetched_at=None, interval=0):
        self.alt_speed = alt_speed
        self.bind_iface = bind_iface
        self.vpn_iface_ok = vpn_iface_ok
        self.fetched_at = fetched_at
        self.interval = interval

    def due(self, now):
        return self.fetched_at is None or (now - self.fetched_at) >= self.interval


def build_status(probe, client, sync, slow, now):
    """Assemble the `qbt status` JSON object. Returns (status, errors)."""
    errors = []
    installed = bool(probe.get("installed"))
    daemon = bool(probe.get("daemon"))
    lock_holder = probe.get("lockHolder") or "none"
    vpn_iface = probe.get("vpnIface") or ""

    api = False
    alt_speed = False
    dl_speed = 0
    up_speed = 0
    torrents = []
    bind_iface = ""

    if installed and daemon and lock_holder != "gui":
        try:
            body = client.get(f"/api/v2/sync/maindata?rid={sync.rid}")
        except ApiError as exc:
            errors.append(exc.message)
        else:
            raw = _try_json_object(body)
            if raw is None:
                # A malformed response is a failed call, not a crash: leave
                # api False and sync untouched, same as an ApiError.
                errors.append("invalid maindata response")
            else:
                merged, rows = merge_maindata(raw, sync.torrents)
                sync.torrents = merged
                sync.rid = raw.get("rid") or 0
                torrents = rows
                server_state = raw.get("server_state") or {}
                dl_speed = server_state.get("dl_info_speed") or 0
                up_speed = server_state.get("up_info_speed") or 0
                api = True

    if api and slow.due(now):
        try:
            mode = client.get("/api/v2/transfer/speedLimitsMode")
            slow.alt_speed = mode == "1"
        except ApiError as exc:
            slow.alt_speed = False
            errors.append(exc.message)
        if vpn_iface:
            try:
                body = client.get("/api/v2/app/preferences")
            except ApiError as exc:
                slow.bind_iface = ""
                slow.vpn_iface_ok = False
                errors.append(exc.message)
            else:
                prefs = _try_json_object(body)
                if prefs is None:
                    slow.bind_iface = ""
                    slow.vpn_iface_ok = False
                    errors.append("invalid preferences response")
                else:
                    slow.bind_iface = prefs.get("current_network_interface") or ""
                    slow.vpn_iface_ok = True
        slow.fetched_at = now

    if api:
        alt_speed = slow.alt_speed
        if vpn_iface:
            bind_iface = slow.bind_iface
            if not slow.vpn_iface_ok:
                vpn_iface = ""

    status = {
        "installed": installed,
        "daemon": daemon,
        "lockHolder": lock_holder,
        "api": api,
        "altSpeed": alt_speed,
        "dlSpeed": dl_speed,
        "upSpeed": up_speed,
        "torrents": torrents,
        "vpnIface": vpn_iface,
        "bindIface": bind_iface,
    }
    return status, errors


def _main(argv):
    if not argv or argv[0] != "status":
        sys.stderr.write("usage: qbtsync.py status\n")
        return 2

    raw_stdin = sys.stdin.read()
    if not raw_stdin.strip():
        return 1
    try:
        probe = json.loads(raw_stdin)
    except ValueError:
        return 1
    if not isinstance(probe, dict):
        return 1

    cookie_file = probe.get("cookieFile") or ""
    rid_file = probe.get("ridFile") or ""
    base = probe.get("base") or ""

    jar = CurlCookieJar(cookie_file)
    if cookie_file and os.path.exists(cookie_file):
        try:
            jar.load(ignore_discard=True, ignore_expires=True)
        except Exception:
            pass

    try:
        client = Client(base, jar)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    sync = SyncState.load(rid_file)
    slow = SlowCache(interval=0)
    status, errors = build_status(probe, client, sync, slow, time.time())

    sync.save(rid_file)
    old_umask = os.umask(0o077)
    try:
        jar.save(ignore_discard=True, ignore_expires=True)
    finally:
        os.umask(old_umask)

    for line in errors:
        print(line, file=sys.stderr)
    print(json.dumps(status, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
