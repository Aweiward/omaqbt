const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// SettingsView.js, SettingsSchema.js and LimitsView.js start with QML-only
// `.pragma library` / `.import` lines, which node can't parse. Strip them and
// run each file as a function body (tests/client-view.test.js's loader);
// SettingsView gets its two imports as the Schema and Limits parameters.
function load(name, params, args) {
  const file = path.join(__dirname, "..", name);
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"].concat(params), { filename: file })(mod, ...args);
  return mod.exports;
}

const Schema = load("SettingsSchema.js", [], []);
const Limits = load("LimitsView.js", [], []);
const V = load("SettingsView.js", ["Schema", "Limits"], [Schema, Limits]);

const DUMP = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "preferences-5.2.3.json"), "utf8"));
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "settings-cases.json"), "utf8"));
const TEXT_RULES_CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "text-rules-cases.json"), "utf8"));
const SECRETS = ["proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key"];

// `qbt prefs` output: the dump with each secret replaced by {set: bool}.
function prefs(overrides) {
  const p = JSON.parse(JSON.stringify(DUMP));
  for (const k of SECRETS) p[k] = { set: false };
  return Object.assign(p, overrides || {});
}

const rowOf = (key, p) => {
  for (const s of Schema.SECTIONS.concat(["Other"])) {
    const r = V.rows(s, p || prefs()).find((x) => x.key === key);
    if (r) return r;
  }
  return null;
};

// --- sections ----------------------------------------------------------------

test("sections: the seven in order with T1's counts, then a dimmed RSS; no Other when every key is mapped", () => {
  const s = V.sections(prefs());
  assert.deepEqual(s.map((x) => [x.name, x.count]), [
    ["Downloads", 33], ["Connection", 27], ["Speed", 11], ["BitTorrent", 23],
    ["Behaviour", 12], ["Web UI", 30], ["Advanced", 72], ["RSS", 0]
  ]);
  assert.equal(s[7].label, "RSS · slice 5");
  assert.equal(s[7].dimmed, true);
  assert.equal(s[0].label, "Downloads");
  assert.equal(s[0].dimmed, false);
});

test("sections: Other appears before RSS when prefs hold an unknown key", () => {
  const s = V.sections(prefs({ brand_new_toggle: true, other_number: 5 }));
  assert.deepEqual(s.slice(7).map((x) => [x.name, x.count]), [["Other", 2], ["RSS", 0]]);
});

test("sections: while loading (no prefs) the counts come from the schema", () => {
  const s = V.sections(null);
  assert.equal(s.find((x) => x.name === "Speed").count, 11);
  assert.equal(s.some((x) => x.name === "Other"), false);
});

test("sections: a key the loaded prefs lack isn't counted or shown", () => {
  const p = prefs();
  delete p.listen_port;
  assert.equal(V.sections(p).find((x) => x.name === "Connection").count, 26);
  assert.equal(rowOf("listen_port", p), null);
  delete p.schedule_from_min;
  assert.equal(rowOf("schedule_from", p), null);
});

// --- rows --------------------------------------------------------------------

test("rows: flat, in KEY_ORDER, groups in first-appearance order; no hidden or deferred keys", () => {
  const r = V.rows("Speed", prefs());
  assert.deepEqual(r.map((x) => x.key), [
    "dl_limit", "up_limit", "alt_dl_limit", "alt_up_limit", "scheduler_enabled",
    "schedule_from", "schedule_to", "scheduler_days", "limit_utp_rate", "limit_tcp_overhead", "limit_lan_peers"
  ]);
  assert.deepEqual([...new Set(r.map((x) => x.group))], ["Global limits", "Alternative limits", "Scheduler", "Rate limit settings"]);
  assert.equal(r[0].section, "Speed");
  assert.equal(r[0].help, Schema.SCHEMA.dl_limit.help);
  for (const s of Schema.SECTIONS) {
    for (const x of V.rows(s, prefs())) {
      const e = Schema.SCHEMA[x.key];
      assert.ok(!e.hidden && !e.deferred, x.key);
      assert.ok(!/^rss_/.test(x.key) && x.key !== "banned_IPs", x.key);
    }
  }
  assert.deepEqual(V.rows("Nope", prefs()), []);
});

test("rows: the row shape", () => {
  const r = rowOf("listen_port");
  assert.deepEqual(Object.keys(r).sort(), [
    "dimmed", "dimmedReason", "group", "help", "key", "label", "locked", "muted", "readOnly",
    "restart", "secret", "section", "text", "typeTag", "value"
  ]);
  assert.equal(r.value, "35763");
  assert.equal(r.text, "35763");
  assert.equal(r.typeTag, "number");
  assert.equal(r.muted, false);
  assert.equal(r.locked, false);
  assert.equal(r.dimmed, false);
  assert.equal(r.dimmedReason, "");
});

test("rows: type tags per type", () => {
  const tags = {
    dht: "on/off", listen_port: "number", max_ratio: "number", dl_limit: "speed",
    encryption: "choice", proxy_type: "choice", schedule_from: "time", save_path: "path",
    locale: "text", proxy_password: "secret", web_ui_port: "OmaqBT",
    current_interface_name: "OmaqBT", add_trackers_url_list: "read-only", web_ui_api_key: "secret"
  };
  for (const k of Object.keys(tags)) assert.equal(rowOf(k).typeTag, tags[k], k);
});

test("rows: the design's dimmed dependents, exactly", () => {
  const from = rowOf("schedule_from");
  assert.equal(from.value, "08:00");
  assert.equal(from.dimmed, true);
  assert.equal(from.dimmedReason, "schedule off");
  assert.equal(from.text, "08:00 (schedule off)");
  assert.equal(from.muted, true);
  assert.equal(rowOf("schedule_to").text, "20:00 (schedule off)");
  const ip = rowOf("proxy_ip");
  assert.equal(ip.dimmedReason, "set the proxy type first");
  assert.equal(ip.text, "(set the proxy type first)");
  assert.equal(rowOf("proxy_port").text, "8080 (set the proxy type first)".replace("8080", String(DUMP.proxy_port)));
  assert.equal(rowOf("ip_filter_trackers").dimmedReason, "IP filtering off");
});

