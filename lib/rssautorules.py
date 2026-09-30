#!/usr/bin/env python3
"""Slice 5b2 (RSS rules, OV14): the auto-download rule logic `qbt rss rule-*`
enforces. lib/rssrules.py stays 5b1's input rules.

Every rule and message comes from tests/fixtures/rss-autorules-cases.json;
the contract is tests/fixtures/rss-rules-contract.md. A regex is checked by
pcre2grep (the PCRE2 that qBittorrent's QRegularExpression uses), with the
pattern on a pipe, never on an argv and never by Python's `re` (which
refuses `\\K`, as PCRE2 doesn't).

The named functions: rule_name, check_field, fields_of, patch,
union_episodes, preview_join, preview_enabled and readback_ok.

CLI, for qbt and the tests. argv holds only the mode; every value and every
response body arrives on stdin (JSON never holds a raw NUL, so bodies are
NUL-separated). Exit 1 prints a refusal sentence, 2 is a usage error (the
case kinds print the usage sentence), 3 "that rule is gone", 4 an
unreadable body.
  <kind>           the case file's input as JSON -> its normalised value as JSON
  name             text -> the trimmed rule name
  check            key NUL value NUL useRegex -> {"ok": true, "value": ...}
  list             rules NUL preferences -> the `qbt rss rules` JSON
  has              name NUL rules -> "yes" or "no"
  shape            changes NUL snapshot NUL enable -> exit 0, or 2
  apply            name NUL changes NUL snapshot NUL enable NUL rules -> the ruleDef JSON
  readback         name NUL written NUL rules -> exit 0 when the rule reads back
  union            name NUL written NUL rules -> the rule to write again, or nothing
  readback-merged  name NUL merged NUL rules -> readback, and every merged episode kept
  preview          name NUL rules NUL matching NUL items -> the preview groups
  enabled          rules -> the enabled rules' names, a JSON list
  preview-enabled  rules NUL items (NUL name NUL matching)... -> {"rules", "will", "noTorrent"}
  created          name NUL feedUrl NUL rules -> exit 0 when the new rule reads back
  renamed          from NUL to NUL rules -> exit 0 when the rename reads back
  create-def       feedUrl -> the new rule's ruleDef JSON
`items` is rss/items?withData=true as qBittorrent sent it (flattened here by
lib/rssitems.py, as `qbt rss items` does).
"""
import copy
import email.utils
import json
import re
import shutil
import subprocess
import sys
from datetime import timezone

from linkrules import CONTROL, Refused, is_space
import rssitems

MSG = {
    "ruleUsage": "usage: qbt rss rules|rules-preview-enabled|rule-check|rule-create|rule-set|rule-preview|rule-rename|rule-remove",
    "ruleExists": "There's already a rule called <name>.",
    "ruleGone": "That rule is gone.",
    "ruleChanged": "<name> changed elsewhere; press r to reload it.",
    "ruleNameEmpty": "Enter a rule name.",
    "ruleNameControl": "Rule names can't contain control characters.",
    "badRegex": "That isn't a valid regular expression.",
    "regexUnchecked": "Couldn't check the regular expression.",
    "noPcre": "Checking regular expressions needs pcre2grep.",
    "badEpisode": "Use an episode filter such as 1x2;8-15;",
    "badDays": "Ignore for a whole number of days, 0 to 365.",
    "badSavePath": "Enter an absolute path, or leave it empty.",
    "multiLine": "Patterns go on one line.",
    "noTorrentBlock": "<m> matching articles have no torrent link, and qBittorrent would retry them forever. Tighten the rule first.",
    "unconfirmedSave": "Couldn't confirm the save.",
    "unconfirmedAdd": "Couldn't confirm <name> was added.",
    "unconfirmedRename": "Couldn't confirm the rename.",
    "unconfirmedRemove": "Couldn't confirm <name> was removed.",
}

# RULE_FIELDS' keys, in the editor's order; a change never holds `enabled`.
FIELD_KEYS = ("enabled", "mustContain", "mustNotContain", "useRegex", "episodeFilter", "smartFilter",
              "affectedFeeds", "category", "savePath", "addStopped", "ignoreDays")
CHANGE_KEYS = FIELD_KEYS[1:]
_STRINGS = ("mustContain", "mustNotContain", "episodeFilter", "category", "savePath")
_BOOLS = ("useRegex", "smartFilter")
_STOPPED = {"default": None, "yes": True, "no": False}
CHECK_KEYS = ("mustContain", "mustNotContain", "episodeFilter", "ignoreDays", "savePath")

