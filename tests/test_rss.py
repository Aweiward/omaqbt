"""Slice 5b1 (Task 2): `qbt rss` against the fixture's qBittorrent 5.2.3 RSS
API, and lib/rssrules.py and lib/rssitems.py against every case in
tests/fixtures/rss-rules-cases.json.

The contract is tests/fixtures/rss-contract.md. Every message these tests
expect is read from the case file (its cases and sentences), never
retyped. Values reach qbt on stdin, NUL-separated; a refusal prints one
sentence on stderr and exits 1, the usage line exits 2, and a refused
value sends no request at all.
"""
import calendar
import json
import os
import shutil
import stat
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
import rssitems  # noqa: E402
import rssrules  # noqa: E402

QBT = os.environ.get("QBT_UNDER_TEST", str(ROOT / "qbt"))
DATA = json.loads((ROOT / "tests" / "fixtures" / "rss-rules-cases.json").read_text())
CASES = DATA["cases"]
S = DATA["sentences"]
PREFS_DUMP = ROOT / "tests" / "fixtures" / "preferences-5.2.3.json"
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
RULE_KINDS = ("feedUrl", "name", "hasTorrent", "errorReason")
SEP = "\\"

MAGNET = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=debian"
DEBIAN_URL = "https://www.debian.org/security/dsa"
ARCH_URL = "https://archlinux.org/feeds/news/"
UBUNTU_URL = "https://ubuntu.example/rss"
ALPHA_URL = "http://127.0.0.1:9117/api/v2.0/indexers/all/results/torznab"
DATE = "Mon, 29 Sep 2025 10:00:00 +0000"
EPOCH = calendar.timegm((2025, 9, 29, 10, 0, 0))


def cases(kind):
    return [c for c in CASES if c["kind"] == kind]


def sentence(key, **values):
    text = S[key]
    for k, v in values.items():
        text = text.replace(f"<{k}>", v)
    return text


def article(aid, title, link, torrent_url=None, date=DATE, read=False, description=""):
    a = {"id": aid, "date": date, "title": title, "author": "", "description": description,
         "torrentURL": link if torrent_url is None else torrent_url, "link": link}
    if read:
        a["isRead"] = True
    return a


def feed(uid, url, title="", articles=(), has_error=False, loading=False):
    return {"uid": "{%08d-0000-4000-8000-000000000000}" % uid, "url": url, "title": title,
            "lastBuildDate": "", "isLoading": loading, "hasError": has_error, "articles": list(articles)}


def tree():
    """alpha (a root feed), Linux {arch, Debian, Distros {ubuntu}}, Zeta
    {News, news}: sorted case-insensitively, then by the exact name."""
    return {
        "alpha": feed(1, ALPHA_URL, "Jackett", [
            article("a1", "Debian 13 ISO", "https://tracker.example/details.php?id=42",
                    "https://tracker.example/download.php?id=42"),
        ]),
        "Linux": {
            "Debian": feed(2, DEBIAN_URL, " Debian Security ", [
                article("d1", "Debian 13 released", "https://www.debian.org/News/2025/13", MAGNET,
                        description="<p>Hello <b>world</b></p>"),
                article("d2", "DSA-6000-1 openssl", "https://www.debian.org/security/2025/dsa-6000",
                        description="<script>alert(1)</script>news"),
                article("d3", "debian-13.torrent", "https://cdimage.debian.org/debian-13.torrent", read=True,
                        date="Mon, 29 Sep 2025 10:00:00 -0000"),
                article("d4", "Evil", "https://example.org/x", "javascript:alert(1)", date="not a date"),
            ]),
            "arch": feed(3, ARCH_URL, "Arch Linux: Recent news updates", [
                article("r1", "Arch news", "https://archlinux.org/news/1/", date="", read=True),
            ]),
            "Distros": {
                "ubuntu": feed(4, UBUNTU_URL, "", [
                    article("u1", "Ubuntu 26.04", "", MAGNET.replace("debian", "ubuntu")),
                ], has_error=True),
            },
        },
        "Zeta": {
            "news": feed(5, "https://news.example/a.xml"),
            "News": feed(6, "https://news.example/b.xml"),
        },
    }


