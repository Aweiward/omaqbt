.pragma library
.import "SettingsSchema.js" as Schema
.import "LimitsView.js" as Limits

// Pure rules for the Settings view (slice 4a): sections and their counts,
// the rows of a section, dimmed dependents, the Other section, search, the
// editor for a key, input parsing, the risky-change confirms, the done notes,
// value formatting and the per-type equality. No I/O, no Qt objects:
// everything comes in through arguments, so tests/settings-view.test.js runs
// it in node. It imports only SettingsSchema.js (the generated schema) and
// LimitsView.js (3b's speed parser and formatter).
//
// The `.pragma library` and `.import` lines above are QML-only. The node test
// strips them and passes the two modules in as Schema and Limits.
//
// prefs is `qbt prefs` output: qBittorrent's preferences object with each
// secret replaced by {set: bool}. null or undefined means "still loading":
// every row shows "—" and nothing is editable. Once prefs are loaded, a
// schema key they lack (an older qBittorrent) isn't shown.
//
// Secrets show "set"/"not set" and never a value. Slice 4b (Task 3): the
// three secretWritable secrets edit through a masked field (editorFor kind
// "secret"; parseListLine("secret", ...) checks it); a dimmed one doesn't
// (Ruling EB). rss_* never show; banned_IPs is its own section (a list).
// The list keys (the schema's listKind: add_trackers, excluded_file_names,
// banned_IPs) are edited a line at a time in the list editor: listItems
// splits a value, listWithAdded / listWithout build the new value so every
// untouched line round-trips exactly, parseListLine checks a typed line
// (tests/fixtures/list-rules-cases.json's rules and messages). The other
// multiline keys (the login-bypass whitelist, the custom headers) are
// read-only or locked and show their first line plus " (+N more)".
//
// Speeds (Ruling DE): qBittorrent keeps global limits in whole KiB, so a
// parsed speed on a step-1024 key is rounded to the NEAREST whole KiB,
// halves up ("1.5K" -> 2 KiB), and a non-zero speed never rounds down to 0
// (which would mean unlimited): "0.4K" -> 1 KiB. "u" and "0" stay 0.

var SCHEMA = Schema.SCHEMA;
var KEY_ORDER = Schema.KEY_ORDER;
var SECTIONS = Schema.SECTIONS;

// --- User-visible strings -----------------------------------------------------

var LOADING = "—";
var EMPTY = "empty";
var CANT_CHANGE = "This setting can't be changed here.";
var OTHER = "Other";
var OTHER_HELP = "A setting OmaqBT doesn't know yet, shown by its raw name.";
var RSS_LABEL = "RSS · slice 5";
var RESTART_NOTE = " · applies after qBittorrent restarts";
var TIME_ERROR = "Use a time like 08:00, as HH:MM.";
var PATH_ERROR = "Use an absolute path, or one starting with ~/.";
var LINE_ERROR = "Use one line.";
var CHOICE_ERROR = "Choose one of the listed values.";
var BOOL_ERROR = "Use true or false.";
var NUMBER_ERROR = "Use a number.";
var WHOLE_NUMBER_ERROR = "Use a whole number.";
// Slice 4b: the list editor and the secret field (list-rules-cases.json's
// messages, exactly: qbt refuses the same lines with the same sentences).
var LIST_ERRORS = {
  ip: "Use an IPv4 or IPv6 address.",
  trackerUrl: "Use an http, https or udp tracker URL.",
  patternEmpty: "Use a pattern such as *.exe.",
  patternLine: "Keep each pattern to one line.",
  secretEmpty: "Type a value, or use --clear.",
  secretLine: "Keep it to one line.",
  secretNul: "Use a value without NUL characters.",
  secretLong: "Use at most 1024 characters."
};
var SECRET_MAX = 1024;
var TRACKER_URL_MAX = 2048;
var BANNED = "Banned IPs";
var BAN_KEY = "banned_IPs";
var TIER_BREAK_TEXT = "— next tier —";
var EMPTY_LINE_TEXT = "(empty line)";
var LIST_EMPTY = {
  banned_IPs: "No banned IPs. Ban a peer with b on the Peers tab, or a to add one here.",
  add_trackers: "No trackers to add. Press a to add a tracker URL.",
  excluded_file_names: "No excluded file names. Press a to add a pattern such as *.exe."
};
var LIST_PROMPTS = {
  banned_IPs: "Ban an IP address",
  add_trackers: "Add a tracker URL (empty: next tier)",
  excluded_file_names: "Add a file name pattern"
};
// What a secret is called in its confirm and done note (the schema's
// labels are short: dyndns_password's is "Password").
var SECRET_NAMES = {
  proxy_password: "proxy password",
  dyndns_password: "dynamic DNS password",
  mail_notification_password: "SMTP password"
};
// qbt's own rules for three kinds of value (Rulings DQ, DR, DS), refused
// here first with the same sentences.
var CLEAN_PATH_ERROR = "Use a clean path without //, /./ or /../.";
var IP_ERROR = "Use an IPv4 or IPv6 address, or leave it empty.";
var USERNAME_ERROR = "Use at least 3 characters and no colon.";

var TYPE_TAGS = {
  bool: "on/off",
  int: "number",
  float: "number",
  speed: "speed",
  "choice-int": "choice",
  "choice-string": "choice",
  time: "time",
  path: "path",
  text: "text",
  secret: "secret"
};

