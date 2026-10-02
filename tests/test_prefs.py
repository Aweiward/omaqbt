"""Slice 4a, Task 2: `qbt prefs` and `qbt pref-set` against the fixture's
state-backed /app/preferences (QBT_FIXTURE_PREFS), which behaves like
qBittorrent 5.2.3's setPreferences: 200 (400 only for a bad
web_ui_username), unknown keys and bad values dropped without a word,
scheduler times only as an hour+minute pair, paths cleaned like
QDir::cleanPath, announce_ip stored as QHostAddress::toString writes it.

The gate under test: no locked, read-only, hidden, deferred or secret key
and no dangerous Other key ever reaches setPreferences; every value arrives
exactly as typed; a write qBittorrent didn't take is reported; no secret
value is ever printed.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "fixtures"))
import harness  # noqa: E402

QBT = os.environ.get("QBT_UNDER_TEST", str(ROOT / "qbt"))
SCHEMA = json.loads((ROOT / "settings-schema.json").read_text())
DUMP = json.loads((ROOT / "tests" / "fixtures" / "preferences-5.2.3.json").read_text())
CASES = json.loads((ROOT / "tests" / "fixtures" / "settings-cases.json").read_text())
TEXT_RULES_CASES = json.loads((ROOT / "tests" / "fixtures" / "text-rules-cases.json").read_text())["cases"]
LIST_RULES = json.loads((ROOT / "tests" / "fixtures" / "list-rules-cases.json").read_text())
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
C_ENV = {"LANG": "C", "LC_ALL": "C"}
USAGE_MESSAGE = "usage: qbt pref-set <key> (-- <value> | --stdin | --clear)"
# Slice 4b: the three writable secrets go through --stdin only (eng 4b D7).
SECRET_ARGV_MESSAGE = "Send this password with --stdin, never as an argument."
STDIN_ONLY_MESSAGE = "Only the proxy, Dynamic DNS and SMTP passwords take --stdin or --clear."
STDIN_TIMEOUT_MESSAGE = "The value didn't arrive within 5 seconds."
# Ruling EB (eng 4b D9).
WHITELIST_MESSAGE = "OmaqBT keeps this read-only: it has no effect while the Web UI only listens on 127.0.0.1."
WRITABLE_SECRETS = ("proxy_password", "dyndns_password", "mail_notification_password")

SECRET_VALUES = {
    "proxy_password": "hunter2-PROXYSECRET",
    "dyndns_password": "DYNSECRET-9f3a",
    "mail_notification_password": "MAILSECRET-77",
    "web_ui_api_key": "APIKEYSECRET-0123456789",
    # Unknown to the schema, but it sounds like a password.
    "backup_password_extra": "OTHERPASSWORDSECRET",
    # Ruling DT: unknown keys that sound like a token, secret or API key.
    "future_token": "TOKENSECRET-5",
    "Auth_TOKEN": "TOKENSECRET-6",
    "client_Secret_x": "SECRETSECRET-7",
    "my_api_key": "APIKEYSECRET-8",
}

# Keys the schema doesn't know (the Other section), seeded into the dump.
OTHER_OK = {"future_flag": False, "future_count": 3, "future_ratio": 1.5, "future_name": "abc"}
OTHER_NON_SCALAR = {"future_obj": {"a": 1}, "future_list": [1, 2], "future_null": None}
OTHER_REFUSED = {
    "web_ui_future": 1,
    "proxy_future": True,
    "vpn_interface_future": "wg1",
    "backup_password_extra": SECRET_VALUES["backup_password_extra"],
    "future_https_flag": True,
    "autorun_future": "x",
}
VPN_LOCKS = ["current_network_interface", "current_interface_address", "current_interface_name"]
LOCK_GLOB_EXTRAS = ["web_ui_https_future", "web_ui_reverse_proxy_future", "alternative_webui_future"]


def prefs_file(extra=None, secrets=True):
    prefs = dict(DUMP)
    if secrets:
        prefs.update(SECRET_VALUES)
    prefs.update(OTHER_OK)
    prefs.update(OTHER_NON_SCALAR)
    prefs.update(OTHER_REFUSED)
    for key in LOCK_GLOB_EXTRAS:
        prefs[key] = "x"
    prefs.update(extra or {})
    fd, path = tempfile.mkstemp(prefix="qbt-prefs-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(prefs, f)
    return path


def fixture(extra=None, secrets=True, env=None):
    path = prefs_file(extra, secrets)
    extra_env = dict(UTF8_ENV)
    extra_env.update(env or {})
    extra_env["QBT_FIXTURE_PREFS"] = path
    return harness.fixture_server(extra_env=extra_env), path


class PrefsCase(unittest.TestCase):
    """One fixture per test class; helpers read its log and state."""

    extra = None
    secrets = True

    @classmethod
    def setUpClass(cls):
        cls._cm, cls._path = fixture(cls.extra, cls.secrets)
        cls.port, cls.env = cls._cm.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls._cm.__exit__(None, None, None)
        os.unlink(cls._path)

    def tearDown(self):
        self.control({})

    def run_qbt(self, *args, env=None):
        full = dict(self.env)
        full.update(env or {})
        import subprocess
        return subprocess.run([QBT, *args], env=full, text=True, capture_output=True)

    def log(self):
        path = Path(self.env["QBT_FIXTURE_LOG"])
        return json.loads(path.read_text() or "[]") if path.exists() else []

    def posts_since(self, before):
        return [e for e in self.log()[before:] if e["method"] == "POST" and e["path"] == "/api/v2/app/setPreferences"]

    def state(self):
        # Straight from the fixture, not through qbt (and unrecorded is not
        # needed: GETs never count as writes).
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/api/v2/app/preferences", timeout=5) as r:
            return json.loads(r.read())

    def control(self, value):
        Path(self.env["QBT_FIXTURE_CONTROL"]).write_text(json.dumps(value))

    def sent(self, post):
        return json.loads(parse_qs(post["body"], keep_blank_values=True)["json"][0])

    def set_ok(self, key, value, env=None):
        before = len(self.log())
        r = self.run_qbt("pref-set", key, "--", value, env=env)
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, '{"ok":true}', ""), f"{key} -- {value!r}")
        posts = self.posts_since(before)
        self.assertEqual(len(posts), 1, f"{key}: one setPreferences POST")
        return self.sent(posts[0])

    def set_refused(self, key, value, message=None, env=None):
        before = len(self.log())
        r = self.run_qbt("pref-set", key, "--", value, env=env)
        self.assertNotEqual(r.returncode, 0, f"{key} -- {value!r} must be refused")
        self.assertEqual(r.stdout, "")
        self.assertEqual(self.posts_since(before), [], f"{key} -- {value!r}: nothing reaches setPreferences")
        if message is not None:
            self.assertEqual(r.stderr.strip(), message, f"{key} -- {value!r}")
        return r


def qbt_array(name):
    text = (ROOT / "qbt").read_text()
    m = re.search(rf"^{name}=\(\n(.*?)^\)", text, re.S | re.M)
    assert m, f"{name} not found in qbt"
    return [line.strip().strip("'") for line in m.group(1).splitlines() if line.strip()]


class HardcodedListsTest(unittest.TestCase):
    """Ruling DB: the schema's locked set equals qbt's hardcoded lists."""

    def test_locked_equals_schema(self):
        mine = qbt_array("PREF_LOCKED_VPN") + qbt_array("PREF_LOCKED_WEBUI")
        self.assertEqual(len(mine), len(set(mine)))
        self.assertEqual(set(mine), set(SCHEMA["locked"]))
        # Eng 4b D8: the custom headers are hardcoded, not just flagged.
        self.assertIn("web_ui_custom_http_headers", mine)
        self.assertIn("web_ui_use_custom_http_headers_enabled", mine)
        self.assertEqual(set(qbt_array("PREF_LOCKED_VPN")), set(VPN_LOCKS))
        self.assertIn("web_ui_reverse_prox*", mine)  # Ruling DD
        # The login bypass stays off (marketplace review, 2026-10-02).
        self.assertIn("bypass_local_auth", mine)
        self.assertIn("bypass_auth_subnet_whitelist_enabled", mine)

    def test_locked_flags_match_the_globs(self):
        import fnmatch
        mine = qbt_array("PREF_LOCKED_VPN") + qbt_array("PREF_LOCKED_WEBUI")
        flagged = {k for k, e in SCHEMA["keys"].items() if e.get("locked")}
        matched = {k for k in SCHEMA["keys"] if any(fnmatch.fnmatchcase(k, g) for g in mine)}
        self.assertEqual(flagged, matched)
        self.assertIn("web_ui_reverse_proxies_list", matched)

    def test_other_refused_equals_schema(self):
        self.assertEqual(qbt_array("PREF_OTHER_REFUSED"), SCHEMA["otherRefusedPatterns"])

    def test_secret_writable_equals_schema(self):
        # Eng 4b D7: the --stdin allowlist, hardcoded before the schema.
        flagged = {k for k, e in SCHEMA["keys"].items() if e.get("secretWritable")}
        self.assertEqual(set(qbt_array("PREF_SECRET_WRITABLE")), flagged)
        self.assertEqual(flagged, set(WRITABLE_SECRETS))


class PrefsReadTest(PrefsCase):
    def test_prints_one_object_with_secrets_redacted(self):
        r = self.run_qbt("prefs")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertEqual(r.stdout.count("\n"), 1, "one line")
        got = json.loads(r.stdout)
        want = self.state()
        for key in SECRET_VALUES:
            self.assertEqual(got[key], {"set": True}, key)
            want[key] = {"set": True}
        self.assertEqual(got, want)
        for secret in SECRET_VALUES.values():
            self.assertNotIn(secret, r.stdout + r.stderr)

    def test_errors_report_the_code_only(self):
        self.control({"preferences": "409state"})
        r = self.run_qbt("prefs")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent refused it (HTTP 409)"))
        self.control({"preferences": "409secret"})
        r = self.run_qbt("prefs")
        self.assertEqual(r.stderr.strip(), "qBittorrent refused it (HTTP 409)")
        self.control({"preferences": "unreadable"})
        r = self.run_qbt("prefs")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent sent something unreadable"))

    def test_extra_args_refused(self):
        r = self.run_qbt("prefs", "x")
        self.assertEqual((r.returncode, r.stderr.strip()), (1, "usage: qbt prefs"))


class PrefsBlankSecretsTest(PrefsCase):
    secrets = False

    def test_blank_secret_is_not_set(self):
        r = self.run_qbt("prefs")
        got = json.loads(r.stdout)
        for key in ("proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key"):
            self.assertEqual(got[key], {"set": False}, key)


class PrefSetRefusalsTest(PrefsCase):
    def test_usage(self):
        for args in (["pref-set"], ["pref-set", "dht"], ["pref-set", "dht", "true"],
                     ["pref-set", "dht", "-", "true"], ["pref-set", "dht", "--"],
                     ["pref-set", "dht", "--", "true", "extra"], ["pref-set", "--", "true"],
                     ["pref-set", "--stdin"], ["pref-set", "--clear"], ["pref-set", "proxy_password", "--stdin", "x"],
                     ["pref-set", "proxy_password", "--clear", "x"], ["pref-set", "proxy_password", "--STDIN"],
                     ["pref-set", "proxy_password", "-", "--stdin"], ["pref-set", "proxy_password", "--", "--stdin", "x"]):
            before = len(self.log())
            r = self.run_qbt(*args)
            self.assertEqual((r.returncode, r.stderr.strip()), (1, USAGE_MESSAGE), args)
            self.assertEqual(self.log()[before:], [], f"{args}: no request at all")

    def test_every_lock(self):
        for key, entry in SCHEMA["keys"].items():
            if not entry.get("locked"):
                continue
            want = "Set by OmaqBT's setup." if key in VPN_LOCKS else "OmaqBT needs this as it is."
            for value in ("x", "1", "true", ""):
                self.set_refused(key, value, want)
        # Glob-only names the schema doesn't know are locked too, before the
        # Other checks.
        for key in LOCK_GLOB_EXTRAS:
            self.set_refused(key, "x", "OmaqBT needs this as it is.")
        self.set_refused("web_ui_reverse_proxies_list", "10.0.0.1", "OmaqBT needs this as it is.")
        # Locked and read-only: the lock wins.
        self.set_refused("current_interface_name", "wg0", "Set by OmaqBT's setup.")

    def test_read_only_hidden_deferred_secret(self):
        self.set_refused("add_trackers_url_list", "x", "qBittorrent doesn't let this be changed.")
        self.set_refused("web_ui_api_key", "x", "qBittorrent doesn't let this be changed.")
        for key in WRITABLE_SECRETS:
            # Slice 4b: never on argv, only through --stdin.
            r = self.set_refused(key, "hunter3", SECRET_ARGV_MESSAGE)
            self.assertNotIn("hunter3", r.stderr)
        # Ruling EB: OmaqBT's choice, not qBittorrent's.
        self.set_refused("bypass_auth_subnet_whitelist", "10.0.0.0/8", WHITELIST_MESSAGE)
        for key, entry in SCHEMA["keys"].items():
            if entry.get("hidden"):
                self.set_refused(key, "1", "OmaqBT doesn't change this setting.")
            if entry.get("deferred"):
                self.set_refused(key, "1", "OmaqBT doesn't change this setting yet.")

    def test_bad_key_names(self):
        for key in ("", "a b", "../x", "dht*", "d?t", "[dht]", "_x", "1x", "déht", "dht\n", "x" * 200):
            self.set_refused(key, "true", "qBittorrent has no setting called that.")

    def test_other_refused_patterns(self):
        for key in OTHER_REFUSED:
            r = self.set_refused(key, "1", "OmaqBT won't change this setting.")
            self.assertNotIn(SECRET_VALUES["backup_password_extra"], r.stderr)
        for key in ("x_password", "my_interface_name", "proxy_x", "web_ui_x", "https_x", "autorun_x",
                    # Ruling DL: case-insensitive.
                    "Proxy_foo", "WEB_UI_x", "My_Interface", "X_PassWord", "HTTPS_x", "AutoRun_x"):
            self.set_refused(key, "1", "OmaqBT won't change this setting.")

    def test_other_non_scalar_and_missing(self):
        for key in OTHER_NON_SCALAR:
            self.set_refused(key, "1", "OmaqBT can only change on/off, number and text settings.")
        self.set_refused("no_such_setting", "1", "qBittorrent has no setting called no_such_setting.")

    def test_invalid_utf8_refused(self):
        self.set_refused("app_instance_name", "a\udcffb", "Use valid UTF-8 text.")


class PrefSetOtherTest(PrefsCase):
    def test_other_scalars_cast_by_current_type(self):
        self.assertEqual(self.set_ok("future_flag", "true"), {"future_flag": True})
        self.set_refused("future_flag", "1", "Use true or false.")
        self.assertEqual(self.set_ok("future_count", "7"), {"future_count": 7})
        self.assertEqual(self.set_ok("future_ratio", "2.25"), {"future_ratio": 2.25})
        self.assertEqual(self.set_ok("future_ratio", "-0.5"), {"future_ratio": -0.5})
        for bad in ("seven", "-0", "-0.0", "+1", "1e3", "01.5", "1.", "1.5\n", "-0\n"):
            self.set_refused("future_ratio", bad, "Use a number.")
        self.assertEqual(self.set_ok("future_ratio", "2.25"), {"future_ratio": 2.25})
        # Ruling DL: an integer stays whole.
        for bad in ("1.5", "7.0", "-0", "seven", "+1", "007", "7\n"):
            self.set_refused("future_count", bad, "Use a whole number.")
        self.assertEqual(self.set_ok("future_count", "-3"), {"future_count": -3})
        self.assertEqual(self.set_ok("future_count", "7"), {"future_count": 7})
        self.assertEqual(self.set_ok("future_name", "7"), {"future_name": "7"})
        self.set_refused("future_name", "a\nb", "Keep it to one line.")
        st = self.state()
        self.assertEqual((st["future_flag"], st["future_count"], st["future_ratio"], st["future_name"]), (True, 7, 2.25, "7"))


class PrefSetCasesTest(PrefsCase):
    """Every settings-cases.json case qbt consumes (shared and only:"qbt")."""

    def expected(self, section, case):
        entry = SCHEMA["keys"][case["key"]]
        text = case["input"]
        if section == "times":
            return {entry["composite"]["hour"]: case["hour"], entry["composite"]["min"]: case["min"]}
        if section == "paths":
            return {case["key"]: os.environ["HOME"] + text[1:] if text.startswith("~/") else text}
        if entry["type"] in ("int", "speed", "choice-int"):
            return {case["key"]: int(text)}
        if entry["type"] == "float":
            return {case["key"]: float(text) if "." in text else int(text)}
        if entry["type"] == "bool":
            return {case["key"]: text == "true"}
        return {case["key"]: text}

    def run_section(self, section, env=None):
        seen = 0
        for case in CASES[section]:
            if case.get("only") not in (None, "qbt"):
                continue
            seen += 1
            with self.subTest(section=section, key=case["key"], input=case["input"], why=case["why"]):
                self.assertFalse(SCHEMA["keys"][case["key"]].get("multiline"), "Ruling DM: lists live in list-rules-cases.json")
                if case["ok"]:
                    want = self.expected(section, case)
                    self.assertEqual(self.set_ok(case["key"], case["input"], env=env), want)
                    st = self.state()
                    for k, v in want.items():
                        self.assertEqual(st[k], v)
                        self.assertEqual(type(st[k]), type(v))
                else:
                    self.set_refused(case["key"], case["input"], env=env)
        self.assertGreater(seen, 0)

    def test_numbers(self):
        self.run_section("numbers")

    def test_choices(self):
        self.run_section("choices")

    def test_times(self):
        self.run_section("times")

    def test_paths(self):
        self.run_section("paths")

    def test_texts_utf8(self):
        self.run_section("texts")

    def test_texts_c_locale(self):
        self.run_section("texts", env=C_ENV)


class PrefSetFidelityTest(PrefsCase):
    def test_sentinels_and_leading_dash(self):
        self.assertEqual(self.set_ok("max_connec", "-1"), {"max_connec": -1})
        self.assertEqual(self.set_ok("listen_port", "0"), {"listen_port": 0})
        self.assertEqual(self.set_ok("max_ratio", "-1"), {"max_ratio": -1})
        self.assertEqual(self.set_ok("disk_cache", "-1"), {"disk_cache": -1})
        self.set_refused("max_connec", "-2", "Use a whole number from 1 to 2147483647, or -1 for unlimited.")
        self.set_refused("max_connec", "0", "Use a whole number from 1 to 2147483647, or -1 for unlimited.")
        self.set_refused("listen_port", "-1", "Use a whole number from 1 to 65535, or 0 for random.")
        self.set_refused("max_ratio", "-0.5", "Use a number from 0 to 9998, or -1 for none, with at most 2 decimals.")
        # A leading dash after -- is a value, never an option.
        self.assertEqual(self.set_ok("app_instance_name", "--"), {"app_instance_name": "--"})
        self.assertEqual(self.set_ok("app_instance_name", "-h"), {"app_instance_name": "-h"})

    def test_number_shapes(self):
        for bad in ("-0", "+5", "007", "1e3", " 5", "5 ", "0x10", "٥", "５", "5\n", "5\r", "x\n5", "99999999999"):
            r = self.set_refused("max_connec", bad, "Use a whole number from 1 to 2147483647, or -1 for unlimited.")
            self.assertNotIn("settings-schema", r.stderr)
        # Ruling DN: a trailing newline never slips past the anchors.
        self.set_refused("listen_port", "5\n", "Use a whole number from 1 to 65535, or 0 for random.")
        self.set_refused("max_ratio", "1.5\n", "Use a number from 0 to 9998, or -1 for none, with at most 2 decimals.")
        self.set_refused("encryption", "1\n", "Use one of: 0, 1, 2.")
        self.assertEqual(self.set_ok("max_connec", "2147483647"), {"max_connec": 2147483647})

    def test_int_vs_float(self):
        post = self.set_ok("max_connec", "5")
        self.assertEqual(post, {"max_connec": 5})
        body = self.posts_since(0)[-1]["body"]
        self.assertEqual(body, "json=%7B%22max_connec%22%3A5%7D", "an int goes out as 5, never 5.0 or \"5\"")
        self.set_refused("max_connec", "1.5", "Use a whole number from 1 to 2147483647, or -1 for unlimited.")
        self.assertEqual(self.set_ok("max_ratio", "1.5"), {"max_ratio": 1.5})
        self.assertEqual(self.set_ok("max_ratio", "0.25"), {"max_ratio": 0.25})
        self.assertEqual(self.set_ok("max_ratio", "3"), {"max_ratio": 3})
        self.set_refused("max_ratio", "1.255", "Use a number from 0 to 9998, or -1 for none, with at most 2 decimals.")
        self.set_refused("max_ratio", "1.", "Use a number from 0 to 9998, or -1 for none, with at most 2 decimals.")

    def test_string_vs_int_enums(self):
        self.assertEqual(self.set_ok("encryption", "1"), {"encryption": 1})
        self.assertEqual(self.set_ok("max_ratio_act", "3"), {"max_ratio_act": 3})
        self.set_refused("encryption", "Require", "Use one of: 0, 1, 2.")
        self.set_refused("encryption", "3", "Use one of: 0, 1, 2.")
        self.set_refused("encryption", "01", "Use one of: 0, 1, 2.")
        self.assertEqual(self.set_ok("torrent_content_layout", "Subfolder"), {"torrent_content_layout": "Subfolder"})
        self.set_refused("torrent_content_layout", "1", "Use one of: Original, Subfolder, NoSubfolder.")
        self.set_refused("torrent_content_layout", "subfolder", "Use one of: Original, Subfolder, NoSubfolder.")
        self.assertEqual(self.set_ok("proxy_type", "SOCKS5"), {"proxy_type": "SOCKS5"})

    def test_bool(self):
        self.assertEqual(self.set_ok("dht", "false"), {"dht": False})
        self.assertEqual(self.set_ok("dht", "true"), {"dht": True})
        for bad in ("1", "0", "True", "yes", "on", ""):
            self.set_refused("dht", bad, "Use true or false.")

    def test_auto_download_is_writable(self):
        # Slice 5b2 (D8): un-deferred; the window asks first (confirmVia),
        # qbt writes it like any bool.
        self.assertEqual(self.set_ok("rss_auto_downloading_enabled", "true"), {"rss_auto_downloading_enabled": True})
        self.assertEqual(self.state()["rss_auto_downloading_enabled"], True)
        self.assertEqual(self.set_ok("rss_auto_downloading_enabled", "false"), {"rss_auto_downloading_enabled": False})
        self.set_refused("rss_auto_downloading_enabled", "yes", "Use true or false.")

    def test_special_characters_reach_qbittorrent_exactly(self):
        for value in ("a&b=c&dht=true", "a+b", "100% %20%zz", "say \"hi\" 'x'", "back\\slash",
                      "café 🦊 𝄞", "$(touch /tmp/pwned) `x`", "tab\there", "{\"json\":1}"):
            for env in (UTF8_ENV, C_ENV):
                self.assertEqual(self.set_ok("app_instance_name", value, env=env), {"app_instance_name": value})
                self.assertEqual(self.state()["app_instance_name"], value)

    def test_newlines(self):
        self.set_refused("app_instance_name", "a\nb", "Keep it to one line.")
        self.set_refused("app_instance_name", "a\rb", "Keep it to one line.")
        self.set_refused("save_path", "/srv/a\nb", "Use an absolute path or one starting with ~/.")

    def test_multiline_keys_that_can_be_edited_are_lists(self):
        # Slice 4b Task 1: the headers are locked (D8), the whitelist read-only (D9).
        keys = [k for k, e in SCHEMA["keys"].items()
                if e.get("multiline") and not (e.get("hidden") or e.get("deferred") or e.get("readOnly") or e.get("locked"))]
        self.assertEqual(sorted(keys), sorted(["excluded_file_names", "add_trackers", "rss_smart_episode_filters"]))
        for key in keys:
            self.assertIn(SCHEMA["keys"][key].get("listKind"), ("trackerUrl", "pattern"), key)
        # Bans travel only through ban-list (eng 4b D3), never pref-set.
        self.assertTrue(SCHEMA["keys"]["banned_IPs"].get("hidden"))
        for value in ("203.0.113.5", "203.0.113.5\n198.51.100.7", ""):
            self.set_refused("banned_IPs", value, "OmaqBT doesn't change this setting.")
        # Locked and read-only multi-line keys stay refused.
        self.set_refused("web_ui_custom_http_headers", "X-A: 1", "OmaqBT needs this as it is.")
        self.set_refused("bypass_auth_subnet_whitelist", "", WHITELIST_MESSAGE)

    def test_paths(self):
        home = os.environ["HOME"]
        self.assertEqual(self.set_ok("save_path", "~/dl/x"), {"save_path": f"{home}/dl/x"})
        # qBittorrent drops a trailing slash; that still counts as taken.
        self.assertEqual(self.set_ok("save_path", "/srv/t/"), {"save_path": "/srv/t/"})
        self.assertEqual(self.state()["save_path"], "/srv/t")
        # A trailing slash on $HOME doesn't make ~/ expand to a "//" path.
        self.assertEqual(self.set_ok("save_path", "~/dl/y", env={"HOME": "/home/slashy/"}), {"save_path": "/home/slashy/dl/y"})
        for bad in ("~", "~user/x", "relative", "./x", ""):
            self.set_refused("save_path", bad, "Use an absolute path or one starting with ~/.")
        self.assertEqual(self.set_ok("export_dir", ""), {"export_dir": ""})
        self.set_refused("export_dir", "rel", "Use an absolute path or one starting with ~/, or nothing for off.")

    def test_trimmed_strings_count_as_taken(self):
        # Ruling DT: 5.2.3 trims only autorun_program,
        # autorun_on_torrent_added_program, announce_ip and
        # current_interface_address (appcontroller.cpp:696, :701, :1019,
        # :1178); a trimmed read-back still counts as taken.
        self.assertEqual(self.set_ok("autorun_program", "  run %N  "), {"autorun_program": "  run %N  "})
        self.assertEqual(self.state()["autorun_program"], "run %N")
        self.assertEqual(self.set_ok("autorun_on_torrent_added_program", " add %N "),
                         {"autorun_on_torrent_added_program": " add %N "})
        self.assertEqual(self.state()["autorun_on_torrent_added_program"], "add %N")
        # Every other string is stored exactly as sent.
        self.assertEqual(self.set_ok("app_instance_name", "  padded  "), {"app_instance_name": "  padded  "})
        self.assertEqual(self.state()["app_instance_name"], "  padded  ")
        self.assertEqual(self.set_ok("future_name", " spaced "), {"future_name": " spaced "})
        self.assertEqual(self.state()["future_name"], " spaced ")

    def test_step_1024(self):
        self.set_refused("dl_limit", "1536", "Use whole KiB.")
        self.set_refused("up_limit", "1", "Use whole KiB.")
        self.assertEqual(self.set_ok("alt_dl_limit", "2048"), {"alt_dl_limit": 2048})
        self.assertEqual(self.set_ok("alt_up_limit", "0"), {"alt_up_limit": 0})
        self.set_refused("dl_limit", "-1", "Use a whole number from 1 to 2146435072, or 0 for unlimited.")


class PrefSetCompositeTest(PrefsCase):
    def test_time_writes_both_members_in_one_request(self):
        self.assertEqual(self.set_ok("schedule_from", "08:30"), {"schedule_from_hour": 8, "schedule_from_min": 30})
        st = self.state()
        self.assertEqual((st["schedule_from_hour"], st["schedule_from_min"]), (8, 30))
        self.assertEqual(self.set_ok("schedule_to", "23:59"), {"schedule_to_hour": 23, "schedule_to_min": 59})
        for bad in ("8:30", "24:00", "12:60", "-1:00", "0830", "08:30:00", "", "08:30\n", "08:30\r", "x\n08:30"):
            self.set_refused("schedule_to", bad, "Use HH:MM, from 00:00 to 23:59.")

    def test_members_alone_are_refused(self):
        for key in ("schedule_from_hour", "schedule_from_min", "schedule_to_hour", "schedule_to_min"):
            self.set_refused(key, "5", "OmaqBT doesn't change this setting.")

    def test_read_back_checks_the_minute(self):
        self.control({"prefs_override": {"schedule_from_min": 0}})
        r = self.run_qbt("pref-set", "schedule_from", "--", "09:45")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent ignored From"))

    def test_read_back_checks_the_hour(self):
        self.control({"prefs_override": {"schedule_to_hour": 1}})
        r = self.run_qbt("pref-set", "schedule_to", "--", "07:15")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent ignored To"))


class PrefSetIgnoredTest(PrefsCase):
    """RED first: qBittorrent answers 200 and drops the value; pref-set must say so."""

    def test_value_qbittorrent_drops(self):
        # 200, but the read-back holds something else: pref-set says so.
        self.control({"prefs_override": {"announce_ip": ""}})
        before = len(self.log())
        r = self.run_qbt("pref-set", "announce_ip", "--", "203.0.113.7")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent ignored IP reported to trackers"))
        self.assertEqual(len(self.posts_since(before)), 1)
        self.control({"prefs_override": {"announce_ip": "2001:db8::2"}})
        r = self.run_qbt("pref-set", "announce_ip", "--", "2001:DB8::1")
        self.assertEqual((r.returncode, r.stderr.strip()), (1, "qBittorrent ignored IP reported to trackers"))
        self.control({})
        self.assertEqual(self.set_ok("announce_ip", "203.0.113.7"), {"announce_ip": "203.0.113.7"})

    def test_noop_write(self):
        self.control({"setPreferences": "noop"})
        for key, value, label in (("dht", "false", "DHT"), ("max_connec", "42", "Global connections"),
                                  ("app_instance_name", "renamed", "Instance name"),
                                  ("future_flag", "true", "future_flag")):
            r = self.run_qbt("pref-set", key, "--", value)
            self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", f"qBittorrent ignored {label}"), key)

    def test_overridden_value(self):
        self.control({"prefs_override": {"dl_limit": 1024}})
        r = self.run_qbt("pref-set", "dl_limit", "--", "4096")
        self.assertEqual(r.stderr.strip(), "qBittorrent ignored Download limit")

    def test_refused_write_reports_the_code_only(self):
        self.control({"setPreferences": "409secret"})
        r = self.run_qbt("pref-set", "dht", "--", "true")
        self.assertEqual((r.returncode, r.stderr.strip()), (1, "qBittorrent refused it (HTTP 409)"))

    def test_read_back_failure_never_leaks_a_secret(self):
        self.control({"preferences": "409state"})
        # After a POST the write may have applied: "Couldn't confirm", never "refused".
        before = len(self.log())
        r = self.run_qbt("pref-set", "dht", "--", "false")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "Couldn't confirm DHT (HTTP 409)"))
        self.assertEqual(len(self.posts_since(before)), 1)
        # Other reads first: a failure there is before any write.
        before = len(self.log())
        r2 = self.run_qbt("pref-set", "future_flag", "--", "true")
        self.assertEqual((r2.returncode, r2.stderr.strip()), (1, "qBittorrent refused it (HTTP 409)"))
        self.assertEqual(self.posts_since(before), [])
        for secret in SECRET_VALUES.values():
            self.assertNotIn(secret, r.stdout + r.stderr + r2.stdout + r2.stderr)
        self.control({})
        self.assertIs(self.state()["dht"], False, "the write did apply")
        self.control({"preferences": "unreadable"})
        r = self.run_qbt("pref-set", "dht", "--", "true")
        self.assertEqual(r.stderr.strip(), "Couldn't confirm DHT (qBittorrent sent something unreadable)")


CLEAN_PATH_MESSAGE = "Use a clean path without //, /./ or /../."
ANNOUNCE_IP_MESSAGE = "Use an IPv4 or IPv6 address, or leave it empty."
USERNAME_MESSAGE = "Use at least 3 characters and no colon."


class FinalFixCase(PrefsCase):
    def post_raw(self, obj):
        """setPreferences straight to the fixture, bypassing qbt."""
        from urllib.parse import quote
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/api/v2/app/setPreferences",
                                     data=f"json={quote(json.dumps(obj))}".encode(), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status
        except urllib.error.HTTPError as e:
            with e:
                return e.code


class CleanPathTest(FinalFixCase):
    """Ruling DQ: 5.2.3 stores Path(value), i.e. QDir::cleanPath
    (appcontroller.cpp:560, :607, :611, :615, :617), so an unclean path
    would read back different and be reported as ignored."""

    def test_unclean_paths_are_refused_before_any_write(self):
        for bad in ("/srv//dl", "//srv", "/srv/dl//", "/srv/./x", "/srv/../x", "/srv/x/.", "/srv/x/..",
                    "/.", "/..", "/srv//dl/./x", "~/a/../dl", "~/./x", "~//x", "~/x/."):
            self.set_refused("save_path", bad, CLEAN_PATH_MESSAGE)
        self.set_refused("export_dir", "/srv/../x", CLEAN_PATH_MESSAGE)
        self.set_refused("python_executable_path", "/usr//bin/python3", CLEAN_PATH_MESSAGE)
        # After ~/ expansion: a $HOME with a "." part is unclean too.
        self.set_refused("save_path", "~/x", CLEAN_PATH_MESSAGE, env={"HOME": "/home/./u"})

    def test_dots_inside_names_are_fine(self):
        for good in ("/srv/.hidden/x", "/srv/x..y", "/srv/..x", "/srv/x.", "/srv/...", "/", "/srv/t/"):
            self.assertEqual(self.set_ok("save_path", good), {"save_path": good})

    def test_reviewer_repro_is_refused_not_ignored(self):
        # The final review's repro: the real value is the cleaned path.
        for value, real in (("/srv//dl/./x", "/srv/dl/x"), ("~/a/../dl", os.environ["HOME"] + "/dl")):
            self.control({"prefs_override": {"save_path": real}})
            self.set_refused("save_path", value, CLEAN_PATH_MESSAGE)

    def test_fixture_cleans_like_qdir(self):
        for sent, stored in (("/srv//dl/./x/../y/", "/srv/dl/y"), ("//srv", "/srv"), ("/..", "/"),
                             ("/srv/t/", "/srv/t"), ("/", "/"), (" /srv/x ", " /srv/x ")):
            self.assertEqual(self.post_raw({"save_path": sent}), 200)
            self.assertEqual(self.state()["save_path"], stored, sent)
        self.assertEqual(self.post_raw({"export_dir": ""}), 200)
        self.assertEqual(self.state()["export_dir"], "")


class AnnounceIpTest(FinalFixCase):
    """Ruling DR: QHostAddress{value.trimmed()}; toString() when it parses,
    "" otherwise (appcontroller.cpp:1178)."""

    GOOD = ("", "203.0.113.7", "0.0.0.0", "255.255.255.255", "10.0.0.1", "2001:DB8::1", "2001:db8::1",
            "2001:0DB8:0000:0:0:0:0:0001", "::", "::1", "1::", "::ffff:192.0.2.1", "::FFFF:192.0.2.1",
            "1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7::", "::2:3:4:5:6:7:8", "fe80::1:2", "1:2:3:4:5:6:1.2.3.4",
            "::1.2.3.4", "abcd:EF01::")
    BAD = ("not.an.ip", "256.1.1.1", "1.2.3.256", "01.2.3.4", "1.2.3", "127.1", "1.2.3.4.5", "1.2.3.",
           " 1.2.3.4", "1.2.3.4 ", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "1::2::3", ":1::", "1:::2", ":::",
           "12345::", "g::1", "fe80::1%eth0", "::1.2.3.4:5", "1.2.3.4::", "1:2:3:4:5:6:7:1.2.3.4",
           "::256.1.1.1", "::01.2.3.4", "localhost", "1:2:3:4::5:6:7:8", ":", "1:", ":1", "[::1]", "0x1.2.3.4")

    def test_addresses_and_empty_are_taken(self):
        for good in self.GOOD:
            self.assertEqual(self.set_ok("announce_ip", good), {"announce_ip": good})

    def test_anything_else_is_refused(self):
        for bad in self.BAD:
            self.set_refused("announce_ip", bad, ANNOUNCE_IP_MESSAGE)

    def test_reviewer_repro_uppercase_ipv6(self):
        self.control({"prefs_override": {"announce_ip": "2001:db8::1"}})
        self.assertEqual(self.set_ok("announce_ip", "2001:DB8::1"), {"announce_ip": "2001:DB8::1"})
        self.control({})
        # And without the override, the fixture itself stores Qt's form.
        self.set_ok("announce_ip", "2001:0DB8:0:0:0:0:0:1")
        self.assertEqual(self.state()["announce_ip"], "2001:db8::1")
        self.set_ok("announce_ip", "::FFFF:192.0.2.1")
        self.assertEqual(self.state()["announce_ip"], "::ffff:192.0.2.1")
        # Sent in hex, stored dotted: only a by-value comparison takes it.
        self.assertEqual(self.set_ok("announce_ip", "::ffff:c000:201"), {"announce_ip": "::ffff:c000:201"})
        self.assertEqual(self.state()["announce_ip"], "::ffff:192.0.2.1")

    def test_fixture_mimics_qt(self):
        for sent, stored in (("not.an.ip", ""), (" 203.0.113.7 ", "203.0.113.7"), ("2001:DB8::1", "2001:db8::1"),
                             ("::ffff:192.0.2.1", "::ffff:192.0.2.1"), ("01.2.3.4", ""), ("", "")):
            self.assertEqual(self.post_raw({"announce_ip": sent}), 200)
            self.assertEqual(self.state()["announce_ip"], stored, sent)


class UsernameTest(FinalFixCase):
    """Ruling DS: 5.2.3 answers 400 for a username under 3 characters or
    with a colon (appcontroller.cpp:907-913)."""

    def test_short_or_colon_is_refused(self):
        for bad in ("", "a", "ab", "a:b", "user:name", ":::"):
            self.set_refused("web_ui_username", bad, USERNAME_MESSAGE)

    def test_good_names_are_taken(self):
        for good in ("abc", "admin", "ünï", "a b"):
            self.assertEqual(self.set_ok("web_ui_username", good), {"web_ui_username": good})
        self.assertEqual(self.set_ok("web_ui_username", "admin"), {"web_ui_username": "admin"})

    def test_fixture_answers_400(self):
        for bad in ("ab", "a:bc"):
            self.assertEqual(self.post_raw({"web_ui_username": bad}), 400, bad)
            self.assertEqual(self.state()["web_ui_username"], "admin")
        self.assertEqual(self.post_raw({"web_ui_username": "root"}), 200)
        self.assertEqual(self.state()["web_ui_username"], "root")
        self.assertEqual(self.post_raw({"web_ui_username": "admin"}), 200)


class TextRulesCasesTest(FinalFixCase):
    """Ruling DV (parity follow-up): the shared case file that both qbt and
    SettingsView.parseInput are checked against, so the window never accepts
    an announce_ip, web_ui_username or path input qbt then refuses."""

    def test_every_case_matches_qbt(self):
        seen = 0
        for case in TEXT_RULES_CASES:
            seen += 1
            with self.subTest(key=case["key"], input=case["input"], why=case["why"]):
                if case["ok"]:
                    text = case["input"]
                    if case["key"] == "save_path" and text.startswith("~/"):
                        want = {"save_path": os.environ["HOME"] + text[1:]}
                    else:
                        want = {case["key"]: text}
                    self.assertEqual(self.set_ok(case["key"], text), want)
                else:
                    self.set_refused(case["key"], case["input"], case["message"])
        self.assertEqual(seen, len(TEXT_RULES_CASES))


class OtherRefusedGainsTokenSecretApiKeyTest(PrefsCase):
    """Ruling DV: PREF_OTHER_REFUSED (and the schema's otherRefusedPatterns)
    gain *token*, *secret* and *api_key*, case-insensitively, so an unknown
    key that sounds like one is refused before it's sent, not just redacted
    on read (RedactionTest)."""

    def test_future_token_and_friends_are_refused(self):
        for key in ("future_token", "Auth_TOKEN", "client_Secret_x", "my_api_key"):
            r = self.set_refused(key, "x", "OmaqBT won't change this setting.")
            self.assertNotIn(SECRET_VALUES[key], r.stderr)


class DerivedKeysTest(FinalFixCase):
    """Ruling DT: 5.2.3 derives these on every GET (appcontroller.cpp:237,
    :316-321) and treats a write of them as the setter (:705, :849-858)."""

    def test_recomputed_after_a_write(self):
        self.set_ok("max_ratio", "2")
        self.assertIs(self.state()["max_ratio_enabled"], True)
        self.set_ok("max_ratio", "-1")
        self.assertIs(self.state()["max_ratio_enabled"], False)
        self.set_ok("max_seeding_time", "60")
        self.assertIs(self.state()["max_seeding_time_enabled"], True)
        self.set_ok("max_seeding_time", "-1")
        self.assertIs(self.state()["max_seeding_time_enabled"], False)
        self.set_ok("max_inactive_seeding_time", "0")
        self.assertIs(self.state()["max_inactive_seeding_time_enabled"], True)
        self.set_ok("max_inactive_seeding_time", "-1")
        self.assertIs(self.state()["max_inactive_seeding_time_enabled"], False)
        self.set_ok("listen_port", "0")
        self.assertIs(self.state()["random_port"], True)
        self.set_ok("listen_port", "50505")
        self.assertIs(self.state()["random_port"], False)

    def test_writing_a_derived_key_is_the_setter(self):
        self.post_raw({"max_ratio": 3})
        self.post_raw({"max_ratio_enabled": False, "max_ratio": 5})
        st = self.state()
        self.assertEqual((st["max_ratio"], st["max_ratio_enabled"]), (-1, False))
        self.post_raw({"max_ratio_enabled": True})
        self.assertEqual(self.state()["max_ratio"], -1, "true alone changes nothing")
        self.post_raw({"random_port": True, "listen_port": 5000})
        st = self.state()
        self.assertEqual((st["listen_port"], st["random_port"]), (0, True))
        self.post_raw({"random_port": False, "listen_port": 5000})
        st = self.state()
        self.assertEqual((st["listen_port"], st["random_port"]), (5000, False))


class SentinelFormsTest(FinalFixCase):
    def test_minus_one_point_zero_is_the_sentinel(self):
        for form in ("-1.0", "-1.00", "-1"):
            before = len(self.log())
            self.assertEqual(self.set_ok("max_ratio", form), {"max_ratio": -1})
            self.assertEqual(self.posts_since(before)[0]["body"], "json=%7B%22max_ratio%22%3A-1%7D", form)
        for bad in ("-1.5", "-1.01", "-2.0", "-01.0", "-1.000"):
            self.set_refused("max_ratio", bad, "Use a number from 0 to 9998, or -1 for none, with at most 2 decimals.")
        # Whole-number keys still take whole numbers only.
        self.set_refused("max_seeding_time", "-1.0", "Use a whole number from 0 to 525600, or -1 for none.")


class SecretsBeforeSchemaTest(FinalFixCase):
    """Ruling DT: the secrets and *password* are refused before the schema
    is read, so a missing or edited schema can't unlock them."""

    def copy_qbt(self, schema=None):
        import shutil
        d = Path(tempfile.mkdtemp(prefix="qbt-noschema-"))
        self.addCleanup(shutil.rmtree, d, True)
        shutil.copy2(QBT, d / "qbt")
        if schema is not None:
            (d / "settings-schema.json").write_text(json.dumps(schema))
        return str(d / "qbt")

    def refused_by(self, qbt, key, message):
        import subprocess
        before = len(self.log())
        r = subprocess.run([qbt, "pref-set", key, "--", "x1"], env=self.env, text=True, capture_output=True)
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", message), key)
        self.assertEqual(self.log()[before:], [], f"{key}: no request at all")

    def refused_stdin(self, qbt, key, mode, message):
        import subprocess
        before = len(self.log())
        r = subprocess.run([qbt, "pref-set", key, mode], env=self.env, input="x1", text=True, capture_output=True)
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", message), f"{key} {mode}")
        self.assertEqual(self.log()[before:], [], f"{key} {mode}: no request at all")

    def check(self, qbt):
        for key in WRITABLE_SECRETS:
            self.refused_by(qbt, key, SECRET_ARGV_MESSAGE)
        self.refused_by(qbt, "web_ui_api_key", "qBittorrent doesn't let this be changed.")
        for key in ("backup_password_extra", "X_PassWord", "web_ui_password", "password"):
            self.refused_by(qbt, key, "OmaqBT won't change this setting.")
        self.refused_by(qbt, "bypass_auth_subnet_whitelist", WHITELIST_MESSAGE)
        # Eng 4b D7: the --stdin allowlist is checked before any schema read.
        for mode in ("--stdin", "--clear"):
            self.refused_stdin(qbt, "web_ui_api_key", mode, "qBittorrent doesn't let this be changed.")
            for key in ("web_ui_password", "backup_password_extra", "X_PassWord", "future_token", "Auth_TOKEN",
                        "client_Secret_x", "my_api_key", "password"):
                self.refused_stdin(qbt, key, mode, "OmaqBT won't change this setting.")
            for key in ("dht", "app_instance_name", "no_such_setting"):
                self.refused_stdin(qbt, key, mode, STDIN_ONLY_MESSAGE)

    def test_without_a_schema(self):
        qbt = self.copy_qbt()
        self.check(qbt)
        # An allowlisted secret still needs the schema's label, and fails closed.
        for mode in ("--stdin", "--clear"):
            self.refused_stdin(qbt, "proxy_password", mode, "The settings schema is missing.")

    def test_a_schema_can_only_restrict_the_allowlist(self):
        schema = json.loads(json.dumps(SCHEMA))
        del schema["keys"]["dyndns_password"]["secretWritable"]
        qbt = self.copy_qbt(schema)
        for mode in ("--stdin", "--clear"):
            self.refused_stdin(qbt, "dyndns_password", mode, "OmaqBT doesn't change secrets yet.")

    def test_with_a_schema_that_unlocks_them(self):
        schema = json.loads(json.dumps(SCHEMA))
        for key in ("proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key"):
            schema["keys"][key] = {"label": key, "type": "text"}
        for key in ("backup_password_extra", "web_ui_password", "future_token", "dht"):
            schema["keys"][key] = {"label": "b", "type": "secret", "secret": True, "secretWritable": True}
        schema["keys"]["bypass_auth_subnet_whitelist"] = {"label": "w", "type": "text"}
        self.check(self.copy_qbt(schema))


class RedactionTest(PrefsCase):
    def test_token_secret_api_key_are_redacted_but_not_schema_keys(self):
        r = self.run_qbt("prefs")
        self.assertEqual(r.returncode, 0, r.stderr)
        got = json.loads(r.stdout)
        for key in ("future_token", "Auth_TOKEN", "client_Secret_x", "my_api_key", "backup_password_extra"):
            self.assertEqual(got[key], {"set": True}, key)
        # A schema key that only sounds like one stays its value.
        self.assertEqual(got["bdecode_token_limit"], DUMP["bdecode_token_limit"])
        self.assertIsInstance(got["bdecode_token_limit"], int)
        for secret in SECRET_VALUES.values():
            self.assertNotIn(secret, r.stdout + r.stderr)


SECRET_LABELS = {"proxy_password": "Proxy password", "dyndns_password": "Password",
                 "mail_notification_password": "SMTP password"}
SECRET_CASES = [c for c in LIST_RULES["cases"] if c["kind"] == "secret"]
BAN_USAGE = "usage: qbt ban-list add|remove <ip>"
IP_MESSAGE = "Use an IPv4 or IPv6 address."
TRACKER_MESSAGE = "Use an http, https or udp tracker URL."
PATTERN_LINE_MESSAGE = "Keep each pattern to one line."


class StdinCase(FinalFixCase):
    def run_stdin(self, key, data=b"", mode="--stdin", env=None):
        import subprocess
        full = dict(self.env)
        full.update(env or {})
        if isinstance(data, str):
            data = data.encode("utf-8", "surrogateescape")
        return subprocess.run([QBT, "pref-set", key, mode], env=full, input=data, capture_output=True)

    def secret_ok(self, key, value, env=None, mode="--stdin"):
        before = len(self.log())
        r = self.run_stdin(key, value, mode=mode, env=env)
        self.assertEqual((r.returncode, r.stdout.decode().strip(), r.stderr.decode()), (0, '{"ok":true}', ""),
                         f"{key} {mode} {value!r}")
        posts = self.posts_since(before)
        self.assertEqual(len(posts), 1, f"{key}: one setPreferences POST")
        self.assertEqual(self.sent(posts[0]), {key: value if isinstance(value, str) else value.decode()})
        return r

    def secret_refused(self, key, value, message, env=None, mode="--stdin", posts=0):
        before = len(self.log())
        r = self.run_stdin(key, value, mode=mode, env=env)
        self.assertEqual((r.returncode, r.stdout, r.stderr.decode().strip()), (1, b"", message), f"{key} {value!r}")
        self.assertEqual(len(self.posts_since(before)), posts, f"{key} {value!r}: setPreferences POSTs")
        return r


class SecretStdinTest(StdinCase):
    """Eng 4b D2/D7, Ruling EB: `pref-set <key> --stdin` for the three
    writable secrets. The value is read once from stdin (5 s), never on an
    argv or in the environment, and read back exactly."""

    def test_every_secret_case(self):
        self.assertGreaterEqual(len(SECRET_CASES), 10)
        for env in (UTF8_ENV, C_ENV):
            for case in SECRET_CASES:
                with self.subTest(input=case["input"][:40], why=case["why"], env=env["LC_ALL"]):
                    if case["ok"]:
                        self.secret_ok("proxy_password", case["input"], env=env)
                        self.assertEqual(self.state()["proxy_password"], case["normalised"])
                    else:
                        r = self.secret_refused("proxy_password", case["input"], case["message"], env=env)
                        if len(case["input"]) > 3:
                            self.assertNotIn(case["input"].encode(), r.stderr)

    def test_each_writable_secret(self):
        for key in WRITABLE_SECRETS:
            self.secret_ok(key, f"new-{key}-value")
            self.assertEqual(self.state()[key], f"new-{key}-value")
            r = self.run_qbt("prefs")
            self.assertEqual(json.loads(r.stdout)[key], {"set": True})
            self.assertNotIn(f"new-{key}-value", r.stdout + r.stderr)

    def test_invalid_utf8_is_refused(self):
        for env in (UTF8_ENV, C_ENV):
            self.secret_refused("proxy_password", b"pass\xffword", "Use valid UTF-8 text.", env=env)
            self.secret_refused("proxy_password", b"\xc3", "Use valid UTF-8 text.", env=env)
            # Byte-exact (fix round 1): what bash's regex lets through.
            for data in (b"a\xed\xa0\x80b", b"\xf4\x90\x80\x80", b"\xc0\xaf", b"\xed\xbf\xbf"):
                self.secret_refused("proxy_password", data, "Use valid UTF-8 text.", env=env)

    def test_nul_anywhere_is_refused(self):
        for data in (b"\x00", b"\x00password", b"password\x00", b"pass\x00word\n", b"a\x00b\x00c"):
            self.secret_refused("dyndns_password", data, "Use a value without NUL characters.")

    def test_line_endings_are_refused(self):
        for data in (b"password\n", b"password\r\n", b"password\r", b"\n", b"\npassword", b"a\nb\n"):
            self.secret_refused("dyndns_password", data, "Keep it to one line.")

    def test_the_cap_counts_code_points(self):
        self.secret_ok("mail_notification_password", "x" * 1024)
        self.secret_ok("mail_notification_password", "\U0001F98A" * 1024, env=C_ENV)
        self.secret_refused("mail_notification_password", "x" * 1025, "Use at most 1024 characters.")
        self.secret_refused("mail_notification_password", "é" * 1025, "Use at most 1024 characters.", env=C_ENV)

    def test_clear_writes_empty_and_reads_no_stdin(self):
        import subprocess
        self.secret_ok("proxy_password", "to-be-cleared")
        for key in WRITABLE_SECRETS:
            before = len(self.log())
            # stdin stays open and unwritten: --clear must not wait on it.
            p = subprocess.Popen([QBT, "pref-set", key, "--clear"], env=self.env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                out, err = p.communicate(timeout=4)
            finally:
                p.kill()
                p.stdin.close() if p.stdin and not p.stdin.closed else None
            self.assertEqual((p.returncode, out.strip(), err), (0, b'{"ok":true}', b""), key)
            posts = self.posts_since(before)
            self.assertEqual([self.sent(x) for x in posts], [{key: ""}])
            self.assertEqual(self.state()[key], "")
            self.assertEqual(json.loads(self.run_qbt("prefs").stdout)[key], {"set": False})

    def test_stdin_timeout(self):
        import subprocess
        import time
        before = len(self.log())
        p = subprocess.Popen([QBT, "pref-set", "proxy_password", "--stdin"], env=self.env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        start = time.monotonic()
        p.stdin.write(b"PARTIALSECRET")
        p.stdin.flush()
        try:
            rc = p.wait(timeout=9)
        finally:
            p.stdin.close()
        out, err = p.stdout.read(), p.stderr.read()
        p.stdout.close()
        p.stderr.close()
        self.assertGreaterEqual(time.monotonic() - start, 4.5)
        self.assertEqual((rc, out, err.decode().strip()), (1, b"", STDIN_TIMEOUT_MESSAGE))
        self.assertEqual(self.log()[before:], [], "no request at all")
        self.assertNotIn(b"PARTIALSECRET", out + err)

    def test_write_failures(self):
        value = "FAILSECRET-1"
        self.control({"setPreferences": "409secret"})
        r = self.secret_refused("proxy_password", value, "qBittorrent refused it (HTTP 409)", posts=1)
        self.assertNotIn(value.encode(), r.stderr)
        self.control({"setPreferences": "noop"})
        self.secret_refused("proxy_password", value, "qBittorrent ignored Proxy password", posts=1)
        self.control({"prefs_override": {"proxy_password": value + " "}})
        self.secret_refused("proxy_password", value, "qBittorrent ignored Proxy password", posts=1)
        self.control({"prefs_override": {"dyndns_password": " " + value}})
        self.secret_refused("dyndns_password", value, "qBittorrent ignored Password", posts=1)
        self.control({"preferences": "409state"})
        self.secret_refused("mail_notification_password", value, "Couldn't confirm SMTP password (HTTP 409)", posts=1)
        self.control({"preferences": "unreadable"})
        self.secret_refused("mail_notification_password", value,
                            "Couldn't confirm SMTP password (qBittorrent sent something unreadable)", posts=1)
        self.control({})

    def test_write_timeout(self):
        # B3: status 000 on the secret POST means qBittorrent may have
        # already applied it -- only the read-back can say, so this reads
        # "couldn't confirm", not "refused".
        self.control({"setPreferences": "sleep7"})
        self.secret_refused("proxy_password", "SLOWSECRET-2",
                            "Couldn't confirm Proxy password (couldn't reach qBittorrent)", posts=1)
        self.control({})

    def test_unreachable(self):
        # Also status 000 (curl never connected): api_stdin can't tell this
        # apart from a timeout after the body went out, so it reads the
        # same "couldn't confirm" as test_write_timeout.
        env = {"QBT_BASE": "http://127.0.0.1:9"}
        self.secret_refused("proxy_password", "DOWNSECRET-3",
                            "Couldn't confirm Proxy password (couldn't reach qBittorrent)", env=env)
        self.secret_refused("proxy_password", "x", "refusing non-localhost host (base must be http://127.0.0.1:<port>)",
                            env={"QBT_BASE": "http://127.0.0.2:1"})


class ListWritesTest(FinalFixCase):
    """Eng 4b D5/D10: add_trackers and excluded_file_names take a whole
    newline-joined list through `pref-set <key> -- <value>`. Every line is
    checked per list-rules-cases.json, and the read-back is exact: tier
    breaks, repeated blank lines, empty entries and a trailing newline all
    round-trip."""

    KEYS = {"trackerUrl": "add_trackers", "pattern": "excluded_file_names"}

    def test_every_list_round_trip(self):
        seen = 0
        for case in LIST_RULES["lists"]:
            if case["key"] == "banned_IPs":
                continue
            seen += 1
            for env in (UTF8_ENV, C_ENV):
                with self.subTest(key=case["key"], why=case["why"], env=env["LC_ALL"]):
                    # Ruling EC: the lines already stored (here, every one)
                    # go back as they are.
                    self.assertEqual(self.post_raw({case["key"]: case["input"]}), 200)
                    self.assertEqual(self.set_ok(case["key"], case["input"], env=env), {case["key"]: case["input"]})
                    self.assertEqual(self.state()[case["key"]], case["normalised"])
        self.assertEqual(seen, 10)

    def test_every_line_case(self):
        seen = 0
        for case in LIST_RULES["cases"]:
            key = self.KEYS.get(case["kind"])
            if key is None:
                continue
            seen += 1
            with self.subTest(kind=case["kind"], input=case["input"][:60], why=case["why"]):
                if "\n" in case["input"]:
                    # One line per list entry: the window refuses a typed
                    # newline, but a whole list is newline-joined, so qbt
                    # checks each line on its own.
                    self.assertEqual(self.set_ok(key, case["input"]), {key: case["input"]})
                elif case["kind"] == "pattern" and case["input"] == "":
                    # "a adds none" is the window's rule; as a whole value
                    # "" is the empty list, which round-trips.
                    self.assertEqual(self.set_ok(key, ""), {key: ""})
                elif case["ok"]:
                    self.assertEqual(self.set_ok(key, case["input"]), {key: case["input"]})
                    self.assertEqual(self.state()[key], case["normalised"])
                else:
                    self.set_refused(key, case["input"], case["message"])
        self.assertGreater(seen, 30)

    def test_one_bad_line_refuses_the_whole_list(self):
        self.set_ok("add_trackers", "udp://a.example:1/announce")
        for bad in ("udp://a.example:1/announce\n\nftp://b.example/x", "udp://a.example:1/announce\nudp://",
                    "https://ok.example/a\n\nhttps://ok.example/a|b", "\n udp://a.example:1/announce",
                    "udp://a.example:1/announce\r\nhttp://b.example/announce"):
            self.set_refused("add_trackers", bad, TRACKER_MESSAGE)
        for bad in ("*.exe\r\n*.scr", "*.exe\n\r", "\r"):
            self.set_refused("excluded_file_names", bad, PATTERN_LINE_MESSAGE)
        self.assertEqual(self.state()["add_trackers"], "udp://a.example:1/announce")

    def test_tracker_length_counts_the_line(self):
        url = "https://t.example/" + "a" * (2048 - len("https://t.example/"))
        self.assertEqual(self.set_ok("add_trackers", url + "\n\n" + url), {"add_trackers": url + "\n\n" + url})
        self.set_refused("add_trackers", url + "a", TRACKER_MESSAGE)

    def test_invalid_utf8_is_refused(self):
        self.set_refused("excluded_file_names", "*.exe\na\udcffb", "Use valid UTF-8 text.")
        # Byte-exact (fix round 1): a UTF-16 surrogate, past U+10FFFF, overlong.
        for bad in ("a\udced\udca0\udc80b", "\udcf4\udc90\udc80\udc80", "\udcc0\udcaf"):
            self.set_refused("excluded_file_names", "*.exe\n" + bad, "Use valid UTF-8 text.")
            self.set_refused("app_instance_name", bad, "Use valid UTF-8 text.")

    def test_only_lines_not_stored_are_checked(self):
        # Ruling EC, the reviewer's repro: a line qBittorrent's own UI stored
        # (wss://) doesn't block adding or removing others.
        stored = "http://a.example/announce\nwss://ws.example/x\n\nudp://b.example:1/announce"
        self.assertEqual(self.post_raw({"add_trackers": stored}), 200)
        added = stored + "\nhttp://c.example/announce"
        self.assertEqual(self.set_ok("add_trackers", added), {"add_trackers": added})
        self.assertEqual(self.state()["add_trackers"], added)
        removed = "wss://ws.example/x\n\nudp://b.example:1/announce\nhttp://c.example/announce"
        self.assertEqual(self.set_ok("add_trackers", removed), {"add_trackers": removed})
        self.assertEqual(self.state()["add_trackers"], removed)
        # A new bad line is still refused.
        self.set_refused("add_trackers", removed + "\nwss://new.example/x", TRACKER_MESSAGE)
        # Patterns: a stored CR line is kept; a new one is refused.
        self.assertEqual(self.post_raw({"excluded_file_names": "*.exe\na\rb"}), 200)
        self.assertEqual(self.set_ok("excluded_file_names", "*.exe\na\rb\n*.scr"),
                         {"excluded_file_names": "*.exe\na\rb\n*.scr"})
        self.set_refused("excluded_file_names", "*.exe\na\rb\n*.scr\nc\rd", PATTERN_LINE_MESSAGE)

    def test_a_new_empty_pattern_is_refused(self):
        self.assertEqual(self.post_raw({"excluded_file_names": "*.exe"}), 200)
        for bad in ("*.exe\n", "\n*.exe", "*.exe\n\n*.scr"):
            self.set_refused("excluded_file_names", bad, "Use a pattern such as *.exe.")
        # Stored empties keep round-tripping, and the empty list is fine.
        self.assertEqual(self.post_raw({"excluded_file_names": "*.exe\n\n*.scr"}), 200)
        self.assertEqual(self.set_ok("excluded_file_names", "*.exe\n\n*.scr\n*.bat"),
                         {"excluded_file_names": "*.exe\n\n*.scr\n*.bat"})
        self.assertEqual(self.set_ok("excluded_file_names", ""), {"excluded_file_names": ""})
        # Tracker tier breaks are always fine.
        self.assertEqual(self.post_raw({"add_trackers": "udp://a.example:1/x"}), 200)
        self.assertEqual(self.set_ok("add_trackers", "udp://a.example:1/x\n\nudp://b.example:1/x"),
                         {"add_trackers": "udp://a.example:1/x\n\nudp://b.example:1/x"})

    def test_the_stored_read_fails_before_any_write(self):
        self.control({"preferences": "409state"})
        self.set_refused("add_trackers", "udp://a.example:1/x", "qBittorrent refused it (HTTP 409)")
        self.control({"preferences": "unreadable"})
        self.set_refused("excluded_file_names", "*.exe", "qBittorrent sent something unreadable")
        self.control({})

    def test_read_back_is_exact(self):
        # 4a's rule trims strings; a list must come back exactly.
        for key, sent, got in (("add_trackers", "udp://a.example:1/announce\n", "udp://a.example:1/announce"),
                               ("add_trackers", "udp://a.example:1/announce\n\nhttp://b.example/x",
                                "udp://a.example:1/announce\nhttp://b.example/x"),
                               ("excluded_file_names", "*.exe\n*.scr", "*.exe"),
                               ("excluded_file_names", " *.tmp ", "*.tmp")):
            self.control({"prefs_override": {key: got}})
            r = self.run_qbt("pref-set", key, "--", sent)
            label = SCHEMA["keys"][key]["label"]
            self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", f"qBittorrent ignored {label}"), sent)
        self.control({})

    def test_untouched_lines_survive_an_edit(self):
        # Review focus 3: the window sends the whole list back; tiers and
        # empty entries it didn't touch reach qBittorrent unchanged.
        start = "udp://a.example:1/announce\n\n\nhttp://b.example/announce\n"
        self.set_ok("add_trackers", start)
        self.assertEqual(self.set_ok("add_trackers", start + "https://c.example/x"),
                         {"add_trackers": start + "https://c.example/x"})
        self.assertEqual(self.state()["add_trackers"], start + "https://c.example/x")


class BanListTest(FinalFixCase):
    """Eng 4b D3/D11: `qbt ban-list add|remove <ip>` re-reads banned_IPs
    just before writing, compares addresses in QHostAddress's form, and
    reports a mismatch without restoring anything."""

    def ban(self, op, ip, env=None):
        return self.run_qbt("ban-list", op, ip, env=env)

    def ban_ok(self, op, ip, changed=True):
        before = len(self.log())
        r = self.ban(op, ip)
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, '{"ok":true}', ""), f"{op} {ip!r}")
        posts = self.posts_since(before)
        self.assertEqual(len(posts), 1 if changed else 0, f"{op} {ip!r}: setPreferences POSTs")
        return [self.sent(x) for x in posts]

    def ban_refused(self, op, ip, message, posts=0, requests=None):
        before = len(self.log())
        r = self.ban(op, ip)
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", message), f"{op} {ip!r}")
        self.assertEqual(len(self.posts_since(before)), posts, f"{op} {ip!r}: setPreferences POSTs")
        if requests is not None:
            self.assertEqual(len(self.log()) - before, requests, f"{op} {ip!r}: requests")
        return r

    def set_bans(self, text):
        self.assertEqual(self.post_raw({"banned_IPs": text}), 200)

    def bans(self):
        return self.state()["banned_IPs"]

    def setUp(self):
        self.set_bans("")

    def test_usage(self):
        for args in (["ban-list"], ["ban-list", "add"], ["ban-list", "add", "1.2.3.4", "x"], ["ban-list", "ban", "1.2.3.4"],
                     ["ban-list", "--", "1.2.3.4"], ["ban-list", "Add", "1.2.3.4"], ["ban-list", "list"]):
            before = len(self.log())
            r = self.run_qbt(*args)
            self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", BAN_USAGE), args)
            self.assertEqual(self.log()[before:], [], f"{args}: no request at all")

    def test_every_ip_case(self):
        seen = 0
        for case in LIST_RULES["cases"]:
            if case["kind"] != "ip":
                continue
            seen += 1
            with self.subTest(input=case["input"], why=case["why"]):
                self.set_bans("")
                if case["ok"]:
                    self.assertEqual(self.ban_ok("add", case["input"]), [{"banned_IPs": case["normalised"]}])
                    self.assertEqual(self.bans(), case["normalised"])
                    self.assertEqual(self.ban_ok("remove", case["input"]), [{"banned_IPs": ""}])
                    self.assertEqual(self.bans(), "")
                else:
                    self.ban_refused("add", case["input"], IP_MESSAGE, requests=0)
                    # Ruling ED: remove first looks for it exactly as stored.
                    self.ban_refused("remove", case["input"], IP_MESSAGE, posts=0,
                                     requests=0 if case["input"] == "" or "\n" in case["input"] else 1)
        self.assertGreater(seen, 20)

    def test_add_keeps_every_other_ban(self):
        self.set_bans("10.0.0.1\n2001:db8::1\n::ffff:1.2.3.4")
        self.assertEqual(self.ban_ok("add", "9.9.9.9"), [{"banned_IPs": "10.0.0.1\n2001:db8::1\n::ffff:1.2.3.4\n9.9.9.9"}])
        self.assertEqual(self.bans(), "10.0.0.1\n2001:db8::1\n9.9.9.9\n::ffff:1.2.3.4")

    def test_remove_matches_any_form(self):
        self.set_bans("10.0.0.1\n2001:db8::1\n9.9.9.9")
        self.assertEqual(self.ban_ok("remove", "2001:0DB8:0000:0000:0000:0000:0000:0001"),
                         [{"banned_IPs": "10.0.0.1\n9.9.9.9"}])
        self.assertEqual(self.bans(), "10.0.0.1\n9.9.9.9")
        self.set_bans("::ffff:1.2.3.4\n1.2.3.4")
        self.assertEqual(self.ban_ok("remove", "::FFFF:0102:0304"), [{"banned_IPs": "1.2.3.4"}])

    def test_already_banned_or_not_banned_writes_nothing(self):
        self.set_bans("10.0.0.1\n2001:db8::1")
        self.ban_ok("add", "2001:DB8:0::1", changed=False)
        self.ban_ok("add", "10.0.0.1", changed=False)
        self.ban_ok("remove", "10.0.0.2", changed=False)
        self.ban_ok("remove", "::ffff:10.0.0.1", changed=False)
        self.assertEqual(self.bans(), "10.0.0.1\n2001:db8::1")

    def test_reads_just_before_writing(self):
        self.set_bans("10.0.0.1")
        before = len(self.log())
        self.ban_ok("add", "10.0.0.2")
        calls = [(e["method"], e["path"]) for e in self.log()[before:]]
        self.assertEqual(calls, [("GET", "/api/v2/app/preferences"), ("POST", "/api/v2/app/setPreferences"),
                                 ("GET", "/api/v2/app/preferences")])
        # A change made elsewhere since the window last read is kept.
        self.set_bans("10.0.0.1\n10.0.0.2\n172.16.0.9")
        self.assertEqual(self.ban_ok("remove", "10.0.0.1"), [{"banned_IPs": "10.0.0.2\n172.16.0.9"}])

    def test_qt_forms(self):
        # QHostAddress::toString (checked against Qt 6.11): an address whose
        # first 96 bits are zero keeps a dotted tail, like a mapped one.
        for ip, stored in (("::1.2.3.4", "::1.2.3.4"), ("::0:102:304", "::1.2.3.4"), ("::0.0.1.0", "::100"),
                           ("::1:0", "::0.1.0.0"), ("::FFFF:c000:201", "::ffff:192.0.2.1"),
                           ("1:0:0:2:0:0:0:3", "1:0:0:2::3"), ("::2:3:4:5:6:7:8", "0:2:3:4:5:6:7:8"),
                           ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"), ("::", "::"), ("ABCD::", "abcd::")):
            with self.subTest(ip=ip):
                self.set_bans("")
                self.assertEqual(self.ban_ok("add", ip), [{"banned_IPs": stored}])
                self.assertEqual(self.bans(), stored)
                self.ban_ok("add", stored, changed=False)

    def test_entries_qbt_would_refuse_are_kept_untouched(self):
        # qBittorrent's own UI can store a ban qbt wouldn't accept (Qt keeps
        # a zone id): an edit of another address carries it through and is
        # not reported as a changed list.
        self.set_bans("fe80::1%eth0\n10.0.0.1")
        self.assertEqual(self.bans(), "10.0.0.1\nfe80::1%eth0")
        self.assertEqual(self.ban_ok("add", "10.0.0.2"), [{"banned_IPs": "10.0.0.1\nfe80::1%eth0\n10.0.0.2"}])
        self.assertEqual(self.bans(), "10.0.0.1\n10.0.0.2\nfe80::1%eth0")
        self.assertEqual(self.ban_ok("remove", "10.0.0.1"), [{"banned_IPs": "10.0.0.2\nfe80::1%eth0"}])
        self.assertEqual(self.bans(), "10.0.0.2\nfe80::1%eth0")

    def test_remove_takes_an_address_exactly_as_stored(self):
        # Ruling ED: a zone id stored by qBittorrent's own UI can be unbanned,
        # though add refuses it.
        self.set_bans("fe80::1%eth0\n10.0.0.1")
        self.ban_refused("add", "fe80::1%eth0", IP_MESSAGE, requests=0)
        self.ban_refused("remove", "FE80::1%eth0", IP_MESSAGE, posts=0)
        self.ban_refused("remove", "fe80::1%eth", IP_MESSAGE, posts=0)
        self.assertEqual(self.ban_ok("remove", "fe80::1%eth0"), [{"banned_IPs": "10.0.0.1"}])
        self.assertEqual(self.bans(), "10.0.0.1")
        self.set_bans("fe80::1%eth0")
        self.control({"prefs_override": {"banned_IPs": "fe80::1%eth0"}})
        self.ban_refused("remove", "fe80::1%eth0", "qBittorrent still bans fe80::1%eth0.", posts=1)
        self.control({})

    def test_lost_update_is_reported_never_restored(self):
        self.set_bans("10.0.0.1")
        # Another writer lands right after ours: the ban is there, the list isn't what we wrote.
        self.control({"prefs_override": {"banned_IPs": "10.0.0.1\n10.0.0.2\n172.16.0.9"}})
        self.ban_refused("add", "10.0.0.2", "The ban list changed while OmaqBT saved it; check it.", posts=1)
        self.assertEqual(self.bans(), "10.0.0.1\n10.0.0.2\n172.16.0.9", "nothing restored")
        # ...or it drops ours.
        self.control({"prefs_override": {"banned_IPs": "10.0.0.1"}})
        self.ban_refused("add", "10.0.0.3", "qBittorrent didn't ban 10.0.0.3.", posts=1)
        # ...or drops another one, keeping ours.
        self.control({"prefs_override": {"banned_IPs": "2001:db8::1"}})
        self.ban_refused("add", "2001:DB8::1", "The ban list changed while OmaqBT saved it; check it.", posts=1)
        self.control({})
        self.set_bans("10.0.0.1\n2001:db8::1")
        self.control({"prefs_override": {"banned_IPs": "10.0.0.1\n2001:db8::1"}})
        self.ban_refused("remove", "2001:DB8::1", "qBittorrent still bans 2001:db8::1.", posts=1)
        self.control({"prefs_override": {"banned_IPs": ""}})
        self.ban_refused("remove", "10.0.0.1", "The ban list changed while OmaqBT saved it; check it.", posts=1)
        self.control({})
        self.assertEqual(self.bans(), "", "nothing restored")

    def test_failures_report_the_code_only(self):
        self.set_bans("10.0.0.1")
        self.control({"preferences": "409state"})
        self.ban_refused("add", "10.0.0.2", "qBittorrent refused it (HTTP 409)", posts=0)
        self.control({"preferences": "unreadable"})
        self.ban_refused("add", "10.0.0.2", "qBittorrent sent something unreadable", posts=0)
        # banned_IPs that isn't a string.
        self.control({"prefs_override": {"banned_IPs": 5}})
        self.set_bans("10.0.0.1")
        self.control({})
        self.ban_refused("add", "10.0.0.2", "qBittorrent sent something unreadable", posts=0)
        self.set_bans("10.0.0.1")
        self.control({"setPreferences": "409secret"})
        r = self.ban_refused("add", "10.0.0.2", "qBittorrent refused it (HTTP 409)", posts=1)
        self.assertNotIn("passkey", r.stderr)
        self.control({"setPreferences": "sleep7"})
        self.ban_refused("add", "10.0.0.2", "qBittorrent refused it (couldn't reach qBittorrent)", posts=1)
        # The read-back after the write fails: the write may have applied.
        for fault, reason in (("409", "HTTP 409"), ("unreadable", "qBittorrent sent something unreadable")):
            self.control({})
            self.set_bans("10.0.0.1")
            self.state()
            self.control({"preferences_after_post": fault})
            self.ban_refused("add", "10.0.0.2", f"Couldn't confirm Banned IPs ({reason})", posts=1)
            self.control({})
            self.assertEqual(self.bans(), "10.0.0.1\n10.0.0.2", "the write applied")
            self.control({"preferences_after_post": fault})
            self.ban_refused("remove", "10.0.0.1", f"Couldn't confirm Banned IPs ({reason})", posts=1)
        self.control({})


class FixtureBannedIpsTest(FinalFixCase):
    """5.2.3's setBannedIPs (sessionimpl.cpp:4167, appcontroller.cpp:783):
    empty parts skipped, invalid addresses dropped, QHostAddress form,
    sorted as strings, de-duplicated."""

    def test_every_banned_ips_round_trip(self):
        seen = 0
        for case in LIST_RULES["lists"]:
            if case["key"] != "banned_IPs":
                continue
            seen += 1
            with self.subTest(why=case["why"]):
                self.assertEqual(self.post_raw({"banned_IPs": case["input"]}), 200)
                self.assertEqual(self.state()["banned_IPs"], case["normalised"])
        self.assertEqual(seen, 6)

    def test_qt_dotted_tail(self):
        self.assertEqual(self.post_raw({"banned_IPs": "::0:102:304\n::1:0\n::0.0.1.0\n::ffff:c000:201"}), 200)
        self.assertEqual(self.state()["banned_IPs"], "::0.1.0.0\n::1.2.3.4\n::100\n::ffff:192.0.2.1")


class LargeBodyTest(FinalFixCase):
    """Final fix wave (B1/B2). With banned_IPs well past bash 5.3's ~64 KiB
    here-string pipe-buffer threshold, a here-string that still carries
    PREFS_JSON or API_BODY would spill to a sh-thd.* temp file for the
    microseconds it takes jq to read it -- long enough, at review-caught
    odds, to hold a just-set secret on disk. And the same big list,
    URI-encoded, is well past MAX_ARG_STRLEN (~128 KiB): a single curl or
    jq argument that size makes exec fail with E2BIG."""

    # 12,000 distinct, valid IPv4 addresses. URI-encoded (each "\n" becomes
    # "%0A") this list is comfortably past both thresholds above.
    MANY_IPS = [f"203.{hi}.{lo}.1" for hi in range(1, 50) for lo in range(256)][:12000]

    def setUp(self):
        self.assertEqual(len(self.MANY_IPS), 12000)
        self.assertEqual(len(self.MANY_IPS), len(set(self.MANY_IPS)))
        self.assertEqual(self.post_raw({"banned_IPs": "\n".join(self.MANY_IPS)}), 200)
        self.addCleanup(self.post_raw, {"banned_IPs": ""})

    def run_bounded(self, *args, env=None, input=None):
        # A file-size cap well under bash's ~64 KiB here-string
        # pipe-buffer threshold. A here-string over that threshold spills
        # to a temp file, which this cap turns into a loud failure
        # (SIGXFSZ, or bash's own "cannot create temp file for
        # here-document") instead of a silent one; a fixed here-string
        # (piped instead) never touches a file, so it's unaffected. A
        # 50 ms poll on a fresh TMPDIR can miss a file that lives for
        # microseconds (that's how the reviewer's own finding was this
        # narrow); this doesn't rely on timing at all.
        full = dict(self.env)
        full.update(env or {})
        return subprocess.run(["bash", "-c", 'ulimit -f 32 && exec "$0" "$@"', QBT, *args],
                              env=full, input=input, capture_output=True)

    def test_ulimit_mechanism_would_catch_a_spilled_here_string(self):
        # Self-check, on this machine's bash, that the cap actually bites
        # on a spilled here-string -- so a pass below means what it says.
        probe = subprocess.run(
            ["bash", "-c", 'ulimit -f 32; x=$(head -c 100000 /dev/zero | tr "\\0" a); cat <<<"$x" >/dev/null'],
            capture_output=True)
        self.assertNotEqual(probe.returncode, 0)
        self.assertIn(b"temp file", probe.stderr)

    def test_prefs_secret_write_and_ban_list_never_spill_a_here_string(self):
        r = self.run_bounded("prefs")
        self.assertEqual((r.returncode, r.stderr), (0, b""), r.stderr)
        r = self.run_bounded("pref-set", "proxy_password", "--stdin", input=b"S3CRET-large-body")
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, b'{"ok":true}', b""))
        r = self.run_bounded("ban-list", "add", "198.51.100.77")
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, b'{"ok":true}', b""))
        self.assertIn("198.51.100.77", self.state()["banned_IPs"].split("\n"))
        r = self.run_bounded("ban-list", "remove", "198.51.100.77")
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, b'{"ok":true}', b""))
        self.assertNotIn("198.51.100.77", self.state()["banned_IPs"].split("\n"))

    def test_prefs_and_ban_list_touch_no_file_in_a_fresh_tmpdir(self):
        # Weaker than the ulimit checks above (a microsecond-lived file
        # can slip past a post-hoc iterdir()), kept alongside them as a
        # second signal against a file left behind.
        tmpdir = Path(tempfile.mkdtemp(prefix="qbt-tmp-"))
        self.addCleanup(__import__("shutil").rmtree, tmpdir, True)
        env = {"TMPDIR": str(tmpdir), "TMP": str(tmpdir), "TEMP": str(tmpdir)}
        self.assertEqual(self.run_qbt("prefs", env=env).returncode, 0)
        r = subprocess.run([QBT, "pref-set", "proxy_password", "--stdin"], env=dict(self.env, **env),
                           input=b"S3CRET-tmpdir-body", capture_output=True)
        self.assertEqual((r.returncode, r.stderr), (0, b""))
        self.assertEqual(self.run_qbt("ban-list", "add", "198.51.100.78", env=env).returncode, 0)
        self.assertEqual(self.run_qbt("ban-list", "remove", "198.51.100.78", env=env).returncode, 0)
        self.assertEqual(list(tmpdir.iterdir()), [])

    def test_ban_list_add_remove_past_max_arg_strlen(self):
        # 12,000 IPv4 addresses, URI-encoded, is well past MAX_ARG_STRLEN
        # (128 KiB): the whole list must never be a single curl or jq
        # argument.
        r = self.run_qbt("ban-list", "add", "198.51.100.99")
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, '{"ok":true}', ""))
        stored = self.state()["banned_IPs"].split("\n")
        self.assertIn("198.51.100.99", stored)
        self.assertGreaterEqual(len(stored), 12000)
        r = self.run_qbt("ban-list", "remove", "198.51.100.99")
        self.assertEqual((r.returncode, r.stdout.strip(), r.stderr), (0, '{"ok":true}', ""))
        self.assertNotIn("198.51.100.99", self.state()["banned_IPs"].split("\n"))

    def test_no_here_string_carries_prefs_json_or_api_body(self):
        text = (ROOT / "qbt").read_text()
        self.assertNotIn('<<<"$PREFS_JSON"', text)
        self.assertNotIn('<<<"$API_BODY"', text)