class LibRulesTest(unittest.TestCase):
    """Every rule case through lib/rssrules.py and lib/rssitems.py."""

    def check_case(self, c):
        ok, normalised, message = rssrules.check(c["kind"], c["input"])
        label = f"{c['kind']}: {c['why']}"
        self.assertEqual(ok, c["ok"], label)
        if c["ok"]:
            self.assertEqual(normalised, c["normalised"], label)
        else:
            self.assertEqual(message, c["message"], label)

    def test_every_rule_case(self):
        n = 0
        for c in CASES:
            if c["kind"] in RULE_KINDS:
                with self.subTest(kind=c["kind"], why=c["why"]):
                    self.check_case(c)
                n += 1
        self.assertEqual(n, len(CASES) - len(cases("articleText")))
        self.assertGreater(n, 70)

    def test_every_article_text_case(self):
        for c in cases("articleText"):
            with self.subTest(why=c["why"]):
                text, truncated = rssitems.article_text(c["input"])
                self.assertEqual({"text": text, "truncated": truncated}, c["normalised"])

    def test_the_named_functions(self):
        self.assertEqual(rssrules.feed_url("https://Example.org/x"), "example.org")
        self.assertEqual(rssrules.name("  x "), "x")
        self.assertEqual(rssrules.has_torrent(MAGNET, ""), "magnet")
        self.assertIsNone(rssrules.error_reason([], "https://example.org/"))

    def test_every_message_is_a_case_file_sentence(self):
        for key, text in rssrules.MSG.items():
            self.assertEqual(text, S[key], key)

    def test_the_cli_reads_stdin_and_matches_every_case(self):
        for c in CASES:
            if c["kind"] not in RULE_KINDS:
                continue
            if c["kind"] == "hasTorrent":
                if "\0" in c["input"]["torrentURL"]:
                    continue  # the NUL framing can't carry a NUL; check_case covers it
                raw = (c["input"]["torrentURL"] + "\0" + c["input"]["link"]).encode("utf-8")
            elif c["kind"] == "errorReason":
                raw = json.dumps(c["input"]).encode()
            else:
                raw = c["input"].encode("utf-8")
            r = subprocess.run([sys.executable, str(ROOT / "lib" / "rssrules.py"), c["kind"]],
                               input=raw, capture_output=True)
            with self.subTest(kind=c["kind"], why=c["why"]):
                if c["ok"]:
                    self.assertEqual(r.returncode, 0, r.stderr)
                    out = r.stdout.decode("utf-8")
                    self.assertEqual(json.loads(out) if c["kind"] == "errorReason" else out, c["normalised"])
                else:
                    self.assertEqual((r.returncode, r.stdout.decode()), (1, c["message"]))

    def test_the_cli_usage(self):
        for argv in ((), ("nope",), ("articleText",)):
            r = subprocess.run([sys.executable, str(ROOT / "lib" / "rssrules.py"), *argv], input=b"", capture_output=True)
            self.assertEqual(r.returncode, 2)

    def test_invalid_utf8_is_refused_like_a_control_character(self):
        run = lambda kind, raw: subprocess.run(  # noqa: E731
            [sys.executable, str(ROOT / "lib" / "rssrules.py"), kind], input=raw, capture_output=True)
        self.assertEqual(run("name", b"deb\xffian").stdout.decode(), S["nameControl"])
        self.assertEqual(run("feedUrl", b"https://example.org/\xff").stdout.decode(), S["feedUrlBad"])
        self.assertEqual(run("hasTorrent", b"magnet:?xt=\xff\0").stdout.decode(), S["badTorrentLink"])

    def test_no_url_library(self):
        for name in ("rssrules.py", "rssitems.py"):
            text = (ROOT / "lib" / name).read_text()
            code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
            for word in ("urllib", "urlsplit", "urlparse", '"idna"', "'idna'"):
                self.assertNotIn(word, code.split('"""', 2)[2], f"{name}: {word}")


class FlattenTest(unittest.TestCase):
    """lib/rssitems.py's flatten, straight from a tree."""

    def test_tree_order_depth_and_counts(self):
        out = rssitems.flatten(tree(), False, 30)
        self.assertEqual((out["processing"], out["refreshInterval"]), (False, 30))
        self.assertEqual([f["path"] for f in out["feeds"]], [
            "alpha", "Linux", "Linux\\arch", "Linux\\Debian", "Linux\\Distros", "Linux\\Distros\\ubuntu",
            "Zeta", "Zeta\\News", "Zeta\\news"])
        linux = out["feeds"][1]
        self.assertEqual(linux, {"path": "Linux", "name": "Linux", "depth": 0, "folder": True,
                                 "unread": 4, "total": 6, "feeds": 3})
        debian = out["feeds"][3]
        self.assertEqual(debian, {"path": "Linux\\Debian", "name": "Debian", "depth": 1, "folder": False,
                                  "url": DEBIAN_URL, "title": " Debian Security ", "isLoading": False,
                                  "hasError": False, "unread": 3, "total": 4})
        self.assertEqual(out["feeds"][5]["depth"], 2)
        self.assertTrue(out["feeds"][5]["hasError"])
        self.assertEqual(out["feeds"][6], {"path": "Zeta", "name": "Zeta", "depth": 0, "folder": True,
                                           "unread": 0, "total": 0, "feeds": 2})

    def test_articles(self):
        out = rssitems.flatten(tree(), True, 5)
        arts = {a["guid"]: a for a in out["articles"]}
        self.assertEqual([a["guid"] for a in out["articles"]], ["a1", "r1", "d1", "d2", "d3", "d4", "u1"])
        self.assertEqual(arts["d1"], {"feedPath": "Linux\\Debian", "guid": "d1", "title": "Debian 13 released",
                                      "date": EPOCH, "isRead": False, "torrentURL": MAGNET,
                                      "link": "https://www.debian.org/News/2025/13", "hasTorrent": True,
                                      "host": "www.debian.org"})
        self.assertFalse(arts["d2"]["hasTorrent"], "torrentURL == link, news")
        self.assertTrue(arts["d3"]["hasTorrent"], "the D4 exception")
        self.assertEqual(arts["d3"]["date"], EPOCH, "-0000 is UTC")
        self.assertTrue(arts["d3"]["isRead"])
        self.assertFalse(arts["d4"]["hasTorrent"], "javascript: is refused")
        self.assertIsNone(arts["d4"]["date"])
        self.assertIsNone(arts["r1"]["date"])
        self.assertTrue(arts["a1"]["hasTorrent"])
        self.assertEqual(arts["u1"]["host"], "")
        self.assertNotIn("description", json.dumps(out))