// The dimmed reason for each key a setting depends on: "08:00 (schedule off)".
var DEPENDENCY_REASONS = {
  scheduler_enabled: "schedule off",
  proxy_type: "set the proxy type first",
  ip_filter_enabled: "IP filtering off",
  temp_path_enabled: "incomplete folder off",
  excluded_file_names_enabled: "exclusions off",
  mail_notification_enabled: "email off",
  mail_notification_auth_enabled: "SMTP login off",
  autorun_enabled: "program off",
  autorun_on_torrent_added_enabled: "program off",
  ssl_enabled: "SSL off",
  i2p_enabled: "I2P off",
  queueing_enabled: "queueing off",
  dont_count_slow_torrents: "slow-torrent rule off",
  add_trackers_enabled: "adding trackers off",
  add_trackers_from_url_enabled: "URL trackers off",
  file_log_enabled: "file log off",
  file_log_backup_enabled: "log backups off",
  file_log_delete_old: "deleting old logs off",
  bypass_auth_subnet_whitelist_enabled: "subnet skip off",
  web_ui_use_custom_http_headers_enabled: "custom headers off",
  web_ui_reverse_proxy_enabled: "reverse proxy off",
  dyndns_enabled: "dynamic DNS off",
  enable_embedded_tracker: "tracker off"
};

// --- Small helpers (private) ---------------------------------------------------

function hasOwn(obj, key) {
  return !!obj && typeof obj === "object" && Object.prototype.hasOwnProperty.call(obj, key);
}

function entryOf(key) {
  return hasOwn(SCHEMA, key) ? SCHEMA[key] : null;
}

function loaded(prefs) {
  return !!prefs && typeof prefs === "object" && !Array.isArray(prefs);
}

function textOf(text) {
  return text === null || text === undefined ? "" : String(text);
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n;
}

function isVisible(entry) {
  return !!entry && !entry.hidden && !entry.deferred;
}

// Whether loaded prefs hold the key (a composite: both of its members).
function present(key, entry, prefs) {
  if (entry && entry.composite) return hasOwn(prefs, entry.composite.hour) && hasOwn(prefs, entry.composite.min);
  return hasOwn(prefs, key);
}

function secretIsSet(value) {
  if (value && typeof value === "object") return value.set === true;
  return typeof value === "string" ? value !== "" : false;
}

function toBool(v) {
  if (v === true || v === "true") return true;
  if (v === false || v === "false") return false;
  return undefined;
}

function toNumber(v) {
  if (typeof v === "number") return isFinite(v) ? v : undefined;
  if (typeof v !== "string") return undefined;
  var s = v.trim();
  if (s === "") return undefined;
  var n = Number(s);
  return isFinite(n) ? n : undefined;
}

