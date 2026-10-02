const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const os = require("node:os");
const { execFileSync } = require("node:child_process");

// The settings schema (slice 4a, Task 1): settings-schema.json is the one
// source that bash `qbt` (through jq) and the window (through the generated
// SettingsSchema.js) both read. These tests hold it to the saved 5.2.3
// preferences dump and to qBittorrent 5.2.3's source.
//
// qBittorrent is GPL and this repo is MIT, so the source isn't vendored.
// The facts the tests need are copied below as plain data, each with its
// file:line. When the source is on disk (QBT_SRC_DIR, default the slice's
// job directory) the "source" tests re-derive those facts from it; without
// it they skip, and the rest still run against the copied facts.

const ROOT = path.join(__dirname, "..");
const SCHEMA_FILE = path.join(ROOT, "settings-schema.json");
const MODULE_FILE = path.join(ROOT, "SettingsSchema.js");
const CASES_FILE = path.join(__dirname, "fixtures", "settings-cases.json");
const DUMP = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "preferences-5.2.3.json"), "utf8"));
const SCHEMA = JSON.parse(fs.readFileSync(SCHEMA_FILE, "utf8"));
const KEYS = SCHEMA.keys;
const GEN = require("../tools/gen-settings-schema.js");

const SRC_DIR = process.env.QBT_SRC_DIR || path.join(os.homedir(), ".claude", "jobs", "6251a6b2", "tmp");
const APPCONTROLLER = path.join(SRC_DIR, "appcontroller.cpp");
const HAVE_SRC = fs.existsSync(APPCONTROLLER);
const SKIP_SRC = HAVE_SRC ? false : `qBittorrent source not found at ${APPCONTROLLER} (set QBT_SRC_DIR)`;

// --- Facts from qBittorrent 5.2.3 --------------------------------------------

// Every key setPreferencesAction (appcontroller.cpp:513) reads with hasKey(),
// plus the four scheduler keys it reads with constFind() (:807-812).
// Note the digits: `grep -o 'hasKey(u"[a-zA-Z_]*"'` misses the eight i2p_*
// keys (:731-746), so the real pattern is [a-zA-Z0-9_]. web_ui_password
// (:916) is write-only: it's never in the GET reply, and OmaqBT doesn't
// edit it (out of scope for slice 4).
const SETTERS = [
  "locale", "status_bar_external_ip", "performance_warning", "confirm_torrent_deletion",
  "file_log_enabled", "file_log_path", "file_log_backup_enabled", "file_log_max_size",
  "file_log_delete_old", "file_log_age", "file_log_age_type", "delete_torrent_content_files",
  "torrent_content_layout", "add_to_top_of_queue", "add_stopped_enabled", "torrent_stop_condition",
  "merge_trackers", "auto_delete_mode", "preallocate_all", "incomplete_files_ext",
  "use_unwanted_folder", "auto_tmm_enabled", "torrent_changed_tmm_enabled",
  "save_path_changed_tmm_enabled", "category_changed_tmm_enabled", "save_path",
  "temp_path_enabled", "temp_path", "use_category_paths_in_manual_mode", "export_dir",
  "export_dir_fin", "scan_dirs", "excluded_file_names_enabled", "excluded_file_names",
  "mail_notification_enabled", "mail_notification_sender", "mail_notification_email",
  "mail_notification_smtp", "mail_notification_ssl_enabled", "mail_notification_auth_enabled",
  "mail_notification_username", "mail_notification_password", "autorun_on_torrent_added_enabled",
  "autorun_on_torrent_added_program", "autorun_enabled", "autorun_program", "random_port",
  "listen_port", "ssl_enabled", "ssl_listen_port", "upnp", "max_connec", "max_connec_per_torrent",
  "max_uploads", "max_uploads_per_torrent", "i2p_enabled", "i2p_address", "i2p_port",
  "i2p_mixed_mode", "i2p_inbound_quantity", "i2p_outbound_quantity", "i2p_inbound_length",
  "i2p_outbound_length", "proxy_type", "proxy_ip", "proxy_port", "proxy_auth_enabled",
  "proxy_username", "proxy_password", "proxy_hostname_lookup", "proxy_bittorrent",
  "proxy_peer_connections", "proxy_rss", "proxy_misc", "ip_filter_enabled", "ip_filter_path",
  "ip_filter_trackers", "banned_IPs", "dl_limit", "up_limit", "alt_dl_limit", "alt_up_limit",
  "bittorrent_protocol", "limit_utp_rate", "limit_tcp_overhead", "limit_lan_peers",
  "scheduler_enabled", "schedule_from_hour", "schedule_from_min", "schedule_to_hour",
  "schedule_to_min", "scheduler_days", "dht", "pex", "lsd", "encryption", "anonymous_mode",
  "max_active_checking_torrents", "queueing_enabled", "max_active_downloads",
  "max_active_torrents", "max_active_uploads", "dont_count_slow_torrents",
  "slow_torrent_dl_rate_threshold", "slow_torrent_ul_rate_threshold", "slow_torrent_inactive_timer",
  "max_ratio_enabled", "max_ratio", "max_seeding_time_enabled", "max_seeding_time",
  "max_inactive_seeding_time_enabled", "max_inactive_seeding_time", "max_ratio_act",
  "add_trackers_enabled", "add_trackers", "add_trackers_from_url_enabled", "add_trackers_url",
  "web_ui_domain_list", "web_ui_address", "web_ui_port", "web_ui_upnp", "use_https",
  "web_ui_https_cert_path", "web_ui_https_key_path", "web_ui_username", "web_ui_password",
  "bypass_local_auth", "bypass_auth_subnet_whitelist_enabled", "bypass_auth_subnet_whitelist",
  "web_ui_max_auth_fail_count", "web_ui_ban_duration", "web_ui_session_timeout",
  "alternative_webui_enabled", "alternative_webui_path", "web_ui_clickjacking_protection_enabled",
  "web_ui_csrf_protection_enabled", "web_ui_secure_cookie_enabled",
  "web_ui_host_header_validation_enabled", "web_ui_use_custom_http_headers_enabled",
  "web_ui_custom_http_headers", "web_ui_reverse_proxy_enabled", "web_ui_reverse_proxies_list",
  "dyndns_enabled", "dyndns_service", "dyndns_username", "dyndns_password", "dyndns_domain",
  "rss_refresh_interval", "rss_fetch_delay", "rss_max_articles_per_feed", "rss_processing_enabled",
  "rss_auto_downloading_enabled", "rss_download_repack_proper_episodes", "rss_smart_episode_filters",
  "resume_data_storage_type", "torrent_content_remove_option", "memory_working_set_limit",
  "current_network_interface", "current_interface_address", "save_resume_data_interval",
  "save_statistics_interval", "torrent_file_size_limit", "confirm_torrent_recheck",
  "recheck_completed_torrents", "app_instance_name", "refresh_interval", "resolve_peer_host_names",
  "resolve_peer_countries", "reannounce_when_address_changed", "embedded_tracker_port",
  "embedded_tracker_port_forwarding", "enable_embedded_tracker", "mark_of_the_web",
  "ignore_ssl_errors", "python_executable_path", "bdecode_depth_limit", "bdecode_token_limit",
  "async_io_threads", "hashing_threads", "file_pool_size", "checking_memory_use", "disk_cache",
  "disk_cache_ttl", "disk_queue_size", "disk_io_type", "disk_io_read_mode", "disk_io_write_mode",
  "enable_coalesce_read_write", "enable_piece_extent_affinity", "enable_upload_suggestions",
  "send_buffer_watermark", "send_buffer_low_watermark", "send_buffer_watermark_factor",
  "connection_speed", "socket_send_buffer_size", "socket_receive_buffer_size", "socket_backlog_size",
  "outgoing_ports_min", "outgoing_ports_max", "upnp_lease_duration", "peer_tos",
  "utp_tcp_mixed_mode", "hostname_cache_ttl", "idn_support_enabled",
  "enable_multi_connections_from_same_ip", "validate_https_tracker_certificate", "ssrf_mitigation",
  "block_peers_on_privileged_ports", "upload_slots_behavior", "upload_choking_algorithm",
  "announce_to_all_trackers", "announce_to_all_tiers", "announce_ip", "announce_port",
  "max_concurrent_http_announces", "stop_tracker_timeout", "peer_turnover", "peer_turnover_cutoff",
  "peer_turnover_interval", "request_queue_size", "dht_bootstrap_nodes"
];