_EPISODE = re.compile(r"[0-9]{1,4}[xX]([0-9]{1,4}(-([0-9]{1,4})?)?;)+")
_DIGITS = re.compile(r"[0-9]+")

# torrentParams keys serializeAddTorrentParams emits only when set; the
# rest it always emits (addtorrentparams.cpp).
TP_OPTIONAL = ("stopped", "content_layout", "use_auto_tmm", "add_to_top_of_queue", "stop_condition", "use_download_path")
TP_ALWAYS = ("category", "tags", "save_path", "download_path", "operating_mode", "skip_checking", "upload_limit",
             "download_limit", "seeding_time_limit", "inactive_seeding_time_limit", "share_limit_action",
             "ratio_limit", "ssl_certificate", "ssl_private_key", "ssl_dh_params")


class Usage(Exception):
    pass


class Unreadable(Exception):
    pass


def _fill(key, **values):
    text = MSG[key]
    for k, v in values.items():
        text = text.replace(f"<{k}>", str(v))
    return text


def _trim(text):
    start, end = 0, len(text)
    while start < end and is_space(text[start]):
        start += 1
    while end > start and is_space(text[end - 1]):
        end -= 1
    return text[start:end]


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


# --- the value kinds ------------------------------------------------------------------


def rule_name(text):
    """A new rule's name -> trimmed with Qt's isSpace set."""
    trimmed = _trim(text)
    if trimmed == "":
        raise Refused(MSG["ruleNameEmpty"])
    if CONTROL.search(trimmed):
        raise Refused(MSG["ruleNameControl"])
    return trimmed


def check_regex(value, use_regex):
    """The regex kind: the value as is, or a refusal. pcre2grep reads the
    pattern from its stdin (-f /dev/stdin, a pipe), never from argv."""
    if value == "":
        return ""
    if "\n" in value or "\r" in value:
        raise Refused(MSG["multiLine"])
    if not use_regex:
        return value
    exe = shutil.which("pcre2grep")
    if exe is None:
        raise Refused(MSG["noPcre"])
    try:
        data = value.encode("utf-8", "surrogateescape") + b"\n"
        r = subprocess.run([exe, "-u", "-i", "-f", "/dev/stdin", "/dev/null"], input=data,
                           capture_output=True, timeout=10)
    except (OSError, UnicodeEncodeError, subprocess.SubprocessError):
        raise Refused(MSG["regexUnchecked"])
    if r.returncode in (0, 1):
        return value
    if r.returncode == 2 and b"Error in regex" in r.stderr:
        raise Refused(MSG["badRegex"])
    raise Refused(MSG["regexUnchecked"])


def check_episode(text):
    trimmed = _trim(text)
    if trimmed == "":
        return ""
    if not _EPISODE.fullmatch(trimmed):
        raise Refused(MSG["badEpisode"])
    return trimmed


def check_days_text(text):
    trimmed = _trim(text)
    if not _DIGITS.fullmatch(trimmed):
        raise Refused(MSG["badDays"])
    digits = trimmed.lstrip("0") or "0"
    if len(digits) > 3 or int(digits) > 365:
        raise Refused(MSG["badDays"])
    return int(digits)


def check_save_path(text):
    trimmed = _trim(text)
    if trimmed == "":
        return ""
    if (CONTROL.search(trimmed) or not trimmed.startswith("/") or "//" in trimmed or "/./" in trimmed
            or "/../" in trimmed or trimmed.endswith("/.") or trimmed.endswith("/..")):
        raise Refused(MSG["badSavePath"])
    if trimmed != "/" and trimmed.endswith("/"):
        trimmed = trimmed[:-1]
    return trimmed


def check_field(key, value, use_regex):
    """`qbt rss rule-check`: one field's text by its kind -> the normalised
    value (ignoreDays: an int)."""
    if key in ("mustContain", "mustNotContain"):
        return check_regex(value, use_regex)
    if key == "episodeFilter":
        return check_episode(value)
    if key == "ignoreDays":
        return check_days_text(value)
    if key == "savePath":
        return check_save_path(value)
    raise Usage()


# --- a rule's fields (fromJsonObject) ---------------------------------------------


def _string(value):
    return value if isinstance(value, str) else ""