function normPath(v) {
  var s = textOf(v).trim();
  while (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.slice(0, -1);
  return s;
}

function isSentinel(entry, value) {
  return !!entry && !!entry.sentinels && value !== undefined && value !== null && hasOwn(entry.sentinels, String(value));
}

// A key Other may show and edit: in prefs, unknown to the schema, not
// banned_IPs or rss_*, not matching a refused pattern (case-insensitively,
// as qbt does: Ruling DL), and a scalar value (a string on one line).
function isOtherKey(key, prefs) {
  if (!loaded(prefs) || !hasOwn(prefs, key) || hasOwn(SCHEMA, key)) return false;
  if (key === "banned_IPs" || key.indexOf("rss_") === 0) return false;
  // qbt refuses the locks before it reads the schema; any case (Ruling DL).
  if (Schema.matchesAny(key, Schema.LOCKED) || Schema.matchesAny(key.toLowerCase(), Schema.LOCKED)) return false;
  if (Schema.matchesAny(key.toLowerCase(), Schema.OTHER_REFUSED_PATTERNS)) return false;
  var v = prefs[key];
  if (typeof v === "boolean") return true;
  if (typeof v === "number") return isFinite(v);
  return typeof v === "string" && !/[\r\n]/.test(v);
}

function otherType(value) {
  if (typeof value === "boolean") return "bool";
  if (typeof value === "number" && Math.floor(value) === value) return "integer";
  if (typeof value === "number") return "number";
  return "text";
}

// --- currentValue / dependencies -------------------------------------------------

// currentValue(key, prefs) -> the raw value prefs hold for key: a time
// composite's "HH:MM" from its two members, anything else as it is.
// undefined while loading or when prefs lack it.
function currentValue(key, prefs) {
  if (!loaded(prefs)) return undefined;
  var entry = entryOf(key);
  if (entry && entry.composite) {
    var h = prefs[entry.composite.hour];
    var m = prefs[entry.composite.min];
    if (typeof h !== "number" || typeof m !== "number") return undefined;
    return pad2(h) + ":" + pad2(m);
  }
  return hasOwn(prefs, key) ? prefs[key] : undefined;
}

// dependencyReason(depKey) -> why a setting depending on depKey is dimmed.
function dependencyReason(depKey) {
  if (hasOwn(DEPENDENCY_REASONS, depKey)) return DEPENDENCY_REASONS[depKey];
  var e = entryOf(depKey);
  if (!e) return "set " + depKey + " first";
  if (e.type === "bool") return e.label.toLowerCase() + " off";
  return "set the " + e.label.toLowerCase() + " first";
}

function dependsMet(dep, prefs) {
  var v = prefs[dep.key];
  var wanted = Array.isArray(dep.value) ? dep.value : [dep.value];
  for (var i = 0; i < wanted.length; i++) {
    if (String(wanted[i]) === String(v)) return true;
  }
  return false;
}

// "" or the reason key is dimmed: walks dependsOn up the chain and names the
// nearest unmet one. A dependency prefs lack doesn't dim.
function dimReason(key, prefs) {
  if (!loaded(prefs)) return "";
  var seen = {};
  var cur = key;
  while (!seen[cur]) {
    seen[cur] = true;
    var e = entryOf(cur);
    var dep = e && e.dependsOn;
    if (!dep || !hasOwn(prefs, dep.key)) return "";
    if (!dependsMet(dep, prefs)) return dependencyReason(dep.key);
    cur = dep.key;
  }
  return "";
}

// --- formatValue ------------------------------------------------------------------

// formatValue(key, value) -> the value in words: "—" (missing), speeds via
// LimitsView ("unlimited", "2 MiB/s"), bools "on"/"off", sentinel labels
// ("random", "unlimited", "off"), choice labels, numbers with their unit
// ("30 s", "4%"), secrets "set"/"not set", empty text "empty", and
// multiline text as its first line plus " (+N more)".
function formatValue(key, value) {
  if (value === undefined || value === null) return LOADING;
  var entry = entryOf(key);
  if (!entry) {
    if (typeof value === "boolean") return value ? "on" : "off";
    return value === "" ? EMPTY : String(value);
  }
  var type = entry.type;
  if (type === "secret" || entry.secret) return secretIsSet(value) ? "set" : "not set";
  if (type === "bool") return toBool(value) === true ? "on" : "off";
  if (type === "speed") return Limits.formatSpeed(value);
  if (isSentinel(entry, value)) return entry.sentinels[String(value)];
  if (entry.choices) {
    for (var i = 0; i < entry.choices.length; i++) {
      if (String(entry.choices[i].value) === String(value)) return entry.choices[i].label;
    }
    return String(value);
  }
  if (type === "int" || type === "float") {
    if (!entry.unit) return String(value);
    return entry.unit === "%" ? value + "%" : value + " " + entry.unit;
  }
  var s = String(value);
  if (s === "") return EMPTY;
  if (entry.listKind) return listSummary(key, s);
  if (entry.multiline) {
    var lines = s.split("\n");
    if (lines.length > 1) return lines[0] + " (+" + (lines.length - 1) + " more)";
  }
  return s;
}

// --- rows ---------------------------------------------------------------------------

function isMutedValue(entry, raw) {
  if (raw === undefined || raw === null) return true;
  if (entry.type === "secret" || entry.secret) return !secretIsSet(raw);
  if (entry.type === "speed") return !(Number(raw) > 0);
  if (isSentinel(entry, raw)) return true;
  return (entry.type === "text" || entry.type === "path") && raw === "";
}

function makeRow(key, entry, prefs) {
  var isLoading = !loaded(prefs);
  var raw = isLoading ? undefined : currentValue(key, prefs);
  var value = formatValue(key, raw);
  // A locked row is never dimmed: the lock is the reason it can't change,
  // and "(reverse proxy off)" would wrongly suggest flipping the switch.
  var reason = isLoading || entry.locked ? "" : dimReason(key, prefs);
  var text = value;
  if (reason !== "") text = value === EMPTY ? "(" + reason + ")" : value + " (" + reason + ")";
  // A list key opens the list editor ("list"); a multiline key that isn't
  // one is read-only (the whitelist, D9) or locked (the headers, D8).
  var tag = entry.locked ? "OmaqBT" : entry.secret ? "secret" : entry.readOnly ? "read-only" :
    entry.listKind ? "list" : (TYPE_TAGS[entry.type] || "text");
  return {
    key: key,
    label: entry.label,
    section: entry.section,
    group: entry.group,
    help: entry.help,
    value: value,
    text: text,
    typeTag: tag,
    muted: isLoading || !!entry.locked || reason !== "" || isMutedValue(entry, raw),
    locked: !!entry.locked,
    readOnly: !!entry.readOnly,
    secret: !!entry.secret,
    restart: !!entry.restart,
    dimmed: reason !== "",
    dimmedReason: reason
  };
}

// otherRows(prefs) -> rows for the keys prefs hold that the schema doesn't
// know, sorted by key: label is the raw key, section and group "Other", the
// type tag from the JSON type ("on/off", "number", "text"). Never a hidden,
// deferred, secret, multiline or read-only key (all of which the schema
// knows), banned_IPs, rss_*, a refused pattern or a non-scalar value.
function otherRows(prefs) {
  if (!loaded(prefs)) return [];
  var keys = Object.keys(prefs).filter(function (k) { return isOtherKey(k, prefs); }).sort();
  return keys.map(function (k) {
    var v = prefs[k];
    var value = formatValue(k, v);
    return {
      key: k,
      label: k,
      section: OTHER,
      group: OTHER,
      help: OTHER_HELP,
      value: value,
      text: value,
      typeTag: typeof v === "boolean" ? TYPE_TAGS.bool : typeof v === "number" ? TYPE_TAGS.int : TYPE_TAGS.text,
      muted: v === "",
      locked: false,
      readOnly: false,
      secret: false,
      restart: false,
      dimmed: false,
      dimmedReason: ""
    };
  });
}

// rows(section, prefs) -> the section's rows in schema order, flat; each
// carries its group (groups come in first-appearance order, for a ListView
// section header):
// {key, label, section, group, help, value, text, typeTag, muted, locked,
//  readOnly, secret, restart, dimmed, dimmedReason}
// value is formatValue's; text is what the row shows: value, or
// "08:00 (schedule off)" on a dimmed row ("(set the proxy type first)" when
// the value is empty). typeTag is "OmaqBT" on locked rows, "secret",
// "read-only", or the type's ("on/off", "number", "speed", "choice", "time",
// "path", "text"). "Other" gives otherRows.
function rows(section, prefs) {
  if (section === OTHER) return otherRows(prefs);
  var out = [];
  var isLoading = !loaded(prefs);
  for (var i = 0; i < KEY_ORDER.length; i++) {
    var key = KEY_ORDER[i];
    var entry = SCHEMA[key];
    if (entry.section !== section || !isVisible(entry)) continue;
    if (!isLoading && !present(key, entry, prefs)) continue;
    out.push(makeRow(key, entry, prefs));
  }
  return out;
}

// rowFor(key, prefs) -> the one row for key (schema or Other), or null.
function rowFor(key, prefs) {
  var entry = entryOf(key);
  if (entry) {
    if (!isVisible(entry) || (loaded(prefs) && !present(key, entry, prefs))) return null;
    return makeRow(key, entry, prefs);
  }
  var o = otherRows(prefs).filter(function (r) { return r.key === key; });
  return o.length ? o[0] : null;
}

// sections(prefs) -> [{name, label, count, dimmed, list?}]: the seven
// schema sections, "Banned IPs" (a list section: list is "banned_IPs", its
// count the bans, its column the list editor; absent when loaded prefs lack
// the key), then "Other" when it has rows, then a dimmed "RSS · slice 5"
// with count 0.
function sections(prefs) {
  var out = SECTIONS.map(function (s) {
    return { name: s, label: s, count: rows(s, prefs).length, dimmed: false };
  });
  if (!loaded(prefs) || hasOwn(prefs, BAN_KEY)) {
    out.push({ name: BANNED, label: BANNED, count: listItems(BAN_KEY, loaded(prefs) ? prefs[BAN_KEY] : "").length, dimmed: false, list: BAN_KEY });
  }
  var other = otherRows(prefs).length;
  if (other > 0) out.push({ name: OTHER, label: OTHER, count: other, dimmed: false });
  out.push({ name: "RSS", label: RSS_LABEL, count: 0, dimmed: true });
  return out;
}

// --- search ----------------------------------------------------------------------------

// noMatch(query) -> 'No setting matches "xyz". Esc clears.'
function noMatch(query) {
  return "No setting matches \"" + textOf(query).trim() + "\". Esc clears.";
}

// search(query, prefs) -> {rows, message}: every row of every section (then
// Other) whose label, help or raw key contains each word of query, ignoring
// case; each row names its section. An empty query gives no rows and no
// message; no match gives noMatch(query).
function search(query, prefs) {
  var q = textOf(query).trim().toLowerCase();
  if (q === "") return { rows: [], message: "" };
  var terms = q.split(/\s+/);
  var all = [];
  for (var i = 0; i < SECTIONS.length; i++) all = all.concat(rows(SECTIONS[i], prefs));
  all = all.concat(otherRows(prefs));
  var hits = all.filter(function (r) {
    var hay = (r.label + "\n" + r.help + "\n" + r.key).toLowerCase();
    for (var j = 0; j < terms.length; j++) {
      if (hay.indexOf(terms[j]) === -1) return false;
    }
    return true;
  });
  return { rows: hits, message: hits.length ? "" : noMatch(query) };
}

// --- editorFor -----------------------------------------------------------------------------

function prefillOf(entry, value) {
  // Borrows 3b's editText for its speed shape ("u", "10K", "2M"): editText
  // reads a status row's dlLimit, so the value goes in as a one-field row.
  if (entry.type === "speed") return Limits.editText("dlLimit", { dlLimit: value });
  return textOf(value);
}

// editorFor(key, prefs) -> how the row is edited:
//   {kind: "toggle", key: "Space", next}           the flipped boolean
//   {kind: "input", key: "Enter", prefill}
//   {kind: "picker", key: "Enter", choices: [{value, label, current}]}
//   {kind: "list", key: "Enter"}                    the list editor (4b)
//   {kind: "secret", key: "Enter", set}             the masked field (4b)
//   {kind: "none", why}  why: "loading", "hidden" (hidden or deferred),
//                        "unknown", "locked", "secret" (not writable),
//                        "readOnly", "dimmed"
// Other keys edit by their JSON type (a boolean toggles, the rest input).
function editorFor(key, prefs) {
  if (!loaded(prefs)) return { kind: "none", why: "loading" };
  var entry = entryOf(key);
  if (!entry) {
    if (!isOtherKey(key, prefs)) return { kind: "none", why: "unknown" };
    var v = prefs[key];
    if (typeof v === "boolean") return { kind: "toggle", key: "Space", next: !v };
    return { kind: "input", key: "Enter", prefill: String(v) };
  }
  if (!isVisible(entry)) return { kind: "none", why: "hidden" };
  if (!present(key, entry, prefs)) return { kind: "none", why: "unknown" };
  if (entry.locked) return { kind: "none", why: "locked" };
  if (entry.secret && !entry.secretWritable) return { kind: "none", why: "secret" };
  if (entry.readOnly) return { kind: "none", why: "readOnly" };
  if (dimReason(key, prefs) !== "") return { kind: "none", why: "dimmed" };
  var cur = currentValue(key, prefs);
  if (entry.secret) return { kind: "secret", key: "Enter", set: secretIsSet(cur) };
  if (entry.listKind) return { kind: "list", key: "Enter" };
  if (entry.multiline) return { kind: "none", why: "readOnly" };
  if (entry.type === "bool") return { kind: "toggle", key: "Space", next: toBool(cur) !== true };
  if (entry.choices) {
    return {
      kind: "picker",
      key: "Enter",
      choices: entry.choices.map(function (c) {
        return { value: c.value, label: c.label, current: String(c.value) === String(cur) };
      })
    };
  }
  return { kind: "input", key: "Enter", prefill: prefillOf(entry, cur) };
}

// --- parseInput ------------------------------------------------------------------------------

function isPortKey(key) {
  return /(^|_)port$/.test(key) || /_ports_/.test(key);
}

// "Use a port from 1 to 65535, or 0 for random." / "Use a number from 1 to
// 33554431, -1 for auto or 0 for off."
function rangeError(key, entry) {
  var sentinels = entry.sentinels ? Object.keys(entry.sentinels) : [];
  var lo = entry.min;
  if (entry.type === "int") {
    while (entry.sentinels && hasOwn(entry.sentinels, String(lo))) lo++;
  }
  var msg = "Use a " + (isPortKey(key) ? "port" : "number") + " from " + lo + " to " + entry.max;
  var parts = sentinels.sort(function (a, b) { return Number(a) - Number(b); }).map(function (s) {
    return s + " for " + entry.sentinels[s];
  });
  if (parts.length === 1) msg += ", or " + parts[0];
  else if (parts.length > 1) msg += ", " + parts.slice(0, -1).join(", ") + " or " + parts[parts.length - 1];
  return msg + ".";
}

function parseNumber(key, entry, s) {
  var isFloat = entry.type === "float";
  var re = isFloat ? /^-?(0|[1-9][0-9]*)(?:\.([0-9]+))?$/ : /^-?(0|[1-9][0-9]*)$/;
  var m = re.exec(s);
  if (!m) return { error: rangeError(key, entry) };
  if (isFloat && m[2] !== undefined && m[2].length > 2) return { error: Limits.RATIO_DECIMALS_ERROR };
  var n = Number(s);
  if (s.charAt(0) === "-" && n === 0) return { error: rangeError(key, entry) };
  if (isSentinel(entry, n)) return { value: n };
  if (n < entry.min || n > entry.max) return { error: rangeError(key, entry) };
  return { value: n };
}

function parseSpeedValue(entry, s) {
  var r = Limits.parseSpeed(s);
  if (r.error) return { error: r.error };
  var bytes = r.bytes;
  var step = entry.step || 1;
  if (bytes > 0 && step > 1) bytes = Math.max(1, Math.round(bytes / step)) * step;
  return { value: bytes };
}

function parseTime(s) {
  var m = /^([01][0-9]|2[0-3]):([0-5][0-9])$/.exec(s);
  if (!m) return { error: TIME_ERROR };
  return { value: s, hour: Number(m[1]), min: Number(m[2]) };
}

function parsePath(entry, s) {
  if (/[\r\n]/.test(s)) return { error: LINE_ERROR };
  if (s === "") return entry.sentinels && hasOwn(entry.sentinels, "") ? { value: "" } : { error: PATH_ERROR };
  if (s.charAt(0) !== "/" && s.indexOf("~/") !== 0) return { error: PATH_ERROR };
  // qBittorrent cleans a path (Ruling DQ), so an unclean one would read back
  // as something else: //, /./, /../ anywhere, or a trailing /. or /..
  if (/\/\/|\/\.\.?(\/|$)/.test(s)) return { error: CLEAN_PATH_ERROR };
  return { value: s };
}

// A dotted IPv4 address: four decimal parts 0-255, no leading zeros.
function isIPv4(s) {
  var parts = s.split(".");
  if (parts.length !== 4) return false;
  for (var i = 0; i < parts.length; i++) {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(parts[i]) || Number(parts[i]) > 255) return false;
  }
  return true;
}