# Every external command qbt may spawn. PATH holds only these shims, so a
# command qbt spawns that isn't here fails loudly instead of going unlogged.
SHIMMED_TOOLS = ("jq", "curl", "sed", "cat", "mktemp", "rm", "readlink", "dirname", "stat", "id", "grep", "cut",
                 "tail", "head", "tr", "wc", "od", "env", "timeout", "sleep", "pgrep", "mkdir", "chmod", "date",
                 "basename", "sort", "uniq", "printf", "tee", "mv", "cp", "ls", "flock", "python3", "base64",
                 # conf_pref reads the API key from qBittorrent.conf.
                 "awk",
                 # qbt's own #!/usr/bin/env bash finds bash through PATH.
                 "bash")


class SecretArgvTest(StdinCase):
    """Eng 4b D7 (mandatory): no secret is ever on the argv or in the
    environment of a process qbt spawns, on success, refusal, timeout and
    failure. Every external command runs through a shim that logs its argv
    and its whole environment first."""

    def make_shims(self):
        import shutil
        bindir = Path(tempfile.mkdtemp(prefix="qbt-argv-"))
        self.addCleanup(shutil.rmtree, bindir, True)
        log = bindir / "spawn.log"
        for tool in SHIMMED_TOOLS:
            real = shutil.which(tool)
            if not real:
                continue
            shim = bindir / tool
            # Absolute paths only: PATH points back at the shims.
            shim.write_text(
                "#!/bin/sh\n"
                # An inherited SHELLOPTS=xtrace would trace the shim itself.
                "{ set +o xtrace; } 2>/dev/null\n"
                f"{{ printf 'ARGV\\0'; printf '%s\\0' \"$0\" \"$@\"; printf 'ENV\\0'; /usr/bin/cat /proc/$$/environ; }} >>'{log}'\n"
                f"exec '{real}' \"$@\"\n")
            shim.chmod(0o755)
        self.assertTrue((bindir / "jq").exists() and (bindir / "curl").exists())
        return {"PATH": str(bindir)}, log

    def test_no_secret_in_any_spawned_argv_or_environment(self):
        import subprocess
        import time
        env, log = self.make_shims()
        secrets = []

        def secret(tag):
            value = f"S3CRET-{tag}-" + "q" * 6
            secrets.append(value)
            return value

        # Success, for all three, and a clear.
        for key in WRITABLE_SECRETS:
            v = secret(key)
            r = self.run_stdin(key, v, env=env)
            self.assertEqual((r.returncode, r.stderr), (0, b""), f"{key}: qbt ran with only the shims on PATH")
            self.assertEqual(self.state()[key], v)
        r = self.run_stdin("proxy_password", mode="--clear", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        # Refusals: NUL, newline, too long, invalid UTF-8, a refused key.
        for data in (secret("nul") + "\0x", secret("nl") + "\n", secret("long") * 80, secret("bad") + "\udcff"):
            r = self.run_stdin("dyndns_password", data, env=env)
            self.assertEqual(r.returncode, 1)
        for key in ("web_ui_password", "dht", "web_ui_api_key"):
            r = self.run_stdin(key, secret(key), env=env)
            self.assertEqual(r.returncode, 1)
        r = self.run_qbt("pref-set", "proxy_password", "--", "argv-is-the-callers", env=env)
        self.assertEqual(r.returncode, 1)
        # Failures: refused POST, ignored write, failed read-back, unreachable.
        for control in ({"setPreferences": "409secret"}, {"setPreferences": "noop"}, {"preferences": "409state"},
                        {"preferences": "unreadable"}):
            self.control(control)
            r = self.run_stdin("mail_notification_password", secret("fail"), env=env)
            self.assertEqual(r.returncode, 1, control)
        self.control({})
        r = self.run_stdin("proxy_password", secret("down"), env=dict(env, QBT_BASE="http://127.0.0.1:9"))
        self.assertEqual(r.returncode, 1)
        # Timeouts: the POST stalls past curl's limit, and stdin never closes.
        self.control({"setPreferences": "sleep7"})
        r = self.run_stdin("proxy_password", secret("slow"), env=env)
        self.assertEqual(r.returncode, 1)
        self.control({})
        full = dict(self.env)
        full.update(env)
        p = subprocess.Popen([QBT, "pref-set", "proxy_password", "--stdin"], env=full, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        p.stdin.write(secret("stall").encode())
        p.stdin.flush()
        try:
            self.assertEqual(p.wait(timeout=9), 1)
        finally:
            p.stdin.close()
            p.stdout.close()
            p.stderr.close()
        # 4a's paths and the 4b list and ban writes, with secrets stored.
        self.secret_ok("proxy_password", secret("stored"))
        self.assertEqual(self.run_qbt("prefs", env=env).returncode, 0)
        self.assertEqual(self.run_qbt("pref-set", "dht", "--", "false", env=env).returncode, 0)
        self.assertEqual(self.run_qbt("pref-set", "add_trackers", "--", "udp://a.example:1/x\n\nhttp://b.example/y",
                                      env=env).returncode, 0)
        self.assertEqual(self.run_qbt("ban-list", "add", "203.0.113.9", env=env).returncode, 0)
        self.assertEqual(self.run_qbt("ban-list", "remove", "203.0.113.9", env=env).returncode, 0)
        self.control({"setPreferences": "noop"})
        self.assertEqual(self.run_qbt("pref-set", "future_flag", "--", "true", env=env).returncode, 1)
        self.control({})

        logged = log.read_bytes()
        self.assertIn(b"setPreferences", logged, "the shims really ran")
        self.assertIn(b"--data-binary", logged, "the secret POST went through a shimmed curl")
        entries = logged.split(b"ARGV\0")[1:]
        self.assertGreater(len(entries), 50)
        stored = [v.encode() for v in SECRET_VALUES.values()]
        for value in secrets:
            self.assertNotIn(value.encode(), logged, value)
            # URL- or JSON-encoded forms too.
            self.assertNotIn(value.replace("-", "%2D").encode(), logged)
        for value in stored:
            self.assertNotIn(value, logged)
        self.assertNotIn(b"S3CRET", logged)

    def test_inherited_shellopts_never_leak(self):
        # Fix round 1 (Ruling EE): an exported SHELLOPTS turns bash options
        # on before qbt's first line runs. allexport would export the value
        # to every child; xtrace would print it on stderr.
        env, log = self.make_shims()
        value = "S3CRET-opts-" + "w" * 6
        for opts in ("allexport", "xtrace", "allexport:xtrace", "braceexpand:allexport:hashall:interactive-comments:xtrace"):
            for key, mode, data in (("proxy_password", "--stdin", value), ("proxy_password", "--stdin", value + "\n"),
                                    ("dyndns_password", "--clear", "")):
                r = self.run_stdin(key, data, mode=mode, env=dict(env, SHELLOPTS=opts))
                self.assertNotIn(value.encode(), r.stdout + r.stderr, opts)
                if data == value:
                    self.assertEqual((r.returncode, r.stderr), (0, b""), f"SHELLOPTS={opts}")
            self.assertEqual(self.run_qbt("ban-list", "add", "203.0.113.8", env=dict(env, SHELLOPTS=opts)).stderr, "")
        self.assertEqual(self.state()["proxy_password"], value)
        logged = log.read_bytes()
        self.assertIn(b"SHELLOPTS=", logged, "the shims saw the inherited SHELLOPTS")
        self.assertNotIn(value.encode(), logged)
        self.assertNotIn(b"S3CRET", logged)

    def test_ban_list_runs_one_jq_between_its_read_and_its_write(self):
        # Fix round 1: the plan, the address and the body are one jq call,
        # so the read-to-write window holds no more spawns than it must.
        env, log = self.make_shims()
        self.assertEqual(FinalFixCase.post_raw(self, {"banned_IPs": "10.0.0.1"}), 200)
        r = self.run_qbt("ban-list", "add", "10.0.0.7", env=env)
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        names = []
        for entry in log.read_bytes().split(b"ARGV\0")[1:]:
            argv = entry.split(b"ENV\0")[0].split(b"\0")
            tool = Path(argv[0].decode()).name
            if tool == "curl":
                tool += " POST" if b"setPreferences" in entry.split(b"ENV\0")[0] else " GET"
            names.append(tool)
        get = names.index("curl GET")
        post = names.index("curl POST")
        self.assertLess(get, post)
        self.assertEqual(names[get + 1:post].count("jq"), 1, names[get:post + 1])

    def test_no_response_body_ever_touches_disk(self):
        # Ruling EG: the preferences body holds every stored secret, so
        # api_exec keeps it in memory only. TMPDIR is a fresh empty dir and
        # must stay empty during every read, including a SIGKILL mid-request
        # (nothing could clean up after that).
        import signal
        import subprocess
        import time
        tmpdir = Path(tempfile.mkdtemp(prefix="qbt-tmp-"))
        self.addCleanup(__import__("shutil").rmtree, tmpdir, True)
        env = {"TMPDIR": str(tmpdir), "TMP": str(tmpdir), "TEMP": str(tmpdir)}
        self.assertEqual(self.run_qbt("prefs", env=env).returncode, 0)
        self.secret_ok("proxy_password", "S3CRET-disk-1", env=env)
        self.assertEqual(self.run_qbt("pref-set", "add_trackers", "--", "udp://a.example:1/x", env=env).returncode, 0)
        self.assertEqual(self.run_qbt("ban-list", "add", "203.0.113.4", env=env).returncode, 0)
        self.assertEqual(list(tmpdir.iterdir()), [])
        for sig, group in ((signal.SIGKILL, True), (signal.SIGTERM, True), (signal.SIGTERM, False)):
            self.control({"preferences": "sleep7"})
            p = subprocess.Popen([QBT, "prefs"], env=dict(self.env, **env), stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                self.assertEqual(list(tmpdir.iterdir()), [], "nothing on disk mid-request")
                time.sleep(0.05)
            if group:
                os.killpg(p.pid, sig)
            else:
                p.send_signal(sig)
            p.wait(timeout=5)
            p.stdout.close()
            p.stderr.close()
            self.assertEqual(list(tmpdir.iterdir()), [], f"{sig!r} group={group}")
            self.control({})
        # And nothing in api_exec can write one.
        text = (ROOT / "qbt").read_text()
        body = re.search(r"^api_exec\(\) \{\n(.*?)^\}", text, re.S | re.M).group(1)
        for word in ("mktemp", "-o ", "tee", "> ", ">>"):
            self.assertNotIn(word, re.sub(r"(?m)^\s*#.*$", "", body), word)

    def test_api_exec_keeps_bodies_and_codes_apart(self):
        # Ruling EG: the status is split off curl's stdout, so an error
        # body, an empty body and an unreachable server all stay distinct.
        self.control({"preferences": "409state"})
        r = self.run_qbt("prefs")
        self.assertEqual((r.returncode, r.stdout, r.stderr.strip()), (1, "", "qBittorrent refused it (HTTP 409)"))
        self.control({})
        r = self.run_qbt("prefs", env={"QBT_BASE": "http://127.0.0.1:9"})
        self.assertEqual((r.returncode, r.stderr.strip()), (1, "qBittorrent refused it (couldn't reach qBittorrent)"))
        self.assertEqual(self.run_qbt("pref-set", "dht", "--", "true").returncode, 0)
        r = self.run_qbt("prefs")
        self.assertEqual(json.loads(r.stdout), json.loads(r.stdout.strip()))
        self.assertEqual(r.stdout.count("\n"), 1)

    def test_secret_never_reaches_stdout_or_stderr(self):
        value = "S3CRET-out-" + "z" * 5
        outputs = []
        for key, data, control in (("proxy_password", value, {}), ("proxy_password", value + "\n", {}),
                                   ("proxy_password", value, {"setPreferences": "409secret"}),
                                   ("proxy_password", value, {"preferences": "409state"}),
                                   ("proxy_password", value, {"setPreferences": "noop"})):
            self.control(control)
            r = self.run_stdin(key, data)
            outputs.append(r.stdout + r.stderr)
        self.control({})
        for out in outputs:
            self.assertNotIn(value.encode(), out)
            self.assertNotIn(b"S3CRET", out)


class ValueStdinArgvTest(StdinCase):
    """Marketplace review, 2026-10-02: a setting's value can carry a private
    tracker's passkey (add_trackers, add_trackers_url). The widget sends it
    with `pref-set <key> --value-stdin`, and qbt hands it to jq through the
    environment, so it is on no spawned process's argv (/proc/*/cmdline is
    world readable; /proc/*/environ is owner-only)."""

    make_shims = SecretArgvTest.make_shims

    def argvs(self, log):
        out = []
        for chunk in log.read_bytes().split(b"ARGV\0")[1:]:
            out.append(chunk.split(b"ENV\0", 1)[0].decode("utf-8", "replace"))
        return "\n".join(out)

    def test_a_tracker_list_with_a_passkey_never_reaches_an_argv(self):
        env, log = self.make_shims()
        passkey = "PASSKEYvalue0123456789abcdef"
        trackers = f"https://tracker.example.com/{passkey}/announce\nudp://open.example:1337/announce"
        before = len(self.log())
        r = self.run_stdin("add_trackers", trackers, mode="--value-stdin", env=env)
        self.assertEqual((r.returncode, r.stdout.decode().strip(), r.stderr.decode()), (0, '{"ok":true}', ""))
        posts = self.posts_since(before)
        self.assertEqual(len(posts), 1)
        self.assertEqual(self.sent(posts[0]), {"add_trackers": trackers})
        self.assertEqual(self.state()["add_trackers"], trackers)
        # A second line added to a list that already holds the passkey: the
        # stored list is read back and compared, still off every argv.
        more = trackers + "\nhttps://tracker2.example.com/" + passkey + "/announce"
        r = self.run_stdin("add_trackers", more, mode="--value-stdin", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()["add_trackers"], more)
        url = f"https://lists.example.com/trackers.txt?token={passkey}"
        r = self.run_stdin("add_trackers_url", url, mode="--value-stdin", env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()["add_trackers_url"], url)
        argv = self.argvs(log)
        self.assertIn("jq", argv)
        self.assertIn("curl", argv)
        self.assertNotIn(passkey, argv)

    def test_value_stdin_takes_an_empty_value_and_plain_settings(self):
        r = self.run_stdin("add_trackers", "", mode="--value-stdin")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.state()["add_trackers"], "")
        r = self.run_stdin("dht", "false", mode="--value-stdin")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIs(self.state()["dht"], False)

    def test_value_stdin_keeps_the_password_rules(self):
        r = self.run_stdin("proxy_password", "x", mode="--value-stdin")
        self.assertEqual(r.returncode, 1)
        self.assertIn("--stdin", r.stderr.decode())

    def test_a_value_stdin_that_never_ends_gives_up(self):
        import subprocess
        p = subprocess.Popen([QBT, "pref-set", "add_trackers", "--value-stdin"], env=self.env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        # stdin stays open and silent: wait(), not communicate(), which
        # would close it and send an empty value.
        try:
            p.wait(timeout=25)
        except subprocess.TimeoutExpired:
            p.kill()
            self.fail("pref-set --value-stdin waited forever on an open stdin")
        finally:
            p.stdin.close()
        self.assertEqual(p.returncode, 1)
        self.assertIn(b"usage:", p.stderr.read())
        p.stdout.close()
        p.stderr.close()


if __name__ == "__main__":
    unittest.main()