// The dump keys with no setter: GET-only (preferencesAction, :145).
// current_interface_name :393, web_ui_api_key :351 (rotated by its own
// endpoint, :1341), add_trackers_url_list :328 (fetched from the URL).
const READ_ONLY = ["add_trackers_url_list", "current_interface_name", "web_ui_api_key"];
// Keys with a setter that OmaqBT still keeps read-only (eng 4b D9): the
// login-bypass whitelist has no effect while the Web UI only listens on
// 127.0.0.1.
const OMAQBT_READ_ONLY = ["bypass_auth_subnet_whitelist"];

// Each choice key: how appcontroller.cpp's setter converts the value (the
// pattern must match its setter line), and the values that conversion
// accepts, from the enum it names.
// Header citations are qBittorrent release-5.2.3 src/.
const ENUMS = {
  // String enums: Utils::String::toEnum, QMetaEnum key names, case-sensitive.
  torrent_content_layout: { setter: /toEnum\(it\.value\(\)\.toString\(\), BitTorrent::TorrentContentLayout::Original\)/,
    values: ["Original", "Subfolder", "NoSubfolder"] }, // base/bittorrent/torrentcontentlayout.h:45
  torrent_stop_condition: { setter: /toEnum\(it\.value\(\)\.toString\(\), BitTorrent::Torrent::StopCondition::None\)/,
    values: ["None", "MetadataReceived", "FilesChecked"] }, // base/bittorrent/torrent.h:120
  proxy_type: { setter: /toEnum\(it\.value\(\)\.toString\(\), Net::ProxyType::None\)/,
    values: ["None", "HTTP", "SOCKS5", "SOCKS4"] }, // base/net/proxyconfigurationmanager.h:40
  resume_data_storage_type: { setter: /toEnum\(it\.value\(\)\.toString\(\), BitTorrent::ResumeDataStorageType::Legacy\)/,
    values: ["Legacy", "SQLite"] }, // base/bittorrent/session.h:126
  torrent_content_remove_option: { setter: /toEnum\(it\.value\(\)\.toString\(\), BitTorrent::TorrentContentRemoveOption::MoveToTrash\)/,
    values: ["Delete", "MoveToTrash"] }, // base/bittorrent/torrentcontentremoveoption.h:42
  // Int enums: static_cast or plain int.
  auto_delete_mode: { setter: /static_cast<TorrentFileGuard::AutoDeleteMode>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] }, // base/torrentfileguard.h:65 Never, IfAdded, Always
  bittorrent_protocol: { setter: /static_cast<BitTorrent::BTProtocol>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] }, // base/bittorrent/session.h:70 Both, TCP, UTP; sessionimpl.cpp:5053 drops the rest
  scheduler_days: { setter: /static_cast<Scheduler::Days>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] }, // base/preferences.h:47 EveryDay..Sunday
  encryption: { setter: /session->setEncryption\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] }, // sessionimpl.cpp:3778 0 ON (prefer), 1 FORCED, else OFF
  max_ratio_act: { setter: /switch \(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2, 3] }, // appcontroller.cpp:861-878, the switch itself
  dyndns_service: { setter: /static_cast<DNS::Service>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1] }, // base/preferences.h:67 DynDNS, NoIP (None = -1 isn't offered by either UI)
  file_log_age_type: { setter: /setFileLoggerAgeType\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] }, // app/application.cpp:506 out of 0-2 becomes 1; days, months, years
  disk_io_type: { setter: /static_cast<BitTorrent::DiskIOType>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2, 3] }, // base/bittorrent/session.h:92 Default, MMap, Posix, SimplePreadPwrite
  disk_io_read_mode: { setter: /static_cast<BitTorrent::DiskIOReadMode>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1] }, // base/bittorrent/session.h:85
  disk_io_write_mode: { setter: /static_cast<BitTorrent::DiskIOWriteMode>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] }, // base/bittorrent/session.h:101 (WriteThrough with libtorrent 2)
  utp_tcp_mixed_mode: { setter: /static_cast<BitTorrent::MixedModeAlgorithm>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1] }, // base/bittorrent/session.h:111
  upload_slots_behavior: { setter: /static_cast<BitTorrent::ChokingAlgorithm>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1] }, // base/bittorrent/session.h:78
  upload_choking_algorithm: { setter: /static_cast<BitTorrent::SeedChokingAlgorithm>\(it\.value\(\)\.toInt\(\)\)/,
    values: [0, 1, 2] } // base/bittorrent/session.h:118
};

// Keys qBittorrent's own UI labels "(requires restart)":
// gui/advancedsettings.cpp:490, :603, :815, :822 and the WebUI's
// preferences.html:1202, :1457, :1703, :1711.
const RESTART = ["resume_data_storage_type", "disk_io_type", "announce_ip", "announce_port"];