def _qt_int(value, default=0):
    """QJsonValue::toInt: an integral number within int range, else default."""
    if _is_int(value):
        return value if -2 ** 31 <= value < 2 ** 31 else default
    if isinstance(value, float) and value.is_integer() and -2 ** 31 <= value < 2 ** 31:
        return int(value)
    return default


def _string_list(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [_string(v) for v in value]
    return []


def fields_of(raw):
    """A rule's JSON -> its RULE_FIELDS values, read as fromJsonObject reads
    them (rss_autodownloadrule.cpp:490)."""
    o = raw if isinstance(raw, dict) else {}
    enabled = o.get("enabled")
    out = {
        "enabled": enabled if isinstance(enabled, bool) else True,
        "mustContain": _string(o.get("mustContain")),
        "mustNotContain": _string(o.get("mustNotContain")),
        "useRegex": o.get("useRegex") is True,
        "episodeFilter": _string(o.get("episodeFilter")),
        "smartFilter": o.get("smartFilter") is True,
        "affectedFeeds": _string_list(o.get("affectedFeeds")),
    }
    if "torrentParams" in o:
        tp = o["torrentParams"] if isinstance(o["torrentParams"], dict) else {}
        category, path, stopped = tp.get("category"), tp.get("save_path"), tp.get("stopped")
    else:
        category, path, stopped = o.get("assignedCategory"), o.get("savePath"), o.get("addPaused")
    out["category"] = _string(category)
    out["savePath"] = _string(path)
    out["addStopped"] = "yes" if stopped is True else "no" if stopped is False else "default"
    out["ignoreDays"] = _qt_int(o.get("ignoreDays"))
    return out


# --- rule-set: the shape, D6, OV13, D5/OV10 ------------------------------------------


def _change_type_ok(key, value):
    if key in _STRINGS:
        return isinstance(value, str)
    if key in _BOOLS:
        return isinstance(value, bool)
    if key == "affectedFeeds":
        return isinstance(value, list) and all(isinstance(v, str) for v in value)
    if key == "addStopped":
        return isinstance(value, str) and value in _STOPPED
    if key == "ignoreDays":
        return _is_int(value)
    return False


def check_shape(changes, snapshot, enable):
    """Step 0: anything else is the usage line (exit 2), before any request."""
    if enable not in ("keep", "off", "on") or not isinstance(changes, dict) or not isinstance(snapshot, dict):
        raise Usage()
    for key, value in changes.items():
        if key not in CHANGE_KEYS or not _change_type_ok(key, value):
            raise Usage()
    if enable == "on" and (changes or snapshot):
        raise Usage()
    if enable == "keep" and not changes:
        raise Usage()
    want = set(changes)
    if changes:
        want.add("enabled")
    if "savePath" in changes:
        want.add("useAutoTmm")
    if set(snapshot) != want:
        raise Usage()
    for key, value in snapshot.items():
        if key == "enabled":
            ok = isinstance(value, bool)
        elif key == "useAutoTmm":
            ok = value is None or isinstance(value, bool)
        else:
            ok = _change_type_ok(key, value)
        if not ok:
            raise Usage()


def _same(a, b):
    return json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)


