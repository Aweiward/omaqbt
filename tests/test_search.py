"""Slice 5a (Task 2): `qbt search` and `qbt search-plugin` against the
fixture's qBittorrent 5.2.3 search API, and lib/searchrules.py against
every case in tests/fixtures/search-rules-cases.json.

The contract is tests/fixtures/search-contract.md. Every message these
tests expect is read from the case file (its cases and sentences), never
retyped. A refusal prints exactly one sentence on stderr, nothing on
stdout, and sends no request at all when it's an argument check.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs, unquote

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "fixtures"))
sys.path.insert(0, str(ROOT / "lib"))
import harness  # noqa: E402
import searchrules  # noqa: E402

QBT = os.environ.get("QBT_UNDER_TEST", str(ROOT / "qbt"))
DATA = json.loads((ROOT / "tests" / "fixtures" / "search-rules-cases.json").read_text())
CASES = DATA["cases"]
# The pageLink rows moved to link-rules-cases.json (slice 5b0); the rule loops still run them.
LINK_CASES = json.loads((ROOT / "tests" / "fixtures" / "link-rules-cases.json").read_text())["cases"]
RULE_CASES = CASES + [c for c in LINK_CASES if c["kind"] == "pageLink"]
S = DATA["sentences"]
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
S_BAD_URL = next(c["message"] for c in CASES if c["kind"] == "pluginUrl" and c["why"] == "a space")
MAGNET = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=debian"
PLUGIN_URL = "https://example.org/plugins/jackett.py"


def cases(kind):
    return [c for c in CASES if c["kind"] == kind]


def sentence(key, **values):
    text = S[key]
    for k, v in values.items():
        text = text.replace(f"<{k}>", v)
    return text


def plugin(name, version="1.0", enabled=True, categories=("movies",), full_name=None):
    cats = [{"id": "all", "name": "All categories"}]
    names = {"anime": "Anime", "books": "Books", "games": "Games", "movies": "Movies", "music": "Music",
             "pictures": "Pictures", "software": "Software", "tv": "TV shows"}
    cats += [{"id": c, "name": names[c]} for c in sorted(categories)]
    return {"name": name, "version": version, "fullName": full_name or name.title(),
            "url": f"https://{name}.example", "supportedCategories": cats, "enabled": enabled}


class LibRulesTest(unittest.TestCase):
    """Every rule case, straight through lib/searchrules.py (the NUL case
    can only be checked here: argv can't carry a NUL)."""

    def check_case(self, c):
        ok, normalised, host, message = searchrules.check(c["kind"], c["input"])
        label = f"{c['kind']}: {c['why']}"
        self.assertEqual(ok, c["ok"], label)
        if c["ok"]:
            if "normalised" in c:
                self.assertEqual(normalised, c["normalised"], label)
            if "host" in c:
                self.assertEqual(host, c["host"], label)
        else:
            self.assertEqual(message, c["message"], label)

    def test_every_rule_case(self):
        kinds = ("pluginUrl", "pageLink", "addLink", "pluginName", "pattern", "category", "searchId")
        n = 0
        for c in RULE_CASES:
            if c["kind"] in kinds:
                with self.subTest(kind=c["kind"], why=c["why"]):
                    self.check_case(c)
                n += 1
        self.assertGreater(n, 140)

    def test_every_install_readback_case(self):
        for c in cases("installReadback"):
            with self.subTest(why=c["why"]):
                i = c["input"]
                got = searchrules.install_readback(i["name"], i["before"], i["after"])
                self.assertEqual(got, None if c["ok"] else c["message"])

    def test_the_cli_reads_stdin_and_matches_every_case(self):
        for c in RULE_CASES:
            if c["kind"] not in ("pluginUrl", "pageLink", "addLink", "pluginName", "pattern", "category", "searchId"):
                continue
            value = "\0".join(c["input"]) if c["kind"] == "addLink" else c["input"]
            r = subprocess.run([sys.executable, str(ROOT / "lib" / "searchrules.py"), c["kind"]],
                               input=value.encode("utf-8"), capture_output=True)
            with self.subTest(kind=c["kind"], why=c["why"]):
                if c["ok"]:
                    self.assertEqual(r.returncode, 0)
                    normalised, host = r.stdout.decode().split("\t")
                    if "normalised" in c:
                        self.assertEqual(normalised, c["normalised"])
                    if "host" in c:
                        self.assertEqual(host, c["host"])
                else:
                    self.assertEqual((r.returncode, r.stdout.decode()), (1, c["message"]))

    def test_invalid_utf8_is_refused_like_a_control_character(self):
        run = lambda kind, raw: subprocess.run(  # noqa: E731
            [sys.executable, str(ROOT / "lib" / "searchrules.py"), kind], input=raw, capture_output=True)
        bad_url = run("pluginUrl", b"https://example.org/\xffjackett.py")
        self.assertEqual((bad_url.returncode, bad_url.stdout.decode()), (1, S_BAD_URL))
        self.assertEqual(run("pattern", b"deb\xffian").stdout.decode(), "Use a search without control characters.")
        self.assertEqual(run("addLink", b"magnet:?xt=\xff").stdout.decode(), "That result has no usable link.")

    def test_no_url_library_and_no_idna_codec(self):
        text = (ROOT / "lib" / "searchrules.py").read_text()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for word in ("urllib", "urlsplit", "urlparse", '"idna"', "'idna'"):
            self.assertNotIn(word, code.split('"""', 2)[2], word)
        # RFC 3492 without nameprep: the idna codec would have mapped this.
        self.assertEqual(searchrules.host_of("ß.example"), "xn--zca.example")


class SearchCase(unittest.TestCase):
    """One fixture per class; every test starts with no jobs, the default
    plugins, no faults and no search.id."""

    extra_env = None

    @classmethod
    def setUpClass(cls):
        env = dict(UTF8_ENV)
        env.update(cls.extra_env or {})
        cls._cm = harness.fixture_server(extra_env=env)
        cls.port, cls.env = cls._cm.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls._cm.__exit__(None, None, None)

    def setUp(self):
        self.control({})
        self.reset()
        self.id_path().unlink(missing_ok=True)

    def tearDown(self):
        self.control({})

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def reset(self, plugins=None):
        body = b"" if plugins is None else json.dumps(plugins).encode()
        req = urllib.request.Request(self.url("/fixture/search-reset"), data=body, method="POST")
        urllib.request.urlopen(req, timeout=5).read()

    def control(self, value):
        Path(self.env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(value))

    def id_path(self):
        return Path(self.env["QBT_STATE_DIR"]) / "search.id"

    def run_qbt(self, *args, env=None, timeout=60):
        full = dict(self.env)
        full.update(env or {})
        return subprocess.run([QBT, *args], env=full, text=True, capture_output=True, timeout=timeout)

    def log(self):
        path = Path(self.env["QBT_FIXTURE_LOG"])
        for _ in range(20):
            text = path.read_text()
            try:
                return json.loads(text or "[]")
            except ValueError:
                time.sleep(0.05)
        raise AssertionError("unreadable fixture log")

    def requests_since(self, before):
        return self.log()[before:]

    def posts_since(self, before, path=None):
        return [e for e in self.requests_since(before)
                if e["method"] == "POST" and (path is None or e["path"] == path)]

    def form(self, entry):
        return parse_qs(entry["body"], keep_blank_values=True)

    def get(self, path):
        # Through qbt's own session: search jobs are per session.
        return json.loads(harness.qbt_urlopen(self.env, path))

    def post(self, path, body):
        try:
            return harness.qbt_request(self.env, path, data=body.encode())
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read()

    def plugins(self):
        return self.get("/api/v2/search/plugins")

    def jobs(self):
        return self.get("/api/v2/search/status")

    def ok(self, r, stdout='{"ok":true}'):
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, stdout, ""))

    def refused(self, r, message):
        self.assertEqual((r.returncode, r.stdout, r.stderr), (1, "", message + "\n"))

    def refused_before_any_request(self, args, message, env=None):
        before = len(self.log())
        r = self.run_qbt(*args, env=env)
        self.refused(r, message)
        self.assertEqual(self.requests_since(before), [], f"{args!r}: no request")