class RssCase(unittest.TestCase):
    """One fixture per class, with the 5.2.3 preferences dump; every test
    starts from tree() and an empty log, no faults and no error cache."""

    @classmethod
    def setUpClass(cls):
        cls._cm = harness.fixture_server(extra_env=dict(UTF8_ENV, QBT_FIXTURE_PREFS=str(PREFS_DUMP)))
        cls.port, cls.env = cls._cm.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls._cm.__exit__(None, None, None)

    def setUp(self):
        self.control({})
        self.reset(tree())
        self.state_path().unlink(missing_ok=True)

    def tearDown(self):
        self.control({})

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def reset(self, t=None, log=(), log_start=0):
        body = json.dumps({"tree": t or {}, "log": list(log), "logStart": log_start}).encode()
        req = urllib.request.Request(self.url("/fixture/rss-reset"), data=body, method="POST")
        urllib.request.urlopen(req, timeout=5).read()

    def control(self, value):
        Path(self.env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(value))

    def state_path(self):
        return Path(self.env["QBT_STATE_DIR"]) / "rss-errors.json"

    def fixture(self):
        return json.loads(urllib.request.urlopen(self.url("/fixture/rss-state"), timeout=5).read())

    def node(self, path):
        n = self.fixture()["tree"]
        for part in path.split(SEP):
            if part not in n:
                return None
            n = n[part]
        return n

    def set_pref(self, key, value):
        body = ("json=" + urllib.request.quote(json.dumps({key: value}))).encode()
        urllib.request.urlopen(urllib.request.Request(self.url("/api/v2/app/setPreferences"), data=body,
                                                      method="POST"), timeout=5).read()

    def rss(self, sub, *fields, raw=None, env=None, argv=None):
        full = dict(self.env)
        full.update(env or {})
        data = raw if raw is not None else "\0".join(fields).encode("utf-8")
        args = argv if argv is not None else ["rss", sub]
        return subprocess.run([QBT, *args], env=full, input=data, capture_output=True, timeout=60)

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

    def items(self):
        r = self.rss("items")
        self.assertEqual((r.returncode, r.stderr.decode()), (0, ""))
        return json.loads(r.stdout)


class UsageTest(RssCase):
    def test_bare_unknown_and_wrong_field_counts(self):
        usage = S["rssUsage"]
        before = len(self.log())
        self.refused(self.rss("", argv=["rss"]), usage, 2)
        for sub in ("go", "ITEMS", "items2", "search"):
            self.refused(self.rss(sub), usage, 2)
        self.refused(self.rss("items", argv=["rss", "items", "extra"]), usage, 2)
        counts = {"error": 1, "add-folder": 1, "remove": 1, "refresh": 1,
                  "article": 2, "add-feed": 2, "rename": 2, "add": 2, "mark-read": 3}
        for sub, k in counts.items():
            for n in (k - 1, k + 1):
                if n < 1:
                    continue
                with self.subTest(sub=sub, fields=n):
                    self.refused(self.rss(sub, *(["x"] * n)), usage, 2)
            # A trailing NUL is one more (empty) field.
            self.refused(self.rss(sub, raw=("\0".join(["x"] * k) + "\0").encode()), usage, 2)
        self.assertEqual(self.since(before), [])

    def test_empty_stdin_is_one_empty_field(self):
        before = len(self.log())
        self.ok(self.rss("refresh", raw=b""), {"ok": True})
        post = self.posts_since(before, "/api/v2/rss/refreshItem")
        self.assertEqual(self.form(post[0]), {"itemPath": [""]})
        self.refused(self.rss("article", raw=b""), S["rssUsage"], 2)

    def test_items_reads_no_stdin(self):
        self.assertEqual(self.rss("items", raw=b"junk\0junk").returncode, 0)


class ItemsTest(RssCase):
    def test_items_shape(self):
        before = len(self.log())
        out = self.items()
        self.assertEqual(out, rssitems.flatten(tree(), False, 30))
        gets = [(e["path"], e["query"]) for e in self.since(before)]
        self.assertEqual(gets, [("/api/v2/rss/items", {"withData": ["true"]}), ("/api/v2/app/preferences", {})])
        self.assertEqual([e["method"] for e in self.since(before)], ["GET", "GET"])

    def test_items_follows_the_preferences(self):
        self.addCleanup(self.set_pref, "rss_refresh_interval", 30)
        self.addCleanup(self.set_pref, "rss_processing_enabled", False)
        self.set_pref("rss_processing_enabled", True)
        self.set_pref("rss_refresh_interval", 7)
        out = self.items()
        self.assertEqual((out["processing"], out["refreshInterval"]), (True, 7))

    def test_no_description_anywhere(self):
        r = self.rss("items")
        self.assertNotIn(b"description", r.stdout)
        self.assertNotIn(b"Hello", r.stdout)
        self.assertNotIn(b"alert", r.stdout.replace(b"javascript:alert(1)", b""))

    def test_an_empty_tree(self):
        self.reset({})
        self.assertEqual(self.items(), {"processing": False, "refreshInterval": 30, "feeds": [], "articles": []})

    def test_read_failures_report_codes_only(self):
        self.control({"rss_items": "409secret"})
        r = self.rss("items")
        self.refused(r, "qBittorrent refused it (HTTP 409)")
        self.assertNotIn("SECRET", r.stderr.decode())
        self.control({"rss_items": "unreadable"})
        self.refused(self.rss("items"), "qBittorrent sent something unreadable")
        self.control({"preferences": "500"})
        self.refused(self.rss("items"), "qBittorrent refused it (HTTP 500)")
        self.control({"forbidden": True})
        self.refused(self.rss("items"), "qBittorrent refused it (localhost auth is required)")
        self.control({})
        r = self.rss("items", env={"QBT_BASE": f"http://127.0.0.1:{harness._free_port()}"})
        self.refused(r, "qBittorrent refused it (couldn't reach qBittorrent)")
        r = self.rss("items", env={"QBT_BASE": "http://127.0.0.2:1"})
        self.refused(r, "refusing non-localhost host (base must be http://127.0.0.1:<port>)")

    def test_the_fixture_clock_and_scripted_sources(self):
        # A refresh loads for rss_load_ticks reads, then applies the source;
        # an article without torrentURL gets its link.
        src = {"title": "Fresh", "articles": [{"id": "n1", "date": DATE, "title": "news", "link": "https://x.example/1",
                                                "description": ""}]}
        self.control({"rss_load_ticks": 2, "rss_sources": {ARCH_URL: src}})
        self.ok(self.rss("refresh", "Linux\\arch"), {"ok": True})
        states = []
        for _ in range(3):
            f = next(f for f in self.items()["feeds"] if f["path"] == "Linux\\arch")
            states.append((f["isLoading"], f["total"], f["title"]))
        self.assertEqual(states, [(True, 1, "Arch Linux: Recent news updates"),
                                  (True, 1, "Arch Linux: Recent news updates"), (False, 2, "Fresh")])
        n1 = next(a for a in self.node("Linux\\arch")["articles"] if a["id"] == "n1")
        self.assertEqual(n1["torrentURL"], "https://x.example/1")
        self.assertNotIn("isRead", n1)


