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
UTF8_ENV = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
C_ENV = {"LANG": "C", "LC_ALL": "C"}
# Ruling DH: multi-line text is read-only in 4a.
MULTILINE_MESSAGE = "Editing multi-line settings arrives in 4b."

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
        self.assertEqual(set(qbt_array("PREF_LOCKED_VPN")), set(VPN_LOCKS))
        self.assertIn("web_ui_reverse_prox*", mine)  # Ruling DD

    def test_locked_flags_match_the_globs(self):
        import fnmatch
        mine = qbt_array("PREF_LOCKED_VPN") + qbt_array("PREF_LOCKED_WEBUI")
        flagged = {k for k, e in SCHEMA["keys"].items() if e.get("locked")}
        matched = {k for k in SCHEMA["keys"] if any(fnmatch.fnmatchcase(k, g) for g in mine)}
        self.assertEqual(flagged, matched)
        self.assertIn("web_ui_reverse_proxies_list", matched)

    def test_other_refused_equals_schema(self):
        self.assertEqual(qbt_array("PREF_OTHER_REFUSED"), SCHEMA["otherRefusedPatterns"])


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
                     ["pref-set", "dht", "--", "true", "extra"], ["pref-set", "--", "true"]):
            before = len(self.log())
            r = self.run_qbt(*args)
            self.assertEqual((r.returncode, r.stderr.strip()), (1, "usage: qbt pref-set <key> -- <value>"), args)
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
        for key in ("proxy_password", "dyndns_password", "mail_notification_password"):
            r = self.set_refused(key, "hunter3", "OmaqBT doesn't change secrets yet.")
            self.assertNotIn("hunter3", r.stderr)
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
                if SCHEMA["keys"][case["key"]].get("multiline"):
                    # Ruling DH overrides the case's ok for 4a.
                    self.set_refused(case["key"], case["input"], MULTILINE_MESSAGE, env=env)
                elif case["ok"]:
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

    def test_multiline_keys_are_read_only_in_4a(self):
        keys = [k for k, e in SCHEMA["keys"].items()
                if e.get("multiline") and not (e.get("hidden") or e.get("deferred") or e.get("readOnly"))]
        self.assertEqual(sorted(keys), sorted(["excluded_file_names", "add_trackers",
                                               "bypass_auth_subnet_whitelist", "web_ui_custom_http_headers"]))
        for key in keys:
            for value in ("one", "a\nb", ""):
                self.set_refused(key, value, MULTILINE_MESSAGE)

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
        self.set_ok("listen_port", "35763")
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

    def check(self, qbt):
        for key in ("proxy_password", "dyndns_password", "mail_notification_password"):
            self.refused_by(qbt, key, "OmaqBT doesn't change secrets yet.")
        self.refused_by(qbt, "web_ui_api_key", "qBittorrent doesn't let this be changed.")
        for key in ("backup_password_extra", "X_PassWord", "web_ui_password", "password"):
            self.refused_by(qbt, key, "OmaqBT won't change this setting.")

    def test_without_a_schema(self):
        self.check(self.copy_qbt())

    def test_with_a_schema_that_unlocks_them(self):
        schema = json.loads(json.dumps(SCHEMA))
        for key in ("proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key"):
            schema["keys"][key] = {"label": key, "type": "text"}
        schema["keys"]["backup_password_extra"] = {"label": "b", "type": "text"}
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


class SecretArgvTest(PrefsCase):
    """No secret value is ever on the argv of a process qbt spawns: every
    external command qbt runs here is shimmed to log its argv first."""

    def test_no_secret_in_any_argv(self):
        import shutil
        bindir = Path(tempfile.mkdtemp(prefix="qbt-argv-"))
        argv_log = bindir / "argv.log"
        try:
            for tool in ("jq", "curl", "sed", "cat", "mktemp", "rm", "readlink", "dirname", "stat", "id"):
                real = shutil.which(tool)
                if not real:
                    continue
                shim = bindir / tool
                shim.write_text(f"#!/bin/sh\nprintf '%s\\0' \"$@\" >>'{argv_log}'\nexec '{real}' \"$@\"\n")
                shim.chmod(0o755)
            env = {"PATH": f"{bindir}:{os.environ['PATH']}"}
            self.run_qbt("prefs", env=env)
            self.run_qbt("pref-set", "dht", "--", "false", env=env)
            self.run_qbt("pref-set", "future_name", "--", "x", env=env)
            self.control({"setPreferences": "noop"})
            self.run_qbt("pref-set", "future_flag", "--", "true", env=env)
            self.control({})
            logged = argv_log.read_bytes().decode("utf-8", "replace")
            self.assertIn("setPreferences", logged, "the shims really ran")
            for secret in SECRET_VALUES.values():
                self.assertNotIn(secret, logged)
        finally:
            shutil.rmtree(bindir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
