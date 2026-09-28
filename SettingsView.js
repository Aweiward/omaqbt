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
// 4a scope (eng D1): secrets show "set"/"not set" and aren't editable,
// banned_IPs and rss_* never show, and done notes carry no "u undoes".
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
// banned_IPs or rss_*, not matching a refused pattern, and a scalar value
// (a string on one line).
function isOtherKey(key, prefs) {
  if (!loaded(prefs) || !hasOwn(prefs, key) || hasOwn(SCHEMA, key)) return false;
  if (key === "banned_IPs" || key.indexOf("rss_") === 0) return false;
  if (Schema.matchesAny(key, Schema.OTHER_REFUSED_PATTERNS)) return false;
  var v = prefs[key];
  if (typeof v === "boolean") return true;
  if (typeof v === "number") return isFinite(v);
  return typeof v === "string" && !/[\r\n]/.test(v);
}

function otherType(value) {
  if (typeof value === "boolean") return "bool";
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
  var tag = entry.locked ? "OmaqBT" : entry.secret ? "secret" : entry.readOnly ? "read-only" : (TYPE_TAGS[entry.type] || "text");
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
      typeTag: TYPE_TAGS[otherType(v) === "number" ? "int" : otherType(v)],
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

// sections(prefs) -> [{name, label, count, dimmed}]: the seven schema
// sections, then "Other" when it has rows, then a dimmed "RSS · slice 5"
// with count 0.
function sections(prefs) {
  var out = SECTIONS.map(function (s) {
    return { name: s, label: s, count: rows(s, prefs).length, dimmed: false };
  });
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
  if (entry.type === "speed") return Limits.editText("dlLimit", { dlLimit: value });
  return textOf(value);
}

// editorFor(key, prefs) -> how the row is edited:
//   {kind: "toggle", key: "Space", next}           the flipped boolean
//   {kind: "input", key: "Enter", prefill, multiline}
//   {kind: "picker", key: "Enter", choices: [{value, label, current}]}
//   {kind: "none", why}  why: "loading", "hidden" (hidden or deferred),
//                        "unknown", "locked", "secret", "readOnly", "dimmed"
// Other keys edit by their JSON type (a boolean toggles, the rest input).
function editorFor(key, prefs) {
  if (!loaded(prefs)) return { kind: "none", why: "loading" };
  var entry = entryOf(key);
  if (!entry) {
    if (!isOtherKey(key, prefs)) return { kind: "none", why: "unknown" };
    var v = prefs[key];
    if (typeof v === "boolean") return { kind: "toggle", key: "Space", next: !v };
    return { kind: "input", key: "Enter", prefill: String(v), multiline: false };
  }
  if (!isVisible(entry)) return { kind: "none", why: "hidden" };
  if (!present(key, entry, prefs)) return { kind: "none", why: "unknown" };
  if (entry.locked) return { kind: "none", why: "locked" };
  if (entry.secret) return { kind: "none", why: "secret" };
  if (entry.readOnly) return { kind: "none", why: "readOnly" };
  if (dimReason(key, prefs) !== "") return { kind: "none", why: "dimmed" };
  var cur = currentValue(key, prefs);
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
  return { kind: "input", key: "Enter", prefill: prefillOf(entry, cur), multiline: !!entry.multiline };
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
  if (s.charAt(0) === "/" || s.indexOf("~/") === 0) return { value: s };
  return { error: PATH_ERROR };
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
// Locked, read-only, secret, hidden, deferred and unknown keys give
// CANT_CHANGE. A dimmed key still parses (the editor refuses it instead).
function parseInput(key, text, prefs) {
  var s = textOf(text);
  var entry = entryOf(key);
  if (!entry) {
    if (!isOtherKey(key, prefs)) return { error: CANT_CHANGE };
    var t = otherType(prefs[key]);
    if (t === "bool") return parseBool(s);
    if (t === "number") return /^-?(0|[1-9][0-9]*)(\.[0-9]+)?$/.test(s) ? { value: Number(s) } : { error: NUMBER_ERROR };
    return /[\r\n]/.test(s) ? { error: LINE_ERROR } : { value: s };
  }
  if (!isVisible(entry) || entry.locked || entry.readOnly || entry.secret) return { error: CANT_CHANGE };
  switch (entry.type) {
    case "bool": return parseBool(s);
    case "int":
    case "float": return parseNumber(key, entry, s);
    case "speed": return parseSpeedValue(entry, s);
    case "choice-int":
    case "choice-string": return parseChoice(entry, s);
    case "time": return parseTime(s);
    case "path": return parsePath(entry, s);
    default: return !entry.multiline && /[\r\n]/.test(s) ? { error: LINE_ERROR } : { value: s };
  }
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
  if (type === "int" || type === "float" || type === "speed" || type === "choice-int" || type === "number") {
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
    equalValue: equalValue
  };
}