// An IPv6 address: eight groups of 1-4 hex digits, one "::" standing for
// one or more zero groups, and a dotted IPv4 tail counting as two groups.
// No zone (%eth0), no brackets, no prefix length.
function isIPv6(s) {
  var halves = s.split("::");
  if (halves.length > 2) return false;
  var groups = 0;
  for (var h = 0; h < halves.length; h++) {
    if (halves[h] === "") continue;
    var parts = halves[h].split(":");
    for (var i = 0; i < parts.length; i++) {
      var last = h === halves.length - 1 && i === parts.length - 1;
      if (last && parts[i].indexOf(".") !== -1) {
        if (!isIPv4(parts[i])) return false;
        groups += 2;
      } else if (/^[0-9A-Fa-f]{1,4}$/.test(parts[i])) {
        groups += 1;
      } else {
        return false;
      }
    }
  }
  return halves.length === 2 ? groups <= 7 : groups === 8;
}

// Per-key rules the schema has no field for (Rulings DR, DS), after the
// type's own parse accepted s. qbt validates both announce_ip and
// web_ui_username on the raw argv, with no trimming, so surrounding
// whitespace is refused rather than silently accepted-and-sent-untrimmed
// (Ruling DV parity follow-up).
function parseByKey(key, s, parsed) {
  if (parsed.error !== undefined) return parsed;
  if (key === "announce_ip" && s !== "" && !(isIPv4(s) || isIPv6(s))) return { error: IP_ERROR };
  if (key === "web_ui_username" && (s.length < 3 || s.indexOf(":") !== -1)) return { error: USERNAME_ERROR };
  return parsed;
}

