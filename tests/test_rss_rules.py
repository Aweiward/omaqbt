"""Slice 5b2 (Task 2): `qbt rss rule-*` against the fixture's qBittorrent
5.2.3 auto-download rules (rss/rules, setRule, renameRule, removeRule,
matchingArticles), and lib/rssautorules.py against every case in
tests/fixtures/rss-autorules-cases.json.

The contract is tests/fixtures/rss-rules-contract.md. Every message these
tests expect is read from the case file (its cases and sentences), never
retyped. Values reach qbt on stdin, NUL-separated; a refusal prints one
sentence on stderr and exits 1, the usage line exits 2, and a refused
value sends no request at all (a refused save sends no POST).
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "fixtures"))
sys.path.insert(0, str(ROOT / "lib"))
import harness  # noqa: E402
import rssautorules  # noqa: E402

QBT = os.environ.get("QBT_UNDER_TEST", str(ROOT / "qbt"))
LIB = ROOT / "lib" / "rssautorules.py"
DATA = json.loads((ROOT / "tests" / "fixtures" / "rss-autorules-cases.json").read_text())
CASES = DATA["cases"]
S = DATA["sentences"]
RSS_USAGE = json.loads((ROOT / "tests" / "fixtures" / "rss-rules-cases.json").read_text())["sentences"]["rssUsage"]
PREFS_DUMP = ROOT / "tests" / "fixtures" / "preferences-5.2.3.json"
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
KINDS = ("ruleName", "regex", "episode", "ignoreDays", "savePath", "fields", "patch", "previewJoin")
FIELD_KEYS = ["enabled", "mustContain", "mustNotContain", "useRegex", "episodeFilter", "smartFilter",
              "affectedFeeds", "category", "savePath", "addStopped", "ignoreDays"]

DEBIAN_URL = "https://www.debian.org/security/dsa"
ARCH_URL = "https://archlinux.org/feeds/news/"
TV_URL = "https://tv.example/rss/show"
ANIME_URL = "https://anime.example/rss/show"
GONE_URL = "https://gone.example/rss"
DATE = "Mon, 29 Sep 2025 10:00:00 +0000"


def cases(kind):
    return [c for c in CASES if c["kind"] == kind]


def sentence(key, **values):
    text = S[key]
    for k, v in values.items():
        text = text.replace(f"<{k}>", str(v))
    return text


def full_rule():
    """Review Focus 1: a rule made in the WebUI, as qBittorrent 5.2.3 emits it
    (tags, content layout, a download limit, priority 2, a lastMatch and 6
    remembered episodes), straight from the case file's first patch row."""
    return copy.deepcopy(cases("patch")[0]["input"]["current"])


def legacy_rule():
    for c in cases("patch"):
        if c["why"].startswith("a legacy rule without torrentParams"):
            return copy.deepcopy(c["input"]["current"])
    raise AssertionError("no legacy rule row")


def article(aid, title, link, torrent_url=None, read=False):
    a = {"id": aid, "date": DATE, "title": title, "author": "", "description": "",
         "torrentURL": link if torrent_url is None else torrent_url, "link": link}
    if read:
        a["isRead"] = True
    return a


def feed(uid, url, articles=()):
    return {"uid": "{%08d-0000-4000-8000-000000000000}" % uid, "url": url, "title": "",
            "lastBuildDate": "", "isLoading": False, "hasError": False, "articles": list(articles)}


def tree():
    """Anime {Show}, Linux {Arch, Debian}, TV {Show}: two feeds called Show,
    three unread-or-read articles titled "Arch news", and every D4 group."""
    return {
        "Anime": {"Show": feed(1, ANIME_URL, [
            article("an1", "Show S01E07 1080p", "https://anime.example/t/an1",
                    "magnet:?xt=urn:btih:" + "a" * 40)])},
        "Linux": {
            "Arch": feed(2, ARCH_URL, [
                article("ar1", "Arch news", "https://archlinux.org/a1.torrent"),
                article("ar2", "Arch news", "https://archlinux.org/a2.torrent"),
                article("ar3", "Arch news", "https://archlinux.org/a3.torrent", read=True),
            ]),
            "Debian": feed(3, DEBIAN_URL, [
                article("d1", "DSA-6000 openssl", "https://www.debian.org/security/2026/dsa-6000",
                        "magnet:?xt=urn:btih:" + "b" * 40),
                article("d2", "DSA-6001 curl", "https://www.debian.org/security/2026/dsa-6001",
                        "magnet:?xt=urn:btih:" + "c" * 40, read=True),
                article("d3", "DSA-6002 news", "https://www.debian.org/security/2026/dsa-6002"),
                article("d5", "DSA-6004 empty", "", ""),
                article("d6", "DSA-6005 zlib", "https://www.debian.org/security/2026/dsa-6005",
                        "https://www.debian.org/t/6005.torrent"),
            ]),
        },
        "TV": {"Show": feed(4, TV_URL, [
            article("tv1", "Show S01E07 1080p", "https://tv.example/t/tv1.torrent"),
            article("tv2", "Show S01E08 1080p", "https://tv.example/t/tv2.torrent", read=True),
        ])},
    }


def disabled(feeds, **extra):
    rule = {"enabled": False, "affectedFeeds": list(feeds)}
    rule.update(extra)
    return rule


def no_pcre_path():
    """A directory of symlinks to every command on PATH except pcre2grep."""
    farm = Path(tempfile.mkdtemp(prefix="qbt-nopcre-"))
    for d in os.environ["PATH"].split(os.pathsep):
        if not d or not os.path.isdir(d):
            continue
        for name in os.listdir(d):
            if name == "pcre2grep" or (farm / name).exists() or (farm / name).is_symlink():
                continue
            src = os.path.join(d, name)
            if os.path.isfile(src) and os.access(src, os.X_OK):
                (farm / name).symlink_to(src)
    return farm