class RuleCasesThroughQbtTest(SearchCase):
    """Every case-file row that argv can carry, through the command that
    enforces it; refusals come before any request."""

    def test_plugin_url_cases_through_install(self):
        self.reset([])
        for c in cases("pluginUrl"):
            if "\0" in c["input"]:
                continue  # argv can't carry a NUL; LibRulesTest covers it
            with self.subTest(why=c["why"]):
                if not c["ok"]:
                    self.refused_before_any_request(("search-plugin", "install", c["input"]), c["message"])
                    continue
                before = len(self.log())
                r = self.run_qbt("search-plugin", "install", c["input"], env={"QBT_SEARCH_INSTALL_WAIT": "0"})
                # Nothing installs it (no source in the fixture's control):
                # the read-back names qBittorrent's name for it.
                self.refused(r, sentence("installUnconfirmed", name=c["normalised"]))
                posts = self.posts_since(before, "/api/v2/search/installPlugin")
                self.assertEqual(len(posts), 1)
                self.assertEqual(self.form(posts[0])["sources"], [c["input"]])

    def test_add_link_cases_through_search_add(self):
        self.reset([plugin("piratebay")])
        for c in cases("addLink"):
            with self.subTest(why=c["why"], input=c["input"]):
                if not c["ok"]:
                    self.refused_before_any_request(("search", "add", *c["input"]), c["message"])
                    continue
                before = len(self.log())
                r = self.run_qbt("search", "add", *c["input"])
                self.ok(r, json.dumps({"ok": True, "via": c["normalised"]}, separators=(",", ":")))
                posts = self.posts_since(before)
                self.assertEqual(len(posts), 1)
                if c["normalised"] == "plugin":
                    self.assertEqual(posts[0]["path"], "/api/v2/search/downloadTorrent")
                    self.assertEqual(self.form(posts[0]), {"torrentUrl": [c["input"][0]], "pluginName": [c["input"][1]]})
                else:
                    self.assertEqual(posts[0]["path"], "/api/v2/torrents/add")
                    self.assertEqual(self.form(posts[0]), {"urls": [c["input"][0]]})

    def test_plugin_name_cases_through_uninstall_enable_and_add(self):
        self.reset([plugin("piratebay"), plugin("eztv_v2"), plugin("Jackett"), plugin("_")])
        for c in cases("pluginName"):
            name = c["input"]
            with self.subTest(why=c["why"]):
                if not c["ok"]:
                    self.refused_before_any_request(("search-plugin", "uninstall", name), c["message"])
                    self.refused_before_any_request(("search-plugin", "enable", name, "on"), c["message"])
                    if name != "":  # an empty plugin is no plugin (addLink)
                        self.refused_before_any_request(("search", "add", "https://example.org/download/1", name),
                                                        c["message"])
                    continue
                self.ok(self.run_qbt("search-plugin", "enable", name, "off"))
                self.ok(self.run_qbt("search", "add", "https://example.org/download/1", name),
                        '{"ok":true,"via":"plugin"}')
                self.ok(self.run_qbt("search-plugin", "uninstall", name))

    def test_pattern_and_category_cases_through_start(self):
        for c in cases("pattern"):
            if "\0" in c["input"]:
                continue
            with self.subTest(why=c["why"]):
                args = ("search", "start", "--pattern", c["input"], "--category", "all")
                if not c["ok"]:
                    self.refused_before_any_request(args, c["message"])
                    continue
                before = len(self.log())
                r = self.run_qbt(*args)
                self.assertEqual((r.returncode, r.stderr), (0, ""))
                post = self.posts_since(before, "/api/v2/search/start")
                self.assertEqual(self.form(post[0])["pattern"], [c["input"]])
        for c in cases("category"):
            with self.subTest(why=c["why"]):
                args = ("search", "start", "--pattern", "debian", "--category", c["input"])
                if not c["ok"]:
                    self.refused_before_any_request(args, c["message"])
                    continue
                before = len(self.log())
                self.assertEqual(self.run_qbt(*args).returncode, 0)
                post = self.posts_since(before, "/api/v2/search/start")
                self.assertEqual(self.form(post[0])["category"], [c["input"]])

    def test_search_id_cases_through_stop_and_delete(self):
        for c in cases("searchId"):
            with self.subTest(why=c["why"]):
                for action in ("stop", "delete"):
                    if not c["ok"]:
                        self.refused_before_any_request(("search", action, c["input"]), c["message"])
                        continue
                    before = len(self.log())
                    # No such job: a 404, which is fine (idempotent cleanup).
                    self.ok(self.run_qbt("search", action, c["input"]))
                    post = self.posts_since(before, f"/api/v2/search/{action}")
                    self.assertEqual(self.form(post[0]), {"id": [c["input"]]})

    def test_magnet_hash_inputs_reach_torrents_add_verbatim(self):
        # The library match is the window's (OV11); qbt's side of a magnet
        # is to hand it to torrents/add exactly as given.
        for c in cases("magnetHash"):
            if not c["input"].lower().startswith("magnet:"):
                continue
            with self.subTest(why=c["why"]):
                before = len(self.log())
                self.ok(self.run_qbt("search", "add", c["input"]), '{"ok":true,"via":"add"}')
                post = self.posts_since(before, "/api/v2/torrents/add")
                self.assertEqual(self.form(post[0]), {"urls": [c["input"]]})