function parseChoice(entry, s) {
  for (var i = 0; i < entry.choices.length; i++) {
    var v = entry.choices[i].value;
    if (typeof v === "number" ? /^-?(0|[1-9][0-9]*)$/.test(s) && Number(s) === v : s === v) return { value: v };
  }
  return { error: CHOICE_ERROR };
}

function parseBool(s) {
  var b = toBool(s);
  return b === undefined ? { error: BOOL_ERROR } : { value: b };
}

// parseInput(key, text, prefs?) -> {value} or {error}. text is taken exactly
// as typed (no trimming). value is what gets written: a number for int,
// float, speed (bytes/s, rounded to whole KiB on step-1024 keys) and
// choice-int; the choice's string for choice-string; true/false for bool;
// "HH:MM" for a time composite (which also carries hour and min); the text
// for path and text. prefs is needed only for Other keys (their JSON type).
// Locked, read-only, multiline (a list edits a line at a time:
// parseListLine), secret (parseListLine("secret", ...)), hidden, deferred
// and unknown keys give CANT_CHANGE. A dimmed key still parses (the editor refuses it instead).
function parseInput(key, text, prefs) {
  var s = textOf(text);
  var entry = entryOf(key);
  if (!entry) {
    if (!isOtherKey(key, prefs)) return { error: CANT_CHANGE };
    var t = otherType(prefs[key]);
    if (t === "bool") return parseBool(s);
    // An integer's key takes whole numbers only, never "-0" (Ruling DL).
    // qbt's limits: at most 10 integer digits and 6 decimals, no exponent,
    // no "-0" or "-0.0".
    if (t === "integer") return /^(0|-?[1-9][0-9]{0,9})$/.test(s) ? { value: Number(s) } : { error: WHOLE_NUMBER_ERROR };
    if (t === "number") {
      return /^-?(0|[1-9][0-9]{0,9})(\.[0-9]{1,6})?$/.test(s) && !/^-0(\.0+)?$/.test(s) ? { value: Number(s) } : { error: NUMBER_ERROR };
    }
    return /[\r\n]/.test(s) ? { error: LINE_ERROR } : { value: s };
  }
  if (!isVisible(entry) || entry.locked || entry.readOnly || entry.secret || entry.multiline) return { error: CANT_CHANGE };
  switch (entry.type) {
    case "bool": return parseBool(s);
    case "int":
    case "float": return parseNumber(key, entry, s);
    case "speed": return parseSpeedValue(entry, s);
    case "choice-int":
    case "choice-string": return parseChoice(entry, s);
    case "time": return parseTime(s);
    case "path": return parsePath(entry, s);
    default: return parseByKey(key, s, /[\r\n]/.test(s) ? { error: LINE_ERROR } : { value: s });
  }
}