// global.md's locked list (eng D8), which qbt hardcodes.
const LOCKED = [
  "current_network_interface", "current_interface_address", "current_interface_name",
  "web_ui_address", "web_ui_port", "bypass_local_auth", "bypass_auth_subnet_whitelist_enabled", "use_https",
  "web_ui_https_*", "web_ui_host_header_validation_enabled", "web_ui_domain_list",
  "web_ui_reverse_prox*", "alternative_webui_*",
  // eng 4b D8: custom headers go on every Web UI reply unfiltered.
  "web_ui_use_custom_http_headers_enabled", "web_ui_custom_http_headers"
];
const OTHER_REFUSED = ["web_ui_*", "proxy_*", "*interface*", "*password*", "*https*", "autorun*",
  "*token*", "*secret*", "*api_key*"];
const SECRETS = ["proxy_password", "dyndns_password", "mail_notification_password", "web_ui_api_key"];

// The design's confirm list (design D7, eng D8, D10).
const CONFIRMS = {
  dht: [false], pex: [false], lsd: [false],
  encryption: [1],
  anonymous_mode: [true],
  auto_delete_mode: [1, 2],
  max_ratio_act: [1, 3],
  web_ui_upnp: [true],
  listen_port: null,
  upnp: [true],
  proxy_type: null,
  proxy_bittorrent: [true],
  proxy_peer_connections: [true],
  autorun_enabled: [true],
  autorun_program: null,
  autorun_on_torrent_added_enabled: [true],
  autorun_on_torrent_added_program: null,
  dyndns_enabled: [true]
};

const TYPES = ["bool", "int", "float", "speed", "choice-int", "choice-string", "time", "path", "text", "secret"];
const NUMERIC = ["int", "float", "speed"];
const FIELDS = ["section", "group", "label", "help", "type", "unit", "min", "max", "step", "sentinels",
  "choices", "locked", "readOnly", "hidden", "deferred", "multiline", "secret", "restart", "confirm",
  "dependsOn", "composite", "listKind", "tierBreaks", "secretWritable", "confirmVia"];

function glob(key, pattern) {
  const re = new RegExp("^" + pattern.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$");
  return re.test(key);
}

function loadModule() {
  const src = fs.readFileSync(MODULE_FILE, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"], { filename: MODULE_FILE })(mod);
  return mod.exports;
}

const composites = () => Object.keys(KEYS).filter((k) => KEYS[k].composite);
const members = () => new Set(composites().flatMap((k) => [KEYS[k].composite.hour, KEYS[k].composite.min]));

// --- The dump -----------------------------------------------------------------

test("the saved dump is 5.2.3's 223 keys with the secrets blanked", () => {
  assert.equal(Object.keys(DUMP).length, 223);
  for (const k of SECRETS) assert.equal(DUMP[k], "", k);
});

test("prefs-skeleton prints every dump key with its live JSON type", () => {
  const out = JSON.parse(execFileSync("python3", [path.join(ROOT, "tools", "prefs-skeleton.py"),
    path.join(__dirname, "fixtures", "preferences-5.2.3.json")], { encoding: "utf8" }));
  assert.deepEqual(Object.keys(out).sort(), Object.keys(DUMP).sort());
  assert.equal(out.listen_port.json, "int");
  assert.equal(out.max_ratio.json, "int"); // -1 is an int on the wire; the schema knows it's a float
  assert.equal(out.dht.json, "bool");
  assert.equal(out.save_path.json, "string");
  assert.equal(out.scan_dirs.json, "object");
  assert.equal(out.proxy_password.value, undefined, "secrets never printed");
});

// --- Coverage -------------------------------------------------------------------

test("every key in the dump is in the schema", () => {
  const missing = Object.keys(DUMP).filter((k) => !(k in KEYS));
  assert.deepEqual(missing, []);
});

test("every schema key is a dump key, except the composites", () => {
  const extra = Object.keys(KEYS).filter((k) => !(k in DUMP) && !KEYS[k].composite);
  assert.deepEqual(extra, []);
  for (const k of composites()) assert.ok(!(k in DUMP), `${k} must not shadow a real key`);
});

test("entries use only the documented fields and types", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    for (const f of Object.keys(e)) assert.ok(FIELDS.includes(f), `${k}.${f}`);
    assert.ok(TYPES.includes(e.type), `${k}: ${e.type}`);
    assert.equal(typeof e.label, "string", k);
    assert.ok(e.label.length > 0 && e.label.length <= 48, `${k} label length`);
    assert.equal(typeof e.help, "string", k);
    assert.ok(e.help.length > 0 && !e.help.includes("\n"), `${k} help is one line`);
    assert.equal(typeof e.group, "string", k);
    for (const flag of ["locked", "readOnly", "hidden", "deferred", "multiline", "secret", "restart", "tierBreaks", "secretWritable"]) {
      if (flag in e) assert.equal(e[flag], true, `${k}.${flag} is present only as true`);
    }
  }
});

// Slice 5b1 (OV9): six RSS keys are live in their own RSS section (after
// Banned IPs and Other, outside the schema's seven); slice 5b2 un-defers
// rss_auto_downloading_enabled, the one key with confirmVia (D8).
test("sections follow the design; nothing is deferred, and only auto-download confirms via rssAutoDl", () => {
  assert.deepEqual(SCHEMA.sections, ["Downloads", "Connection", "Speed", "BitTorrent", "Behaviour", "Web UI", "Advanced"]);
  const deferred = Object.keys(KEYS).filter((k) => KEYS[k].deferred);
  assert.deepEqual(deferred, []);
  const via = Object.keys(KEYS).filter((k) => "confirmVia" in KEYS[k]);
  assert.deepEqual(via, ["rss_auto_downloading_enabled"]);
  assert.equal(KEYS.rss_auto_downloading_enabled.confirmVia, "rssAutoDl");
  assert.equal(KEYS.rss_auto_downloading_enabled.type, "bool");
  assert.ok(!("confirm" in KEYS.rss_auto_downloading_enabled));
  assert.equal(KEYS.rss_smart_episode_filters.listKind, "pattern");
  for (const [k, e] of Object.entries(KEYS)) {
    if (k.startsWith("rss_")) {
      assert.equal(e.section, "RSS", k);
    } else {
      assert.ok(!e.deferred, k);
      assert.ok(SCHEMA.sections.includes(e.section), `${k}: ${e.section}`);
    }
  }
});