test("rows: a met dependency isn't dimmed; proxy dependents wake for any proxy type", () => {
  const on = rowOf("schedule_from", prefs({ scheduler_enabled: true }));
  assert.equal(on.dimmed, false);
  assert.equal(on.text, "08:00");
  for (const t of ["HTTP", "SOCKS5", "SOCKS4"]) assert.equal(rowOf("proxy_ip", prefs({ proxy_type: t })).dimmed, false);
});

test("rows: dependency chains dim on the nearest unmet ancestor", () => {
  // file_log_age -> file_log_delete_old (true) -> file_log_enabled
  assert.equal(rowOf("file_log_age").dimmed, false);
  const off = rowOf("file_log_age", prefs({ file_log_enabled: false }));
  assert.equal(off.dimmed, true);
  assert.equal(off.dimmedReason, "file log off");
  assert.equal(rowOf("file_log_age", prefs({ file_log_delete_old: false })).dimmedReason, "deleting old logs off");
  // a dependency the prefs lack doesn't dim
  const p = prefs();
  delete p.scheduler_enabled;
  assert.equal(rowOf("schedule_from", p).dimmed, false);
});

test("rows: every dependsOn key has a reason", () => {
  const p = prefs();
  for (const k of Schema.KEY_ORDER) {
    const d = Schema.SCHEMA[k].dependsOn;
    if (!d) continue;
    const reason = V.dependencyReason(d.key);
    assert.ok(reason.length > 0 && reason.length <= 30, d.key + ": " + reason);
  }
  void p;
});

