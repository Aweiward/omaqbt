#!/usr/bin/env python3
"""Slice 5b1 (RSS): the rules `qbt rss` enforces.

Every rule and message comes from tests/fixtures/rss-rules-cases.json (the
contract is tests/fixtures/rss-contract.md); the window only pre-checks the
same cases in RssView.js. URLs are split by 5b0's text rule and hosts
checked by its host rule (lib/linkrules.py), never by a URL library.

CLI, for qbt: `rssrules.py <kind>` reads the value on stdin (hasTorrent:
torrentURL, NUL, link; errorReason: the case file's {log, url} as JSON).
Exit 0 prints the normalised value (errorReason: as JSON, null when no row
matches); a refusal exits 1 printing its message. argv never carries a
value.
"""
import json
import sys

from linkrules import BAD, CONTROL, Refused, host_of, is_space, split_url  # noqa: F401

MSG = {
    "nameEmpty": "Enter a name.",
    "nameBackslash": "Names can't contain \\.",
    "nameControl": "Names can't contain control characters.",
    "feedUrlEmpty": "Enter a feed URL.",
    "feedUrlBad": "Feed URLs can't contain spaces, control characters, | or \\.",
    "feedUrlScheme": "Feed URLs start with http:// or https://.",
    "feedUrlUser": "Feed URLs can't contain a user name or password.",
    "feedUrlHost": "That feed URL has no valid host.",
    "noTorrent": "This article has no torrent link.",
    "badTorrentLink": "That link isn't http, https or magnet.",
}

_ERROR_PREFIXES = ("Failed to download RSS feed at '", "Failed to parse RSS feed at '")
_ERROR_MIDDLE = "'. Reason: "


def feed_url(text):
    """-> the host as the name prompt prefills it."""
    if text == "":
        raise Refused(MSG["feedUrlEmpty"])
    if BAD.search(text) or "|" in text:
        raise Refused(MSG["feedUrlBad"])
    parts = split_url(text)
    if not parts or parts[0] not in ("http", "https"):
        raise Refused(MSG["feedUrlScheme"])
    if "@" in parts[1]:
        raise Refused(MSG["feedUrlUser"])
    host = host_of(parts[1])
    if host is None:
        raise Refused(MSG["feedUrlHost"])
    return host


def name(text):
    """-> the name trimmed with Qt's isSpace set (ruling FE: U+FEFF stays)."""
    start, end = 0, len(text)
    while start < end and is_space(text[start]):
        start += 1
    while end > start and is_space(text[end - 1]):
        end -= 1
    trimmed = text[start:end]
    if trimmed == "":
        raise Refused(MSG["nameEmpty"])
    if "\\" in trimmed:
        raise Refused(MSG["nameBackslash"])
    if CONTROL.search(trimmed):
        raise Refused(MSG["nameControl"])
    return trimmed


def has_torrent(torrent_url, link):
    """The add rule (D4, OV1 and the D4 exception) -> "magnet" or "url"."""
    if torrent_url == "":
        raise Refused(MSG["noTorrent"])
    if BAD.search(torrent_url) or "|" in torrent_url:
        raise Refused(MSG["badTorrentLink"])
    if torrent_url[:8].lower() == "magnet:?":
        return "magnet"
    parts = split_url(torrent_url)
    if not parts or parts[0] not in ("http", "https"):
        raise Refused(MSG["badTorrentLink"])
    if "@" in parts[1] or host_of(parts[1]) is None:
        raise Refused(MSG["badTorrentLink"])
    if torrent_url != link:
        return "url"
    if parts[2].lower().endswith(".torrent"):
        return "url"
    raise Refused(MSG["noTorrent"])


def error_reason(log_rows, url):
    """The newest (highest id) log row naming exactly this URL -> its
    reason, or None. A prefix test, never a pattern."""
    best_id, best = None, None
    heads = [p + url + _ERROR_MIDDLE for p in _ERROR_PREFIXES]
    for row in log_rows if isinstance(log_rows, list) else []:
        if not isinstance(row, dict):
            continue
        message, rid = row.get("message"), row.get("id")
        if not isinstance(message, str) or not isinstance(rid, int) or isinstance(rid, bool):
            continue
        for head in heads:
            if message.startswith(head):
                if best_id is None or rid > best_id:
                    best_id, best = rid, message[len(head):]
                break
    return best


def check(kind, value):
    """(ok, normalised, message) for one case-file input."""
    try:
        if kind == "feedUrl":
            return True, feed_url(value), None
        if kind == "name":
            return True, name(value), None
        if kind == "hasTorrent":
            return True, has_torrent(value["torrentURL"], value["link"]), None
        if kind == "errorReason":
            return True, error_reason(value["log"], value["url"]), None
    except Refused as exc:
        return False, None, exc.message
    raise KeyError(kind)


KINDS = ("feedUrl", "name", "hasTorrent", "errorReason")


def main(argv):
    if len(argv) != 2 or argv[1] not in KINDS:
        print("usage: rssrules.py " + "|".join(KINDS), file=sys.stderr)
        return 2
    kind = argv[1]
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    if kind == "hasTorrent":
        fields = text.split("\0")
        if len(fields) != 2:
            print("usage: rssrules.py hasTorrent (torrentURL NUL link on stdin)", file=sys.stderr)
            return 2
        value = {"torrentURL": fields[0], "link": fields[1]}
    elif kind == "errorReason":
        try:
            value = json.loads(text)
            value = {"log": value["log"], "url": value["url"]}
        except (ValueError, TypeError, KeyError):
            print("usage: rssrules.py errorReason ({log, url} as JSON on stdin)", file=sys.stderr)
            return 2
    else:
        value = text
    ok, normalised, message = check(kind, value)
    out = sys.stdout.buffer
    if not ok:
        out.write(message.encode("utf-8"))
        return 1
    if kind == "errorReason":
        out.write(json.dumps(normalised).encode("ascii"))
    else:
        out.write(normalised.encode("utf-8", "surrogateescape"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