class LibCasesTest(unittest.TestCase):
    """Every case row through lib/rssautorules.py and its CLI."""

    def test_every_case_through_the_lib(self):
        seen = set()
        for c in CASES:
            with self.subTest(kind=c["kind"], why=c["why"]):
                ok, normalised, message = rssautorules.check(c["kind"], c["input"])
                self.assertEqual(ok, c["ok"], c["why"])
                if c["ok"]:
                    self.assertEqual(normalised, c["normalised"], c["why"])
                else:
                    self.assertEqual(message, c["message"], c["why"])
            seen.add(c["kind"])
        self.assertEqual(seen, set(KINDS))
        self.assertGreater(len(CASES), 170)

    def test_every_case_through_the_cli(self):
        for c in CASES:
            r = subprocess.run([sys.executable, str(LIB), c["kind"]], input=json.dumps(c["input"]).encode(),
                               capture_output=True)
            with self.subTest(kind=c["kind"], why=c["why"]):
                if c["ok"]:
                    self.assertEqual((r.returncode, r.stderr), (0, b""), c["why"])
                    self.assertEqual(json.loads(r.stdout), c["normalised"], c["why"])
                else:
                    code = 2 if c["message"] == S["ruleUsage"] else 1
                    self.assertEqual((r.returncode, r.stdout.decode()), (code, c["message"]), c["why"])

    def test_the_cli_usage(self):
        for argv in ((), ("nope",), ("regex", "extra")):
            r = subprocess.run([sys.executable, str(LIB), *argv], input=b"", capture_output=True)
            self.assertEqual(r.returncode, 2, argv)
        r = subprocess.run([sys.executable, str(LIB), "regex"], input=b"not json", capture_output=True)
        self.assertEqual(r.returncode, 2)

    def test_every_message_is_a_case_file_sentence(self):
        self.assertEqual(rssautorules.MSG, S)

    def test_the_named_functions(self):
        self.assertEqual(rssautorules.rule_name("  Show "), "Show")
        with self.assertRaises(rssautorules.Refused) as cm:
            rssautorules.rule_name("")
        self.assertEqual(cm.exception.message, S["ruleNameEmpty"])
        self.assertEqual(rssautorules.check_field("ignoreDays", " 007 ", False), 7)
        self.assertEqual(rssautorules.check_field("savePath", "/media/tv/", False), "/media/tv")
        self.assertEqual(rssautorules.check_field("mustContain", "(", False), "(")
        self.assertEqual(rssautorules.fields_of({})["enabled"], True)
        self.assertEqual(list(rssautorules.fields_of({}).keys()), FIELD_KEYS)
        row = cases("patch")[0]["input"]
        out = rssautorules.patch(row["current"], row["changes"], row["snapshot"], row["enable"], name=row["name"])
        self.assertEqual(out, cases("patch")[0]["normalised"])
        pj = cases("previewJoin")[0]["input"]
        self.assertEqual(rssautorules.preview_join(pj["items"], pj["matching"], pj["rule"]),
                         cases("previewJoin")[0]["normalised"])

    def test_union_episodes(self):
        written = full_rule()
        reread = copy.deepcopy(written)
        # Nothing new either way: nothing more to write.
        self.assertIsNone(rssautorules.union_episodes(written, reread))
        # The auto-downloader appended an episode after the write: reread
        # already holds the union.
        reread["previouslyMatchedEpisodes"].append("1x7")
        reread["lastMatch"] = "29 Sep 2026 20:00:00 +0000"
        self.assertIsNone(rssautorules.union_episodes(written, reread))
        # The reread lost 1x2 and gained 1x7: the written list, then the new
        # entries in the re-read order; lastMatch the later one.
        reread = copy.deepcopy(written)
        reread["previouslyMatchedEpisodes"] = ["1x1", "1x3", "1x4", "1x5", "1x6", "1x7"]
        reread["lastMatch"] = "1 Jan 2026 00:00:00 +0000"
        merged = rssautorules.union_episodes(written, reread)
        self.assertEqual(merged["previouslyMatchedEpisodes"], ["1x1", "1x2", "1x3", "1x4", "1x5", "1x6", "1x7"])
        self.assertEqual(merged["lastMatch"], written["lastMatch"])
        # Everything else is the re-read rule's.
        reread["mustContain"] = "changed"
        self.assertEqual(rssautorules.union_episodes(written, reread)["mustContain"], "changed")
        # An unparsable or empty lastMatch is the oldest.
        r2 = copy.deepcopy(written)
        r2["lastMatch"] = "junk"
        self.assertEqual(rssautorules.union_episodes(written, r2)["lastMatch"], written["lastMatch"])
        w2 = copy.deepcopy(written)
        w2["lastMatch"] = "junk"
        r2["lastMatch"] = ""
        self.assertIsNone(rssautorules.union_episodes(w2, r2), "two oldest: the re-read one stays")
        r2["lastMatch"] = "1 Jan 2000 00:00:00 +0000"
        self.assertIsNone(rssautorules.union_episodes(w2, r2))

    def test_the_regex_is_never_pythons_re(self):
        text = LIB.read_text()
        self.assertNotIn("re.compile(pattern", text)
        self.assertIn("pcre2grep", text)


class Pcre2Test(unittest.TestCase):
    """The regex kind through the real pcre2grep, and its failure modes."""

    def check(self, value, use_regex=True, key="mustContain"):
        try:
            return True, rssautorules.check_field(key, value, use_regex)
        except rssautorules.Refused as exc:
            return False, exc.message

    def test_the_real_pcre2grep(self):
        self.assertIsNotNone(shutil.which("pcre2grep"), "pcre2grep must be installed for these tests")
        self.assertEqual(self.check("("), (False, S["badRegex"]))
        self.assertEqual(self.check("\\K"), (True, "\\K"))
        self.assertEqual(self.check("a++b"), (True, "a++b"))
        self.assertEqual(self.check("(?<=a+)b"), (False, S["badRegex"]))
        self.assertEqual(self.check("(", key="mustNotContain"), (False, S["badRegex"]))

    def test_checked_only_when_use_regex(self):
        self.assertEqual(self.check("(", use_regex=False), (True, "("))
        self.assertEqual(self.check("", use_regex=True), (True, ""))

    def test_a_multi_line_pattern(self):
        for use_regex in (True, False):
            self.assertEqual(self.check("Show\nS01", use_regex), (False, S["multiLine"]))
            self.assertEqual(self.check("Show\r", use_regex), (False, S["multiLine"]))

    def with_path(self, path):
        old = os.environ["PATH"]
        os.environ["PATH"] = str(path)
        self.addCleanup(os.environ.__setitem__, "PATH", old)

    def test_no_pcre2grep(self):
        empty = Path(tempfile.mkdtemp(prefix="qbt-empty-"))
        self.addCleanup(shutil.rmtree, empty, True)
        self.with_path(empty)
        self.assertEqual(self.check("x"), (False, S["noPcre"]))
        # Not needed when nothing is a regex.
        self.assertEqual(self.check("x", use_regex=False), (True, "x"))

    def shim(self, body):
        d = Path(tempfile.mkdtemp(prefix="qbt-pcre-shim-"))
        self.addCleanup(shutil.rmtree, d, True)
        (d / "pcre2grep").write_text("#!/bin/sh\n" + body)
        (d / "pcre2grep").chmod(0o755)
        return d

    def test_an_exit_2_without_a_compile_message(self):
        self.with_path(self.shim("echo 'pcre2grep: something else' >&2\nexit 2\n"))
        self.assertEqual(self.check("x"), (False, S["regexUnchecked"]))

    def test_any_other_exit(self):
        self.with_path(self.shim("exit 3\n"))
        self.assertEqual(self.check("x"), (False, S["regexUnchecked"]))

    def test_a_too_long_pattern(self):
        self.assertEqual(self.check("a" * 10031), (False, S["regexUnchecked"]))

    def test_the_pattern_goes_on_a_pipe_never_argv(self):
        d = Path(tempfile.mkdtemp(prefix="qbt-pcre-log-"))
        self.addCleanup(shutil.rmtree, d, True)
        real = shutil.which("pcre2grep")
        log = d / "argv.log"
        (d / "pcre2grep").write_text(f'#!/bin/bash\nprintf "%s " "$@" >>"{log}"\necho >>"{log}"\nexec "{real}" "$@"\n')
        (d / "pcre2grep").chmod(0o755)
        self.with_path(f"{d}:{os.environ['PATH']}")
        self.assertEqual(self.check("MARKER-(a|b)"), (True, "MARKER-(a|b)"))
        self.assertEqual(self.check("-MARKER("), (False, S["badRegex"]))
        logged = log.read_text()
        self.assertEqual(logged.count("\n"), 2)
        self.assertNotIn("MARKER", logged)