class ArticleTest(RssCase):
    def test_the_text_rules(self):
        self.ok(self.rss("article", "Linux\\Debian", "d1"), {"text": "Hello world", "truncated": False})
        self.ok(self.rss("article", "Linux\\Debian", "d2"), {"text": "news", "truncated": False})
        for c in cases("articleText"):
            with self.subTest(why=c["why"]):
                t = tree()
                t["Linux"]["Debian"]["articles"][0]["description"] = c["input"]
                self.reset(t)
                self.ok(self.rss("article", "Linux\\Debian", "d1"), c["normalised"])

    def test_hostile_descriptions(self):
        t = tree()
        big = "<p>" + ("&amp;<b>x</b><img src=x onerror=alert(1)>‮" * 60000) + "</p>"
        t["Linux"]["Debian"]["articles"][0]["description"] = big
        self.reset(t)
        r = self.rss("article", "Linux\\Debian", "d1")
        out = json.loads(r.stdout)
        self.assertTrue(out["truncated"])
        self.assertEqual(len(out["text"]), 4096)
        self.assertNotIn("<", out["text"])
        self.assertNotIn("onerror", out["text"])

    def test_gone(self):
        for path, guid in (("Linux\\Nope", "d1"), ("Linux\\Debian", "zz"), ("Linux", "d1"), ("", "d1"),
                           ("Linux\\Debian\\d1", "d1")):
            with self.subTest(path=path, guid=guid):
                self.refused(self.rss("article", path, guid), S["articleGone"])


class AddFeedTest(RssCase):
    def test_add_then_refresh(self):
        before = len(self.log())
        url = "https://feeds.example/new.xml?cat=4&x=1"
        self.ok(self.rss("add-feed", url, "Linux\\New feed"), {"ok": True, "path": "Linux\\New feed"})
        posts = self.posts_since(before)
        self.assertEqual([p["path"] for p in posts], ["/api/v2/rss/addFeed", "/api/v2/rss/refreshItem"])
        self.assertEqual(self.form(posts[0]), {"url": [url], "path": ["Linux\\New feed"]})
        self.assertEqual(self.form(posts[1]), {"itemPath": ["Linux\\New feed"]})
        self.assertEqual(self.node("Linux\\New feed")["url"], url)
        # The read-back came between the two posts.
        paths = [e["path"] for e in self.since(before)]
        self.assertEqual(paths, ["/api/v2/rss/addFeed", "/api/v2/rss/items", "/api/v2/rss/refreshItem"])

    def test_the_fixture_fetches_on_add_only_while_processing_is_on(self):
        self.control({"rss_load_ticks": 0, "rss_sources": {"https://p.example/": {"title": "P"}}})
        before = len(self.log())
        urllib.request.urlopen(urllib.request.Request(
            self.url("/api/v2/rss/addFeed"), data=b"url=https%3A%2F%2Fp.example%2F&path=P", method="POST"), timeout=5)
        self.assertEqual(self.node("P")["title"], "")
        self.set_pref("rss_processing_enabled", True)
        try:
            urllib.request.urlopen(urllib.request.Request(
                self.url("/api/v2/rss/addFeed"), data=b"url=https%3A%2F%2Fq.example%2F&path=Q", method="POST"),
                timeout=5)
            self.assertEqual(self.node("P")["title"], "P", "processing on: addFeed refreshes everything")
        finally:
            self.set_pref("rss_processing_enabled", False)
        self.assertEqual(len(self.posts_since(before, "/api/v2/rss/refreshItem")), 0)

    def test_a_root_feed(self):
        self.ok(self.rss("add-feed", "http://x.example/r", "Root"), {"ok": True, "path": "Root"})

    def test_duplicate_and_missing_folders(self):
        self.refused(self.rss("add-feed", DEBIAN_URL, "Linux\\Again"), S["feedDup"])
        self.refused(self.rss("add-feed", "https://n.example/", "Nope\\x"), S["folderGone"])
        self.refused(self.rss("add-feed", "https://n.example/", "Linux\\Debian\\x"), S["folderGone"])
        self.refused(self.rss("add-feed", "https://n.example/", "Linux\\Debian"),
                     sentence("itemExists", name="Debian"))

    def test_the_url_cases(self):
        for c in cases("feedUrl"):
            with self.subTest(why=c["why"]):
                if c["ok"]:
                    self.reset({})
                    self.ok(self.rss("add-feed", c["input"], "F"), {"ok": True, "path": "F"})
                    self.assertEqual(self.node("F")["url"], c["input"])
                else:
                    self.refused_before_any_request("add-feed", (c["input"], "F"), c["message"])

    def test_the_new_segment_only(self):
        # The name rule on the new segment: a refusal gets its message, a
        # segment it would trim is the usage line; existing parents are
        # taken as they are (qBittorrent names feeds untrimmed).
        self.refused_before_any_request("add-feed", ("https://n.example/", "Linux\\"), S["nameEmpty"])
        self.refused_before_any_request("add-feed", ("https://n.example/", ""), S["nameEmpty"])
        self.refused_before_any_request("add-feed", ("https://n.example/", "Linux\\a\u0007b"), S["nameControl"])
        self.refused_before_any_request("add-feed", ("https://n.example/", "Linux\\ New"), S["rssUsage"], 2)
        self.refused_before_any_request("add-feed", ("https://n.example/", "Linux\\New　"), S["rssUsage"], 2)
        # A trailing newline is a Qt space too, never lost on the way.
        self.refused_before_any_request("add-folder", ("Linux\\New\n",), S["rssUsage"], 2)
        self.refused_before_any_request("rename", ("Linux\n\\Debian", "Linux\\Debian2"), S["rssUsage"], 2)
        t = tree()
        t[" Spaced "] = {}
        self.reset(t)
        self.ok(self.rss("add-feed", "https://n.example/", " Spaced \\New"), {"ok": True, "path": " Spaced \\New"})

    def test_the_read_back(self):
        self.control({"rss_addFeed": "noop"})
        before = len(self.log())
        self.refused(self.rss("add-feed", "https://n.example/", "Linux\\Gone"),
                     sentence("unconfirmedAdd", name="Gone"))
        self.assertEqual(self.posts_since(before, "/api/v2/rss/refreshItem"), [])

    def test_other_failures(self):
        self.control({"rss_addFeed": "409secret"})
        r = self.rss("add-feed", "https://n.example/", "N")
        self.refused(r, "qBittorrent refused it (HTTP 409)")
        self.assertNotIn("SECRET", r.stderr.decode())
        self.control({"rss_addFeed": "500"})
        self.refused(self.rss("add-feed", "https://n.example/", "N"), "qBittorrent refused it (HTTP 500)")