test("hidden keys are exactly the composite members, the derived and deprecated keys, and banned_IPs", () => {
  const hidden = Object.keys(KEYS).filter((k) => KEYS[k].hidden).sort();
  assert.deepEqual(hidden, [
    "banned_IPs", // 4b's list section
    "max_inactive_seeding_time_enabled", "max_ratio_enabled", "max_seeding_time_enabled", // derived: :316-321, :849-860
    "random_port", // deprecated: :237, :705
    "scan_dirs", // deprecated object: :193, :619
    "schedule_from_hour", "schedule_from_min", "schedule_to_hour", "schedule_to_min" // composite members
  ]);
});

// --- Writable set ---------------------------------------------------------------

test("a key is read-only exactly when setPreferences has no setter for it", () => {
  const setters = new Set(SETTERS);
  for (const k of Object.keys(DUMP)) {
    assert.equal(!!KEYS[k].readOnly, !setters.has(k) || OMAQBT_READ_ONLY.includes(k), k);
  }
  assert.deepEqual(Object.keys(KEYS).filter((k) => KEYS[k].readOnly).sort(), [...READ_ONLY, ...OMAQBT_READ_ONLY].sort());
});

test("source: SETTERS is exactly setPreferencesAction's hasKey and constFind keys", { skip: SKIP_SRC }, () => {
  const src = fs.readFileSync(APPCONTROLLER, "utf8");
  const body = src.slice(src.indexOf("void AppController::setPreferencesAction()"), src.indexOf("void AppController::defaultSavePathAction()"));
  const found = new Set();
  for (const m of body.matchAll(/(?:hasKey|constFind)\(u"([a-zA-Z0-9_]+)"/g)) found.add(m[1]);
  assert.deepEqual([...found].sort(), [...SETTERS].sort());
  // And the brief's digit-less grep really does miss the i2p keys.
  const naive = new Set([...body.matchAll(/hasKey\(u"([a-zA-Z_]*)"/g)].map((m) => m[1]));
  assert.ok(!naive.has("i2p_enabled"));
});

test("source: READ_ONLY keys are in the GET reply and nowhere in the setter", { skip: SKIP_SRC }, () => {
  const src = fs.readFileSync(APPCONTROLLER, "utf8");
  const get = src.slice(src.indexOf("void AppController::preferencesAction()"), src.indexOf("void AppController::setPreferencesAction()"));
  const set = src.slice(src.indexOf("void AppController::setPreferencesAction()"), src.indexOf("void AppController::defaultSavePathAction()"));
  for (const k of READ_ONLY) {
    assert.ok(get.includes(`data[u"${k}"_s]`), k);
    assert.ok(!set.includes(`u"${k}"`), k);
  }
});

// --- Types, ranges, choices ---------------------------------------------------

test("every choice key's values are the setter's enum values, and every enum setter is a choice", () => {
  const choiceKeys = Object.keys(KEYS).filter((k) => KEYS[k].type.startsWith("choice-")).sort();
  assert.deepEqual(choiceKeys, Object.keys(ENUMS).sort());
  for (const [k, spec] of Object.entries(ENUMS)) {
    const e = KEYS[k];
    const want = typeof spec.values[0] === "string" ? "choice-string" : "choice-int";
    assert.equal(e.type, want, k);
    // Display order is the UI's (max_ratio_act lists Remove with files, 3,
    // before Super seeding, 2, as qBittorrent's dialog does).
    const sorted = (a) => [...a].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    assert.deepEqual(sorted(e.choices.map((c) => c.value)), sorted(spec.values), k);
    for (const c of e.choices) assert.ok(typeof c.label === "string" && c.label.length > 0, k);
    assert.equal(typeof DUMP[k], want === "choice-string" ? "string" : "number", `${k} live type`);
    assert.ok(spec.values.includes(DUMP[k]), `${k}: live value ${DUMP[k]} is a choice`);
  }
});

test("source: each choice key's setter line converts through the named enum", { skip: SKIP_SRC }, () => {
  const src = fs.readFileSync(APPCONTROLLER, "utf8");
  const lines = src.split("\n");
  for (const [k, spec] of Object.entries(ENUMS)) {
    const at = lines.findIndex((l) => l.includes(`hasKey(u"${k}"_s)`));
    assert.ok(at >= 0, k);
    const block = lines.slice(at, at + 3).join("\n");
    assert.match(block, spec.setter, k);
  }
  // max_ratio_act: the switch's cases are the values.
  const at = src.indexOf('hasKey(u"max_ratio_act"_s)');
  const sw = src.slice(at, src.indexOf("// Add trackers", at));
  const cases = [...sw.matchAll(/case (\d+):/g)].map((m) => Number(m[1]));
  assert.deepEqual(cases, ENUMS.max_ratio_act.values);
});

test("numeric entries carry a sane range, and the live value fits it", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    if (!NUMERIC.includes(e.type)) {
      assert.ok(!("min" in e) && !("max" in e) && !("step" in e), `${k}: range on a ${e.type}`);
      continue;
    }
    if (e.hidden && !members().has(k)) continue; // derived bools etc. aren't numeric
    assert.ok(Number.isFinite(e.min) && Number.isFinite(e.max) && e.min <= e.max, k);
    assert.ok(e.max <= 2147483647, `${k}: qBittorrent reads ints with toInt`);
    if (e.type !== "float") assert.ok(Number.isInteger(e.min) && Number.isInteger(e.max), k);
    const sentinels = Object.keys(e.sentinels || {}).map(Number);
    const v = DUMP[k];
    if (typeof v === "number") assert.ok((v >= e.min && v <= e.max) || sentinels.includes(v), `${k}: live ${v}`);
  }
});

test("speeds are bytes/s whole KiB, capped like 3b's parser", () => {
  const speeds = Object.keys(KEYS).filter((k) => KEYS[k].type === "speed").sort();
  assert.deepEqual(speeds, ["alt_dl_limit", "alt_up_limit", "dl_limit", "up_limit"]);
  for (const k of speeds) {
    const e = KEYS[k];
    assert.equal(e.unit, "B/s");
    assert.equal(e.min, 0);
    assert.equal(e.max, 2146435072); // LimitsView's 2047 MiB/s
    assert.equal(e.step, 1024); // sessionimpl.cpp:3480 stores whole KiB
    assert.deepEqual(e.sentinels, { 0: "unlimited" });
  }
});

test("floats are only the ratio", () => {
  assert.deepEqual(Object.keys(KEYS).filter((k) => KEYS[k].type === "float"), ["max_ratio"]);
});

test("sentinels are labelled values outside the range or the range's special ends", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    if (!e.sentinels) continue;
    for (const [v, label] of Object.entries(e.sentinels)) {
      assert.ok(typeof label === "string" && label.length > 0, `${k} ${v}`);
      if (e.type === "path") assert.equal(v, "", `${k}: a path's only sentinel is empty`);
    }
  }
  assert.deepEqual(KEYS.listen_port.sentinels, { 0: "random" });
  assert.match(KEYS.listen_port.help, /0 = random/); // eng D10
  assert.deepEqual(KEYS.max_connec.sentinels, { "-1": "unlimited" });
  assert.equal(KEYS.max_connec.min, 1); // sessionimpl.cpp:5023 turns 0 into -1
});

