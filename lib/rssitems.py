#!/usr/bin/env python3
"""Slice 5b1 (RSS): qBittorrent 5.2.3's feed tree as `qbt rss` prints it.

`flatten` turns rss/items?withData=true (plus app/preferences) into the
lean rows of tests/fixtures/rss-contract.md ("qbt rss items"): no
description anywhere (OV6). `article_text` turns one description into
plain text by the case file's articleText rule. The other modes are qbt's
checks before and after a write (the existence check, the read-backs) and
the `qbt rss error` cache.

CLI, for qbt. Every value and every response body arrives on stdin,
NUL-separated (a body is JSON, which never holds a raw NUL); argv holds
only the mode (and, for the error cache, the state file's path):
  flatten             items NUL preferences -> the items JSON
  article             path NUL guid NUL items -> {"text", "truncated"}; exit 3 when gone
  kind                path NUL items -> "feed", "folder" or "none" ("" is the root folder)
  unread              path NUL items -> the unread count in that scope, or "none"
  read                path NUL guid NUL items -> "read", "unread", "nofeed" or "noarticle"
  error-since <state> -> the last_known_id to ask log/main with
  error <state>       url NUL items NUL log NUL full -> {"reason": ...}, saving the cache
Exit 2 is a usage error, 4 an unreadable body.
"""
import email.utils
import json
import os
import re
import sys
from datetime import timezone
from html.parser import HTMLParser

from linkrules import Refused, page_link
from rssrules import has_torrent, error_reason

SEPARATOR = "\\"
TEXT_CAP = 4096
ERROR_CACHE_CAP = 200
_BLOCK_TAGS = frozenset(("p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"))
_DROP_TAGS = frozenset(("script", "style"))
_WHITESPACE = re.compile("[ \t\n\r\f\v]+")
_SPACES = re.compile(" +")
_BLANKS = re.compile("\n{4,}")


class Unreadable(Exception):
    pass


# --- the description as text (articleText) -----------------------------------------


class _TextParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.dropping = 0

    def handle_starttag(self, tag, attrs):
        if tag in _DROP_TAGS:
            self.dropping += 1
        elif tag in _BLOCK_TAGS or tag == "br":
            self.parts.append("\n")

    def handle_startendtag(self, tag, attrs):
        # <p/> counts as its start tag only; <script/> opens nothing.
        if tag in _BLOCK_TAGS or tag == "br":
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in _DROP_TAGS:
            self.dropping = max(0, self.dropping - 1)
        elif tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.dropping:
            self.parts.append(_WHITESPACE.sub(" ", data))

    # Comments, CDATA, declarations and processing instructions: dropped.
    def handle_comment(self, data):
        pass

    def handle_decl(self, decl):
        pass

    def unknown_decl(self, data):
        pass

    def handle_pi(self, data):
        pass


def article_text(html):
    """-> (text, truncated) by the case file's articleText rule."""
    parser = _TextParser()
    parser.feed(html if isinstance(html, str) else "")
    parser.close()
    lines = [_SPACES.sub(" ", line).strip(" ") for line in "".join(parser.parts).split("\n")]
    text = _BLANKS.sub("\n\n\n", "\n".join(lines)).strip("\n")
    if len(text) > TEXT_CAP:
        return text[:TEXT_CAP], True
    return text, False


# --- the tree -------------------------------------------------------------------------


def _is_feed(node):
    return isinstance(node, dict) and isinstance(node.get("uid"), str) and isinstance(node.get("url"), str)


def _sorted_children(folder):
    return sorted(((k, v) for k, v in folder.items() if isinstance(v, dict)),
                  key=lambda kv: (kv[0].lower(), kv[0]))


def _string(value):
    return value if isinstance(value, str) else ""


def _articles(feed):
    arts = feed.get("articles")
    return [a for a in arts if isinstance(a, dict)] if isinstance(arts, list) else []


def _is_read(article):
    # 5.2.3 leaves isRead out of an unread article (only markAsRead adds it).
    return article.get("isRead") is True


def _root(items):
    if not isinstance(items, dict) or _is_feed(items):
        raise Unreadable()
    return items