class RulesCase(unittest.TestCase):
    """One fixture per class, with the 5.2.3 preferences dump; every test
    starts from tree(), no rules, no faults."""

    @classmethod
    def setUpClass(cls):
        cls._cm = harness.fixture_server(extra_env=dict(UTF8_ENV, QBT_FIXTURE_PREFS=str(PREFS_DUMP)))
        cls.port, cls.env = cls._cm.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls._cm.__exit__(None, None, None)

    def setUp(self):
        self.control({})
        self.reset()
        self.set_pref("rss_auto_downloading_enabled", False)

    def tearDown(self):
        self.control({})

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def reset(self, t=None, rules=None):
        body = json.dumps({"tree": tree() if t is None else t, "rules": rules or {}}).encode()
        req = urllib.request.Request(self.url("/fixture/rss-reset"), data=body, method="POST")
        urllib.request.urlopen(req, timeout=5).read()

    def control(self, value):
        Path(self.env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(value))

    def rules_state(self):
        return json.loads(urllib.request.urlopen(self.url("/fixture/rss-state"), timeout=5).read())["rules"]

    def set_pref(self, key, value):
        body = ("json=" + urllib.request.quote(json.dumps({key: value}))).encode()
        urllib.request.urlopen(urllib.request.Request(self.url("/api/v2/app/setPreferences"), data=body,
                                                      method="POST"), timeout=5).read()

    def raw(self, method, path, body=None):
        data = body.encode() if body is not None else None
        req = urllib.request.Request(self.url(path), data=data, method=method)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def rss(self, sub, *fields, raw=None, env=None, argv=None):
        full = dict(self.env)
        full.update(env or {})
        data = raw if raw is not None else "\0".join(fields).encode("utf-8")
        args = argv if argv is not None else ["rss", sub]
        return subprocess.run([QBT, *args], env=full, input=data, capture_output=True, timeout=60)

    def rule_set(self, name, changes, snapshot, enable="keep", env=None):
        return self.rss("rule-set", name, json.dumps(changes), json.dumps(snapshot), enable, env=env)

    def log(self):
        path = Path(self.env["QBT_FIXTURE_LOG"])
        for _ in range(20):
            try:
                return json.loads(path.read_text() or "[]")
            except ValueError:
                time.sleep(0.05)
        raise AssertionError("unreadable fixture log")

    def since(self, before):
        return self.log()[before:]

    def posts_since(self, before, path=None):
        return [e for e in self.since(before) if e["method"] == "POST" and (path is None or e["path"] == path)]

    def form(self, entry):
        return parse_qs(entry["body"], keep_blank_values=True)

    def set_rule_posts(self, before):
        return [json.loads(self.form(e)["ruleDef"][0]) for e in self.posts_since(before, "/api/v2/rss/setRule")]

    def ok(self, r, expected):
        self.assertEqual((r.returncode, r.stderr.decode()), (0, ""))
        self.assertEqual(json.loads(r.stdout), expected)
        self.assertTrue(r.stdout.endswith(b"\n") and r.stdout.count(b"\n") == 1)

    def refused(self, r, message, code=1):
        self.assertEqual((r.returncode, r.stdout.decode(), r.stderr.decode()), (code, "", message + "\n"))

    def refused_before_any_request(self, sub, fields, message, code=1):
        before = len(self.log())
        self.refused(self.rss(sub, *fields), message, code)
        self.assertEqual(self.since(before), [], f"{sub} {fields!r}: no request")

    def refused_without_a_post(self, r, message, before, code=1):
        self.refused(r, message, code)
        self.assertEqual(self.posts_since(before), [], "no POST")


class UsageTest(RulesCase):
    def test_wrong_field_counts_are_the_rule_usage_line(self):
        before = len(self.log())
        counts = {"rule-preview": 1, "rule-remove": 1, "rule-create": 2, "rule-rename": 2, "rule-check": 3, "rule-set": 4}
        for sub, k in counts.items():
            for n in (k - 1, k + 1):
                if n < 1:
                    continue
                with self.subTest(sub=sub, fields=n):
                    self.refused(self.rss(sub, *(["x"] * n)), S["ruleUsage"], 2)
            self.refused(self.rss(sub, raw=("\0".join(["x"] * k) + "\0").encode()), S["ruleUsage"], 2)
        self.assertEqual(self.since(before), [])

    def test_bare_and_unknown_still_print_5b1s_usage(self):
        before = len(self.log())
        self.refused(self.rss("", argv=["rss"]), RSS_USAGE, 2)
        for sub in ("rule", "RULES", "rule-sets", "rules-preview"):
            self.refused(self.rss(sub), RSS_USAGE, 2)
        self.refused(self.rss("rules", argv=["rss", "rules", "extra"]), RSS_USAGE, 2)
        self.assertEqual(self.since(before), [])

    def test_rules_reads_no_stdin(self):
        self.assertEqual(self.rss("rules", raw=b"junk\0junk").returncode, 0)
        self.assertEqual(self.rss("rules-preview-enabled", raw=b"junk").returncode, 0)

    def test_rule_check_shapes(self):
        for fields in (("nope", "x", "false"), ("enabled", "true", "false"), ("category", "tv", "false"),
                       ("mustContain", "x", "yes"), ("episodeFilter", "1x2;", "TRUE"), ("savePath", "/a", "")):
            with self.subTest(fields=fields):
                self.refused_before_any_request("rule-check", fields, S["ruleUsage"], 2)

    def test_rule_set_shapes(self):
        self.reset(rules={"Show": full_rule()})
        bad = [
            ("not json", "{}", "keep"),
            ("[]", "{}", "keep"),
            ('{"mustContain": "x"}', '{"mustContain": "Show", "enabled": false}', "maybe"),
            ('{"enabled": true}', '{"enabled": false}', "keep"),
            ('{"priority": 3}', '{"priority": 2, "enabled": false}', "keep"),
            ('{"mustContain": 5}', '{"mustContain": "Show", "enabled": false}', "keep"),
            ('{"useRegex": "true"}', '{"useRegex": false, "enabled": false}', "keep"),
            ('{"ignoreDays": "7"}', '{"ignoreDays": 0, "enabled": false}', "keep"),
            ('{"ignoreDays": 7.5}', '{"ignoreDays": 0, "enabled": false}', "keep"),
            ('{"ignoreDays": true}', '{"ignoreDays": 0, "enabled": false}', "keep"),
            ('{"addStopped": "maybe"}', '{"addStopped": "default", "enabled": false}', "keep"),
            ('{"affectedFeeds": "x"}', '{"affectedFeeds": [], "enabled": false}', "keep"),
            ('{"affectedFeeds": [1]}', '{"affectedFeeds": [], "enabled": false}', "keep"),
            ('{"savePath": "/a"}', '{"savePath": "", "enabled": false}', "keep"),
            ('{"savePath": "/a"}', '{"savePath": "", "enabled": false, "useAutoTmm": "yes"}', "keep"),
            ('{"mustContain": "x"}', '{"mustContain": "Show", "enabled": false, "useAutoTmm": null}', "keep"),
            ('{"mustContain": "x"}', '{"mustContain": "Show", "enabled": "no"}', "keep"),
            ('{"mustContain": "x"}', '{"mustContain": 5, "enabled": false}', "keep"),
            ('{"mustContain": "x"}', "{}", "keep"),
            ("{}", "{}", "keep"),
            ('{"mustContain": "x"}', '{"mustContain": "Show", "enabled": false}', "on"),
            ("{}", '{"enabled": false}', "on"),
            ("{}", '{"enabled": false}', "off"),
        ]
        for changes, snapshot, enable in bad:
            with self.subTest(changes=changes, snapshot=snapshot, enable=enable):
                self.refused_before_any_request("rule-set", ("Show", changes, snapshot, enable), S["ruleUsage"], 2)