test("time composites send hour and minute together", () => {
  assert.deepEqual(composites().sort(), ["schedule_from", "schedule_to"]);
  for (const k of composites()) {
    const e = KEYS[k];
    assert.equal(e.type, "time", k);
    assert.equal(e.section, "Speed");
    for (const part of ["hour", "min"]) {
      const m = KEYS[e.composite[part]];
      assert.ok(m, `${k}.${part}`);
      assert.equal(m.hidden, true);
      assert.equal(m.type, "int");
      assert.equal(m.min, 0);
      assert.equal(m.max, part === "hour" ? 23 : 59);
    }
    assert.deepEqual(e.dependsOn, { key: "scheduler_enabled", value: true });
  }
});

test("dependsOn names a real key and a value it can hold", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    if (!e.dependsOn) continue;
    const d = KEYS[e.dependsOn.key];
    assert.ok(d, `${k} depends on ${e.dependsOn.key}`);
    const vals = Array.isArray(e.dependsOn.value) ? e.dependsOn.value : [e.dependsOn.value];
    if (d.type === "bool") assert.deepEqual(vals, [true], k);
    if (d.choices) for (const v of vals) assert.ok(d.choices.some((c) => c.value === v), `${k}: ${v}`);
  }
  // eng D7: proxy and IP-filter dependents
  for (const k of ["proxy_ip", "proxy_port", "proxy_auth_enabled", "proxy_username", "proxy_password",
    "proxy_hostname_lookup", "proxy_bittorrent", "proxy_peer_connections", "proxy_rss", "proxy_misc"]) {
    assert.deepEqual(KEYS[k].dependsOn, { key: "proxy_type", value: ["HTTP", "SOCKS5", "SOCKS4"] }, k);
  }
  for (const k of ["ip_filter_path", "ip_filter_trackers"]) {
    assert.deepEqual(KEYS[k].dependsOn, { key: "ip_filter_enabled", value: true }, k);
  }
});

test("multiline is the newline-joined lists", () => {
  const ml = Object.keys(KEYS).filter((k) => KEYS[k].multiline).sort();
  assert.deepEqual(ml, ["add_trackers", "add_trackers_url_list", "banned_IPs", "bypass_auth_subnet_whitelist",
    "excluded_file_names", "rss_smart_episode_filters", "web_ui_custom_http_headers"]);
});

// --- Locks, secrets, confirms, restart --------------------------------------------

test("LOCKED and OTHER_REFUSED_PATTERNS are global.md's lists", () => {
  assert.deepEqual(SCHEMA.locked, LOCKED);
  assert.deepEqual(SCHEMA.otherRefusedPatterns, OTHER_REFUSED);
});

test("the locked flags are exactly the keys the LOCKED patterns match", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    const want = !e.composite && LOCKED.some((p) => glob(k, p));
    assert.equal(!!e.locked, want, k);
  }
  const locked = Object.keys(KEYS).filter((k) => KEYS[k].locked);
  assert.ok(locked.includes("web_ui_https_cert_path") && locked.includes("alternative_webui_path"));
  assert.ok(locked.includes("web_ui_reverse_proxies_list"), "Ruling DD");
  for (const k of locked) assert.match(KEYS[k].help, /OmaqBT/, `${k} says why`);
  for (const k of ["current_network_interface", "current_interface_address", "current_interface_name"]) {
    assert.match(KEYS[k].help, /Set by OmaqBT's setup\./, k); // eng D5
  }
});

test("secrets are the four passwords and the API key, and only those", () => {
  const secrets = Object.keys(KEYS).filter((k) => KEYS[k].secret || KEYS[k].type === "secret").sort();
  assert.deepEqual(secrets, [...SECRETS].sort());
  for (const k of SECRETS) {
    assert.equal(KEYS[k].type, "secret");
    assert.equal(KEYS[k].secret, true);
  }
});

test("confirm is set exactly on the design's list, with the consequence first", () => {
  const got = Object.keys(KEYS).filter((k) => KEYS[k].confirm).sort();
  assert.deepEqual(got, Object.keys(CONFIRMS).sort());
  for (const [k, when] of Object.entries(CONFIRMS)) {
    const c = KEYS[k].confirm;
    assert.ok(typeof c.text === "string" && c.text.length > 0 && !c.text.includes("\n"), k);
    if (when === null) assert.ok(!("values" in c), `${k} confirms every change`);
    else assert.deepEqual(c.values, when, k);
  }
  assert.equal(KEYS.dht.confirm.text, "Magnets without trackers will stop finding peers.");
  assert.match(KEYS.pex.confirm.text, /[Ff]ewer peers .*through other peers/);
  assert.match(KEYS.lsd.confirm.text, /local network/);
  assert.match(KEYS.anonymous_mode.confirm.text, /may refuse you/);
  assert.match(KEYS.upnp.confirm.text, /router.*outside the VPN tunnel/);
  assert.match(KEYS.web_ui_upnp.confirm.text, /exposes the Web UI port to the internet through your router/);
  // The confirm names the worst outcome: value 3 deletes files too.
  assert.deepEqual(Object.keys(KEYS.max_ratio_act.confirm.byValue), ["3"]);
  assert.match(KEYS.max_ratio_act.confirm.byValue["3"], /removed with their downloaded files/);
  for (const [k, e] of Object.entries(KEYS)) {
    if (!e.confirm || !e.confirm.byValue) continue;
    for (const v of Object.keys(e.confirm.byValue)) {
      assert.ok(e.confirm.values.map(String).includes(v), `${k}: byValue ${v} is a confirmed value`);
    }
  }
  assert.equal(KEYS.encryption.confirm.text, "Peers that don't encrypt are dropped.");
  assert.match(KEYS.proxy_type.confirm.text, /applies immediately with the current host/);
  assert.match(KEYS.proxy_peer_connections.confirm.text, /sends peer traffic outside the VPN tunnel/);
  assert.match(KEYS.autorun_program.confirm.text, /runs this command after every torrent/);
});

test("restart is tagged only where qBittorrent's UI says 'requires restart'", () => {
  const got = Object.keys(KEYS).filter((k) => KEYS[k].restart).sort();
  assert.deepEqual(got, [...RESTART].sort());
  for (const k of RESTART) assert.match(KEYS[k].help, /restart/i, k);
});

// --- Generated outputs ------------------------------------------------------------