class FolderRenameRemoveTest(RssCase):
    def test_add_folder(self):
        before = len(self.log())
        self.ok(self.rss("add-folder", "Linux\\Distros\\Fedora"), {"ok": True, "path": "Linux\\Distros\\Fedora"})
        self.assertEqual(self.node("Linux\\Distros\\Fedora"), {})
        self.assertEqual(self.form(self.posts_since(before)[0]), {"path": ["Linux\\Distros\\Fedora"]})
        self.refused(self.rss("add-folder", "Linux"), sentence("itemExists", name="Linux"))
        self.refused(self.rss("add-folder", "Nope\\x"), S["folderGone"])
        self.refused_before_any_request("add-folder", ("x\u0085y",), S["nameControl"])
        self.refused_before_any_request("add-folder", (" x",), S["rssUsage"], 2)
        self.control({"rss_addFolder": "noop"})
        self.refused(self.rss("add-folder", "Quiet"), sentence("unconfirmedAdd", name="Quiet"))

    def test_rename(self):
        before = len(self.log())
        self.ok(self.rss("rename", "Linux\\Debian", "Linux\\debian"), {"ok": True, "path": "Linux\\debian"})
        self.assertEqual(self.form(self.posts_since(before)[0]),
                         {"itemPath": ["Linux\\Debian"], "destPath": ["Linux\\debian"]})
        self.assertIsNone(self.node("Linux\\Debian"))
        self.ok(self.rss("rename", "Linux", "Operating systems"), {"ok": True, "path": "Operating systems"})
        self.assertEqual(self.node("Operating systems\\debian")["url"], DEBIAN_URL)

    def test_rename_refusals(self):
        self.refused_before_any_request("rename", ("Linux\\Debian", "Zeta\\Debian"), S["rssUsage"], 2)
        self.refused_before_any_request("rename", ("Linux\\Debian", "Debian"), S["rssUsage"], 2)
        self.refused_before_any_request("rename", ("Linux\\Debian", "Linux\\"), S["nameEmpty"])
        self.refused_before_any_request("rename", ("Linux\\Debian", "Linux\\ D"), S["rssUsage"], 2)
        before = len(self.log())
        self.refused(self.rss("rename", "Linux\\Gone", "Linux\\Went"), S["feedGone"])
        self.assertEqual(self.posts_since(before), [])
        self.refused(self.rss("rename", "Linux\\Debian", "Linux\\arch"), sentence("itemExists", name="arch"))

    def test_rename_read_back(self):
        self.control({"rss_ignore_move": True})
        self.refused(self.rss("rename", "Linux\\Debian", "Linux\\Deb"), S["unconfirmedRename"])
        self.assertIsNotNone(self.node("Linux\\Debian"))

    def test_an_untrimmed_existing_name_stays_manageable(self):
        t = tree()
        t[" Debian "] = feed(9, "https://spaced.example/")
        self.reset(t)
        self.ok(self.rss("rename", " Debian ", "Debian2"), {"ok": True, "path": "Debian2"})
        self.ok(self.rss("remove", "Debian2"), {"ok": True})

    def test_remove(self):
        before = len(self.log())
        self.ok(self.rss("remove", "Linux"), {"ok": True})
        self.assertEqual(self.form(self.posts_since(before)[0]), {"path": ["Linux"]})
        self.assertIsNone(self.node("Linux"))
        self.assertEqual([f["path"] for f in self.items()["feeds"]], ["alpha", "Zeta", "Zeta\\News", "Zeta\\news"])
        before = len(self.log())
        self.refused(self.rss("remove", "Linux"), S["feedGone"])
        self.assertEqual(self.posts_since(before), [])
        self.refused(self.rss("remove", ""), S["feedGone"])
        self.control({"rss_removeItem": "noop"})
        self.refused(self.rss("remove", "alpha"), sentence("unconfirmedRemove", name="alpha"))