def find(items, path):
    """The node at `path` exactly as qBittorrent names it ("" is the
    root), or None."""
    node = _root(items)
    if path == "":
        return node
    for part in path.split(SEPARATOR):
        if _is_feed(node) or not isinstance(node, dict):
            return None
        node = node.get(part)
        if not isinstance(node, dict):
            return None
    return node


def _feeds_under(node):
    if _is_feed(node):
        yield node
        return
    for _, child in _sorted_children(node):
        yield from _feeds_under(child)


def unread_in(node):
    return sum(1 for feed in _feeds_under(node) for a in _articles(feed) if not _is_read(a))


def _epoch(text):
    if not isinstance(text, str) or text == "":
        return None
    try:
        when = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None
    if when is None:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    try:
        return int(when.timestamp())
    except (OverflowError, ValueError, OSError):
        return None


def _host(link):
    try:
        return page_link(link)[1]
    except Refused:
        return ""


def _has_torrent(torrent_url, link):
    try:
        has_torrent(torrent_url, link)
        return True
    except Refused:
        return False


def flatten(items_json, processing, refresh_interval=None):
    """rss/items?withData=true -> the `qbt rss items` shape."""
    root = _root(items_json)
    feeds, articles = [], []

    def walk(folder, prefix, depth):
        for name, node in _sorted_children(folder):
            path = name if prefix == "" else prefix + SEPARATOR + name
            if _is_feed(node):
                arts = _articles(node)
                unread = sum(1 for a in arts if not _is_read(a))
                feeds.append({
                    "path": path, "name": name, "depth": depth, "folder": False,
                    "url": node["url"], "title": _string(node.get("title")),
                    "isLoading": node.get("isLoading") is True, "hasError": node.get("hasError") is True,
                    "unread": unread, "total": len(arts),
                })
                for a in arts:
                    torrent_url, link = _string(a.get("torrentURL")), _string(a.get("link"))
                    articles.append({
                        "feedPath": path, "guid": _string(a.get("id")), "title": _string(a.get("title")),
                        "date": _epoch(a.get("date")), "isRead": _is_read(a),
                        "torrentURL": torrent_url, "link": link,
                        "hasTorrent": _has_torrent(torrent_url, link), "host": _host(link),
                    })
            else:
                row = {"path": path, "name": name, "depth": depth, "folder": True,
                       "unread": 0, "total": 0, "feeds": 0}
                feeds.append(row)
                under = list(_feeds_under(node))
                row["feeds"] = len(under)
                row["total"] = sum(len(_articles(f)) for f in under)
                row["unread"] = sum(1 for f in under for a in _articles(f) if not _is_read(a))
                walk(node, path, depth + 1)

    walk(root, "", 0)
    return {"processing": processing is True, "refreshInterval": refresh_interval,
            "feeds": feeds, "articles": articles}


# --- the error cache (qbt rss error) ------------------------------------------------


def _load_state(path):
    # O_NOFOLLOW: a planted symlink is never read as the cache.
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return -1, {}
    if not isinstance(data, dict):
        return -1, {}
    last = data.get("lastId")
    reasons = data.get("reasons")
    # -1: no row seen yet (qBittorrent's log ids start at 0).
    if not isinstance(last, int) or isinstance(last, bool) or last < -1:
        last = -1
    if not isinstance(reasons, dict):
        reasons = {}
    return last, {k: v for k, v in reasons.items() if isinstance(k, str) and isinstance(v, str)}


def _save_state(path, last, reasons):
    """Written to a fresh temporary name (O_EXCL, 0600) and moved into
    place, so a planted file or symlink is never written through."""
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        return
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"lastId": last, "reasons": reasons}, f, ensure_ascii=True, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def error_since(state_path):
    """The last_known_id to ask log/main with: one below lastId, so the
    row lastId names comes back while qBittorrent's log still holds it,
    and a reply without it means qBittorrent restarted (its ids began
    again)."""
    last, _ = _load_state(state_path)
    return last - 1 if last > 0 else -1


def _log_rows(log):
    if not isinstance(log, list):
        raise Unreadable()
    return [r for r in log if isinstance(r, dict) and isinstance(r.get("id"), int) and not isinstance(r.get("id"), bool)]