test("SettingsSchema.js is the generator's output for the JSON", () => {
  assert.equal(fs.readFileSync(MODULE_FILE, "utf8"), GEN.renderModule(SCHEMA));
});

test("SettingsSchema.js loads like the other .pragma library modules and exports the schema", () => {
  const src = fs.readFileSync(MODULE_FILE, "utf8");
  assert.match(src.split("\n")[0], /^\.pragma library$/);
  const M = loadModule();
  assert.deepEqual(M.SCHEMA, SCHEMA.keys);
  assert.deepEqual(M.SECTIONS, SCHEMA.sections);
  assert.deepEqual(M.LOCKED, LOCKED);
  assert.deepEqual(M.OTHER_REFUSED_PATTERNS, OTHER_REFUSED);
  assert.deepEqual(M.KEY_ORDER, Object.keys(SCHEMA.keys));
  assert.equal(M.matchesAny("web_ui_https_key_path", M.LOCKED), true);
  assert.equal(M.matchesAny("web_ui_port", M.LOCKED), true);
  assert.equal(M.matchesAny("web_ui_upnp", M.LOCKED), false);
  assert.equal(M.matchesAny("new_proxy_thing", M.OTHER_REFUSED_PATTERNS), false);
  assert.equal(M.matchesAny("proxy_new_thing", M.OTHER_REFUSED_PATTERNS), true);
  assert.equal(M.matchesAny("some_https_flag", M.OTHER_REFUSED_PATTERNS), true);
  assert.equal(M.matchesAny("a.b", ["a*b"]), true, "dots are literal, * is the only wildcard");
  assert.equal(M.matchesAny("axb", ["a.b"]), false);
});

test("settings-cases.json is the generator's output for the JSON", () => {
  const text = fs.readFileSync(CASES_FILE, "utf8");
  assert.equal(text, GEN.renderCases(SCHEMA));
  const cases = JSON.parse(text);
  assert.equal(typeof cases._doc, "string");
});

test("settings-cases covers every editable numeric key's bounds, sentinels and neighbours", () => {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, "utf8"));
  const by = (k) => cases.numbers.filter((c) => c.key === k);
  for (const [k, e] of Object.entries(KEYS)) {
    if (!NUMERIC.includes(e.type) || e.readOnly || e.locked || e.deferred || e.hidden) continue;
    const got = by(k);
    const ok = (input) => got.find((c) => c.input === input);
    assert.equal(ok(String(e.min)).ok, true, `${k} min`);
    assert.equal(ok(String(e.max)).ok, true, `${k} max`);
    for (const s of Object.keys(e.sentinels || {})) assert.equal(ok(String(s)).ok, true, `${k} sentinel ${s}`);
    const below = String(e.type === "float" ? e.min - 0.01 : e.min - 1);
    if (!(below in (e.sentinels || {}))) assert.equal(ok(below).ok, false, `${k} below`);
    const above = String(e.type === "float" ? e.max + 0.01 : e.max + 1);
    assert.equal(ok(above).ok, false, `${k} above`);
  }
  assert.deepEqual(by("listen_port").map((c) => [c.input, c.ok]),
    [["0", true], ["65535", true], ["-1", false], ["65536", false], ["abc", false], ["1.5", false], ["", false]]);
});

test("settings-cases covers every editable choice's values and near misses", () => {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, "utf8"));
  for (const [k, e] of Object.entries(KEYS)) {
    if (!e.choices || e.locked || e.readOnly) continue;
    const got = cases.choices.filter((c) => c.key === k);
    for (const c of e.choices) assert.ok(got.some((g) => g.input === String(c.value) && g.ok), `${k} ${c.value}`);
    assert.ok(got.some((g) => !g.ok), `${k} has a refusal`);
  }
  const ct = cases.choices.filter((c) => c.key === "torrent_content_layout" && !c.ok).map((c) => c.input);
  assert.ok(ct.includes("original"), "string enums are case-sensitive");
});

test("settings-cases covers the times, paths and text fidelity", () => {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, "utf8"));
  const t = (i) => cases.times.find((c) => c.key === "schedule_from" && c.input === i);
  assert.deepEqual(t("08:00"), { key: "schedule_from", input: "08:00", ok: true, hour: 8, min: 0, why: t("08:00").why });
  assert.equal(t("23:59").ok, true);
  assert.equal(t("24:00").ok, false);
  assert.equal(t("12:60").ok, false);
  const p = cases.paths.filter((c) => c.key === "save_path");
  assert.ok(p.some((c) => c.input.startsWith("/") && c.ok));
  assert.ok(p.some((c) => c.input.startsWith("~/") && c.ok));
  assert.ok(p.some((c) => c.input === "relative/dir" && !c.ok));
  assert.ok(p.some((c) => c.input === "" && !c.ok));
  assert.ok(cases.paths.some((c) => c.key === "export_dir" && c.input === "" && c.ok), "sentinel empty path");
  const texts = cases.texts.map((c) => c.input);
  for (const needle of ["&", "+", "%", "\"", "-", "\u{1F98A}"]) {
    assert.ok(texts.some((s) => s.includes(needle)), `a text case with ${needle}`);
  }
  assert.ok(cases.texts.some((c) => c.input.includes("\n") && !c.ok), "a newline in one-line text is refused");
});

test("speed cases are qbt-only argv bytes, and nothing else is qbt-only (Ruling DF)", () => {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, "utf8"));
  for (const group of ["numbers", "choices", "times", "paths", "texts"]) {
    for (const c of cases[group]) {
      const speed = group === "numbers" && KEYS[c.key].type === "speed";
      assert.equal(c.only, speed ? "qbt" : undefined, `${c.key} ${JSON.stringify(c.input)}`);
    }
  }
  assert.ok(cases.numbers.some((c) => c.key === "dl_limit" && c.input === "1536" && !c.ok && c.only === "qbt"));
  assert.match(cases._doc, /bare number as KiB/);
});

test("announce_ip's help says it takes an IP address", () => {
  assert.match(KEYS.announce_ip.help, /must be an IP address/);
});

test("the committed dump carries no real home directory", () => {
  const text = fs.readFileSync(path.join(__dirname, "fixtures", "preferences-5.2.3.json"), "utf8");
  assert.doesNotMatch(text, /\/home\/(?!user\/)/);
  assert.equal(DUMP.save_path, "/home/user/Downloads");
});

// --- Slice 4b contract (Task 1) ------------------------------------------------------