class MarkReadTest(RssCase):
    def unread(self, path):
        return next(f for f in self.items()["feeds"] if f["path"] == path)["unread"]

    def test_an_article(self):
        before = len(self.log())
        self.ok(self.rss("mark-read", "Linux\\Debian", "d1", "0"), {"ok": True})
        self.assertEqual(self.form(self.posts_since(before)[0]), {"itemPath": ["Linux\\Debian"], "articleId": ["d1"]})
        self.assertTrue(self.node("Linux\\Debian")["articles"][0]["isRead"])
        self.refused(self.rss("mark-read", "Linux\\Gone", "d1", "0"), S["feedGone"])
        self.refused(self.rss("mark-read", "Linux\\Debian", "zz", "0"), S["articleGone"])
        self.refused(self.rss("mark-read", "Linux", "d1", "0"), S["articleGone"])
        self.control({"rss_markAsRead": "noop"})
        self.refused(self.rss("mark-read", "Linux\\Debian", "d2", "0"), S["unconfirmedRead"])

    def test_a_feed_a_folder_and_everything(self):
        for path, expect in (("Linux\\Debian", "3"), ("Linux", "1"), ("", "1")):
            with self.subTest(path=path):
                before = len(self.log())
                self.ok(self.rss("mark-read", path, "", expect), {"ok": True})
                post = self.posts_since(before, "/api/v2/rss/markAsRead")
                # articleId is omitted entirely (rsscontroller.cpp:143).
                self.assertEqual(post[0]["body"], "itemPath=" + urllib.request.quote(path, safe=""))
                self.assertEqual(self.form(post[0]), {"itemPath": [path]})
        self.assertEqual(self.items()["feeds"][1]["unread"], 0)
        self.assertTrue(all(a["isRead"] for a in self.items()["articles"]))

    def test_more_arrived(self):
        before = len(self.log())
        self.ok(self.rss("mark-read", "Linux", "", "3"), {"ok": False, "unread": 4})
        self.ok(self.rss("mark-read", "", "", "0"), {"ok": False, "unread": 5})
        self.assertEqual(self.posts_since(before), [])
        self.assertEqual(self.unread("Linux"), 4)
        # More than the count now is fine: fewer are left to mark.
        self.ok(self.rss("mark-read", "Linux", "", "9"), {"ok": True})

    def test_a_missing_path_is_caught_before_the_silent_200(self):
        before = len(self.log())
        self.refused(self.rss("mark-read", "Linux\\Gone", "", "0"), S["feedGone"])
        self.assertEqual(self.posts_since(before), [])
        # qBittorrent itself answers 200 and does nothing.
        with urllib.request.urlopen(urllib.request.Request(self.url("/api/v2/rss/markAsRead"),
                                                           data=b"itemPath=Nope", method="POST"), timeout=5) as r:
            self.assertEqual(r.status, 200)

    def test_expect_must_be_a_whole_number(self):
        for bad in ("", "-1", "x", "1.5", "１", "99999999999"):
            with self.subTest(expect=bad):
                self.refused_before_any_request("mark-read", ("Linux", "", bad), S["rssUsage"], 2)

    def test_the_read_back(self):
        self.control({"rss_markAsRead": "noop"})
        self.refused(self.rss("mark-read", "Linux", "", "4"), S["unconfirmedRead"])


class RefreshTest(RssCase):
    def test_existing_missing_and_all(self):
        before = len(self.log())
        self.ok(self.rss("refresh", "Linux\\Debian"), {"ok": True})
        self.assertEqual(self.form(self.posts_since(before)[0]), {"itemPath": ["Linux\\Debian"]})
        self.assertTrue(self.node("Linux\\Debian")["isLoading"])
        before = len(self.log())
        self.refused(self.rss("refresh", "Linux\\Gone"), S["feedGone"])
        self.assertEqual(self.posts_since(before), [])
        before = len(self.log())
        self.ok(self.rss("refresh", ""), {"ok": True})
        post = self.posts_since(before)
        self.assertEqual([p["body"] for p in post], ["itemPath="])
        self.assertTrue(self.node("Zeta\\news")["isLoading"])


class AddTest(RssCase):
    def test_magnet_and_enclosure(self):
        before = len(self.log())
        self.ok(self.rss("add", MAGNET, "https://www.debian.org/News/2025/13"), {"ok": True, "via": "magnet"})
        enc = "https://tracker.example/download.php?id=42"
        self.ok(self.rss("add", enc, "https://tracker.example/details.php?id=42"), {"ok": True, "via": "url"})
        posts = self.posts_since(before)
        self.assertEqual([p["path"] for p in posts], ["/api/v2/torrents/add", "/api/v2/torrents/add"])
        self.assertEqual([self.form(p) for p in posts], [{"urls": [MAGNET]}, {"urls": [enc]}])

    def test_every_has_torrent_case(self):
        for c in cases("hasTorrent"):
            i = c["input"]
            if "\0" in i["torrentURL"]:
                continue  # the NUL framing can't carry a NUL; LibRulesTest covers it
            with self.subTest(why=c["why"]):
                if not c["ok"]:
                    self.refused_before_any_request("add", (i["torrentURL"], i["link"]), c["message"])
                    continue
                before = len(self.log())
                self.ok(self.rss("add", i["torrentURL"], i["link"]), {"ok": True, "via": c["normalised"]})
                self.assertEqual(self.form(self.posts_since(before)[0]), {"urls": [i["torrentURL"]]})

    def test_failures(self):
        self.control({"add": "404"})
        self.refused(self.rss("add", MAGNET, ""), "qBittorrent refused it (HTTP 404)")