class SearchStartTest(SearchCase):
    def start(self, pattern="debian 13", category="all", env=None):
        return self.run_qbt("search", "start", "--pattern", pattern, "--category", category, env=env)

    def test_start_prints_the_id_and_writes_search_id(self):
        before = len(self.log())
        r = self.start("  debian 13 ", "movies")
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        out = json.loads(r.stdout)
        self.assertEqual(list(out), ["id"])
        jid = out["id"]
        self.assertTrue(1 <= jid <= 2147483647)
        self.assertEqual(r.stdout, json.dumps({"id": jid}, separators=(",", ":")) + "\n")
        gets = [e["path"] for e in self.requests_since(before) if e["method"] == "GET"]
        self.assertEqual(gets, ["/api/v2/search/plugins"])
        self.assertIn(jid, [j["id"] for j in self.jobs()])
        # The id file: the number and a newline, mode 0600.
        path = self.id_path()
        self.assertEqual(path.read_text(), f"{jid}\n")
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertFalse(path.is_symlink())
        posts = self.posts_since(before)
        self.assertEqual([p["path"] for p in posts], ["/api/v2/search/start"])
        self.assertEqual(posts[0]["body"], "pattern=%20%20debian%2013%20&category=movies&plugins=enabled")

    def test_usage(self):
        usage = sentence("startUsage")
        for args in ((), ("--pattern", "x"), ("--category", "all"), ("--pattern", "x", "--category"),
                     ("--pattern", "x", "--category", "all", "extra"), ("--pattern", "x", "--pattern", "y"),
                     ("--category", "all", "--pattern")):
            with self.subTest(args=args):
                self.refused_before_any_request(("search", "start", *args), usage)
        # The flags in either order.
        r = self.run_qbt("search", "start", "--category", "tv", "--pattern", "x")
        self.assertEqual((r.returncode, r.stderr), (0, ""))

    def test_bare_search_and_unknown_subcommand(self):
        for args in (("search",), ("search", "go"), ("search", "START")):
            self.refused_before_any_request(args, sentence("searchUsage"))
        self.refused_before_any_request(("search", "stop"), sentence("stopUsage"))
        self.refused_before_any_request(("search", "stop", "1", "2"), sentence("stopUsage"))
        self.refused_before_any_request(("search", "delete"), sentence("deleteUsage"))
        self.refused_before_any_request(("search", "add"), sentence("addUsage"))
        self.refused_before_any_request(("search", "add", "a", "b", "c"), sentence("addUsage"))

    def test_all_plugins_off(self):
        self.reset([plugin("piratebay", enabled=False), plugin("eztv", enabled=False)])
        before = len(self.log())
        self.refused(self.start(), sentence("allOff"))
        self.assertEqual(self.posts_since(before), [])
        self.reset([])
        self.refused(self.start(), sentence("allOff"))

    def test_plugins_read_failures(self):
        for fault, why in (("500", "HTTP 500"), ("404", "HTTP 404")):
            self.control({"search_plugins": fault})
            before = len(self.log())
            self.refused(self.start(), sentence("pluginsUnreadable", why=why))
            self.assertEqual(self.posts_since(before), [])
        self.control({"search_plugins": "unreadable"})
        self.refused(self.start(), sentence("unreadable"))
        self.control({"search_plugins": "409secret"})
        r = self.start()
        self.refused(r, sentence("pluginsUnreadable", why="HTTP 409"))
        self.assertNotIn("SECRET", r.stderr)

    def test_unreachable_forbidden_and_non_local(self):
        r = self.run_qbt("search", "start", "--pattern", "x", "--category", "all",
                         env={"QBT_BASE": f"http://127.0.0.1:{harness._free_port()}"})
        self.refused(r, sentence("pluginsUnreadable", why="couldn't reach qBittorrent"))
        r = self.run_qbt("search", "start", "--pattern", "x", "--category", "all",
                         env={"QBT_BASE": "http://127.0.0.2:1"})
        self.refused(r, "refusing non-localhost host (base must be http://127.0.0.1:<port>)")
        self.control({"forbidden": True})
        self.refused(self.start(), sentence("pluginsUnreadable", why="localhost auth is required"))

    def test_cap_and_python_409s_are_told_apart(self):
        self.control({"search": {"finish": None}})
        for _ in range(5):
            self.assertEqual(self.start().returncode, 0)
            # Not replaced: each start deletes the job search.id names.
            self.id_path().unlink()
        self.assertEqual([j["status"] for j in self.jobs()], ["Running"] * 5)
        before = len(self.log())
        r = self.start()
        self.refused(r, sentence("cap"))
        self.assertNotIn("concurrent", r.stderr)
        self.assertEqual([e["path"] for e in self.requests_since(before)][-2:],
                         ["/api/v2/search/start", "/api/v2/search/status"])
        self.assertFalse(self.id_path().exists())
        # Stopping one frees a slot.
        jid = self.jobs()[0]["id"]
        self.ok(self.run_qbt("search", "stop", str(jid)))
        self.assertEqual(self.start().returncode, 0)

        self.reset()
        self.control({"search_python": "missing"})
        r = self.start()
        self.refused(r, sentence("noPython"))
        self.assertNotIn("Python must", r.stderr)
        # A 409 whose status read fails.
        self.control({"search_python": "missing", "search_status": "500"})
        self.refused(self.start(), sentence("refused", why="HTTP 409"))
        self.control({"search_python": "missing", "search_status": "unreadable"})
        self.refused(self.start(), sentence("refused", why="HTTP 409"))

    def test_other_failures_and_an_unreadable_id(self):
        self.control({"search_start": "500"})
        self.refused(self.start(), sentence("refused", why="HTTP 500"))
        self.control({"search_start": "409secret", "search_status": "404"})
        r = self.start()
        self.refused(r, sentence("refused", why="HTTP 409"))
        self.assertNotIn("SECRET", r.stderr)
        for body in ("unreadable", "noop"):
            self.control({"search_start": body})
            self.refused(self.start(), sentence("unreadable"))
            self.assertFalse(self.id_path().exists())

    def test_a_stale_job_is_deleted_first(self):
        first = json.loads(self.start().stdout)["id"]
        before = len(self.log())
        second = json.loads(self.start().stdout)["id"]
        posts = self.posts_since(before)
        self.assertEqual([p["path"] for p in posts], ["/api/v2/search/delete", "/api/v2/search/start"])
        self.assertEqual(self.form(posts[0]), {"id": [str(first)]})
        self.assertEqual([j["id"] for j in self.jobs()], [second])
        self.assertEqual(self.id_path().read_text(), f"{second}\n")

    def test_a_stale_job_already_gone_is_fine(self):
        self.id_path().write_text("12345\n")
        r = self.start()
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.assertEqual(self.id_path().read_text(), f"{json.loads(r.stdout)['id']}\n")

    def test_a_stale_delete_that_fails_keeps_the_file(self):
        self.id_path().write_text("12345\n")
        self.control({"search_delete": "500"})
        before = len(self.log())
        self.refused(self.start(), sentence("refused", why="HTTP 500"))
        self.assertEqual(self.id_path().read_text(), "12345\n")
        self.assertEqual(self.posts_since(before, "/api/v2/search/start"), [])

    def test_a_garbage_or_symlinked_search_id_is_just_removed(self):
        for content in ("abc\n", "0\n", "012\n", "2147483648\n", "", "12 34\n", "\u0661\u0662\n"):
            self.id_path().write_text(content)
            before = len(self.log())
            r = self.start()
            self.assertEqual((r.returncode, r.stderr), (0, ""), content)
            self.assertEqual(self.posts_since(before, "/api/v2/search/delete"), [], content)
            self.reset()
        target = Path(tempfile.mkdtemp(prefix="qbt-search-target-"))
        self.addCleanup(shutil.rmtree, target, True)
        (target / "victim").write_text("keep\n")
        self.id_path().unlink(missing_ok=True)
        self.id_path().symlink_to(target / "victim")
        r = self.start()
        self.assertEqual(r.returncode, 0)
        self.assertEqual((target / "victim").read_text(), "keep\n")
        self.assertFalse(self.id_path().is_symlink())
        self.assertEqual(self.id_path().read_text(), f"{json.loads(r.stdout)['id']}\n")

    def start_with_planted_temp(self, plant):
        """Runs `qbt search start` under a known pid (exec keeps it), and
        calls plant(temp_path) before it starts: search_id_write's temporary
        name is search.id.<pid>.tmp."""
        p = subprocess.Popen(["bash", "-c", 'echo $$; read -r _; exec "$0" search start --pattern x --category all',
                              QBT], env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        pid = int(p.stdout.readline())
        tmp = self.id_path().with_name(f"search.id.{pid}.tmp")
        plant(tmp)
        out, err = p.communicate("\n", timeout=60)
        self.assertEqual((p.returncode, err), (0, ""))
        return tmp, json.loads(out)["id"]

    def test_a_planted_temp_file_is_never_written_through(self):
        # Ruling FG: noclobber on the temporary name. Whatever is already
        # there fails the write; start still prints its id, and search.id
        # is simply not written (the window deletes its own job).
        target = Path(tempfile.mkdtemp(prefix="qbt-search-target-"))
        self.addCleanup(shutil.rmtree, target, True)
        (target / "victim").write_text("keep\n")
        plants = {
            "a planted file": lambda t: t.write_text("planted\n"),
            "a symlink to a file": lambda t: t.symlink_to(target / "victim"),
            "a dangling symlink": lambda t: t.symlink_to(target / "nowhere"),
        }
        for why, plant in plants.items():
            with self.subTest(why):
                self.id_path().unlink(missing_ok=True)
                tmp, _ = self.start_with_planted_temp(plant)
                self.assertFalse(self.id_path().exists(), why)
                self.assertEqual((target / "victim").read_text(), "keep\n")
                self.assertFalse((target / "nowhere").exists())
                if why == "a planted file":
                    self.assertEqual(tmp.read_text(), "planted\n")
                tmp.unlink()
                self.reset()

    def test_the_fixture_cancels_after_three_minutes_on_a_fake_clock(self):
        self.control({"search": {"rate": 1, "total": 1000, "finish": None}})
        jid = json.loads(self.start().stdout)["id"]
        self.assertEqual(self.get(f"/api/v2/search/status?id={jid}")[0]["status"], "Running")
        self.control({"search": {"rate": 1, "total": 1000, "finish": None}, "search_clock": 179})
        status = self.get(f"/api/v2/search/status?id={jid}")[0]
        self.assertEqual(status["status"], "Running")
        self.control({"search_clock": 181})
        status = self.get(f"/api/v2/search/status?id={jid}")[0]
        self.assertEqual((status["status"], status["total"]), ("Stopped", 180))
        res = self.get(f"/api/v2/search/results?id={jid}&offset=170")
        self.assertEqual((res["status"], res["total"], len(res["results"])), ("Stopped", 180, 10))
        # Stopped jobs don't count toward the cap.
        self.control({"search_clock": 181, "search": {"finish": None}})
        for _ in range(5):
            self.id_path().unlink(missing_ok=True)
            self.assertEqual(self.start().returncode, 0)

    def test_the_fixture_results_offsets(self):
        self.control({"search": {"total": 7}})
        jid = json.loads(self.start().stdout)["id"]
        self.assertEqual(len(self.get(f"/api/v2/search/results?id={jid}")["results"]), 7)
        self.assertEqual(self.get(f"/api/v2/search/results?id={jid}&offset=7")["results"], [])
        self.assertEqual(len(self.get(f"/api/v2/search/results?id={jid}&offset=2&limit=3")["results"]), 3)
        for path, code in ((f"/api/v2/search/results?id={jid}&offset=8", 409),
                           ("/api/v2/search/results?id=1", 404),
                           ("/api/v2/search/status?id=1", 404)):
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self.get(path)
            self.assertEqual(cm.exception.code, code)


class SearchStopDeleteTest(SearchCase):
    def job(self, finish=None):
        self.control({"search": {"finish": finish}})
        r = self.run_qbt("search", "start", "--pattern", "x", "--category", "all")
        return json.loads(r.stdout)["id"]

    def test_stop_stops_and_never_touches_search_id(self):
        jid = self.job()
        self.ok(self.run_qbt("search", "stop", str(jid)))
        self.assertEqual(self.jobs()[0]["status"], "Stopped")
        self.assertEqual(self.id_path().read_text(), f"{jid}\n")
        # Again, and on an unknown id: still ok.
        self.ok(self.run_qbt("search", "stop", str(jid)))
        self.ok(self.run_qbt("search", "stop", "77"))
        self.assertEqual(self.id_path().read_text(), f"{jid}\n")

    def test_jobs_live_in_qbts_session(self):
        # Search jobs are per WebUI session (Ruling FH): a request with no SID
        # (a fresh session) can't see qbt's job, and qbt's own stop and
        # delete reach it through its cookie file.
        jid = self.job()
        for path in (f"/api/v2/search/status?id={jid}", f"/api/v2/search/results?id={jid}"):
            with self.assertRaises(urllib.error.HTTPError) as cm:
                urllib.request.urlopen(self.url(path), timeout=5)
            self.assertEqual(cm.exception.code, 404)
        self.ok(self.run_qbt("search", "stop", str(jid)))
        self.assertEqual([(j["id"], j["status"]) for j in self.jobs()], [(jid, "Stopped")])
        self.ok(self.run_qbt("search", "delete", str(jid)))
        self.assertEqual(self.jobs(), [])

    def test_delete_removes_the_job_and_search_id_when_it_names_it(self):
        jid = self.job()
        self.ok(self.run_qbt("search", "delete", "77"))
        self.assertEqual(self.id_path().read_text(), f"{jid}\n")
        self.ok(self.run_qbt("search", "delete", str(jid)))
        self.assertEqual(self.jobs(), [])
        self.assertFalse(self.id_path().exists())
        # Gone already: still ok, and the file is removed even so.
        self.id_path().write_text(f"{jid}\n")
        self.ok(self.run_qbt("search", "delete", str(jid)))
        self.assertFalse(self.id_path().exists())

    def test_failures_report_codes_only(self):
        jid = self.job()
        for action in ("stop", "delete"):
            self.control({f"search_{action}": "409secret"})
            r = self.run_qbt("search", action, str(jid))
            self.refused(r, sentence("refused", why="HTTP 409"))
            self.assertNotIn("SECRET", r.stderr)
        self.assertEqual(self.id_path().read_text(), f"{jid}\n")
        self.control({})
        self.control({"forbidden": True})
        r = self.run_qbt("search", "delete", str(jid))
        self.refused(r, sentence("refused", why="localhost auth is required"))
        self.refused(self.run_qbt("search", "stop", str(jid),
                                  env={"QBT_BASE": f"http://127.0.0.1:{harness._free_port()}"}),
                     sentence("refused", why="couldn't reach qBittorrent"))


class SearchAddTest(SearchCase):
    def test_a_magnet_is_exactly_qbt_add(self):
        before = len(self.log())
        self.ok(self.run_qbt("add", MAGNET))
        self.ok(self.run_qbt("search", "add", MAGNET, "piratebay"), '{"ok":true,"via":"add"}')
        a, b = self.posts_since(before)
        self.assertEqual((a["path"], a["body"]), (b["path"], b["body"]))
        # The plugin is ignored: no plugin read at all.
        self.assertEqual([e["path"] for e in self.requests_since(before)], [a["path"], b["path"]])

    def test_https_with_a_plugin_goes_through_download_torrent(self):
        link = "https://example.org/download/123?key=a&b=c"
        before = len(self.log())
        self.ok(self.run_qbt("search", "add", link, "piratebay"), '{"ok":true,"via":"plugin"}')
        reqs = self.requests_since(before)
        self.assertEqual([(e["method"], e["path"]) for e in reqs],
                         [("GET", "/api/v2/search/plugins"), ("POST", "/api/v2/search/downloadTorrent")])
        self.assertEqual(self.form(reqs[1]), {"torrentUrl": [link], "pluginName": ["piratebay"]})

    def test_a_plugin_not_in_the_list(self):
        before = len(self.log())
        self.refused(self.run_qbt("search", "add", "https://example.org/d/1", "jackett"),
                     sentence("noSuchPlugin", name="jackett"))
        self.assertEqual(self.posts_since(before), [])
        self.control({"search_plugins": "500"})
        self.refused(self.run_qbt("search", "add", "https://example.org/d/1", "piratebay"),
                     sentence("pluginsUnreadable", why="HTTP 500"))

    def test_https_torrent_without_a_plugin(self):
        before = len(self.log())
        self.ok(self.run_qbt("search", "add", "https://example.org/dl/debian.torrent"), '{"ok":true,"via":"add"}')
        self.assertEqual([e["path"] for e in self.requests_since(before)], ["/api/v2/torrents/add"])

    def test_the_fixture_answers_a_pending_url_with_202(self):
        # qBittorrent 5.2.3's torrents/add (APIStatus::Async): a URL it must
        # fetch first is pending, a magnet is added at once.
        status, body = self.post("/api/v2/torrents/add", "urls=https%3A%2F%2Fexample.org%2Fdl%2Fdebian.torrent")
        self.assertEqual((status, json.loads(body)["pending_count"]), (202, 1))
        status, _ = self.post("/api/v2/torrents/add", "urls=" + MAGNET.replace(":", "%3A").replace("?", "%3F")
                              .replace("=", "%3D").replace("&", "%26"))
        self.assertEqual(status, 200)

    def test_qbt_add_takes_a_pending_https_torrent_as_added(self):
        # B1: the pre-existing `qbt add <https url>` hits the same 202.
        before = len(self.log())
        self.ok(self.run_qbt("add", "https://example.org/dl/debian.torrent"))
        reqs = self.requests_since(before)
        self.assertEqual([e["path"] for e in reqs], ["/api/v2/torrents/add"])
        self.assertEqual(self.form(reqs[0])["urls"], ["https://example.org/dl/debian.torrent"])

    def test_202_is_success_only_for_torrents_add(self):
        self.control({"search_downloadTorrent": "202"})
        self.refused(self.run_qbt("search", "add", "https://example.org/d/1", "piratebay"),
                     sentence("refused", why="HTTP 202"))

    def test_failed_requests(self):
        self.control({"add": "404"})
        self.refused(self.run_qbt("search", "add", MAGNET), sentence("refused", why="HTTP 404"))
        self.control({"search_downloadTorrent": "409secret"})
        r = self.run_qbt("search", "add", "https://example.org/d/1", "piratebay")
        self.refused(r, sentence("refused", why="HTTP 409"))
        self.assertNotIn("SECRET", r.stderr)
        self.control({"forbidden": True})
        r = self.run_qbt("search", "add", MAGNET)
        self.refused(r, sentence("refused", why="localhost auth is required"))
        self.assertNotIn("SID", r.stderr)

    def test_download_torrent_with_a_magnet_adds_it_in_the_fixture(self):
        h = "ab" * 20
        status, _ = self.post("/api/v2/search/downloadTorrent",
                              f"torrentUrl=magnet%3A%3Fxt%3Durn%3Abtih%3A{h}&pluginName=piratebay")
        self.assertEqual(status, 200)
        rows = self.get(f"/api/v2/torrents/info?hashes={h}")
        self.assertEqual([r["hash"] for r in rows], [h])


class SearchPluginTest(SearchCase):
    INSTALL_ENV = {"QBT_SEARCH_INSTALL_WAIT": "3"}

    def test_usage(self):
        usage = sentence("pluginUsage")
        for args in ((), ("lst",), ("list", "x"), ("install",), ("install", "a", "b"), ("uninstall",),
                     ("enable", "piratebay"), ("enable", "piratebay", "yes"), ("enable", "piratebay", "ON"),
                     ("enable", "piratebay", "on", "x"), ("update", "now")):
            with self.subTest(args=args):
                self.refused_before_any_request(("search-plugin", *args), usage)

    def test_list(self):
        r = self.run_qbt("search-plugin", "list")
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        out = json.loads(r.stdout)
        self.assertEqual([p["name"] for p in out], ["piratebay", "eztv"])
        self.assertEqual(list(out[0]), ["name", "fullName", "version", "enabled", "url", "supportedCategories"])
        self.assertEqual(out[0]["supportedCategories"][:2],
                         [{"id": "all", "name": "All categories"}, {"id": "anime", "name": "Anime"}])
        self.assertEqual(out[1]["enabled"], False)
        self.assertEqual(r.stdout.count("\n"), 1)
        self.reset([])
        self.ok(self.run_qbt("search-plugin", "list"), "[]")
        self.control({"search_plugins": "500"})
        self.refused(self.run_qbt("search-plugin", "list"), sentence("pluginsUnreadable", why="HTTP 500"))
        self.control({"search_plugins": "unreadable"})
        self.refused(self.run_qbt("search-plugin", "list"), sentence("unreadable"))

    def install(self, url=PLUGIN_URL, env=None):
        return self.run_qbt("search-plugin", "install", url, env=dict(self.INSTALL_ENV, **(env or {})))

    def test_install_a_new_plugin(self):
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "4.0"}}, "plugin_install_delay": 1.2})
        before = len(self.log())
        started = time.monotonic()
        self.ok(self.install())
        self.assertGreater(time.monotonic() - started, 1.0)
        self.assertEqual([p["version"] for p in self.plugins() if p["name"] == "jackett"], ["4.0"])
        posts = self.posts_since(before)
        self.assertEqual([p["path"] for p in posts], ["/api/v2/search/installPlugin"])
        self.assertEqual(posts[0]["body"], "sources=https%3A%2F%2Fexample.org%2Fplugins%2Fjackett.py")
        gets = [e for e in self.requests_since(before) if e["method"] == "GET"]
        self.assertGreaterEqual(len(gets), 3, "one read before, then every 0.5 s")

    def test_install_names_the_plugin_by_qbittorrents_rule(self):
        url = "HTTPS://Example.ORG/plugins/Jackett.PY?x=1#top"
        self.control({"plugin_sources": {url: {"version": "1.2"}}})
        self.ok(self.install(url))
        self.assertIn("Jackett", [p["name"] for p in self.plugins()])

    def test_install_an_update(self):
        self.reset([plugin("jackett", "3.5")])
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "4.0"}}})
        self.ok(self.install())
        self.assertEqual(self.plugins()[0]["version"], "4.0")

    def test_same_or_older_version_is_already_installed(self):
        # installReadback: before 4.0 / after 4.0, and before 4.1 with an
        # older file (qBittorrent refuses both silently).
        for installed, offered in (("4.0", "4.0"), ("4.1", "4.0")):
            with self.subTest(installed=installed, offered=offered):
                self.reset([plugin("jackett", installed)])
                self.control({"plugin_sources": {PLUGIN_URL: {"version": offered}}})
                case = next(c for c in cases("installReadback") if c["input"]["before"] == installed)
                self.refused(self.install(), case["message"])
                self.assertEqual(self.plugins()[0]["version"], installed)

    def test_a_failed_download_is_unconfirmed(self):
        # installReadback: before null / after null, and a plugin that
        # vanished during the wait (before 1.0 / after null).
        self.refused(self.install(), sentence("installUnconfirmed", name="jackett"))
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "4.0", "broken": True}}})
        self.refused(self.install(), sentence("installUnconfirmed", name="jackett"))
        self.reset([plugin("eztv", "1.0")])
        url = "https://example.org/eztv.py"
        proc = subprocess.Popen([QBT, "search-plugin", "install", url], env=dict(self.env, **self.INSTALL_ENV),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.8)
        self.assertEqual(self.post("/api/v2/search/uninstallPlugin", "names=eztv")[0], 200)
        out, err = proc.communicate(timeout=30)
        self.assertEqual((proc.returncode, out, err), (1, "", sentence("installUnconfirmed", name="eztv") + "\n"))

    def test_the_read_back_waits_20_seconds_by_default(self):
        started = time.monotonic()
        r = self.run_qbt("search-plugin", "install", PLUGIN_URL)
        elapsed = time.monotonic() - started
        self.refused(r, sentence("installUnconfirmed", name="jackett"))
        self.assertGreaterEqual(elapsed, 20)
        self.assertLess(elapsed, 30)

    def test_install_read_failures(self):
        self.control({"search_plugins": "500"})
        before = len(self.log())
        self.refused(self.install(), sentence("pluginsUnreadable", why="HTTP 500"))
        self.assertEqual(self.posts_since(before), [])
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "4.0"}}, "search_installPlugin": "500"})
        self.refused(self.install(), sentence("refused", why="HTTP 500"))
        self.control({"search_installPlugin": "409secret"})
        r = self.install()
        self.refused(r, sentence("refused", why="HTTP 409"))
        self.assertNotIn("SECRET", r.stderr)

    def test_a_transient_read_failure_during_the_wait_is_retried(self):
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "4.0"}}, "plugin_install_delay": 1.0,
                      "search_plugins": "500@2"})
        self.ok(self.install())

    def test_the_last_read_failing_says_so(self):
        # The first read (before) succeeds; every later one fails.
        path = Path(self.env["QBT_FIXTURE_CONTROL"])
        self.control({})
        proc = subprocess.Popen([QBT, "search-plugin", "install", PLUGIN_URL],
                                env=dict(self.env, QBT_SEARCH_INSTALL_WAIT="2"),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not any(
                e["path"] == "/api/v2/search/installPlugin" for e in self.log()):
            time.sleep(0.05)
        path.write_text(json.dumps({"search_plugins": "500"}))
        out, err = proc.communicate(timeout=30)
        self.assertEqual((proc.returncode, err), (1, sentence("pluginsUnreadable", why="HTTP 500") + "\n"))

    def test_uninstall(self):
        before = len(self.log())
        self.ok(self.run_qbt("search-plugin", "uninstall", "eztv"))
        self.assertEqual([p["name"] for p in self.plugins()], ["piratebay"])
        posts = self.posts_since(before)
        self.assertEqual([(p["path"], p["body"]) for p in posts], [("/api/v2/search/uninstallPlugin", "names=eztv")])
        self.refused(self.run_qbt("search-plugin", "uninstall", "eztv"), sentence("noSuchPlugin", name="eztv"))
        self.control({"search_uninstallPlugin": "noop"})
        self.refused(self.run_qbt("search-plugin", "uninstall", "piratebay"),
                     sentence("uninstallUnconfirmed", name="piratebay"))
        self.reset()
        self.control({"search_plugins": "500@2"})
        self.refused(self.run_qbt("search-plugin", "uninstall", "piratebay"),
                     sentence("pluginsUnreadable", why="HTTP 500"))
        self.reset()
        self.control({"search_uninstallPlugin": "500"})
        self.refused(self.run_qbt("search-plugin", "uninstall", "piratebay"), sentence("refused", why="HTTP 500"))

    def test_enable_on_and_off(self):
        before = len(self.log())
        self.ok(self.run_qbt("search-plugin", "enable", "eztv", "on"))
        self.ok(self.run_qbt("search-plugin", "enable", "piratebay", "off"))
        self.assertEqual({p["name"]: p["enabled"] for p in self.plugins()}, {"piratebay": False, "eztv": True})
        self.assertEqual([p["body"] for p in self.posts_since(before)],
                         ["names=eztv&enable=true", "names=piratebay&enable=false"])
        # Already there is fine: the read-back is what counts.
        self.ok(self.run_qbt("search-plugin", "enable", "piratebay", "off"))
        self.control({"search_enablePlugin": "noop"})
        self.refused(self.run_qbt("search-plugin", "enable", "piratebay", "on"),
                     sentence("enableUnconfirmed", name="piratebay"))
        self.refused(self.run_qbt("search-plugin", "enable", "eztv", "off"),
                     sentence("disableUnconfirmed", name="eztv"))
        self.control({})
        self.refused(self.run_qbt("search-plugin", "enable", "jackett", "on"), sentence("noSuchPlugin", name="jackett"))
        self.reset()
        self.control({"search_plugins": "500@2"})
        self.refused(self.run_qbt("search-plugin", "enable", "eztv", "on"),
                     sentence("pluginsUnreadable", why="HTTP 500"))

    def test_update(self):
        self.control({"plugin_updates": {"piratebay": "3.4"}})
        before = len(self.log())
        self.ok(self.run_qbt("search-plugin", "update"))
        reqs = [(e["method"], e["path"]) for e in self.requests_since(before)]
        self.assertEqual(reqs, [("POST", "/api/v2/search/updatePlugins"), ("GET", "/api/v2/search/plugins")])
        time.sleep(0.6)
        self.assertEqual(self.plugins()[0]["version"], "3.4")
        self.assertEqual(self.plugins()[0]["fullName"], "The Pirate Bay")
        self.control({"search_updatePlugins": "500"})
        self.refused(self.run_qbt("search-plugin", "update"), sentence("refused", why="HTTP 500"))
        self.control({"search_plugins": "500"})
        self.refused(self.run_qbt("search-plugin", "update"), sentence("pluginsUnreadable", why="HTTP 500"))


class NoBodyOnDiskTest(SearchCase):
    """Response bodies never touch disk: no temp file, no spilled
    here-string. A plugin list well over bash's ~64 KiB here-string pipe
    threshold would spill to a file under `ulimit -f 32` (a loud failure),
    and a fresh TMPDIR must stay empty."""

    def big_plugins(self):
        big = [plugin(f"p{i}", full_name="x" * 2000) for i in range(60)]
        big[0]["name"] = "piratebay"
        return big

    def commands(self):
        jid = None
        yield ("search-plugin", "list")
        yield ("search", "start", "--pattern", "debian " * 3000, "--category", "all")
        yield ("search", "add", MAGNET)
        yield ("search", "add", "https://example.org/d/1", "piratebay")
        yield ("search-plugin", "enable", "p1", "off")
        yield ("search-plugin", "uninstall", "p2")
        yield ("search-plugin", "update")
        yield ("search-plugin", "install", PLUGIN_URL)
        jid = self.jobs()[0]["id"]
        yield ("search", "stop", str(jid))
        yield ("search", "delete", str(jid))

    def test_ulimit_and_a_fresh_tmpdir(self):
        self.reset(self.big_plugins())
        self.control({"plugin_sources": {PLUGIN_URL: {"version": "1.0"}}, "search": {"finish": None}})
        self.assertGreater(len(json.dumps(self.plugins())), 100000)
        tmpdir = Path(tempfile.mkdtemp(prefix="qbt-tmp-"))
        self.addCleanup(shutil.rmtree, tmpdir, True)
        env = dict(self.env, TMPDIR=str(tmpdir), TMP=str(tmpdir), TEMP=str(tmpdir), QBT_SEARCH_INSTALL_WAIT="3")
        for args in self.commands():
            with self.subTest(args=args[:3]):
                r = subprocess.run(["bash", "-c", 'ulimit -f 32 && exec "$0" "$@"', QBT, *args],
                                   env=env, capture_output=True, timeout=60)
                self.assertEqual((r.returncode, r.stderr), (0, b""), args[:3])
                self.assertEqual(list(tmpdir.iterdir()), [])
        # The long pattern went out whole, through stdin (never argv).
        start = [e for e in self.log() if e["path"] == "/api/v2/search/start"][-1]
        self.assertEqual(self.form(start)["pattern"], ["debian " * 3000])

    def test_search_code_has_no_here_strings_or_temp_files(self):
        text = (ROOT / "qbt").read_text()
        start = text.index("# Slice 5a: `qbt search` and `qbt search-plugin`")
        end = text.index("\ncase ${1:-} in", start)
        code = "\n".join(line for line in text[start:end].splitlines() if not line.lstrip().startswith("#"))
        for word in ("<<<", "mktemp", "tee ", "--data \"", "--arg u", "api POST"):
            self.assertNotIn(word, code, word)
        self.assertTrue(text.startswith("#!/usr/bin/env bash\n"))
        first = [line for line in text.splitlines()[1:] if line and not line.startswith("#")][0]
        self.assertEqual(first, "{ set +o xtrace +o allexport; } 2>/dev/null")


if __name__ == "__main__":
    unittest.main()