def patch(current, changes, snapshot, enable, name=""):
    """rule-set's check-and-patch (the case file's `patch` kind) -> the
    ruleDef to post. Raises Usage, or Refused with the first sentence."""
    check_shape(changes, snapshot, enable)
    cur = fields_of(current)
    # D6: the changed keys, and enabled, as they were at the draft's start.
    for key in FIELD_KEYS:
        if key in snapshot and not _same(cur[key], snapshot[key]):
            raise Refused(_fill("ruleChanged", name=name))
    # OV13: only the changed fields, in RULE_FIELDS order.
    use_regex = changes.get("useRegex", cur["useRegex"])
    turning_on = changes.get("useRegex") is True and cur["useRegex"] is False
    value = {}
    for key in CHANGE_KEYS:
        if key in ("mustContain", "mustNotContain"):
            if key in changes:
                value[key] = check_regex(changes[key], use_regex)
            elif turning_on:
                check_regex(cur[key], True)
            continue
        if key not in changes:
            continue
        v = changes[key]
        if key == "episodeFilter":
            v = check_episode(v)
        elif key == "savePath":
            v = check_save_path(v)
        elif key == "ignoreDays" and not 0 <= v <= 365:
            raise Refused(MSG["badDays"])
        value[key] = v
    # D5: onto the current JSON, nothing else touched.
    out = copy.deepcopy(current) if isinstance(current, dict) else {}
    for key in ("mustContain", "mustNotContain", "useRegex", "episodeFilter", "smartFilter", "affectedFeeds", "ignoreDays"):
        if key in value:
            out[key] = value[key]
    has_tp = "torrentParams" in out
    if has_tp and any(k in value for k in ("category", "savePath", "addStopped")) and not isinstance(out["torrentParams"], dict):
        out["torrentParams"] = {}
    tp = out["torrentParams"] if has_tp else None
    if "category" in value:
        out["assignedCategory"] = value["category"]
        if has_tp:
            tp["category"] = value["category"]
    if "savePath" in value:
        path = value["savePath"]
        out["savePath"] = path
        if has_tp and path != "":
            tp["save_path"] = path
            tp["use_auto_tmm"] = False
        elif has_tp:
            # OV10: back to what it was when the draft started.
            tp.pop("save_path", None)
            if snapshot["useAutoTmm"] is None:
                tp.pop("use_auto_tmm", None)
            else:
                tp["use_auto_tmm"] = snapshot["useAutoTmm"]
    if "addStopped" in value:
        stopped = _STOPPED[value["addStopped"]]
        out["addPaused"] = stopped
        if has_tp and stopped is None:
            tp.pop("stopped", None)
        elif has_tp:
            tp["stopped"] = stopped
    out["enabled"] = True if enable == "on" else False if enable == "off" else cur["enabled"]
    return out


# --- the read-backs and OV9 -----------------------------------------------------------


def _tp_value(key, value):
    """A torrentParams value as it compares after qBittorrent's round trip."""
    if key == "tags" and isinstance(value, list):
        return sorted({_string(v) for v in value})
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if isinstance(value, (int, float)):
        return float(value)
    return value


def readback_ok(written, reread):
    """Every field, and every other key qBittorrent keeps, reads back as
    written (lastMatch and previouslyMatchedEpisodes are OV9's)."""
    if not isinstance(reread, dict):
        return False
    if fields_of(written) != fields_of(reread):
        return False
    w = written if isinstance(written, dict) else {}
    if "priority" in w and _qt_int(w["priority"]) != _qt_int(reread.get("priority")):
        return False
    tp_w = w.get("torrentParams")
    if isinstance(tp_w, dict):
        tp_r = reread.get("torrentParams")
        if not isinstance(tp_r, dict):
            return False
        for key in TP_ALWAYS:
            if key in tp_w and _tp_value(key, tp_w[key]) != _tp_value(key, tp_r.get(key)):
                return False
        for key in TP_OPTIONAL:
            present = key in tp_w and tp_w[key] is not None
            if present != (key in tp_r and tp_r[key] is not None):
                return False
            if present and _tp_value(key, tp_w[key]) != _tp_value(key, tp_r[key]):
                return False
    return True


def _when(text):
    """RFC 2822 -> a timestamp; unparsable or empty is the oldest (None)."""
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
        return when.timestamp()
    except (OverflowError, ValueError, OSError):
        return None


def union_episodes(written, reread):
    """OV9 -> the re-read rule with the merged episode memory and the later
    lastMatch, or None when the re-read rule already holds both."""
    wl = _string_list(written.get("previouslyMatchedEpisodes"))
    rl = _string_list(reread.get("previouslyMatchedEpisodes"))
    merged, seen = list(wl), set(wl)
    for e in rl:
        if e not in seen:
            merged.append(e)
            seen.add(e)
    lw, lr = written.get("lastMatch"), reread.get("lastMatch")
    tw, tr = _when(lw), _when(lr)
    later = lw if tw is not None and (tr is None or tw > tr) else lr
    if merged == rl and later == lr:
        return None
    out = copy.deepcopy(reread)
    out["previouslyMatchedEpisodes"] = merged
    out["lastMatch"] = later if later is not None else ""
    return out


# --- the preview (D4, OV4, OV5) --------------------------------------------------------