class RulesListTest(RulesCase):
    def test_sorted_with_fields_and_raw(self):
        rule = full_rule()
        self.reset(rules={"b": disabled([]), "Show": rule, "a": disabled([TV_URL]), "A": {}})
        before = len(self.log())
        r = self.rss("rules")
        self.assertEqual((r.returncode, r.stderr), (0, b""))
        out = json.loads(r.stdout)
        self.assertEqual(out["autoDownload"], False)
        self.assertEqual([x["name"] for x in out["rules"]], ["A", "a", "b", "Show"])
        show = out["rules"][3]
        self.assertEqual(show["raw"], rule)
        self.assertEqual(show["fields"], rssautorules.fields_of(rule))
        self.assertEqual(show["enabled"], False)
        self.assertEqual(out["rules"][0]["enabled"], True)
        self.assertEqual(list(show["fields"].keys()), FIELD_KEYS)
        self.assertEqual({e["path"] for e in self.since(before)}, {"/api/v2/rss/rules", "/api/v2/app/preferences"})
        self.assertEqual(self.posts_since(before), [])

    def test_auto_download_follows_the_preferences(self):
        self.set_pref("rss_auto_downloading_enabled", True)
        self.assertEqual(json.loads(self.rss("rules").stdout), {"autoDownload": True, "rules": []})

    def test_read_failures_report_codes_only(self):
        self.control({"rss_rules": "409secret"})
        r = self.rss("rules")
        self.assertEqual(r.returncode, 1)
        self.assertIn("HTTP 409", r.stderr.decode())
        self.assertNotIn("passkey", r.stderr.decode().lower())
        self.control({"rss_rules": "unreadable"})
        self.refused(self.rss("rules"), "qBittorrent sent something unreadable")


class RuleCheckTest(RulesCase):
    def test_every_value_case(self):
        before = len(self.log())
        for c in CASES:
            if c["kind"] not in ("regex", "episode", "ignoreDays", "savePath"):
                continue
            if c["kind"] == "regex":
                fields = ("mustContain", c["input"]["value"], "true" if c["input"]["useRegex"] else "false")
            else:
                key = {"episode": "episodeFilter"}.get(c["kind"], c["kind"])
                fields = (key, c["input"], "false")
            if any("\0" in f for f in fields):
                continue
            with self.subTest(kind=c["kind"], why=c["why"]):
                r = self.rss("rule-check", *fields)
                if c["ok"]:
                    self.ok(r, {"ok": True, "value": c["normalised"]})
                else:
                    self.refused(r, c["message"])
        self.assertEqual(self.since(before), [])

    def test_must_not_contain_and_use_regex(self):
        self.refused(self.rss("rule-check", "mustNotContain", "(", "true"), S["badRegex"])
        self.ok(self.rss("rule-check", "mustNotContain", "(", "false"), {"ok": True, "value": "("})
        # useRegex is read only for the patterns.
        self.refused(self.rss("rule-check", "episodeFilter", "1x2", "true"), S["badEpisode"])

    def test_no_pcre2grep(self):
        farm = no_pcre_path()
        self.addCleanup(shutil.rmtree, farm, True)
        env = {"PATH": str(farm)}
        self.refused(self.rss("rule-check", "mustContain", "x", "true", env=env), S["noPcre"])
        self.ok(self.rss("rule-check", "mustContain", "x", "false", env=env), {"ok": True, "value": "x"})


class RuleCreateTest(RulesCase):
    def test_create_disabled_on_a_feed(self):
        before = len(self.log())
        self.ok(self.rss("rule-create", "  Show ", TV_URL), {"ok": True, "name": "Show"})
        posts = self.posts_since(before)
        self.assertEqual([e["path"] for e in posts], ["/api/v2/rss/setRule"])
        self.assertEqual(self.form(posts[0])["ruleName"], ["Show"])
        self.assertEqual(json.loads(self.form(posts[0])["ruleDef"][0]), {"enabled": False, "affectedFeeds": [TV_URL]})
        rule = self.rules_state()["Show"]
        self.assertEqual((rule["enabled"], rule["affectedFeeds"]), (False, [TV_URL]))

    def test_create_without_a_feed(self):
        self.ok(self.rss("rule-create", "Blank", ""), {"ok": True, "name": "Blank"})
        self.assertEqual(self.rules_state()["Blank"]["affectedFeeds"], [])
        self.assertFalse(self.rules_state()["Blank"]["enabled"])

    def test_an_odd_name(self):
        self.ok(self.rss("rule-create", "Linux\\Debian | x265", ""), {"ok": True, "name": "Linux\\Debian | x265"})

    def test_refusals(self):
        for c in cases("ruleName"):
            if c["ok"] or "\0" in c["input"]:
                continue
            with self.subTest(why=c["why"]):
                self.refused_before_any_request("rule-create", (c["input"], TV_URL), c["message"])
        self.reset(rules={"Show": disabled([])})
        before = len(self.log())
        self.refused_without_a_post(self.rss("rule-create", "Show", TV_URL), sentence("ruleExists", name="Show"), before)

    def test_the_read_back(self):
        self.control({"rss_setRule": "noop"})
        before = len(self.log())
        self.refused(self.rss("rule-create", "Show", TV_URL), sentence("unconfirmedAdd", name="Show"))
        self.assertEqual(len(self.posts_since(before)), 1)

    def test_other_failures(self):
        self.control({"rss_setRule": "500"})
        r = self.rss("rule-create", "Show", TV_URL)
        self.assertEqual((r.returncode, r.stderr.decode()), (1, "qBittorrent refused it (HTTP 500)\n"))