class ErrorTest(RssCase):
    def row(self, url, reason, kind="download"):
        verb = "download" if kind == "download" else "parse"
        return {"message": f"Failed to {verb} RSS feed at '{url}'. Reason: {reason}", "type": "warning"}

    def test_a_reason_found_and_another_url(self):
        self.reset(tree(), [self.row(UBUNTU_URL, "Host ubuntu.example not found"),
                            {"message": "unrelated", "type": "normal"}])
        before = len(self.log())
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "Host ubuntu.example not found"})
        reqs = self.since(before)
        self.assertEqual([e["path"] for e in reqs], ["/api/v2/log/main", "/api/v2/rss/items"])
        self.assertEqual(reqs[0]["query"], {"normal": ["false"], "info": ["false"], "warning": ["true"],
                                            "critical": ["false"], "last_known_id": ["-1"]})
        self.ok(self.rss("error", DEBIAN_URL), {"reason": None})
        self.ok(self.rss("error", "https://never.example/"), {"reason": None})
        st = self.state_path()
        self.assertEqual(stat.S_IMODE(st.stat().st_mode), 0o600)
        self.assertEqual(json.loads(st.read_text()), {"lastId": 0, "reasons": {UBUNTU_URL: "Host ubuntu.example not found"}})

    def test_last_known_id_advances_and_newer_rows_win(self):
        self.reset(tree(), [self.row(UBUNTU_URL, "old")], log_start=10)
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "old"})
        self.assertEqual(json.loads(self.state_path().read_text())["lastId"], 10)
        # The fixture's scripted failure appends a newer warning.
        self.control({"rss_load_ticks": 0, "rss_feed_errors": {UBUNTU_URL: "Connection timed out"}})
        self.ok(self.rss("refresh", "Linux\\Distros\\ubuntu"), {"ok": True})
        before = len(self.log())
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "Connection timed out"})
        self.assertEqual(self.since(before)[0]["query"]["last_known_id"], ["9"])
        self.assertEqual(json.loads(self.state_path().read_text())["lastId"], 11)
        before = len(self.log())
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "Connection timed out"})
        self.assertEqual(self.since(before)[0]["query"]["last_known_id"], ["10"])

    def test_the_reason_lasts_until_the_error_clears(self):
        self.reset(tree(), [self.row(UBUNTU_URL, "gone away")])
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "gone away"})
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "gone away"})
        self.control({"rss_load_ticks": 0})
        self.ok(self.rss("refresh", "Linux\\Distros\\ubuntu"), {"ok": True})
        self.ok(self.rss("error", UBUNTU_URL), {"reason": None})
        self.assertEqual(json.loads(self.state_path().read_text())["reasons"], {})

    def test_a_restarted_qbittorrent_is_read_again(self):
        self.reset(tree(), [{"message": "x", "type": "warning"}] * 5 + [self.row(UBUNTU_URL, "before")])
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "before"})
        self.assertEqual(json.loads(self.state_path().read_text())["lastId"], 5)
        # Restarted: the ids begin again at 0.
        self.reset(tree(), [self.row(UBUNTU_URL, "after")])
        before = len(self.log())
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "after"})
        queries = [e["query"]["last_known_id"] for e in self.since(before) if e["path"] == "/api/v2/log/main"]
        self.assertEqual(queries, [["4"], ["-1"]])
        self.assertEqual(json.loads(self.state_path().read_text())["lastId"], 0)

    def test_at_most_200_urls_least_recently_stored_dropped(self):
        t = {f"f{i:03d}": feed(100 + i, f"https://f{i:03d}.example/", has_error=True) for i in range(250)}
        self.reset(t, [self.row(f"https://f{i:03d}.example/", f"r{i}") for i in range(250)])
        self.ok(self.rss("error", "https://f249.example/"), {"reason": "r249"})
        reasons = json.loads(self.state_path().read_text())["reasons"]
        self.assertEqual(len(reasons), 200)
        self.assertNotIn("https://f000.example/", reasons)
        self.ok(self.rss("error", "https://f000.example/"), {"reason": None})

    def test_a_planted_or_symlinked_state_file(self):
        target = Path(tempfile.mkdtemp(prefix="qbt-rss-target-"))
        self.addCleanup(shutil.rmtree, target, True)
        planted = json.dumps({"lastId": 0, "reasons": {"https://planted.example/": "planted"}})
        (target / "victim").write_text(planted)
        self.state_path().symlink_to(target / "victim")
        self.reset(tree(), [self.row(UBUNTU_URL, "r")])
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "r"})
        self.assertEqual((target / "victim").read_text(), planted)
        # The symlinked file was never read as the cache.
        self.assertEqual(json.loads(self.state_path().read_text()), {"lastId": 0, "reasons": {UBUNTU_URL: "r"}})
        self.assertFalse(self.state_path().is_symlink())
        self.state_path().write_text("not json")
        self.ok(self.rss("error", UBUNTU_URL), {"reason": "r"})

    def test_failures(self):
        self.control({"log_main": "500"})
        self.refused(self.rss("error", UBUNTU_URL), "qBittorrent refused it (HTTP 500)")
        self.control({"log_main": "unreadable"})
        self.refused(self.rss("error", UBUNTU_URL), "qBittorrent sent something unreadable")


