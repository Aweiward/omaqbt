#!/usr/bin/env python3
"""Slice 5b0 (shared link rules): the URL text rule and the page-link rule
`searchrules.py` (Search) and, later, RSS enforce. Rules and messages come
from tests/fixtures/link-rules-cases.json; the window pre-checks the same
cases in LinkRules.js. URLs are split by the contract's own text rule, never
by a URL library (Ruling FB), and an IDN label becomes RFC 3492 punycode with
no other IDNA mapping. Lengths are counted in code points. Python has no
magnet-hash rule: magnetHash rows are JS-only.
"""
import re
import unicodedata

# The case file's BAD class, plus U+DC80-DCFF: invalid UTF-8 from argv,
# decoded with surrogateescape, is refused like a control character.
# U+00AD (soft hyphen) and the IDNA dot variants U+3002, U+FF0E, U+FF61
# are in it too (Ruling FG): a dot variant inside a host would otherwise
# punycode into one label and pass the host rule.
BAD = re.compile(
    "[\u0000-\u0020\u007f-\u00a0\u00ad\u1680\u2000-\u200f\u2028-\u202f"
    "\u205f-\u206f\u3000\u3002\ufeff\uff0e\uff61\\\\\udc80-\udcff]"
)
CONTROL = re.compile("[\u0000-\u001f\u007f-\u009f\udc80-\udcff]")
_PORT = re.compile("[0-9]{1,5}")
_IPV6 = re.compile(r"\[([0-9A-Fa-f:.]+)\](?::(.*))?")
_LABEL = re.compile("[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?")
_SCHEME = re.compile("([A-Za-z][A-Za-z0-9+.-]*)://")

MSG_LINK = {
    "pageEmpty": "That result has no page link.",
    "pageBad": "That page link has spaces, control characters or \\ in it.",
    "pageScheme": "That page link isn't http or https.",
    "pageUser": "That page link has a user name or password in it.",
    "pageHost": "That page link has no valid host.",
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


def page_link(text):
    if text == "":
        raise Refused(MSG_LINK["pageEmpty"])
    if BAD.search(text):
        raise Refused(MSG_LINK["pageBad"])
    parts = split_url(text)
    if not parts or parts[0] not in ("http", "https"):
        raise Refused(MSG_LINK["pageScheme"])
    if "@" in parts[1]:
        raise Refused(MSG_LINK["pageUser"])
    host = host_of(parts[1])
    if host is None:
        raise Refused(MSG_LINK["pageHost"])
    return "", host


def is_space(ch):
    # QString::trimmed's QChar::isSpace: \t-\r, space, U+0085, U+00A0 and
    # the Unicode separators (Zs, Zl, Zp).
    return ch in "\t\n\v\f\r \x85\xa0" or unicodedata.category(ch) in ("Zs", "Zl", "Zp")