class RuleSetTest(RulesCase):
    def test_review_focus_1_only_must_contain_changes(self):
        rule = full_rule()
        self.reset(rules={"Show": rule})
        before = len(self.log())
        self.ok(self.rule_set("Show", {"mustContain": "Show 1080p"}, {"mustContain": "Show", "enabled": False}),
                {"ok": True})
        expected = copy.deepcopy(rule)
        expected["mustContain"] = "Show 1080p"
        self.assertEqual(self.set_rule_posts(before), [expected])
        self.assertEqual(json.dumps(self.rules_state()["Show"], sort_keys=True), json.dumps(expected, sort_keys=True))
        self.assertEqual(self.rules_state()["Show"]["previouslyMatchedEpisodes"], rule["previouslyMatchedEpisodes"])

    def test_ov10_a_path_then_cleared(self):
        for start, restored in ((True, True), (None, None), (False, False)):
            with self.subTest(use_auto_tmm=start):
                rule = full_rule()
                if start is None:
                    del rule["torrentParams"]["use_auto_tmm"]
                else:
                    rule["torrentParams"]["use_auto_tmm"] = start
                self.reset(rules={"Show": rule})
                self.ok(self.rule_set("Show", {"savePath": "/media/tv/"},
                                      {"savePath": "", "useAutoTmm": start, "enabled": False}), {"ok": True})
                now = self.rules_state()["Show"]
                self.assertEqual((now["torrentParams"]["save_path"], now["torrentParams"]["use_auto_tmm"], now["savePath"]),
                                 ("/media/tv", False, "/media/tv"))
                self.ok(self.rule_set("Show", {"savePath": ""},
                                      {"savePath": "/media/tv", "useAutoTmm": start, "enabled": False}), {"ok": True})
                now = self.rules_state()["Show"]
                self.assertEqual((now["torrentParams"]["save_path"], now["savePath"]), ("", ""))
                if restored is None:
                    self.assertNotIn("use_auto_tmm", now["torrentParams"])
                else:
                    self.assertEqual(now["torrentParams"]["use_auto_tmm"], restored)
                self.assertEqual(json.dumps(now, sort_keys=True), json.dumps(rule, sort_keys=True))

    def test_stopped_tri_state(self):
        self.reset(rules={"Show": full_rule()})
        prev = "default"
        for value, stopped, paused in (("yes", True, True), ("no", False, False), ("default", None, None)):
            with self.subTest(addStopped=value):
                self.ok(self.rule_set("Show", {"addStopped": value}, {"addStopped": prev, "enabled": False}), {"ok": True})
                now = self.rules_state()["Show"]
                self.assertEqual(now["torrentParams"].get("stopped"), stopped)
                self.assertEqual(now["addPaused"], paused)
                self.assertEqual("stopped" in now["torrentParams"], stopped is not None)
                prev = value

    def test_category_mirrors_the_flat_key(self):
        self.reset(rules={"Show": full_rule()})
        self.ok(self.rule_set("Show", {"category": "anime"}, {"category": "tv", "enabled": False}), {"ok": True})
        now = self.rules_state()["Show"]
        self.assertEqual((now["torrentParams"]["category"], now["assignedCategory"]), ("anime", "anime"))

    def test_a_snapshot_conflict_writes_nothing(self):
        self.reset(rules={"Show": full_rule()})
        before = len(self.log())
        self.refused_without_a_post(self.rule_set("Show", {"mustContain": "x"}, {"mustContain": "Show 720p", "enabled": False}),
                                    sentence("ruleChanged", name="Show"), before)
        # Turned on elsewhere under the editor.
        self.refused_without_a_post(self.rule_set("Show", {"mustContain": "x"}, {"mustContain": "Show", "enabled": True}),
                                    sentence("ruleChanged", name="Show"), before)

    def test_ov9_an_episode_the_auto_downloader_adds_is_kept(self):
        self.reset(rules={"Show": full_rule()})
        self.control({"rss_setrule_inject": {"append": ["1x7"], "lastMatch": "30 Sep 2026 08:00:00 +0000"}})
        before = len(self.log())
        self.ok(self.rule_set("Show", {"mustContain": "Show 1080p"}, {"mustContain": "Show", "enabled": False}),
                {"ok": True})
        self.assertEqual(len(self.set_rule_posts(before)), 1)
        now = self.rules_state()["Show"]
        self.assertEqual(now["previouslyMatchedEpisodes"], ["1x1", "1x2", "1x3", "1x4", "1x5", "1x6", "1x7"])
        self.assertEqual(now["lastMatch"], "30 Sep 2026 08:00:00 +0000")
        self.assertEqual(now["mustContain"], "Show 1080p")

    def test_ov9_a_lost_episode_is_written_back_once(self):
        self.reset(rules={"Show": full_rule()})
        self.control({"rss_setrule_inject": {"drop": ["1x2"], "append": ["1x7"], "lastMatch": "1 Jan 2020 00:00:00 +0000"}})
        before = len(self.log())
        self.ok(self.rule_set("Show", {"mustContain": "Show 1080p"}, {"mustContain": "Show", "enabled": False}),
                {"ok": True})
        posts = self.set_rule_posts(before)
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[1]["previouslyMatchedEpisodes"], ["1x1", "1x2", "1x3", "1x4", "1x5", "1x6", "1x7"])
        now = self.rules_state()["Show"]
        self.assertEqual(now["previouslyMatchedEpisodes"], ["1x1", "1x2", "1x3", "1x4", "1x5", "1x6", "1x7"])
        self.assertEqual(now["lastMatch"], full_rule()["lastMatch"])
        self.assertEqual(now["mustContain"], "Show 1080p")

    def test_ov9_never_loops(self):
        self.reset(rules={"Show": full_rule()})
        # Every setRule loses 1x2: the second write's read-back fails, and
        # there is no third.
        self.control({"rss_setrule_inject": {"drop": ["1x2"], "every": True}})
        before = len(self.log())
        self.refused(self.rule_set("Show", {"mustContain": "Show 1080p"}, {"mustContain": "Show", "enabled": False}),
                     S["unconfirmedSave"])
        self.assertEqual(len(self.set_rule_posts(before)), 2)

    def test_rule_gone(self):
        before = len(self.log())
        self.refused_without_a_post(self.rule_set("Nope", {"mustContain": "x"}, {"mustContain": "", "enabled": True}),
                                    S["ruleGone"], before)

    def test_a_read_back_mismatch(self):
        self.reset(rules={"Show": full_rule()})
        self.control({"rss_setRule": "noop"})
        self.refused(self.rule_set("Show", {"mustContain": "x"}, {"mustContain": "Show", "enabled": False}),
                     S["unconfirmedSave"])
        # A rule removed between the write and the read-back.
        self.control({"rss_setrule_inject": {"remove": True}})
        self.refused(self.rule_set("Show", {"mustContain": "x"}, {"mustContain": "Show", "enabled": False}),
                     S["unconfirmedSave"])

    def test_ov13_only_changed_fields_are_validated(self):
        rule = full_rule()
        rule["episodeFilter"] = "1x2; 3;"
        self.reset(rules={"Show": rule})
        self.ok(self.rule_set("Show", {"mustContain": "Show 1080p"}, {"mustContain": "Show", "enabled": False}),
                {"ok": True})
        self.assertEqual(self.rules_state()["Show"]["episodeFilter"], "1x2; 3;")
        before = len(self.log())
        self.refused_without_a_post(
            self.rule_set("Show", {"episodeFilter": "1x2; 3;x"}, {"episodeFilter": "1x2; 3;", "enabled": False}),
            S["badEpisode"], before)

    def test_value_refusals_write_nothing(self):
        rule = full_rule()
        rule["mustNotContain"] = "("
        self.reset(rules={"Show": rule})
        before = len(self.log())
        for changes, snapshot, message in (
            ({"useRegex": True}, {"useRegex": False, "enabled": False}, S["badRegex"]),
            ({"ignoreDays": 400}, {"ignoreDays": 0, "enabled": False}, S["badDays"]),
            ({"savePath": "media"}, {"savePath": "", "useAutoTmm": True, "enabled": False}, S["badSavePath"]),
            ({"mustContain": "a\nb"}, {"mustContain": "Show", "enabled": False}, S["multiLine"]),
        ):
            with self.subTest(changes=changes):
                self.refused_without_a_post(self.rule_set("Show", changes, snapshot), message, before)

    def test_no_pcre2grep_refuses_before_any_write(self):
        self.reset(rules={"Show": full_rule()})
        farm = no_pcre_path()
        self.addCleanup(shutil.rmtree, farm, True)
        before = len(self.log())
        self.refused_without_a_post(self.rule_set("Show", {"useRegex": True}, {"useRegex": False, "enabled": False},
                                                  env={"PATH": str(farm)}), S["noPcre"], before)
        # No regex to check: no pcre2grep needed.
        self.ok(self.rule_set("Show", {"ignoreDays": 3}, {"ignoreDays": 0, "enabled": False}, env={"PATH": str(farm)}),
                {"ok": True})

    def test_off_and_keep(self):
        rule = full_rule()
        rule["enabled"] = True
        self.reset(rules={"Show": rule})
        self.ok(self.rule_set("Show", {}, {}, "off"), {"ok": True})
        self.assertFalse(self.rules_state()["Show"]["enabled"])
        self.ok(self.rule_set("Show", {"ignoreDays": 7}, {"ignoreDays": 0, "enabled": False}), {"ok": True})
        self.assertEqual((self.rules_state()["Show"]["enabled"], self.rules_state()["Show"]["ignoreDays"]), (False, 7))

    def test_on_previews_before_any_write(self):
        # The Debian rule matches DSA-6002 news: an unread page link.
        self.reset(rules={"Deb": disabled([DEBIAN_URL], mustContain="DSA")})
        before = len(self.log())
        self.refused_without_a_post(self.rule_set("Deb", {}, {}, "on"), sentence("noTorrentBlock", m=1), before)
        paths = [e["path"] for e in self.since(before)]
        self.assertIn("/api/v2/rss/matchingArticles", paths)
        self.assertIn("/api/v2/rss/items", paths)
        self.assertFalse(self.rules_state()["Deb"]["enabled"])

    def test_on_writes_enabled_and_nothing_else(self):
        rule = full_rule()
        rule["affectedFeeds"] = [TV_URL]
        self.reset(rules={"Show": rule})
        before = len(self.log())
        self.ok(self.rule_set("Show", {}, {}, "on"), {"ok": True})
        expected = copy.deepcopy(rule)
        expected["enabled"] = True
        self.assertEqual(self.set_rule_posts(before), [expected])
        self.assertEqual(json.dumps(self.rules_state()["Show"], sort_keys=True), json.dumps(expected, sort_keys=True))

    def test_a_legacy_rule_reads_back_with_torrent_params(self):
        self.reset(rules={"Legacy": legacy_rule()})
        self.ok(self.rule_set("Legacy", {"savePath": "/media/tv", "category": "anime", "addStopped": "yes"},
                              {"savePath": "", "useAutoTmm": None, "category": "tv", "addStopped": "default",
                               "enabled": False}), {"ok": True})
        now = self.rules_state()["Legacy"]
        self.assertEqual(now["torrentParams"]["save_path"], "/media/tv")
        self.assertEqual((now["assignedCategory"], now["addPaused"]), ("anime", True))

    def test_flat_keys_that_disagree_with_torrent_params_are_not_a_mismatch(self):
        row = [c for c in cases("fields") if c["input"].get("savePath") == "/old" and "torrentParams" in c["input"]
               and isinstance(c["input"]["torrentParams"], dict)][0]
        self.reset(rules={"Odd": copy.deepcopy(row["input"])})
        self.ok(self.rule_set("Odd", {"ignoreDays": 2}, {"ignoreDays": 0, "enabled": False}), {"ok": True})


