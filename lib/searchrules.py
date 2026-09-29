#!/usr/bin/env python3
"""Slice 5a (Search): the rules `qbt search` and `qbt search-plugin` enforce.

Every rule and message comes from tests/fixtures/search-rules-cases.json
(the pageLink and magnetHash rules also from tests/fixtures/link-rules-cases.json)
(the contract, eng OV9); the window only pre-checks the same cases in
SearchView.js. URLs are split by the contract's own text rule, never by a
URL library (Ruling FB), and an IDN label becomes RFC 3492 punycode with no
other IDNA mapping (the stdlib "punycode" codec on the lowercased label; the
"idna" codec would apply nameprep). Lengths are counted in code points.

CLI, for qbt: `searchrules.py <kind>` reads the value on stdin (addLink:
the link, then NUL and the plugin when one was given). Exit 0 prints
"<normalised>\\t<host>"; a refusal exits 1 printing its message. argv can
carry no NUL, so a NUL-separated stdin can't be confused.
"""
import re
import sys

from linkrules import (  # noqa: F401
    BAD, CONTROL, MSG_LINK, Refused, host_of, is_space, last_segment, page_link, split_url)

_PLUGIN_NAME = re.compile("[A-Za-z0-9_]+")
_SEARCH_ID = re.compile("[1-9][0-9]{0,9}")

# qBittorrent 5.2.3's category ids (searchpluginmanager.cpp categoryFullName).
CATEGORIES = ("all", "anime", "books", "games", "movies", "music", "pictures", "software", "tv")

MSG = {
    **MSG_LINK,
    "pluginUrlEmpty": "Paste an https:// link to a plugin's .py file.",
    "pluginUrlLong": "Use a URL of at most 2048 characters.",
    "pluginUrlBad": "Use a URL without spaces, control characters, | or \\.",
    "pluginUrlScheme": "Plugin URLs must start with https://.",
    "pluginUrlUser": "Use a URL without a user name or password.",
    "pluginUrlHost": "That URL has no valid host.",
    "pluginUrlPy": "The URL must point to a .py file.",
    "pluginName": "Plugin names use only letters, digits and _.",
    "noLink": "That result has no usable link.",
    "patternControl": "Use a search without control characters.",
    "patternEmpty": "Type something to search for.",
    "category": "That isn't a search category.",
    "searchId": "That isn't a search id.",
    "alreadyInstalled": "<name> v<version> is already installed.",
    "installUnconfirmed": "Couldn't confirm the install of <name>.",
}


def plugin_url(text):
    if text == "":
        raise Refused(MSG["pluginUrlEmpty"])
    if len(text) > 2048:
        raise Refused(MSG["pluginUrlLong"])
    if BAD.search(text) or "|" in text:
        raise Refused(MSG["pluginUrlBad"])
    parts = split_url(text)
    if not parts or parts[0] != "https":
        raise Refused(MSG["pluginUrlScheme"])
    _, authority, path = parts
    if "@" in authority:
        raise Refused(MSG["pluginUrlUser"])
    host = host_of(authority)
    if host is None:
        raise Refused(MSG["pluginUrlHost"])
    segment = last_segment(path)
    if not segment.lower().endswith(".py"):
        raise Refused(MSG["pluginUrlPy"])
    name = segment[:-3]
    if not _PLUGIN_NAME.fullmatch(name):
        raise Refused(MSG["pluginName"])
    return name, host


def plugin_name(text):
    if not _PLUGIN_NAME.fullmatch(text):
        raise Refused(MSG["pluginName"])
    return text, ""


def add_link(link, plugin=""):
    """-> ("add" | "plugin", host). A magnet has no host."""
    if plugin != "":
        plugin_name(plugin)
    if link == "" or BAD.search(link):
        raise Refused(MSG["noLink"])
    if link[:8].lower() == "magnet:?":
        return "add", ""
    parts = split_url(link)
    if not parts or parts[0] != "https" or "@" in parts[1]:
        raise Refused(MSG["noLink"])
    host = host_of(parts[1])
    if host is None:
        raise Refused(MSG["noLink"])
    if plugin != "":
        return "plugin", host
    segment = last_segment(parts[2])
    if len(segment) > len(".torrent") and segment.lower().endswith(".torrent"):
        return "add", host
    raise Refused(MSG["noLink"])


def pattern(text):
    if CONTROL.search(text):
        raise Refused(MSG["patternControl"])
    start, end = 0, len(text)
    while start < end and is_space(text[start]):
        start += 1
    while end > start and is_space(text[end - 1]):
        end -= 1
    if start == end:
        raise Refused(MSG["patternEmpty"])
    return "", ""


def category(text):
    if text not in CATEGORIES:
        raise Refused(MSG["category"])
    return text, ""


def search_id(text):
    if not _SEARCH_ID.fullmatch(text) or int(text) > 2147483647:
        raise Refused(MSG["searchId"])
    return text, ""


def install_readback(name, before, after):
    """The install read-back's verdict (A3, OV4): None when confirmed, else
    the message. `before`/`after` are versions (None when absent)."""
    if after is not None and after != before:
        return None
    if before is not None and after == before:
        return MSG["alreadyInstalled"].replace("<name>", name).replace("<version>", before)
    return MSG["installUnconfirmed"].replace("<name>", name)


RULES = {
    "pluginUrl": plugin_url,
    "pageLink": page_link,
    "pluginName": plugin_name,
    "pattern": pattern,
    "category": category,
    "searchId": search_id,
}


def check(kind, value):
    """(ok, normalised, host, message) for one case-file input."""
    try:
        if kind == "addLink":
            normalised, host = add_link(*value)
        else:
            normalised, host = RULES[kind](value)
    except Refused as exc:
        return False, None, None, exc.message
    return True, normalised, host, None


def main(argv):
    if len(argv) != 2 or (argv[1] not in RULES and argv[1] != "addLink"):
        print("usage: searchrules.py pluginUrl|pageLink|addLink|pluginName|pattern|category|searchId",
              file=sys.stderr)
        return 2
    kind = argv[1]
    text = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    value = text.split("\0", 1) if kind == "addLink" else text
    ok, normalised, host, message = check(kind, value)
    if not ok:
        sys.stdout.write(message)
        return 1
    sys.stdout.write(f"{normalised}\t{host}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