// --- Slice 4b: lists and secrets ----------------------------------------------------------

// listKindOf(key) -> the schema's listKind ("ip", "trackerUrl", "pattern")
// or "".
function listKindOf(key) {
  var e = entryOf(key);
  return e && e.listKind ? e.listKind : "";
}

// Hex groups of an IPv6 address isIPv6 accepted: eight numbers, a dotted
// tail counting as two.
function ipv6Groups(s) {
  var halves = s.split("::");
  var sides = halves.map(function (h) {
    if (h === "") return [];
    var out = [];
    h.split(":").forEach(function (p) {
      if (p.indexOf(".") !== -1) {
        var o = p.split(".").map(Number);
        out.push(o[0] * 256 + o[1], o[2] * 256 + o[3]);
      } else {
        out.push(parseInt(p, 16));
      }
    });
    return out;
  });
  if (sides.length === 1) return sides[0];
  var zeros = [];
  for (var i = sides[0].length + sides[1].length; i < 8; i++) zeros.push(0);
  return sides[0].concat(zeros, sides[1]);
}

// normaliseIp(s) -> s in QHostAddress::toString's form (Qt 6.11, as Task
// 2's qbt `qt_addr` checks it), "" when s isn't an address: IPv4 as it
// is; IPv6 lowercase with the first longest run of two or more zero groups
// as "::"; an IPv4-mapped address as ::ffff:a.b.c.d; an address whose
// first 96 bits are zero and whose group 7 isn't as ::a.b.c.d (Python's
// ipaddress, and so 4a's fixture, get that one wrong).
function normaliseIp(text) {
  var s = textOf(text);
  if (isIPv4(s)) return s;
  if (!isIPv6(s)) return "";
  var g = ipv6Groups(s);
  var dotted = [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join(".");
  if (g[0] === 0 && g[1] === 0 && g[2] === 0 && g[3] === 0 && g[4] === 0) {
    if (g[5] === 0xffff) return "::ffff:" + dotted;
    if (g[5] === 0 && g[6] !== 0) return "::" + dotted;
  }
  var best = -1, bestLen = 1, run = -1;
  for (var i = 0; i <= 8; i++) {
    if (i < 8 && g[i] === 0) {
      if (run === -1) run = i;
    } else if (run !== -1) {
      if (i - run > bestLen) { best = run; bestLen = i - run; }
      run = -1;
    }
  }
  var hex = g.map(function (n) { return n.toString(16); });
  if (best === -1) return hex.join(":");
  return hex.slice(0, best).join(":") + "::" + hex.slice(best + bestLen).join(":");
}

// parseListLine(kind, text) -> {value} or {error}: one line typed into the
// list editor (kind ip, trackerUrl, pattern) or the secret field (kind
// secret), by list-rules-cases.json's rules, never trimmed. value is what
// qBittorrent keeps: an ip in normaliseIp's form, anything else exactly as
// typed. An empty tracker URL is a tier break ({value: "", tierBreak:
// true}). A secret counts code points (Array.from), not UTF-16 units.
function parseListLine(kind, text) {
  var s = textOf(text);
  if (kind === "ip") {
    var ip = normaliseIp(s);
    return ip === "" ? { error: LIST_ERRORS.ip } : { value: ip };
  }
  if (kind === "trackerUrl") {
    if (s === "") return { value: "", tierBreak: true };
    var good = s.length <= TRACKER_URL_MAX && /^(http|https|udp):\/\/[!-~]+$/.test(s) && s.indexOf("|") === -1;
    return good ? { value: s } : { error: LIST_ERRORS.trackerUrl };
  }
  if (kind === "pattern") {
    if (s === "") return { error: LIST_ERRORS.patternEmpty };
    return /[\r\n]/.test(s) ? { error: LIST_ERRORS.patternLine } : { value: s };
  }
  if (kind === "secret") {
    if (s === "") return { error: LIST_ERRORS.secretEmpty };
    if (s.indexOf("\u0000") !== -1) return { error: LIST_ERRORS.secretNul };
    if (/[\r\n]/.test(s)) return { error: LIST_ERRORS.secretLine };
    return Array.from(s).length <= SECRET_MAX ? { value: s } : { error: LIST_ERRORS.secretLong };
  }
  return { error: CANT_CHANGE };
}

// The lines of a list value: "" is no lines; otherwise split on "\n"
// keeping empty ones, so joinList gives the value back exactly.
function splitList(value) {
  var s = textOf(value);
  return s === "" ? [] : s.split("\n");
}

// joinList(lines) -> the newline-joined value qBittorrent stores.
function joinList(lines) {
  return (lines || []).join("\n");
}

// listItems(key, value) -> [{index, value, tierBreak, text}]: the list
// editor's rows. banned_IPs skips empty lines (qBittorrent does too);
// add_trackers shows an empty line as a tier break ("— next tier —");
// excluded_file_names keeps an empty entry as "(empty line)". index is
// the line's position in the value (what listWithout checks).
function listItems(key, value) {
  var lines = splitList(value);
  var tiers = !!(entryOf(key) && entryOf(key).tierBreaks);
  var out = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (key === BAN_KEY) {
      if (line !== "") out.push({ index: out.length, value: line, tierBreak: false, text: line });
      continue;
    }
    var brk = tiers && line === "";
    out.push({ index: i, value: line, tierBreak: brk, text: brk ? TIER_BREAK_TEXT : (line === "" ? EMPTY_LINE_TEXT : line) });
  }
  return out;
}