class RulePreviewTest(RulesCase):
    def preview(self, name):
        r = self.rss("rule-preview", name)
        self.assertEqual((r.returncode, r.stderr.decode()), (0, ""))
        return json.loads(r.stdout)

    def item(self, path, guid, title, dup=1):
        return {"feedPath": path, "guid": guid, "title": title, "dup": dup}

    def test_the_groups(self):
        self.reset(rules={"Deb": disabled([DEBIAN_URL], mustContain="dsa-600")})
        before = len(self.log())
        out = self.preview("Deb")
        deb = "Linux\\Debian"
        self.assertEqual(out, {
            "will": [self.item(deb, "d1", "DSA-6000 openssl"), self.item(deb, "d6", "DSA-6005 zlib")],
            "read": [self.item(deb, "d2", "DSA-6001 curl")],
            "noTorrent": [self.item(deb, "d3", "DSA-6002 news")],
            "unpreviewable": [], "gone": []})
        reads = [e for e in self.since(before) if e["path"] == "/api/v2/rss/matchingArticles"]
        self.assertEqual(len(reads), 1)
        self.assertEqual((reads[0]["method"], reads[0]["query"]), ("GET", {"ruleName": ["Deb"]}))
        self.assertEqual(self.posts_since(before), [])

    def test_scripted_matching_dup_and_gone(self):
        self.reset(rules={"Arch": disabled([ARCH_URL, GONE_URL, ARCH_URL])})
        self.control({"rss_matching": {"Arch": {"Arch": ["Arch news"]}}})
        arch = "Linux\\Arch"
        self.assertEqual(self.preview("Arch"), {
            "will": [self.item(arch, "ar1", "Arch news", 3), self.item(arch, "ar2", "Arch news", 3)],
            "read": [self.item(arch, "ar3", "Arch news", 3)],
            "noTorrent": [], "unpreviewable": [], "gone": [GONE_URL]})

    def test_two_feeds_with_the_same_name(self):
        self.reset(rules={"Show": disabled([TV_URL, ANIME_URL, DEBIAN_URL], mustContain="S01E07")})
        out = self.preview("Show")
        self.assertEqual(out["unpreviewable"], [{"name": "Show", "feedPaths": ["Anime\\Show", "TV\\Show"]}])
        self.assertEqual((out["will"], out["read"], out["noTorrent"]), ([], [], []))

    def test_gone(self):
        before = len(self.log())
        self.refused_without_a_post(self.rss("rule-preview", "Nope"), S["ruleGone"], before)

    def test_preview_enabled_dedupes(self):
        self.reset(rules={
            "Deb": {"enabled": True, "affectedFeeds": [DEBIAN_URL], "mustContain": "DSA"},
            "Deb2": {"enabled": True, "affectedFeeds": [DEBIAN_URL, TV_URL], "mustContain": "openssl"},
            "Off": disabled([ARCH_URL], mustContain="Arch"),
            "Tv": {"affectedFeeds": [TV_URL], "mustContain": "S01E07"},
        })
        before = len(self.log())
        self.ok(self.rss("rules-preview-enabled"), {"rules": 3, "will": 3, "noTorrent": 1})
        names = sorted(e["query"]["ruleName"][0] for e in self.since(before) if e["path"] == "/api/v2/rss/matchingArticles")
        self.assertEqual(names, ["Deb", "Deb2", "Tv"])
        self.assertEqual(self.posts_since(before), [])

    def test_preview_enabled_with_none(self):
        self.reset(rules={"Off": disabled([ARCH_URL])})
        self.ok(self.rss("rules-preview-enabled"), {"rules": 0, "will": 0, "noTorrent": 0})

    def test_an_odd_rule_name_reaches_matching_articles_exactly(self):
        name = "a&b=c d\\e+f%"
        self.reset(rules={name: disabled([DEBIAN_URL], mustContain="zlib")})
        before = len(self.log())
        self.assertEqual(len(self.preview(name)["will"]), 1)
        q = [e["query"] for e in self.since(before) if e["path"] == "/api/v2/rss/matchingArticles"]
        self.assertEqual(q, [{"ruleName": [name]}])