const LIST_RULES_FILE = path.join(__dirname, "fixtures", "list-rules-cases.json");
// Slice 5b1: rss_smart_episode_filters is a pattern list too.
const LIST_KINDS = { banned_IPs: "ip", add_trackers: "trackerUrl", excluded_file_names: "pattern", rss_smart_episode_filters: "pattern" };
const SECRET_WRITABLE = ["proxy_password", "dyndns_password", "mail_notification_password"];
const HEADER_LOCKS = ["web_ui_use_custom_http_headers_enabled", "web_ui_custom_http_headers"];

// The exact messages both lanes show (list-rules-cases.json).
const LIST_MESSAGES = {
  ip: ["Use an IPv4 or IPv6 address."],
  trackerUrl: ["Use an http, https or udp tracker URL."],
  pattern: ["Use a pattern such as *.exe.", "Keep each pattern to one line."],
  secret: ["Type a value, or use --clear.", "Keep it to one line.", "Use a value without NUL characters.",
    "Use at most 1024 characters."]
};

test("4b: listKind is exactly banned_IPs ip, add_trackers trackerUrl, excluded_file_names and rss_smart_episode_filters pattern", () => {
  const got = {};
  for (const [k, e] of Object.entries(KEYS)) if ("listKind" in e) got[k] = e.listKind;
  assert.deepEqual(got, LIST_KINDS);
  for (const k of Object.keys(LIST_KINDS)) {
    // Stored as one newline-joined string: still multiline and text.
    assert.equal(KEYS[k].type, "text", k);
    assert.equal(KEYS[k].multiline, true, k);
    assert.ok(!KEYS[k].readOnly && !KEYS[k].locked && !KEYS[k].deferred, k);
  }
});

test("4b: only add_trackers has tier breaks (blank lines, appcontroller.cpp:883, sessionimpl.cpp:3971)", () => {
  assert.deepEqual(Object.keys(KEYS).filter((k) => KEYS[k].tierBreaks), ["add_trackers"]);
});

test("4b: every multiline key is a list kind or can't be edited (headers and the whitelist lose multi-line editing)", () => {
  for (const [k, e] of Object.entries(KEYS)) {
    if (!e.multiline || e.listKind) continue;
    assert.ok(e.readOnly || e.locked || e.deferred, k);
  }
});

test("4b: secretWritable is exactly the three allowlisted secrets (eng 4b D2/D7)", () => {
  assert.deepEqual(Object.keys(KEYS).filter((k) => KEYS[k].secretWritable).sort(), [...SECRET_WRITABLE].sort());
  for (const k of SECRET_WRITABLE) {
    assert.equal(KEYS[k].type, "secret", k);
    assert.ok(!KEYS[k].readOnly && !KEYS[k].locked, k);
  }
  assert.ok(!KEYS.web_ui_api_key.secretWritable, "the API key stays read-only");
});

test("4b: the custom-header keys are locked, and their help names OmaqBT (eng 4b D8)", () => {
  for (const k of HEADER_LOCKS) {
    assert.equal(KEYS[k].locked, true, k);
    assert.ok(SCHEMA.locked.includes(k), k + " in the top-level locked list");
    assert.match(KEYS[k].help, /OmaqBT/, k);
  }
});

test("4b: the login-bypass whitelist is read-only with the D9 help", () => {
  const e = KEYS.bypass_auth_subnet_whitelist;
  assert.equal(e.readOnly, true);
  assert.equal(e.help, "Has no effect while the Web UI only listens on 127.0.0.1.");
});

test("4b: the schema _doc describes the new fields", () => {
  for (const f of ["listKind", "tierBreaks", "secretWritable"]) assert.match(SCHEMA._doc, new RegExp(f), f);
});

test("4b (Ruling DM): settings-cases has no case for a list key; texts are one-line text", () => {
  const cases = JSON.parse(fs.readFileSync(CASES_FILE, "utf8"));
  for (const group of ["numbers", "choices", "times", "paths", "texts"]) {
    for (const c of cases[group]) {
      assert.ok(!KEYS[c.key].multiline, `${group} ${c.key}: multi-line keys are list kinds (list-rules-cases.json)`);
    }
  }
  assert.ok(cases.texts.length > 0);
  assert.doesNotMatch(cases._doc, /multiline text that must survive/);
});

// --- list-rules-cases.json -----------------------------------------------------------

// A reference for the rules, only to keep the hand-written cases honest;
// qbt (Task 2) and SettingsView (Task 3) each implement them and test
// against the file itself.
function refIPv4(s) {
  const oct = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  return new RegExp("^(" + oct + "\\.){3}" + oct + "$").test(s);
}
function refIPv6(s) {
  const p = s.split("::");
  if (p.length > 2) return false;
  const all = [].concat(...p.map((x) => (x === "" ? [] : x.split(":"))));
  const tail4 = !(all.length === 0 || (p.length === 2 && p[1] === "")) && refIPv4(all[all.length - 1]);
  const hex = tail4 ? all.slice(0, -1) : all;
  const n = hex.length + (tail4 ? 2 : 0);
  return hex.every((h) => /^[0-9A-Fa-f]{1,4}$/.test(h)) && (p.length === 2 ? n <= 7 : n === 8);
}
function refRule(kind, input) {
  const no = (message) => ({ ok: false, message });
  if (kind === "ip") return refIPv4(input) || refIPv6(input) ? { ok: true } : no(LIST_MESSAGES.ip[0]);
  if (kind === "trackerUrl") {
    if (input === "") return { ok: true }; // a tier break
    const good = input.length <= 2048 && /^(http|https|udp):\/\/[!-~]+$/.test(input) && !input.includes("|");
    return good ? { ok: true } : no(LIST_MESSAGES.trackerUrl[0]);
  }
  if (kind === "pattern") {
    if (input === "") return no("Use a pattern such as *.exe.");
    return /[\n\r]/.test(input) ? no("Keep each pattern to one line.") : { ok: true };
  }
  if (kind === "secret") {
    if (input === "") return no("Type a value, or use --clear.");
    if (input.includes("\u0000")) return no("Use a value without NUL characters.");
    if (/[\n\r]/.test(input)) return no("Keep it to one line.");
    return [...input].length <= 1024 ? { ok: true } : no("Use at most 1024 characters.");
  }
  throw new Error("unknown kind " + kind);
}

// server.py's _qt_address (QHostAddress::toString), run as it is.
function qtAddresses(inputs) {
  const prog = [
    "import json, re, sys",
    "src = open(sys.argv[1]).read()",
    "ns = {}",
    "exec(re.search(r'^def _qt_address\\(.*?(?=^\\S)', src, re.S | re.M).group(0), ns)",
    "print(json.dumps([ns['_qt_address'](s) for s in json.load(sys.stdin)]))"
  ].join("\n");
  return JSON.parse(execFileSync("python3", ["-c", prog, path.join(__dirname, "fixtures", "server.py")],
    { input: JSON.stringify(inputs), encoding: "utf8" }));
}