def preview_join(items, matching, rule):
    """The `previewJoin` kind: {will, read, noTorrent, unpreviewable, gone}."""
    feeds = [f for f in (items.get("feeds") or []) if isinstance(f, dict) and not f.get("folder")]
    articles = [a for a in (items.get("articles") or []) if isinstance(a, dict)]
    matching = matching if isinstance(matching, dict) else {}
    urls = []
    for u in fields_of(rule)["affectedFeeds"]:
        if u not in urls:
            urls.append(u)
    by_url = {}
    for f in feeds:
        by_url.setdefault(f.get("url"), f)
    gone = [u for u in urls if u not in by_url]
    resolved = {by_url[u]["path"] for u in urls if u in by_url}
    mine = [f for f in feeds if f["path"] in resolved]
    counts = {}
    for f in mine:
        counts[f["name"]] = counts.get(f["name"], 0) + 1
    unpreviewable, titles = [], {}
    for f in mine:
        if counts[f["name"]] > 1:
            group = next((g for g in unpreviewable if g["name"] == f["name"]), None)
            if group is None:
                unpreviewable.append({"name": f["name"], "feedPaths": [f["path"]]})
            else:
                group["feedPaths"].append(f["path"])
        else:
            listed = matching.get(f["name"])
            titles[f["path"]] = {t for t in listed if isinstance(t, str)} if isinstance(listed, list) else set()
    dup = {}
    for a in articles:
        k = (a.get("feedPath"), a.get("title"))
        dup[k] = dup.get(k, 0) + 1
    out = {"will": [], "read": [], "noTorrent": [], "unpreviewable": unpreviewable, "gone": gone}
    for a in articles:
        path, title = a.get("feedPath"), a.get("title")
        if path not in titles or title not in titles[path]:
            continue
        row = {"feedPath": path, "guid": a.get("guid"), "title": title, "dup": dup[(path, title)]}
        if a.get("isRead") is True:
            out["read"].append(row)
        elif a.get("hasTorrent") is True:
            out["will"].append(row)
        elif (a.get("torrentURL") or a.get("link") or "") != "":
            out["noTorrent"].append(row)
    return out


def preview_enabled(rules, items, matchings):
    """rules-preview-enabled: every enabled rule's join, each article counted
    once by feedPath and guid (first match wins)."""
    will, no_torrent, r = set(), set(), 0
    for name in enabled_names(rules):
        r += 1
        groups = preview_join(items, matchings.get(name), rules[name])
        will.update((x["feedPath"], x["guid"]) for x in groups["will"])
        no_torrent.update((x["feedPath"], x["guid"]) for x in groups["noTorrent"])
    return {"rules": r, "will": len(will), "noTorrent": len(no_torrent)}


def _sorted_names(rules):
    return sorted(rules, key=lambda n: (n.lower(), n))


def enabled_names(rules):
    return [n for n in _sorted_names(rules) if fields_of(rules[n])["enabled"]]


def list_rules(rules, prefs):
    out = []
    for name in _sorted_names(rules):
        fields = fields_of(rules[name])
        out.append({"name": name, "enabled": fields["enabled"], "fields": fields, "raw": rules[name]})
    return {"autoDownload": prefs.get("rss_auto_downloading_enabled") is True, "rules": out}


# --- the case kinds ---------------------------------------------------------------------


def check(kind, value):
    """(ok, normalised, message) for one case-file input."""
    try:
        if kind == "ruleName":
            return True, rule_name(value), None
        if kind == "regex":
            return True, check_regex(value["value"], value["useRegex"] is True), None
        if kind == "episode":
            return True, check_episode(value), None
        if kind == "ignoreDays":
            return True, check_days_text(value), None
        if kind == "savePath":
            return True, check_save_path(value), None
        if kind == "fields":
            return True, fields_of(value), None
        if kind == "patch":
            return True, patch(value["current"], value["changes"], value["snapshot"], value["enable"],
                               name=value["name"]), None
        if kind == "previewJoin":
            return True, preview_join(value["items"], value["matching"], value["rule"]), None
    except Refused as exc:
        return False, None, exc.message
    except Usage:
        return False, None, MSG["ruleUsage"]
    raise KeyError(kind)


KINDS = ("ruleName", "regex", "episode", "ignoreDays", "savePath", "fields", "patch", "previewJoin")


# --- CLI ------------------------------------------------------------------------------


def _stdin():
    return sys.stdin.buffer.read().decode("utf-8", "surrogateescape")


def _fields(n=None):
    fields = _stdin().split("\0")
    if n is not None and len(fields) != n:
        raise Usage()
    return fields


def _json(text):
    try:
        return json.loads(text)
    except ValueError:
        raise Unreadable()


def _rules(text):
    rules = _json(text)
    if not isinstance(rules, dict):
        raise Unreadable()
    return rules


def _items(text):
    try:
        return rssitems.flatten(_json(text), False, None)
    except rssitems.Unreadable:
        raise Unreadable()