class RenameRemoveTest(RulesCase):
    def test_rename(self):
        self.reset(rules={"Show": full_rule()})
        before = len(self.log())
        self.ok(self.rss("rule-rename", "Show", " Show 2 "), {"ok": True, "name": "Show 2"})
        posts = self.posts_since(before)
        self.assertEqual([(e["path"], self.form(e)) for e in posts],
                         [("/api/v2/rss/renameRule", {"ruleName": ["Show"], "newRuleName": ["Show 2"]})])
        self.assertEqual(list(self.rules_state().keys()), ["Show 2"])

    def test_rename_refusals(self):
        self.reset(rules={"Show": disabled([]), "Other": disabled([])})
        before = len(self.log())
        self.refused_without_a_post(self.rss("rule-rename", "Show", "Other"), sentence("ruleExists", name="Other"), before)
        self.refused_without_a_post(self.rss("rule-rename", "Nope", "New"), S["ruleGone"], before)
        self.refused_before_any_request("rule-rename", ("Show", "  "), S["ruleNameEmpty"])
        self.refused_before_any_request("rule-rename", ("Show", "a\u0007b"), S["ruleNameControl"])
        # Unchanged: no request at all.
        before = len(self.log())
        self.ok(self.rss("rule-rename", "Show", "Show "), {"ok": True, "name": "Show"})
        self.assertEqual(self.since(before), [])

    def test_rename_read_back_catches_the_silent_no_op(self):
        self.reset(rules={"Show": disabled([])})
        self.control({"rss_renameRule": "noop"})
        self.refused(self.rss("rule-rename", "Show", "New"), S["unconfirmedRename"])

    def test_an_odd_existing_name_stays_manageable(self):
        self.reset(rules={" padded\u0007": disabled([])})
        self.ok(self.rss("rule-rename", " padded\u0007", "Clean"), {"ok": True, "name": "Clean"})
        self.reset(rules={" padded\u0007": disabled([])})
        self.ok(self.rss("rule-remove", " padded\u0007"), {"ok": True})
        self.assertEqual(self.rules_state(), {})

    def test_remove(self):
        self.reset(rules={"Show": disabled([]), "Other": disabled([])})
        before = len(self.log())
        self.ok(self.rss("rule-remove", "Show"), {"ok": True})
        self.assertEqual([(e["path"], self.form(e)) for e in self.posts_since(before)],
                         [("/api/v2/rss/removeRule", {"ruleName": ["Show"]})])
        self.assertEqual(list(self.rules_state().keys()), ["Other"])
        before = len(self.log())
        self.refused_without_a_post(self.rss("rule-remove", "Show"), S["ruleGone"], before)

    def test_remove_read_back(self):
        self.reset(rules={"Show": disabled([])})
        self.control({"rss_removeRule": "noop"})
        self.refused(self.rss("rule-remove", "Show"), sentence("unconfirmedRemove", name="Show"))


class FixtureTest(RulesCase):
    """The fixture's rules model against qBittorrent 5.2.3's behaviour."""

    def set_rule(self, name, rule_def):
        body = "ruleName=" + urllib.request.quote(name) + "&ruleDef=" + urllib.request.quote(rule_def)
        return self.raw("POST", "/api/v2/rss/setRule", body)[0]

    def test_writes_are_post_only(self):
        for action in ("setRule", "renameRule", "removeRule"):
            self.assertEqual(self.raw("GET", f"/api/v2/rss/{action}?ruleName=x")[0], 405, action)

    def test_set_rule_replaces_the_whole_rule(self):
        self.assertEqual(self.set_rule("Blank", "{}"), 200)
        blank = self.rules_state()["Blank"]
        self.assertEqual(rssautorules.fields_of(blank), rssautorules.fields_of({}))
        self.assertTrue(blank["enabled"])
        self.assertIn("torrentParams", blank)
        self.assertEqual(blank["torrentParams"]["save_path"], "")
        self.assertEqual(self.set_rule("Blank", "not json"), 200)
        self.assertTrue(self.rules_state()["Blank"]["enabled"])
        # Once torrentParams is present the flat keys are ignored.
        self.set_rule("Tp", json.dumps({"savePath": "/flat", "assignedCategory": "flat", "addPaused": True,
                                        "torrentParams": None}))
        tp = self.rules_state()["Tp"]
        self.assertEqual((tp["savePath"], tp["assignedCategory"], tp["addPaused"]), ("", "", None))
        # Without it the flat keys make the torrentParams (and a path turns
        # automatic management off).
        self.set_rule("Flat", json.dumps({"savePath": "/flat/", "assignedCategory": "c", "addPaused": False}))
        flat = self.rules_state()["Flat"]
        self.assertEqual(flat["torrentParams"]["save_path"], "/flat")
        self.assertEqual((flat["torrentParams"]["category"], flat["torrentParams"]["stopped"],
                          flat["torrentParams"]["use_auto_tmm"]), ("c", False, False))
        # A full rule round-trips byte for byte.
        self.set_rule("Full", json.dumps(full_rule()))
        self.assertEqual(json.dumps(self.rules_state()["Full"], sort_keys=True), json.dumps(full_rule(), sort_keys=True))

    def test_rename_and_remove_are_silent_no_ops(self):
        self.reset(rules={"A": disabled([]), "B": disabled([])})
        body = "ruleName=A&newRuleName=B"
        self.assertEqual(self.raw("POST", "/api/v2/rss/renameRule", body)[0], 200)
        self.assertEqual(sorted(self.rules_state()), ["A", "B"])
        self.assertEqual(self.raw("POST", "/api/v2/rss/renameRule", "ruleName=Nope&newRuleName=C")[0], 200)
        self.assertEqual(self.raw("POST", "/api/v2/rss/removeRule", "ruleName=Nope")[0], 200)
        self.assertEqual(sorted(self.rules_state()), ["A", "B"])

    def test_matching_articles_by_feed_name(self):
        self.reset(rules={"Show": disabled([TV_URL, ANIME_URL, GONE_URL], mustContain="s01e0"),
                          "None": disabled([DEBIAN_URL], mustContain="nothing")})
        status, body = self.raw("GET", "/api/v2/rss/matchingArticles?ruleName=Show")
        # The later same-named feed overwrites the earlier one.
        self.assertEqual((status, json.loads(body)), (200, {"Show": ["Show S01E07 1080p"]}))
        self.assertEqual(json.loads(self.raw("GET", "/api/v2/rss/matchingArticles?ruleName=None")[1]), {})
        self.assertEqual(json.loads(self.raw("GET", "/api/v2/rss/matchingArticles?ruleName=Nope")[1]), {})
        self.reset(rules={"Show": disabled([ANIME_URL, TV_URL], mustContain="s01e0")})
        self.assertEqual(json.loads(self.raw("GET", "/api/v2/rss/matchingArticles?ruleName=Show")[1]),
                         {"Show": ["Show S01E07 1080p", "Show S01E08 1080p"]})

    def test_reset_clears_rules(self):
        self.reset(rules={"A": {}})
        self.reset()
        self.assertEqual(self.rules_state(), {})