function listRules() {
  return JSON.parse(fs.readFileSync(LIST_RULES_FILE, "utf8"));
}

test("list-rules: the documented shape", () => {
  const f = listRules();
  assert.deepEqual(Object.keys(f), ["_doc", "cases", "lists"]);
  for (const word of ["kind", "input", "ok", "normalised", "message", "why", "lists", "QHostAddress", "tier"]) {
    assert.ok(f._doc.includes(word), "_doc mentions " + word);
  }
  for (const c of f.cases) {
    const label = c.kind + " " + JSON.stringify(c.input);
    assert.deepEqual(Object.keys(c), c.ok ? ["kind", "input", "ok", "normalised", "why"] : ["kind", "input", "ok", "message", "why"], label);
    assert.ok(Object.keys(LIST_MESSAGES).includes(c.kind), label);
    assert.equal(typeof c.input, "string", label);
    assert.ok(typeof c.why === "string" && c.why.length > 0, label);
    if (!c.ok) assert.ok(LIST_MESSAGES[c.kind].includes(c.message), label + ": " + c.message);
  }
  for (const l of f.lists) {
    assert.deepEqual(Object.keys(l), ["key", "kind", "input", "normalised", "why"], l.why);
    assert.equal(LIST_KINDS[l.key], l.kind, l.why);
  }
});

test("list-rules: every case follows the rules, and every message is used", () => {
  const used = new Set();
  for (const c of listRules().cases) {
    const want = refRule(c.kind, c.input);
    assert.equal(c.ok, want.ok, c.kind + " " + JSON.stringify(c.input) + " (" + c.why + ")");
    if (!c.ok) {
      assert.equal(c.message, want.message, c.why);
      used.add(c.message);
    }
  }
  for (const msgs of Object.values(LIST_MESSAGES)) for (const m of msgs) assert.ok(used.has(m), "a case shows " + m);
});

test("list-rules: an ok case's normalised is what qBittorrent keeps (IPs through QHostAddress, the rest unchanged)", () => {
  const cases = listRules().cases.filter((c) => c.ok);
  const ips = cases.filter((c) => c.kind === "ip");
  const qt = qtAddresses(ips.map((c) => c.input));
  ips.forEach((c, i) => assert.equal(c.normalised, qt[i], c.input));
  for (const c of cases.filter((x) => x.kind !== "ip")) assert.equal(c.normalised, c.input, c.kind + " " + c.why);
});

test("list-rules: the cases cover what the brief asks for", () => {
  const cases = listRules().cases;
  const has = (kind, pred, what) => assert.ok(cases.some((c) => c.kind === kind && pred(c)), kind + ": " + what);
  has("ip", (c) => c.ok && refIPv4(c.input), "IPv4");
  has("ip", (c) => c.ok && c.input.includes(":") && c.normalised !== c.input, "IPv6 that normalises");
  has("ip", (c) => c.ok && /[A-F]/.test(c.input), "mixed case");
  has("ip", (c) => !c.ok && c.input !== c.input.trim(), "surrounding spaces");
  has("ip", (c) => !c.ok && c.input === "", "empty");
  for (const scheme of ["http://", "https://", "udp://"]) has("trackerUrl", (c) => c.ok && c.input.startsWith(scheme), scheme);
  has("trackerUrl", (c) => !c.ok && c.input.startsWith("wss://"), "wss is not offered");
  has("trackerUrl", (c) => !c.ok && c.input.includes(" "), "a space");
  has("trackerUrl", (c) => !c.ok && c.input.includes("\n"), "a newline");
  has("trackerUrl", (c) => c.ok && c.input === "", "empty is a tier break");
  has("trackerUrl", (c) => !c.ok && c.input.includes("next tier"), "the tier-break marker, typed");
  has("pattern", (c) => c.ok && c.input.includes("\u{1F98A}"), "non-BMP fidelity");
  has("pattern", (c) => !c.ok && c.input.includes("\n"), "a newline");
  has("secret", (c) => !c.ok && c.input === "", "empty");
  has("secret", (c) => !c.ok && c.input.includes("\u0000"), "NUL");
  has("secret", (c) => !c.ok && c.input.includes("\n"), "newline");
  has("secret", (c) => c.ok && [...c.input].length === 1024 && c.input.length === 2048, "1024 non-BMP characters (code points, not UTF-16 units)");
  has("secret", (c) => !c.ok && [...c.input].length === 1025, "one past the cap");
  has("secret", (c) => c.ok && /[^\x00-\x7f]/.test(c.input), "non-ASCII");
  has("secret", (c) => c.ok && c.input !== c.input.trim(), "surrounding spaces kept (IFS= read)");
  has("secret", (c) => c.ok && c.input.includes("\\"), "a backslash kept (read -r)");
});

test("list-rules: whole-list values round-trip as 5.2.3 stores them", () => {
  const lists = listRules().lists;
  for (const l of lists.filter((x) => x.kind !== "ip")) {
    // add_trackers is raw text (appcontroller.cpp:883); excluded_file_names
    // is split on \n keeping empty entries and joined back (:670, :203).
    assert.equal(l.normalised, l.input, l.why);
  }
  // banned_IPs (sessionimpl.cpp:4167): skip empty parts (appcontroller.cpp:783),
  // drop invalid, QHostAddress form, QStringList::sort (code units), dedupe.
  const ipLists = lists.filter((x) => x.kind === "ip");
  for (const l of ipLists) {
    const parts = l.input.split("\n").filter((s) => s !== "");
    const qt = qtAddresses(parts).filter((s) => s !== "");
    const want = [...new Set(qt)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).join("\n");
    assert.equal(l.normalised, want, l.why);
  }
  const by = (key, pred, what) => assert.ok(lists.some((l) => l.key === key && pred(l)), key + ": " + what);
  by("add_trackers", (l) => (l.input.match(/\n\n/g) || []).length >= 2, "three tiers");
  by("add_trackers", (l) => l.input.includes("\n\n\n"), "a double blank line");
  by("excluded_file_names", (l) => l.input.includes("\n\n"), "an empty entry");
  by("excluded_file_names", (l) => l.input.endsWith("\n"), "a trailing empty entry");
  by("banned_IPs", (l) => l.normalised !== l.input && l.input.split("\n").length > l.normalised.split("\n").length, "de-duplicated");
  by("banned_IPs", (l) => /^10\./.test(l.normalised) && l.normalised.includes("\n9."), "sorted as strings");
  by("banned_IPs", (l) => /[A-F]/.test(l.input) && !/[A-F]/.test(l.normalised), "lowercase IPv6");
});