test("rows: locked rows say OmaqBT, are muted, and keep the schema's help", () => {
  const r = rowOf("current_network_interface");
  assert.equal(r.locked, true);
  assert.equal(r.typeTag, "OmaqBT");
  assert.equal(r.muted, true);
  assert.equal(r.value, "wg0-mullvad");
  assert.match(r.help, /Set by OmaqBT's setup\.$/);
  const proxies = rowOf("web_ui_reverse_proxies_list");
  assert.equal(proxies.typeTag, "OmaqBT");
  assert.equal(proxies.help, Schema.SCHEMA.web_ui_reverse_proxies_list.help);
  for (const k of Schema.KEY_ORDER) {
    if (Schema.SCHEMA[k].locked && k in DUMP) assert.equal(rowOf(k).typeTag, "OmaqBT", k);
  }
});

test("rows: secrets read set / not set and never their value", () => {
  assert.equal(rowOf("proxy_password").value, "not set");
  assert.equal(rowOf("proxy_password", prefs({ proxy_password: { set: true } })).value, "set");
  assert.equal(rowOf("proxy_password", prefs({ proxy_password: { set: true } })).secret, true);
  // a raw value in a secret slot (qbt didn't redact) still never shows
  const leaked = rowOf("dyndns_password", prefs({ dyndns_password: "hunter2" }));
  assert.equal(leaked.value, "set");
  assert.ok(!leaked.text.includes("hunter2"));
  assert.equal(rowOf("dyndns_password", prefs({ dyndns_password: "" })).value, "not set");
});

test("rows: read-only and restart flags", () => {
  assert.equal(rowOf("add_trackers_url_list").readOnly, true);
  assert.equal(rowOf("disk_io_type").restart, true);
  assert.equal(rowOf("locale").restart, false);
});

test("rows: loading shows — everywhere", () => {
  const r = V.rows("Speed", null);
  assert.equal(r.length, 11);
  for (const x of r) {
    assert.equal(x.value, "—");
    assert.equal(x.text, "—");
    assert.equal(x.dimmed, false);
  }
  assert.equal(V.rows("Other", null).length, 0);
});

test("rows: sentinels and unlimited speeds are muted; empty text reads empty", () => {
  assert.equal(rowOf("dl_limit").value, "unlimited");
  assert.equal(rowOf("dl_limit").muted, true);
  assert.equal(rowOf("alt_dl_limit").value, "10 KiB/s");
  assert.equal(rowOf("alt_dl_limit").muted, false);
  assert.equal(rowOf("max_ratio").value, "none");
  assert.equal(rowOf("max_ratio").muted, true);
  assert.equal(rowOf("export_dir").value, "off");
  assert.equal(rowOf("app_instance_name", prefs({ app_instance_name: "" })).value, "empty");
  assert.equal(rowOf("app_instance_name", prefs({ app_instance_name: "" })).muted, true);
});

// --- otherRows ---------------------------------------------------------------

test("otherRows: unknown scalar keys, sorted, editable by JSON type", () => {
  const p = prefs({ zeta_flag: true, alpha_count: 3, mid_name: "x" });
  const o = V.otherRows(p);
  assert.deepEqual(o.map((x) => x.key), ["alpha_count", "mid_name", "zeta_flag"]);
  assert.deepEqual(o.map((x) => x.typeTag), ["number", "text", "on/off"]);
  assert.equal(o[0].label, "alpha_count");
  assert.equal(o[0].section, "Other");
  assert.equal(o[0].group, "Other");
  assert.equal(o[0].help, V.OTHER_HELP);
  assert.equal(o[2].value, "on");
  assert.deepEqual(V.rows("Other", p), o);
});

test("otherRows: never refused patterns, rss_*, banned_IPs, secrets, multiline, objects or known keys", () => {
  const p = prefs({
    web_ui_new: 1, proxy_new: 1, new_interface_x: "a", smtp_password2: "a", new_https_x: true, autorun_x: "a",
    rss_new: true, banned_IPs: "1.2.3.4", new_secret: { set: true }, new_obj: {}, new_list: [1], new_null: null,
    new_multi: "a\nb", ok_key: 1
  });
  assert.deepEqual(V.otherRows(p).map((x) => x.key), ["ok_key"]);
  assert.deepEqual(V.otherRows(prefs()), []);
  assert.deepEqual(V.otherRows(null), []);
});

// --- search ------------------------------------------------------------------

test("search: label, help and raw key, with each result's section", () => {
  const r = V.search("port", prefs());
  const keys = r.rows.map((x) => x.key);
  assert.ok(keys.includes("listen_port"));
  assert.ok(keys.includes("web_ui_port"));
  assert.equal(r.message, "");
  assert.equal(r.rows.find((x) => x.key === "web_ui_port").section, "Web UI");
  assert.equal(r.rows.find((x) => x.key === "web_ui_port").typeTag, "OmaqBT");
  // raw key
  assert.deepEqual(V.search("max_connec_per", prefs()).rows.map((x) => x.key), ["max_connec_per_torrent"]);
  // help text only ("tunnel" is in the VPN help)
  assert.ok(V.search("tunnel", prefs()).rows.some((x) => x.key === "current_network_interface"));
  // case-insensitive, every word must match
  assert.ok(V.search("INCOMING   port", prefs()).rows.some((x) => x.key === "listen_port"));
  assert.ok(!V.search("incoming nowhere", prefs()).rows.length);
});

test("search: composites show, their hidden members, rss and banned IPs never do", () => {
  const r = V.search("schedule", prefs()).rows.map((x) => x.key);
  assert.ok(r.includes("schedule_from") && r.includes("schedule_to"));
  assert.ok(!r.some((k) => /_(hour|min)$/.test(k)));
  assert.deepEqual(V.search("rss", prefs()).rows.filter((x) => /^rss_/.test(x.key)), []);
  assert.ok(!V.search("banned", prefs()).rows.some((x) => x.key === "banned_IPs"));
  assert.ok(!V.search("banned_IPs", prefs()).rows.length);
});

test("search: Other rows by raw key; no match; empty query", () => {
  assert.deepEqual(V.search("zzz_new", prefs({ zzz_new: 1 })).rows.map((x) => [x.key, x.section]), [["zzz_new", "Other"]]);
  assert.deepEqual(V.search("xyz", prefs()), { rows: [], message: "No setting matches \"xyz\". Esc clears." });
  assert.deepEqual(V.search("  ", prefs()), { rows: [], message: "" });
  assert.deepEqual(V.search("", prefs()), { rows: [], message: "" });
  assert.equal(V.noMatch("  a b "), "No setting matches \"a b\". Esc clears.");
});

// --- editorFor ---------------------------------------------------------------

test("editorFor: toggle, with the next value", () => {
  assert.deepEqual(V.editorFor("dht", prefs()), { kind: "toggle", key: "Space", next: false });
  assert.deepEqual(V.editorFor("dht", prefs({ dht: false })), { kind: "toggle", key: "Space", next: true });
});

test("editorFor: input with a prefill per type", () => {
  const e = (k, o) => V.editorFor(k, prefs(o));
  assert.deepEqual(e("listen_port"), { kind: "input", key: "Enter", prefill: "35763" });
  assert.equal(e("dl_limit").prefill, "u");
  assert.equal(e("alt_dl_limit").prefill, "10K");
  assert.equal(e("alt_dl_limit", { alt_dl_limit: 2097152 }).prefill, "2M");
  assert.equal(e("max_ratio").prefill, "-1");
  assert.equal(e("max_ratio", { max_ratio: 1.5 }).prefill, "1.5");
  assert.equal(e("schedule_from", { scheduler_enabled: true }).prefill, "08:00");
  assert.equal(e("save_path").prefill, "/home/user/Downloads");
  assert.equal(e("locale").prefill, "en_US");
});

test("editorFor: picker with choices and the current value marked", () => {
  const e = V.editorFor("encryption", prefs());
  assert.equal(e.kind, "picker");
  assert.equal(e.key, "Enter");
  assert.deepEqual(e.choices, [
    { value: 0, label: "Prefer", current: true },
    { value: 1, label: "Require", current: false },
    { value: 2, label: "Disable", current: false }
  ]);
  assert.equal(V.editorFor("proxy_type", prefs()).choices.find((c) => c.current).value, "None");
});

test("editorFor: none for locked, read-only, secret, dimmed, loading and unknown keys", () => {
  const why = (k, p) => V.editorFor(k, p === undefined ? prefs() : p);
  assert.deepEqual(why("web_ui_port"), { kind: "none", why: "locked" });
  assert.deepEqual(why("current_interface_name"), { kind: "none", why: "locked" });
  assert.deepEqual(why("add_trackers_url_list"), { kind: "none", why: "readOnly" });
  assert.deepEqual(why("proxy_password", prefs({ proxy_type: "HTTP" })), { kind: "none", why: "secret" });
  assert.deepEqual(why("web_ui_api_key"), { kind: "none", why: "secret" });
  assert.deepEqual(why("schedule_from"), { kind: "none", why: "dimmed" });
  assert.deepEqual(why("dht", null), { kind: "none", why: "loading" });
  assert.deepEqual(why("schedule_from_hour"), { kind: "none", why: "hidden" });
  assert.deepEqual(why("banned_IPs"), { kind: "none", why: "hidden" });
  assert.deepEqual(why("rss_processing_enabled"), { kind: "none", why: "hidden" });
  assert.deepEqual(why("no_such_key"), { kind: "none", why: "unknown" });
  assert.deepEqual(why("web_ui_new", prefs({ web_ui_new: 1 })), { kind: "none", why: "unknown" });
  const p = prefs();
  delete p.listen_port;
  assert.deepEqual(why("listen_port", p), { kind: "none", why: "unknown" });
});

test("editorFor: Other keys by JSON type", () => {
  const p = prefs({ new_flag: false, new_num: 2.5, new_text: "hi" });
  assert.deepEqual(V.editorFor("new_flag", p), { kind: "toggle", key: "Space", next: true });
  assert.deepEqual(V.editorFor("new_num", p), { kind: "input", key: "Enter", prefill: "2.5" });
  assert.deepEqual(V.editorFor("new_text", p), { kind: "input", key: "Enter", prefill: "hi" });
});

// --- parseInput --------------------------------------------------------------

test("parseInput: every window case in settings-cases.json", () => {
  let n = 0;
  let multi = 0;
  for (const group of ["numbers", "choices", "times", "paths", "texts"]) {
    for (const c of CASES[group]) {
      if (c.only === "qbt") continue;
      n++;
      const r = V.parseInput(c.key, c.input, prefs());
      const label = group + " " + c.key + " " + JSON.stringify(c.input) + " (" + c.why + ")";
      // Ruling DH: multiline keys are read-only in 4a, whatever the input.
      if (Schema.SCHEMA[c.key].multiline) {
        assert.deepEqual(r, { error: V.CANT_CHANGE }, label);
        multi++;
        continue;
      }
      if (!c.ok) {
        assert.equal(typeof r.error, "string", label);
        assert.ok(r.error.length > 0, label);
        assert.ok(!("value" in r), label);
        continue;
      }
      assert.ok(!("error" in r), label + ": " + r.error);
      if (group === "numbers") assert.equal(r.value, Number(c.input), label);
      else if (group === "choices") assert.equal(r.value, typeof Schema.SCHEMA[c.key].choices[0].value === "number" ? Number(c.input) : c.input, label);
      else if (group === "times") {
        assert.equal(r.value, c.input, label);
        assert.equal(r.hour, c.hour, label);
        assert.equal(r.min, c.min, label);
      } else assert.equal(r.value, c.input, label);
    }
  }
  assert.ok(n > 400, "window cases: " + n);
  assert.ok(multi >= 9, "multiline cases: " + multi);
});

test("parseInput: the number messages name the range and the sentinels", () => {
  const err = (k, t) => V.parseInput(k, t, prefs()).error;
  assert.equal(err("listen_port", "65536"), "Use a port from 1 to 65535, or 0 for random.");
  assert.equal(err("proxy_port", "0"), "Use a port from 1 to 65535.");
  assert.equal(err("outgoing_ports_min", "x"), "Use a port from 1 to 65535, or 0 for any.");
  assert.equal(err("max_connec", "0"), "Use a number from 1 to 2147483647, or -1 for unlimited.");
  assert.equal(err("disk_cache", "-2"), "Use a number from 1 to 33554431, -1 for auto or 0 for off.");
  assert.equal(err("peer_turnover_interval", "29"), "Use a number from 30 to 3600.");
  assert.equal(err("max_ratio", "9998.01"), "Use a number from 0 to 9998, or -1 for none.");
  assert.equal(err("max_ratio", "1.555"), "Use at most 2 decimals.");
  assert.equal(err("listen_port", " 80"), "Use a port from 1 to 65535, or 0 for random.");
  assert.equal(err("listen_port", "080"), "Use a port from 1 to 65535, or 0 for random.");
  assert.equal(err("listen_port", "1e3"), "Use a port from 1 to 65535, or 0 for random.");
  assert.equal(err("max_connec", "-0"), "Use a number from 1 to 2147483647, or -1 for unlimited.");
});

test("parseInput: speeds use LimitsView and round to the nearest whole KiB (halves up, never down to 0)", () => {
  const v = (t) => V.parseInput("up_limit", t, prefs());
  assert.deepEqual(v("u"), { value: 0 });
  assert.deepEqual(v("0"), { value: 0 });
  assert.deepEqual(v("0M"), { value: 0 });
  assert.deepEqual(v("10"), { value: 10240 });
  assert.deepEqual(v("2M"), { value: 2097152 });
  assert.deepEqual(v("1.5K"), { value: 2048 });
  assert.deepEqual(v("1.4K"), { value: 1024 });
  assert.deepEqual(v("0.4K"), { value: 1024 });
  assert.deepEqual(v("0.01K"), { value: 1024 });
  assert.deepEqual(v("1.5M"), { value: 1572864 });
  assert.deepEqual(v("2047M"), { value: 2146435072 });
  assert.deepEqual(v("2047.01M"), { error: Limits.SPEED_CAP_ERROR });
  assert.deepEqual(v("abc"), { error: Limits.SPEED_ERROR });
  assert.deepEqual(v("1.555K"), { error: "Use at most 2 decimals." });
  assert.deepEqual(v(""), { error: Limits.SPEED_ERROR });
  for (const t of ["u", "10", "1.5K", "0.4K", "2047M", "3.33M"]) assert.equal(v(t).value % 1024, 0, t);
});

test("parseInput: KiB/s-unit ints are plain numbers, not speeds", () => {
  assert.deepEqual(V.parseInput("slow_torrent_dl_rate_threshold", "2", prefs()), { value: 2 });
  assert.ok(V.parseInput("slow_torrent_dl_rate_threshold", "2K", prefs()).error);
});

test("parseInput: time, path, text and choice messages", () => {
  const err = (k, t) => V.parseInput(k, t, prefs()).error;
  assert.equal(err("schedule_from", "8:00"), "Use a time like 08:00, as HH:MM.");
  assert.equal(err("save_path", "rel"), "Use an absolute path, or one starting with ~/.");
  assert.equal(err("save_path", ""), "Use an absolute path, or one starting with ~/.");
  assert.equal(err("save_path", "/a\nb"), "Use one line.");
  assert.equal(err("locale", "a\nb"), "Use one line.");
  assert.equal(err("locale", "a\rb"), "Use one line.");
  assert.deepEqual(V.parseInput("locale", "", prefs()), { value: "" });
  assert.deepEqual(V.parseInput("locale", "  x ", prefs()), { value: "  x " });
  assert.equal(err("encryption", "3"), "Choose one of the listed values.");
  assert.equal(err("proxy_type", "http"), "Choose one of the listed values.");
});

test("parseInput: bools, Other keys by JSON type, and refused keys", () => {
  const p = prefs({ new_flag: false, new_num: 2, new_text: "a" });
  assert.deepEqual(V.parseInput("dht", "false", p), { value: false });
  assert.deepEqual(V.parseInput("dht", "true", p), { value: true });
  assert.equal(V.parseInput("dht", "yes", p).error, "Use true or false.");
  assert.deepEqual(V.parseInput("new_flag", "true", p), { value: true });
  assert.deepEqual(V.parseInput("new_num", "-3", p), { value: -3 });
  assert.deepEqual(V.parseInput("new_num", "0", p), { value: 0 });
  assert.equal(V.parseInput("new_num", "3x", p).error, "Use a whole number.");
  // Ruling DL: an integer's Other key refuses decimals and "-0"
  assert.equal(V.parseInput("new_num", "-3.25", p).error, "Use a whole number.");
  assert.equal(V.parseInput("new_num", "-0", p).error, "Use a whole number.");
  assert.equal(V.WHOLE_NUMBER_ERROR, "Use a whole number.");
  const f = prefs({ new_ratio: 2.5 });
  assert.deepEqual(V.parseInput("new_ratio", "-3.25", f), { value: -3.25 });
  assert.equal(V.parseInput("new_ratio", "3x", f).error, "Use a number.");
  assert.deepEqual(V.parseInput("new_text", "b c", p), { value: "b c" });
  assert.equal(V.parseInput("new_text", "b\nc", p).error, "Use one line.");
  for (const k of ["web_ui_port", "current_network_interface", "add_trackers_url_list", "proxy_password", "schedule_from_hour", "banned_IPs", "rss_refresh_interval", "nope"]) {
    assert.equal(V.parseInput(k, "1", p).error, V.CANT_CHANGE, k);
  }
  assert.equal(V.parseInput("web_ui_new", "1", prefs({ web_ui_new: 1 })).error, V.CANT_CHANGE);
  // Ruling DL: refused patterns match case-insensitively
  for (const k of ["Web_UI_New", "PROXY_x", "My_Interface", "smtp_Password", "use_HTTPS2", "AutoRun_x"]) {
    const q = prefs({ [k]: 1 });
    assert.equal(V.parseInput(k, "1", q).error, V.CANT_CHANGE, k);
    assert.deepEqual(V.editorFor(k, q), { kind: "none", why: "unknown" }, k);
    assert.deepEqual(V.otherRows(q), [], k);
  }
  assert.equal(V.CANT_CHANGE, "This setting can't be changed here.");
});

// --- confirmFor --------------------------------------------------------------

test("confirmFor: every schema confirm fires on its values and only there", () => {
  for (const k of Schema.KEY_ORDER) {
    const c = Schema.SCHEMA[k].confirm;
    if (!c || !c.values) continue;
    for (const v of c.values) {
      const expected = c.byValue && c.byValue[String(v)] ? c.byValue[String(v)] : c.text;
      assert.equal(V.confirmFor(k, "whatever", v), expected, k + " " + v);
    }
  }
});

test("confirmFor: the D7 and D8 list", () => {
  assert.equal(V.confirmFor("dht", true, false), "Magnets without trackers will stop finding peers.");
  assert.equal(V.confirmFor("dht", false, true), "");
  assert.equal(V.confirmFor("pex", true, false), "Fewer peers will be found through other peers.");
  assert.equal(V.confirmFor("lsd", true, false), "No peers will be found on your local network.");
  assert.equal(V.confirmFor("encryption", 0, 1), "Peers that don't encrypt are dropped.");
  assert.equal(V.confirmFor("encryption", 1, 2), "");
  assert.match(V.confirmFor("anonymous_mode", false, true), /stop identifying itself/);
  assert.equal(V.confirmFor("anonymous_mode", true, false), "");
  assert.equal(V.confirmFor("auto_delete_mode", 0, 1), "The .torrent files you add are deleted from disk.");
  assert.equal(V.confirmFor("auto_delete_mode", 0, 2), "The .torrent files you add are deleted from disk.");
  assert.equal(V.confirmFor("auto_delete_mode", 1, 0), "");
  assert.equal(V.confirmFor("max_ratio_act", 0, 1), "Torrents that reach their share limit will be removed.");
  assert.equal(V.confirmFor("max_ratio_act", 0, 3), "Torrents that reach their share limit will be removed with their downloaded files.");
  assert.equal(V.confirmFor("max_ratio_act", 3, 2), "");
  assert.match(V.confirmFor("web_ui_upnp", false, true), /exposes the Web UI port/);
  assert.equal(V.confirmFor("web_ui_upnp", true, false), "");
  assert.equal(V.confirmFor("upnp", false, true), "This maps ports on your router, outside the VPN tunnel.");
  assert.equal(V.confirmFor("upnp", true, false), "");
  assert.match(V.confirmFor("listen_port", 35763, 51414), /new port/);
  assert.match(V.confirmFor("listen_port", 35763, 0), /new port/);
  assert.match(V.confirmFor("proxy_bittorrent", false, true), /outside the VPN tunnel/);
  assert.match(V.confirmFor("proxy_peer_connections", false, true), /outside the VPN tunnel/);
  assert.equal(V.confirmFor("proxy_bittorrent", true, false), "");
  assert.match(V.confirmFor("proxy_type", "None", "SOCKS5"), /applies immediately with the current host/);
  assert.match(V.confirmFor("autorun_enabled", false, true), /after every torrent finishes/);
  assert.match(V.confirmFor("autorun_on_torrent_added_enabled", false, true), /every time a torrent is added/);
  assert.match(V.confirmFor("autorun_program", "", "notify-send done"), /runs this command/);
  assert.match(V.confirmFor("autorun_on_torrent_added_program", "", "x"), /runs this command/);
  assert.match(V.confirmFor("dyndns_enabled", false, true), /publishes your IP/);
});

test("confirmFor: values compare as strings; no confirm for an unchanged value, other keys or Other", () => {
  assert.equal(V.confirmFor("encryption", 0, "1"), "Peers that don't encrypt are dropped.");
  assert.equal(V.confirmFor("dht", true, "false"), "Magnets without trackers will stop finding peers.");
  assert.equal(V.confirmFor("listen_port", 51414, 51414), "");
  assert.equal(V.confirmFor("listen_port", 51414, "51414"), "");
  assert.equal(V.confirmFor("autorun_program", "x", " x "), "");
  assert.equal(V.confirmFor("locale", "en", "de"), "");
  assert.equal(V.confirmFor("new_key", 1, 2), "");
});

// --- formatValue / doneNote ----------------------------------------------------

test("formatValue: per type", () => {
  const f = V.formatValue;
  assert.equal(f("dl_limit", 0), "unlimited");
  assert.equal(f("dl_limit", 2097152), "2 MiB/s");
  assert.equal(f("dht", true), "on");
  assert.equal(f("dht", false), "off");
  assert.equal(f("listen_port", 0), "random");
  assert.equal(f("max_connec", -1), "unlimited");
  assert.equal(f("disk_cache", -1), "auto");
  assert.equal(f("disk_cache", 0), "off");
  assert.equal(f("disk_cache", 64), "64 MiB");
  assert.equal(f("peer_turnover", 4), "4%");
  assert.equal(f("max_seeding_time", 90), "90 min");
  assert.equal(f("max_ratio", 1.5), "1.5");
  assert.equal(f("encryption", 1), "Require");
  assert.equal(f("encryption", 9), "9");
  assert.equal(f("proxy_type", "SOCKS5"), "SOCKS5");
  assert.equal(f("torrent_content_layout", "NoSubfolder"), "Don't create subfolder");
  assert.equal(f("schedule_from", "09:15"), "09:15");
  assert.equal(f("export_dir", ""), "off");
  assert.equal(f("save_path", "/x"), "/x");
  assert.equal(f("locale", ""), "empty");
  assert.equal(f("excluded_file_names", "a\nb\nc"), "a (+2 more)");
  assert.equal(f("proxy_password", { set: true }), "set");
  assert.equal(f("proxy_password", { set: false }), "not set");
  assert.equal(f("proxy_password", "leak"), "set");
  assert.equal(f("listen_port", undefined), "—");
  assert.equal(f("listen_port", null), "—");
  assert.equal(f("unknown_key", true), "on");
  assert.equal(f("unknown_key", 5), "5");
  assert.equal(f("unknown_key", "s"), "s");
});

test("doneNote: label set to value; bools on/off; restart keys; no undo", () => {
  assert.equal(V.doneNote("listen_port", 51414), "Port for incoming connections set to 51414");
  assert.equal(V.doneNote("dl_limit", 2048), "Download limit set to 2 KiB/s");
  assert.equal(V.doneNote("dl_limit", 0), "Download limit set to unlimited");
  assert.equal(V.doneNote("dht", false), "DHT off");
  assert.equal(V.doneNote("dht", true), "DHT on");
  assert.equal(V.doneNote("schedule_from", "09:15"), "From set to 09:15");
  assert.equal(V.doneNote("encryption", 1), "Encryption set to Require");
  assert.equal(V.doneNote("disk_io_type", 1), "Disk I/O type set to Memory-mapped files · applies after qBittorrent restarts");
  assert.ok(V.doneNote("announce_ip", "1.2.3.4").endsWith(" · applies after qBittorrent restarts"));
  assert.equal(V.doneNote("new_key", 3), "new_key set to 3");
  assert.equal(V.doneNote("new_flag", true), "new_flag on");
  assert.ok(!V.doneNote("listen_port", 1).includes("undo"));
  assert.equal(V.RESTART_NOTE, " · applies after qBittorrent restarts");
});

// --- equalValue ----------------------------------------------------------------

test("equalValue: trimmed strings, numeric numbers, paths without a trailing slash", () => {
  const e = V.equalValue;
  assert.equal(e("locale", " en ", "en"), true);
  assert.equal(e("locale", "en", "de"), false);
  assert.equal(e("listen_port", "51414", 51414), true);
  assert.equal(e("listen_port", 1, 2), false);
  assert.equal(e("max_ratio", "1.50", 1.5), true);
  assert.equal(e("dl_limit", 1024, "1024"), true);
  assert.equal(e("encryption", "1", 1), true);
  assert.equal(e("listen_port", "", 0), false);
  assert.equal(e("listen_port", "abc", "abc"), false);
  assert.equal(e("save_path", "/a/b/", "/a/b"), true);
  assert.equal(e("save_path", "/a/b//", " /a/b"), true);
  assert.equal(e("save_path", "/", "/"), true);
  assert.equal(e("save_path", "/a", "/b"), false);
  assert.equal(e("dht", true, true), true);
  assert.equal(e("dht", true, "true"), true);
  assert.equal(e("dht", true, false), false);
  assert.equal(e("proxy_type", "HTTP", " HTTP"), true);
  assert.equal(e("schedule_from", "08:00", "08:00"), true);
  assert.equal(e("schedule_from", "08:00", "09:00"), false);
  assert.equal(e("proxy_password", { set: true }, { set: true }), false);
  // Other keys by the JSON type of a
  assert.equal(e("new_num", 2, "2.0"), true);
  assert.equal(e("new_flag", false, "false"), true);
  assert.equal(e("new_text", "a ", "a"), true);
});

// --- purity -----------------------------------------------------------------------

test("SettingsView.js: .pragma library and imports only the schema and LimitsView", () => {
  const src = fs.readFileSync(path.join(__dirname, "..", "SettingsView.js"), "utf8");
  const lines = src.split("\n");
  assert.equal(lines[0], ".pragma library");
  const imports = lines.filter((l) => /^\s*\.import\b/.test(l));
  assert.deepEqual(imports, ['.import "SettingsSchema.js" as Schema', '.import "LimitsView.js" as Limits']);
  assert.ok(!/\brequire\(|\bQt\.|XMLHttpRequest|Date\b/.test(src.replace(/\/\/.*$/gm, "")));
});

// --- rowFor / currentValue ----------------------------------------------------------

test("currentValue: composites as HH:MM, plain keys as they are, undefined when missing or loading", () => {
  assert.equal(V.currentValue("schedule_from", prefs({ schedule_from_hour: 9, schedule_from_min: 5 })), "09:05");
  assert.equal(V.currentValue("listen_port", prefs()), 35763);
  assert.equal(V.currentValue("listen_port", null), undefined);
  assert.equal(V.currentValue("nope", prefs()), undefined);
  assert.equal(V.currentValue("schedule_from", prefs({ schedule_from_hour: "9" })), undefined);
});

test("rowFor: one schema or Other row; null for hidden, missing or unknown keys", () => {
  assert.deepEqual(V.rowFor("listen_port", prefs()), rowOf("listen_port"));
  assert.equal(V.rowFor("new_k", prefs({ new_k: 1 })).section, "Other");
  assert.equal(V.rowFor("schedule_from_hour", prefs()), null);
  assert.equal(V.rowFor("rss_refresh_interval", prefs()), null);
  assert.equal(V.rowFor("nope", prefs()), null);
  assert.equal(V.rowFor("dht", null).value, "—");
});

test("dependencyReason: the fallbacks for keys outside the map", () => {
  assert.equal(V.dependencyReason("dht"), "dht off");
  assert.equal(V.dependencyReason("locale"), "set the language first".replace("language", Schema.SCHEMA.locale.label.toLowerCase()));
  assert.equal(V.dependencyReason("nope"), "set nope first");
});

test("rows: a locked row is never dimmed; the lock is its reason", () => {
  const r = rowOf("web_ui_reverse_proxies_list", prefs({ web_ui_reverse_proxy_enabled: false }));
  assert.equal(r.dimmed, false);
  assert.equal(r.dimmedReason, "");
  assert.equal(r.text, r.value);
  assert.equal(r.typeTag, "OmaqBT");
  assert.equal(r.muted, true);
});

// --- Ruling DH: multiline keys are read-only in 4a -------------------------------------

const MULTI = ["excluded_file_names", "add_trackers", "bypass_auth_subnet_whitelist", "web_ui_custom_http_headers"];

test("multiline: exactly the four editable-in-4b keys are the schema's multiline, non-hidden, non-deferred, writable keys", () => {
  const found = Schema.KEY_ORDER.filter((k) => {
    const e = Schema.SCHEMA[k];
    return e.multiline && !e.hidden && !e.deferred && !e.readOnly;
  });
  assert.deepEqual(found.sort(), MULTI.slice().sort());
});

test("multiline: rows say multi-line and read-only, with the 4b note after the schema help", () => {
  const on = prefs({
    excluded_file_names_enabled: true, add_trackers_enabled: true,
    bypass_auth_subnet_whitelist_enabled: true, web_ui_use_custom_http_headers_enabled: true
  });
  for (const k of MULTI) {
    const r = rowOf(k, on);
    assert.equal(r.typeTag, "multi-line", k);
    assert.equal(r.readOnly, true, k);
    assert.equal(r.help, Schema.SCHEMA[k].help + " Editing multi-line settings arrives in 4b.", k);
    assert.deepEqual(V.editorFor(k, on), { kind: "none", why: "multiline" }, k);
    // before the dimmed check
    assert.deepEqual(V.editorFor(k, prefs()), { kind: "none", why: "multiline" }, k);
    assert.deepEqual(V.parseInput(k, "x", on), { error: V.CANT_CHANGE }, k);
  }
  assert.equal(V.MULTILINE_NOTE, " Editing multi-line settings arrives in 4b.");
  assert.equal(rowOf("bypass_auth_subnet_whitelist", on).value, "127.0.0.1/32 (+1 more)");
});

test("multiline: add_trackers_url_list keeps its permanent read-only tag and help", () => {
  const r = rowOf("add_trackers_url_list");
  assert.equal(r.typeTag, "read-only");
  assert.equal(r.readOnly, true);
  assert.equal(r.help, Schema.SCHEMA.add_trackers_url_list.help);
  assert.deepEqual(V.editorFor("add_trackers_url_list", prefs()), { kind: "none", why: "readOnly" });
});

test("multiline: section counts are unchanged", () => {
  assert.deepEqual(V.sections(prefs()).slice(0, 7).map((x) => x.count), [33, 27, 11, 23, 12, 30, 72]);
});

// --- Final fix wave (Ruling DU) --------------------------------------------------------

test("secret rows: the help says editing secrets arrives in 4b; the API key keeps its own text", () => {
  for (const k of ["proxy_password", "dyndns_password", "mail_notification_password"]) {
    const r = V.rowFor(k, prefs());
    assert.equal(r.help, Schema.SCHEMA[k].help + " Editing secrets arrives in 4b.", k);
  }
  assert.equal(V.SECRET_NOTE, " Editing secrets arrives in 4b.");
  assert.equal(V.rowFor("web_ui_api_key", prefs()).help, Schema.SCHEMA.web_ui_api_key.help);
});

test("parseInput (DQ): a path must be clean, without //, /./, /../ or a trailing /. or /..", () => {
  const msg = "Use a clean path without //, /./ or /../.";
  assert.equal(V.CLEAN_PATH_ERROR, msg);
  for (const bad of ["/srv//dl", "//srv", "/srv/./dl", "/srv/../dl", "/srv/.", "/srv/..", "~/a//b", "~/./a", "~/..", "/."]) {
    assert.deepEqual(V.parseInput("save_path", bad), { error: msg }, bad);
  }
  for (const ok of ["/srv/dl", "/srv/dl/", "/srv/.hidden", "/srv/..x", "/srv/x.", "~/Downloads", "/", "/a/b..c/d"]) {
    assert.deepEqual(V.parseInput("save_path", ok), { value: ok }, ok);
  }
  // A relative path still gets the absolute-path message first.
  assert.deepEqual(V.parseInput("save_path", "a//b"), { error: V.PATH_ERROR });
  // The sentinel "" stays a sentinel.
  assert.deepEqual(V.parseInput("python_executable_path", ""), { value: "" });
});

test("parseInput (DR): announce_ip takes an IPv4 or IPv6 address, or nothing", () => {
  const msg = "Use an IPv4 or IPv6 address, or leave it empty.";
  assert.equal(V.IP_ERROR, msg);
  for (const ok of ["", "10.0.0.1", "0.0.0.0", "255.255.255.255", "::", "::1", "2001:db8::1",
    "2001:DB8:0:0:0:0:0:1", "fe80::1:2:3:4", "::ffff:10.0.0.1", "1:2:3:4:5:6:7:8", "1::", "1:2:3:4:5:6::8", "::2:3:4:5:6:7:8"]) {
    assert.deepEqual(V.parseInput("announce_ip", ok), { value: ok }, JSON.stringify(ok));
  }
  // Never trimmed: qbt validates the raw argv, so surrounding whitespace is refused,
  // not silently accepted-and-sent-untrimmed (Ruling DV parity follow-up).
  for (const bad of ["example.com", "10.0.0", "10.0.0.256", "10.0.0.1.2", "010.0.0.1", "1.2.3.-4", "1:2:3:4:5:6:7:8:9", "1::2::3",
    "12345::", "::g", "fe80::1%eth0", "[::1]", ":1:2:3:4:5:6:7", "1:2:3:4:5:6:7:", "1:2:3:4:5:6:7::8", "::ffff:10.0.0", " ", "10.0.0.1/24",
    " 10.0.0.1", "10.0.0.1 "]) {
    assert.deepEqual(V.parseInput("announce_ip", bad), { error: msg }, JSON.stringify(bad));
  }
  assert.deepEqual(V.parseInput("announce_ip", "10.0.0.1\n"), { error: V.LINE_ERROR });
});

test("parseInput (DS): the Web UI username needs 3 characters and no colon", () => {
  const msg = "Use at least 3 characters and no colon.";
  assert.equal(V.USERNAME_ERROR, msg);
  for (const bad of ["", "ab", "a:b", "admin:", ":admin"]) {
    assert.deepEqual(V.parseInput("web_ui_username", bad), { error: msg }, bad);
  }
  for (const ok of ["abc", "admin", "ünï", "a b"]) assert.deepEqual(V.parseInput("web_ui_username", ok), { value: ok }, ok);
  assert.deepEqual(V.parseInput("web_ui_username", "abc\n"), { error: V.LINE_ERROR });
});

// Ruling DV (parity follow-up): one shared case file for announce_ip,
// web_ui_username and path cleanliness, with qbt as the source of truth.
// tests/test_prefs.py runs the same file against the real qbt.
test("parseInput: every case in text-rules-cases.json matches qbt", () => {
  let n = 0;
  for (const c of TEXT_RULES_CASES.cases) {
    n++;
    const label = c.key + " " + JSON.stringify(c.input) + " (" + c.why + ")";
    const r = V.parseInput(c.key, c.input);
    if (c.ok) assert.deepEqual(r, { value: c.input }, label);
    else assert.deepEqual(r, { error: c.message }, label);
  }
  assert.equal(n, TEXT_RULES_CASES.cases.length);
});

test("Other: future_token, secret and api_key names never show or edit (Ruling DV)", () => {
  const p = prefs({ future_token: "x", my_app_secret: "y", zz_api_key: "z" });
  const keys = V.otherRows(p).map((r) => r.key);
  for (const k of ["future_token", "my_app_secret", "zz_api_key"]) {
    assert.ok(!keys.includes(k), k + " is refused");
    assert.deepEqual(V.parseInput(k, "1", p), { error: V.CANT_CHANGE }, k);
  }
});

test("Other: a key matching a lock is refused, whatever its case", () => {
  const p = prefs({ web_ui_https_zz: true, alternative_webui_zz: "x", BYPASS_LOCAL_AUTH: true, bypass_local_auth_zz: 1, Use_Https: false });
  const keys = V.otherRows(p).map((r) => r.key);
  for (const k of ["web_ui_https_zz", "alternative_webui_zz", "BYPASS_LOCAL_AUTH", "Use_Https"]) {
    assert.ok(!keys.includes(k), k + " is locked");
    assert.deepEqual(V.parseInput(k, "1", p), { error: V.CANT_CHANGE }, k);
    assert.equal(V.editorFor(k, p).kind, "none", k);
  }
  assert.ok(keys.includes("bypass_local_auth_zz"), "only an exact lock match is refused");
});

test("Other numbers: qbt's limits, no exponents, at most 10 integer digits and 6 decimals", () => {
  const p = prefs({ zz_count: 7, zz_ratio: 1.5 });
  for (const bad of ["1e5", "1E5", "0x10", "Infinity", "NaN", "12345678901", "1.0", "-0", "+1", " 1", "01"]) {
    assert.deepEqual(V.parseInput("zz_count", bad, p), { error: V.WHOLE_NUMBER_ERROR }, bad);
  }
  for (const ok of ["0", "1234567890", "-1234567890", "-1"]) assert.deepEqual(V.parseInput("zz_count", ok, p), { value: Number(ok) }, ok);
  for (const bad of ["1e5", "1.5e2", "1E-3", "Infinity", "12345678901", "12345678901.5", "0.1234567", "-0", "-0.0", "-0.000", ".5", "5.", "01.5"]) {
    assert.deepEqual(V.parseInput("zz_ratio", bad, p), { error: V.NUMBER_ERROR }, bad);
  }
  for (const ok of ["0", "1234567890", "1234567890.123456", "-0.5", "0.000001", "-3", "2.25"]) {
    assert.deepEqual(V.parseInput("zz_ratio", ok, p), { value: Number(ok) }, ok);
  }
});