class ProbeTest(RulesCase):
    def test_probe_reports_pcre2grep(self):
        r = subprocess.run([QBT, "probe"], env=self.env, capture_output=True, timeout=30)
        self.assertEqual(json.loads(r.stdout)["pcre2grep"], True)
        farm = no_pcre_path()
        self.addCleanup(shutil.rmtree, farm, True)
        r = subprocess.run([QBT, "probe"], env=dict(self.env, PATH=str(farm)), capture_output=True, timeout=30)
        self.assertEqual(json.loads(r.stdout)["pcre2grep"], False)


class PostOnlyTest(RulesCase):
    def test_every_write_is_a_post(self):
        before = len(self.log())
        self.rss("rule-create", "P", TV_URL)
        self.rule_set("P", {"mustContain": "S01"}, {"mustContain": "", "enabled": False})
        self.rule_set("P", {}, {}, "on")
        self.rss("rule-rename", "P", "Q")
        self.rss("rule-remove", "Q")
        writes = [e for e in self.since(before) if e["path"].rsplit("/", 1)[1] in ("setRule", "renameRule", "removeRule")]
        self.assertEqual(len(writes), 5)
        self.assertTrue(all(e["method"] == "POST" for e in writes))
        reads = [e for e in self.since(before) if e["path"].rsplit("/", 1)[1] in ("rules", "matchingArticles", "items")]
        self.assertTrue(reads and all(e["method"] == "GET" for e in reads))


class NoBodyOnDiskOrArgvTest(RulesCase):
    """Response bodies never touch disk, and no value reaches any argv."""

    def big(self):
        t = tree()
        for i in range(40):
            t["Linux"]["Debian"]["articles"].append(article(f"big{i}", "MARKER-TITLE " + "x" * 3000, f"https://big.example/{i}"))
        rules = {f"bulk{i}": disabled([DEBIAN_URL], mustContain="y" * 2000) for i in range(60)}
        rules["MARKER-SEED"] = {"enabled": True, "affectedFeeds": [DEBIAN_URL], "mustContain": "MARKER-TITLE"}
        return t, rules

    def commands(self):
        yield "rules", ()
        yield "rule-check", ("mustContain", "MARKER-PAT(a|b)", "true")
        yield "rule-check", ("savePath", "/MARKER-PATH", "false")
        yield "rule-create", ("MARKER-RULE", "https://marker-feed.example/MARKER-Q")
        yield "rule-set", ("MARKER-RULE", json.dumps({"mustContain": "MARKER-MUST"}),
                           json.dumps({"mustContain": "", "enabled": False}), "keep")
        yield "rule-set", ("MARKER-RULE", json.dumps({"useRegex": True}), json.dumps({"useRegex": False, "enabled": False}), "keep")
        yield "rule-set", ("MARKER-RULE", json.dumps({"savePath": "/MARKER-PATH"}),
                           json.dumps({"savePath": "", "useAutoTmm": None, "enabled": False}), "keep")
        yield "rule-preview", ("MARKER-SEED",)
        yield "rule-set", ("MARKER-RULE", "{}", "{}", "on")
        yield "rules-preview-enabled", ()
        yield "rule-rename", ("MARKER-RULE", "MARKER-RENAMED")
        yield "rule-remove", ("MARKER-RENAMED",)

    def test_ulimit_and_a_fresh_tmpdir(self):
        t, rules = self.big()
        self.reset(t, rules)
        self.assertGreater(len(self.rss("rules").stdout), 100000)
        tmpdir = Path(tempfile.mkdtemp(prefix="qbt-tmp-"))
        self.addCleanup(shutil.rmtree, tmpdir, True)
        env = dict(self.env, TMPDIR=str(tmpdir), TMP=str(tmpdir), TEMP=str(tmpdir))
        for sub, fields in self.commands():
            with self.subTest(sub=sub, fields=fields):
                r = subprocess.run(["bash", "-c", 'ulimit -f 32 && exec "$0" "$@"', QBT, "rss", sub],
                                   env=env, input="\0".join(fields).encode(), capture_output=True, timeout=60)
                self.assertEqual((r.returncode, r.stderr), (0, b""), sub)
                self.assertEqual(list(tmpdir.iterdir()), [])

    def test_no_value_is_ever_on_an_argv(self):
        shims = Path(tempfile.mkdtemp(prefix="qbt-shims-"))
        self.addCleanup(shutil.rmtree, shims, True)
        argv_log = shims / "argv.log"
        for tool in ("curl", "jq", "python3", "pcre2grep"):
            real = shutil.which(tool)
            (shims / tool).write_text(f'#!/bin/bash\nprintf "%s " "$@" >>"{argv_log}"\necho >>"{argv_log}"\n'
                                      f'exec "{real}" "$@"\n')
            (shims / tool).chmod(0o755)
        env = dict(self.env, PATH=f"{shims}:{os.environ['PATH']}")
        t, rules = self.big()
        self.reset(t, rules)
        for sub, fields in self.commands():
            with self.subTest(sub=sub, fields=fields):
                r = self.rss(sub, *fields, env=env)
                self.assertEqual((r.returncode, r.stderr), (0, b""), sub)
        logged = argv_log.read_text()
        self.assertIn("/api/v2/rss/rules", logged)
        self.assertIn("-u -i -f", logged)
        self.assertGreater(logged.count("\n"), 30)
        for marker in ("MARKER", "marker-feed", "Debian", "debian.org", "DSA", "yyyy"):
            self.assertNotIn(marker, logged, marker)

    def test_rss_code_has_no_here_strings_or_temp_files(self):
        text = (ROOT / "qbt").read_text()
        start = text.index("# Slice 5b1: `qbt rss`")
        end = text.index("\ncase ${1:-} in", start)
        region = text[start:end]
        self.assertIn("rss_rule_set", region)
        code = "\n".join(line for line in region.splitlines() if not line.lstrip().startswith("#"))
        for word in ("<<<", "mktemp", "tee ", "--data \"", "--arg ", "--argjson", "api POST", "api_try POST",
                     "api_try GET \"/api/v2/rss/matchingArticles"):
            self.assertNotIn(word, code, word)


if __name__ == "__main__":
    unittest.main()