// listSummary(key, value) -> a list row's value: "3 trackers in 2 tiers",
// "2 patterns", "2 addresses" (empty lines aren't counted).
function listSummary(key, value) {
  var items = listItems(key, value);
  var n = 0;
  var tiers = 1;
  for (var i = 0; i < items.length; i++) {
    if (items[i].value !== "") n++;
    else if (items[i].tierBreak && i > 0 && !items[i - 1].tierBreak) tiers++;
  }
  // A break before the first URL or after the last starts no tier.
  if (items.length && items[items.length - 1].tierBreak) tiers--;
  if (n === 0) return EMPTY;
  var kind = listKindOf(key);
  var word = kind === "trackerUrl" ? ["tracker", "trackers"] : kind === "ip" ? ["address", "addresses"] : ["pattern", "patterns"];
  var text = n + " " + word[n === 1 ? 0 : 1];
  return kind === "trackerUrl" && tiers > 1 ? text + " in " + tiers + " tiers" : text;
}

// listWithAdded(key, value, after, line) -> {value, index} with line
// inserted after line index `after` (-1: first; past the end: last), every
// other line exactly as it was; index is the new line's. {same: true}
// when nothing would change: a tier break into an empty list (qBittorrent
// would read it back as nothing), or with a note, a line already there.
function listWithAdded(key, value, after, line) {
  var lines = splitList(value);
  var l = textOf(line);
  if (l === "" && lines.length === 0) return { same: true };
  if (l !== "" && lines.indexOf(l) !== -1) return { same: true, note: l + " is already in the list." };
  var at = Math.max(0, Math.min(lines.length, (Number(after) || 0) + 1));
  if (Number(after) < 0) at = 0;
  lines.splice(at, 0, l);
  return { value: joinList(lines), index: at };
}

// listWithout(key, value, item) -> {value} without line item.index, every
// other line exactly as it was; {stale: true} when that line isn't
// item.value any more (the list changed since the key was pressed).
function listWithout(key, value, item) {
  var lines = splitList(value);
  var i = item ? Number(item.index) : -1;
  if (!(i >= 0 && i < lines.length) || lines[i] !== textOf(item.value)) return { stale: true };
  lines.splice(i, 1);
  return { value: joinList(lines) };
}

// listBadLine(key, value) -> {index, value, error} for the first line of a
// whole add_trackers or excluded_file_names value that qbt would refuse
// (it checks every line, not just the new one), else null. A tracker tier
// break (an empty line) and an empty pattern are kept, not refused.
function listBadLine(key, value) {
  var kind = listKindOf(key);
  if (kind !== "trackerUrl" && kind !== "pattern") return null;
  var lines = splitList(value);
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue;
    var r = parseListLine(kind, lines[i]);
    if (r.error !== undefined) return { index: i, value: lines[i], error: r.error };
  }
  return null;
}

// listBadNote(bad) -> "Remove <line> first: <reason>", for listBadLine's
// answer: the new list can't be saved until that line goes.
function listBadNote(bad) {
  return "Remove " + textOf(bad && bad.value) + " first: " + textOf(bad && bad.error);
}

// banHas(value, ip) -> whether the ban list holds ip, compared in
// QHostAddress's form.
function banHas(value, ip) {
  var want = normaliseIp(ip);
  if (want === "") return false;
  var items = listItems(BAN_KEY, value);
  for (var i = 0; i < items.length; i++) if (normaliseIp(items[i].value) === want) return true;
  return false;
}

function listEmptyText(key) { return hasOwn(LIST_EMPTY, key) ? LIST_EMPTY[key] : ""; }
function listPrompt(key) { return hasOwn(LIST_PROMPTS, key) ? LIST_PROMPTS[key] : ""; }
function listTitle(key) { var e = entryOf(key); return e ? e.label : String(key); }