def _dump(obj):
    return json.dumps(obj, ensure_ascii=True, separators=(",", ":"))


def _write(text):
    sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))


def _rule_of(rules, name):
    if name not in rules:
        raise SystemExit(3)
    return rules[name]


def run(argv):
    if len(argv) != 2:
        raise Usage()
    mode = argv[1]
    if mode in KINDS:
        try:
            value = json.loads(_stdin())
        except ValueError:
            raise Usage()
        try:
            ok, normalised, message = check(mode, value)
        except (KeyError, TypeError, AttributeError):
            raise Usage()
        if not ok:
            _write(message)
            return 2 if message == MSG["ruleUsage"] else 1
        _write(_dump(normalised))
        return 0
    if mode == "name":
        _write(rule_name(_stdin()))
        return 0
    if mode == "check":
        key, value, use_regex = _fields(3)
        if key not in CHECK_KEYS or use_regex not in ("true", "false"):
            raise Usage()
        _write(_dump({"ok": True, "value": check_field(key, value, use_regex == "true")}))
        return 0
    if mode == "list":
        rules, prefs = _fields(2)
        prefs = _json(prefs)
        if not isinstance(prefs, dict):
            raise Unreadable()
        _write(_dump(list_rules(_rules(rules), prefs)))
        return 0
    if mode == "has":
        name, rules = _fields(2)
        _write("yes" if name in _rules(rules) else "no")
        return 0
    if mode == "shape":
        changes, snapshot, enable = _fields(3)
        try:
            check_shape(json.loads(changes), json.loads(snapshot), enable)
        except ValueError:
            raise Usage()
        return 0
    if mode == "apply":
        name, changes, snapshot, enable, rules = _fields(5)
        try:
            changes, snapshot = json.loads(changes), json.loads(snapshot)
        except ValueError:
            raise Usage()
        check_shape(changes, snapshot, enable)
        current = _rule_of(_rules(rules), name)
        _write(_dump(patch(current, changes, snapshot, enable, name=name)))
        return 0
    if mode in ("readback", "union", "readback-merged"):
        name, written, rules = _fields(3)
        written, rules = _json(written), _rules(rules)
        if name not in rules or not isinstance(written, dict):
            return 1
        reread = rules[name]
        if mode == "union":
            merged = union_episodes(written, reread) if isinstance(reread, dict) else None
            if merged is not None:
                _write(_dump(merged))
            return 0
        if not readback_ok(written, reread):
            return 1
        if mode == "readback-merged":
            kept = set(_string_list(reread.get("previouslyMatchedEpisodes")))
            if not set(_string_list(written.get("previouslyMatchedEpisodes"))) <= kept:
                return 1
        return 0
    if mode == "preview":
        name, rules, matching, items = _fields(4)
        rule = _rule_of(_rules(rules), name)
        _write(_dump(preview_join(_items(items), _json(matching), rule)))
        return 0
    if mode == "enabled":
        (rules,) = _fields(1)
        _write(_dump(enabled_names(_rules(rules))))
        return 0
    if mode == "preview-enabled":
        fields = _fields()
        if len(fields) < 2 or len(fields) % 2:
            raise Usage()
        rules, items = _rules(fields[0]), _items(fields[1])
        matchings = {fields[i]: _json(fields[i + 1]) for i in range(2, len(fields), 2)}
        _write(_dump(preview_enabled(rules, items, matchings)))
        return 0
    if mode == "created":
        name, feed_url, rules = _fields(3)
        rules = _rules(rules)
        if name not in rules:
            return 1
        f = fields_of(rules[name])
        return 0 if f["enabled"] is False and f["affectedFeeds"] == ([feed_url] if feed_url else []) else 1
    if mode == "renamed":
        old, new, rules = _fields(3)
        rules = _rules(rules)
        return 0 if old not in rules and new in rules else 1
    if mode == "create-def":
        (feed_url,) = _fields(1)
        _write(_dump({"enabled": False, "affectedFeeds": [feed_url] if feed_url else []}))
        return 0
    raise Usage()


def main(argv):
    try:
        return run(argv)
    except Refused as exc:
        _write(exc.message)
        return 1
    except Usage:
        if len(argv) == 2 and argv[1] in KINDS:
            _write(MSG["ruleUsage"])
        return 2
    except Unreadable:
        return 4
    except SystemExit as exc:
        return exc.code if isinstance(exc.code, int) else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