class PostOnlyTest(RssCase):
    def test_every_write_is_a_post_and_get_is_405(self):
        for action in ("addFolder", "addFeed", "removeItem", "moveItem", "markAsRead", "refreshItem"):
            with self.subTest(action=action):
                with self.assertRaises(urllib.error.HTTPError) as cm:
                    urllib.request.urlopen(self.url(f"/api/v2/rss/{action}?path=x&itemPath=x"), timeout=5)
                self.assertEqual(cm.exception.code, 405)
        before = len(self.log())
        self.rss("add-folder", "P")
        self.rss("add-feed", "https://p.example/", "P\\f")
        self.rss("rename", "P\\f", "P\\g")
        self.rss("mark-read", "P\\g", "", "0")
        self.rss("refresh", "P")
        self.rss("remove", "P")
        writes = [e for e in self.since(before) if e["path"].rsplit("/", 1)[1] in (
            "addFolder", "addFeed", "removeItem", "moveItem", "markAsRead", "refreshItem")]
        self.assertEqual(len(writes), 7)
        self.assertTrue(all(e["method"] == "POST" for e in writes))


class NoBodyOnDiskOrArgvTest(RssCase):
    """Response bodies never touch disk, and no value reaches any argv."""

    def big_tree(self):
        t = tree()
        for i in range(40):
            t["Linux"]["Debian"]["articles"].append(
                article(f"big{i}", "x" * 3000, f"https://big.example/{i}", description="y" * 3000))
        return t

    def commands(self):
        yield "items", ()
        yield "article", ("Linux\\Debian", "big3")
        yield "error", (UBUNTU_URL,)
        yield "add-folder", ("MARKER-FOLDER",)
        yield "add-feed", ("https://marker-url.example/MARKER-Q", "MARKER-FOLDER\\MARKER-FEED")
        yield "rename", ("MARKER-FOLDER\\MARKER-FEED", "MARKER-FOLDER\\MARKER-RENAMED")
        yield "mark-read", ("Linux\\Debian", "big7", "0")
        yield "mark-read", ("MARKER-FOLDER", "", "0")
        yield "refresh", ("MARKER-FOLDER\\MARKER-RENAMED",)
        yield "add", ("magnet:?xt=urn:btih:" + "c" * 40 + "&dn=MARKER-MAGNET", "")
        yield "remove", ("MARKER-FOLDER",)

    def test_ulimit_and_a_fresh_tmpdir(self):
        self.reset(self.big_tree(), [ErrorTest.row(None, UBUNTU_URL, "r")])
        self.assertGreater(len(self.rss("items").stdout), 100000)
        tmpdir = Path(tempfile.mkdtemp(prefix="qbt-tmp-"))
        self.addCleanup(shutil.rmtree, tmpdir, True)
        env = dict(self.env, TMPDIR=str(tmpdir), TMP=str(tmpdir), TEMP=str(tmpdir))
        for sub, fields in self.commands():
            with self.subTest(sub=sub):
                r = subprocess.run(["bash", "-c", 'ulimit -f 32 && exec "$0" "$@"', QBT, "rss", sub],
                                   env=env, input="\0".join(fields).encode(), capture_output=True, timeout=60)
                self.assertEqual((r.returncode, r.stderr), (0, b""), sub)
                self.assertEqual(list(tmpdir.iterdir()), [])

    def test_no_value_is_ever_on_an_argv(self):
        # Shims for curl, jq and python3 log every argv they get.
        shims = Path(tempfile.mkdtemp(prefix="qbt-shims-"))
        self.addCleanup(shutil.rmtree, shims, True)
        argv_log = shims / "argv.log"
        for tool in ("curl", "jq", "python3"):
            real = shutil.which(tool)
            (shims / tool).write_text(f'#!/bin/bash\nprintf "%s " "$@" >>"{argv_log}"\necho >>"{argv_log}"\n'
                                      f'exec "{real}" "$@"\n')
            (shims / tool).chmod(0o755)
        env = dict(self.env, PATH=f"{shims}:{os.environ['PATH']}")
        self.reset(self.big_tree(), [ErrorTest.row(None, UBUNTU_URL, "MARKER-REASON")])
        for sub, fields in self.commands():
            with self.subTest(sub=sub):
                r = self.rss(sub, *fields, env=env)
                self.assertEqual((r.returncode, r.stderr), (0, b""), sub)
        logged = argv_log.read_text()
        self.assertIn("/api/v2/rss/items", logged)
        self.assertGreater(logged.count("\n"), 20)
        for marker in ("MARKER", "big3", "big7", "marker-url", "Debian", "ubuntu.example", "cccc"):
            self.assertNotIn(marker, logged, marker)

    def test_rss_code_has_no_here_strings_or_temp_files(self):
        text = (ROOT / "qbt").read_text()
        start = text.index("# Slice 5b1: `qbt rss`")
        end = text.index("\ncase ${1:-} in", start)
        code = "\n".join(line for line in text[start:end].splitlines() if not line.lstrip().startswith("#"))
        for word in ("<<<", "mktemp", "tee ", "--data \"", "--arg ", "--argjson", "api POST", "api_try POST"):
            self.assertNotIn(word, code, word)


if __name__ == "__main__":
    unittest.main()
