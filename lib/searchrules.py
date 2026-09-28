#!/usr/bin/env python3
"""Slice 5a (Search): the rules `qbt search` and `qbt search-plugin` enforce.

Every rule and message comes from tests/fixtures/search-rules-cases.json
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
import unicodedata

# The case file's BAD class, plus U+DC80-DCFF: invalid UTF-8 from argv,
# decoded with surrogateescape, is refused like a control character.
_BAD = re.compile(
    "[\u0000- \u007f-   -‏ - "
    " -⁯　﻿\\\\\udc80-\udcff]"
)
_CONTROL = re.compile("[\u0000-\u001f\u007f-\u009f\udc80-\udcff]")
_PLUGIN_NAME = re.compile("[A-Za-z0-9_]+")
_SEARCH_ID = re.compile("[1-9][0-9]{0,9}")
_PORT = re.compile("[0-9]{1,5}")
_IPV6 = re.compile(r"\[([0-9A-Fa-f:.]+)\](?::(.*))?")
_LABEL = re.compile("[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
_SCHEME = re.compile("([A-Za-z][A-Za-z0-9+.-]*)://")

# qBittorrent 5.2.3's category ids (searchpluginmanager.cpp categoryFullName).
CATEGORIES = ("all", "anime", "books", "games", "movies", "music", "pictures", "software", "tv")

MSG = {
    "pluginUrlEmpty": "Paste an https:// link to a plugin's .py file.",
    "pluginUrlLong": "Use a URL of at most 2048 characters.",
    "pluginUrlBad": "Use a URL without spaces, control characters, | or \\.",
    "pluginUrlScheme": "Plugin URLs must start with https://.",
    "pluginUrlUser": "Use a URL without a user name or password.",
    "pluginUrlHost": "That URL has no valid host.",
    "pluginUrlPy": "The URL must point to a .py file.",
    "pluginName": "Plugin names use only letters, digits and _.",
    "pageEmpty": "That result has no page link.",
    "pageBad": "That page link has spaces, control characters or \\ in it.",
    "pageScheme": "That page link isn't http or https.",
    "pageUser": "That page link has a user name or password in it.",
    "pageHost": "That page link has no valid host.",
    "noLink": "That result has no usable link.",
    "patternControl": "Use a search without control characters.",
    "patternEmpty": "Type something to search for.",
    "category": "That isn't a search category.",
    "searchId": "That isn't a search id.",
    "alreadyInstalled": "<name> v<version> is already installed.",
    "installUnconfirmed": "Couldn't confirm the install of <name>.",
}


class Refused(Exception):
    def __init__(self, message):
        super().__init__(message)
        self.message = message


def split_url(text):
    """The contract's text rule: (scheme, authority, path) or None when
    there's no "<scheme>://". The authority runs to the first /, ? or #
    (or the end); the path from that / to the first ? or #."""
    m = _SCHEME.match(text)
    if not m:
        return None
    rest = text[m.end():]
    end = len(rest)
    for ch in "/?#":
        i = rest.find(ch)
        if i != -1 and i < end:
            end = i
    authority, after = rest[:end], rest[end:]
    path = ""
    if after.startswith("/"):
        stop = len(after)
        for ch in "?#":
            i = after.find(ch)
            if i != -1 and i < stop:
                stop = i
        path = after[:stop]
    return m.group(1).lower(), authority, path


def last_segment(path):
    return path[path.rfind("/") + 1:] if "/" in path else ""


def _port_ok(port):
    return bool(_PORT.fullmatch(port)) and 1 <= int(port) <= 65535


def _label(label):
    if any(ord(c) > 0x7F for c in label):
        try:
            label = "xn--" + label.encode("punycode").decode("ascii")
        except (UnicodeError, ValueError):
            return None
    return label


def host_of(authority):
    """host[:port] (no userinfo) -> the host as the confirm shows it (lower
    case, IDN labels as punycode, no port), or None when refused."""
    if authority.startswith("["):
        m = _IPV6.fullmatch(authority)
        if not m or ":" not in m.group(1):
            return None
        if m.group(2) is not None and not _port_ok(m.group(2)):
            return None
        return "[" + m.group(1).lower() + "]"
    if authority.count(":") > 1:
        return None
    name, colon, port = authority.partition(":")
    if colon and not _port_ok(port):
        return None
    labels = [_label(part) for part in name.lower().split(".")]
    if any(label is None or not _LABEL.fullmatch(label) for label in labels):
        return None
    host = ".".join(labels)
    return host if 1 <= len(host) <= 253 else None


def plugin_url(text):
    if text == "":
        raise Refused(MSG["pluginUrlEmpty"])
    if len(text) > 2048:
        raise Refused(MSG["pluginUrlLong"])
    if _BAD.search(text) or "|" in text:
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


def page_link(text):
    if text == "":
        raise Refused(MSG["pageEmpty"])
    if _BAD.search(text):
        raise Refused(MSG["pageBad"])
    parts = split_url(text)
    if not parts or parts[0] not in ("http", "https"):
        raise Refused(MSG["pageScheme"])
    if "@" in parts[1]:
        raise Refused(MSG["pageUser"])
    host = host_of(parts[1])
    if host is None:
        raise Refused(MSG["pageHost"])
    return "", host


def plugin_name(text):
    if not _PLUGIN_NAME.fullmatch(text):
        raise Refused(MSG["pluginName"])
    return text, ""


def add_link(link, plugin=""):
    """-> ("add" | "plugin", host). A magnet has no host."""
    if plugin != "":
        plugin_name(plugin)
    if link == "" or _BAD.search(link):
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


def _is_space(ch):
    # QString::trimmed's QChar::isSpace: \t-\r, space, U+0085, U+00A0 and
    # the Unicode separators (Zs, Zl, Zp).
    return ch in "\t\n\v\f\r \x85\xa0" or unicodedata.category(ch) in ("Zs", "Zl", "Zp")


def pattern(text):
    if _CONTROL.search(text):
        raise Refused(MSG["patternControl"])
    start, end = 0, len(text)
    while start < end and _is_space(text[start]):
        start += 1
    while end > start and _is_space(text[end - 1]):
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