def restarted(state_path, log):
    """True when the log reply (asked with error_since) doesn't reach the
    stored lastId: qBittorrent restarted, so the whole log is read again.
    With lastId 0 the reply is already the whole log (error_since gives
    -1) and error_update rescans it, so there is nothing to ask again."""
    last, _ = _load_state(state_path)
    return last > 0 and not any(r["id"] >= last for r in _log_rows(log))


def error_update(state_path, url, items, log, full):
    """Applies the log rows after lastId (every row when `full`) to the
    cache, drops the reasons of feeds whose hasError is false, saves, and
    returns the stored reason for `url` or None."""
    last, reasons = _load_state(state_path)
    rows = _log_rows(log)
    # lastId 0 can't tell the row it names from a restarted log's new row
    # 0, so it rescans the whole reply (error_since asked with -1); a row
    # read again only restores the reason it already gave.
    if full or last == 0:
        last = -1
    else:
        rows = [r for r in rows if r["id"] > last]
    for feed in _feeds_under(_root(items)):
        feed_url = feed["url"]
        if feed.get("hasError") is not True:
            reasons.pop(feed_url, None)
            continue
        reason = error_reason(rows, feed_url)
        if reason is not None:
            reasons.pop(feed_url, None)
            reasons[feed_url] = reason
    while len(reasons) > ERROR_CACHE_CAP:
        reasons.pop(next(iter(reasons)))
    top = max((r["id"] for r in rows), default=None)
    if top is not None and top > last:
        last = top
    _save_state(state_path, last, reasons)
    return reasons.get(url)


# --- CLI ------------------------------------------------------------------------------


def _json(text):
    try:
        return json.loads(text)
    except ValueError:
        raise Unreadable()


def _fields(n):
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    fields = text.split("\0")
    if len(fields) != n:
        raise SystemExit(2)
    return fields


def _write(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True, separators=(",", ":")))


def run(argv):
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "flatten" and len(argv) == 2:
        items, prefs = _fields(2)
        prefs = _json(prefs)
        if not isinstance(prefs, dict):
            raise Unreadable()
        processing, interval = prefs.get("rss_processing_enabled"), prefs.get("rss_refresh_interval")
        if not isinstance(processing, bool) or not isinstance(interval, int) or isinstance(interval, bool):
            raise Unreadable()
        _write(flatten(_json(items), processing, interval))
        return 0
    if mode == "article" and len(argv) == 2:
        path, guid, items = _fields(3)
        feed = find(_json(items), path)
        if not _is_feed(feed):
            return 3
        for a in _articles(feed):
            if a.get("id") == guid:
                text, truncated = article_text(_string(a.get("description")))
                _write({"text": text, "truncated": truncated})
                return 0
        return 3
    if mode == "kind" and len(argv) == 2:
        path, items = _fields(2)
        node = find(_json(items), path)
        sys.stdout.write("none" if node is None else "feed" if _is_feed(node) else "folder")
        return 0
    if mode == "unread" and len(argv) == 2:
        path, items = _fields(2)
        node = find(_json(items), path)
        sys.stdout.write("none" if node is None else str(unread_in(node)))
        return 0
    if mode == "read" and len(argv) == 2:
        path, guid, items = _fields(3)
        feed = find(_json(items), path)
        if not _is_feed(feed):
            sys.stdout.write("nofeed")
            return 0
        for a in _articles(feed):
            if a.get("id") == guid:
                sys.stdout.write("read" if _is_read(a) else "unread")
                return 0
        sys.stdout.write("noarticle")
        return 0
    if mode == "error-since" and len(argv) == 3:
        sys.stdout.write(str(error_since(argv[2])))
        return 0
    if mode == "error-restarted" and len(argv) == 3:
        (log,) = _fields(1)
        sys.stdout.write("yes" if restarted(argv[2], _json(log)) else "no")
        return 0
    if mode == "error" and len(argv) == 3:
        url, items, log, full = _fields(4)
        _write({"reason": error_update(argv[2], url, _json(items), _json(log), full == "full")})
        return 0
    return 2


def main(argv):
    try:
        return run(argv)
    except Unreadable:
        return 4
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