// listDoneNote(key, op, line) -> the note after a list write: "Banned
// 1.2.3.4", "Unbanned 1.2.3.4", "Added *.exe to Excluded file names",
// "Next tier added to Trackers to add".
function listDoneNote(key, op, line) {
  var l = textOf(line);
  if (key === BAN_KEY) return (op === "add" ? "Banned " : "Unbanned ") + l;
  var title = listTitle(key);
  if (l === "" && entryOf(key) && entryOf(key).tierBreaks) {
    return op === "add" ? "Next tier added to " + title : "Tier break removed from " + title;
  }
  if (op === "add") return "Added " + l + " to " + title;
  return l === "" ? "Removed an empty line from " + title : "Removed " + l + " from " + title;
}

function secretName(key) {
  if (hasOwn(SECRET_NAMES, key)) return SECRET_NAMES[key];
  var e = entryOf(key);
  return e ? e.label.toLowerCase() : String(key);
}

// secretQuestion(key) -> "Clear the proxy password?"
function secretQuestion(key) {
  return "Clear the " + secretName(key) + "?";
}

// secretDoneNote(key, op) -> "Proxy password set" / "... cleared": never
// a value.
function secretDoneNote(key, op) {
  var n = secretName(key);
  return n.charAt(0).toUpperCase() + n.slice(1) + (op === "clear" ? " cleared" : " set");
}

// --- equalValue -------------------------------------------------------------------------------

// equalValue(key, a, b) -> whether a write of b over a changes nothing, by
// the key's type (the JSON type of a for Other keys), like qbt's read-back:
// bools (true/"true"), numbers numerically ("51414" = 51414, "1.50" = 1.5;
// a non-number is never equal), paths trimmed and without trailing slashes,
// everything else as trimmed strings. A secret is never equal.
function equalValue(key, a, b) {
  var entry = entryOf(key);
  var type = entry ? entry.type : otherType(a);
  if (type === "secret") return false;
  if (type === "bool") {
    var x = toBool(a);
    return x !== undefined && x === toBool(b);
  }
  if (type === "int" || type === "float" || type === "speed" || type === "choice-int" || type === "number" || type === "integer") {
    var n = toNumber(a);
    return n !== undefined && n === toNumber(b);
  }
  if (type === "path") return normPath(a) === normPath(b);
  return textOf(a).trim() === textOf(b).trim();
}

// --- confirmFor / doneNote -----------------------------------------------------------------------

// confirmFor(key, from, to) -> "" or the one line to confirm before writing
// to over from: the schema's confirm.byValue[String(to)], else its text when
// to is one of confirm.values (compared as strings) or there are no values.
// An unchanged value (equalValue) never confirms.
function confirmFor(key, from, to) {
  var entry = entryOf(key);
  var c = entry && entry.confirm;
  if (!c || equalValue(key, from, to)) return "";
  if (c.byValue && hasOwn(c.byValue, String(to))) return c.byValue[String(to)];
  if (!c.values) return c.text;
  for (var i = 0; i < c.values.length; i++) {
    if (String(c.values[i]) === String(to)) return c.text;
  }
  return "";
}

// doneNote(key, value) -> the status note after a successful write:
// "Listening port set to 51414", "DHT off", plus RESTART_NOTE on restart
// keys. Other keys use their raw name.
function doneNote(key, value) {
  var entry = entryOf(key);
  var label = entry ? entry.label : key;
  var isBool = entry ? entry.type === "bool" : typeof value === "boolean";
  var note = isBool ? label + (toBool(value) === true ? " on" : " off") : label + " set to " + formatValue(key, value);
  return entry && entry.restart ? note + RESTART_NOTE : note;
}

if (typeof module !== "undefined") {
  module.exports = {
    LOADING: LOADING,
    EMPTY: EMPTY,
    CANT_CHANGE: CANT_CHANGE,
    OTHER_HELP: OTHER_HELP,
    RSS_LABEL: RSS_LABEL,
    RESTART_NOTE: RESTART_NOTE,
    TIME_ERROR: TIME_ERROR,
    PATH_ERROR: PATH_ERROR,
    LINE_ERROR: LINE_ERROR,
    CHOICE_ERROR: CHOICE_ERROR,
    BOOL_ERROR: BOOL_ERROR,
    NUMBER_ERROR: NUMBER_ERROR,
    WHOLE_NUMBER_ERROR: WHOLE_NUMBER_ERROR,
    LIST_ERRORS: LIST_ERRORS,
    TIER_BREAK_TEXT: TIER_BREAK_TEXT,
    BANNED: BANNED,
    BAN_KEY: BAN_KEY,
    CLEAN_PATH_ERROR: CLEAN_PATH_ERROR,
    IP_ERROR: IP_ERROR,
    USERNAME_ERROR: USERNAME_ERROR,
    sections: sections,
    rows: rows,
    rowFor: rowFor,
    otherRows: otherRows,
    search: search,
    noMatch: noMatch,
    currentValue: currentValue,
    dependencyReason: dependencyReason,
    editorFor: editorFor,
    parseInput: parseInput,
    confirmFor: confirmFor,
    doneNote: doneNote,
    formatValue: formatValue,
    equalValue: equalValue,
    listKindOf: listKindOf,
    normaliseIp: normaliseIp,
    parseListLine: parseListLine,
    joinList: joinList,
    listItems: listItems,
    listWithAdded: listWithAdded,
    listWithout: listWithout,
    banHas: banHas,
    listBadLine: listBadLine,
    listBadNote: listBadNote,
    listEmptyText: listEmptyText,
    listPrompt: listPrompt,
    listTitle: listTitle,
    listDoneNote: listDoneNote,
    secretQuestion: secretQuestion,
    secretDoneNote: secretDoneNote
  };
}
