.pragma library

// The Search view's pure rules (slice 5a, Task 3). No I/O, no Date, no Qt
// objects: everything comes in through arguments, so
// tests/search-view.test.js runs it in node against
// tests/fixtures/search-rules-cases.json. It imports nothing.
//
// The `.pragma library` line above is QML-only; the node test strips it.
//
// What lives here (tests/fixtures/search-contract.md is the contract):
// - the rules of the case file, as the window's pre-checks (qbt enforces):
//   pluginUrl, pageLink, addLink, magnetHash, row (sanitising: OV9/OV12,
//   the only place it happens; the sidecar passes rows raw), pluginName,
//   pattern, category, searchId and installReadback. Every URL is split by
//   the contract's text rule, never a URL library (Ruling FB), and a
//   non-ASCII host label becomes xn-- plus RFC 3492 punycode (encoded
//   here, lowercased first, no other IDNA mapping);
// - the library match (OV11) and merging same-hash rows across plugins;
// - per-plugin counts with an "other" bucket for an empty engineName (OV1);
// - the sort, the query bar's run state, the empty states and the confirm
//   lines (A1, D3, D4), all built from the case file's `window` copy;
// - the sidecar reply rule (OV7, Ruling FB): which reply to apply, which
//   to answer with a re-sent watch, and which is final.
//
// The sentences below are the case file's; the node test checks each one
// against it, so none can drift.

var EMPTY = "—";

var WINDOW = {
  added: "Added <name>.",
  sent: "Sent <name> to qBittorrent · it appears when its download finishes.",
  inLibrary: "Already in your library.",
  gone: "The search ended when qBittorrent restarted.",
  addConfirm: "Add <name> (<size>) from <host>?",
  openConfirm: "Open <host> in your browser? It won't go through the VPN.",
  installConfirm: "Install <name> from <host>?",
  installDetail: "This runs Python code as qBittorrent, with access to your downloads.",
  uninstallConfirm: "Uninstall <name>?",
  running: "searching… · <k> results",
  done: "done · <k> results",
  stopped: "stopped · <k> results",
  capped: "showing 2000 of <n>",
  noPlugins: "No search plugins yet",
  noResultsYet: "No results yet",
  noResults: "No results for \"<q>\". Try fewer words, or check which plugins are on (P).",
  noPluginsHelp: "qBittorrent searches through plugins it runs with Python on this machine. P manages them; i installs one from an https URL.",
  stalled: "No results are arriving; press Esc and try again.",
  addUnconfirmed: "Couldn't confirm <name> was added.",
  noPluginResults: "No results from <plugin>.",
  installing: "installing…",
  updating: "updating…",
  uninstalling: "uninstalling…",
  saving: "saving…"
};

var SENTENCES = {
  alreadyInstalled: "<name> v<version> is already installed.",
  installUnconfirmed: "Couldn't confirm the install of <name>.",
  unreadable: "qBittorrent sent something unreadable"
};

// The rules' own messages (the case file's `message`s).
var MSG = {
  pluginUrlEmpty: "Paste an https:// link to a plugin's .py file.",
  pluginUrlLong: "Use a URL of at most 2048 characters.",
  pluginUrlBad: "Use a URL without spaces, control characters, | or \\.",
  pluginUrlScheme: "Plugin URLs must start with https://.",
  pluginUrlUserinfo: "Use a URL without a user name or password.",
  pluginUrlHost: "That URL has no valid host.",
  pluginUrlPy: "The URL must point to a .py file.",
  pluginName: "Plugin names use only letters, digits and _.",
  pageEmpty: "That result has no page link.",
  pageBad: "That page link has spaces, control characters or \\ in it.",
  pageScheme: "That page link isn't http or https.",
  pageUserinfo: "That page link has a user name or password in it.",
  pageHost: "That page link has no valid host.",
  noLink: "That result has no usable link.",
  patternEmpty: "Type something to search for.",
  patternControl: "Use a search without control characters.",
  category: "That isn't a search category.",
  searchId: "That isn't a search id."
};

// qBittorrent 5.2.3's category ids, in its table order
// (searchpluginmanager.cpp categoryFullName), and its names for them.
var CATEGORY_ORDER = ["anime", "books", "games", "movies", "music", "pictures", "software", "tv"];
var ALL_CATEGORIES = { id: "all", name: "All categories" };
var CATEGORY_NAMES = { anime: "Anime", books: "Books", games: "Games", movies: "Movies", music: "Music",
  pictures: "Pictures", software: "Software", tv: "TV shows" };

// The sidecar never reads past row 2000 (OV15).
var ROW_CAP = 2000;
// Recent keeps the last 8 queries (design D7).
var RECENT_MAX = 8;
// The "other" bucket: a result whose engineName is empty (OV1).
var OTHER = "";
var OTHER_LABEL = "other";

// fill(template, vars) -> the template with each <key> replaced.
function fill(template, vars) {
  var v = vars || {};
  return String(template).replace(/<([a-z]+)>/g, function(all, k) {
    return Object.prototype.hasOwnProperty.call(v, k) ? String(v[k]) : all;
  });
}

// ---- characters ------------------------------------------------------------------

// BAD (the case file's _doc): controls, every Unicode space, zero-widths,
// bidi controls, the soft hyphen, the IDNA dots (U+3002, U+FF0E, U+FF61)
// and the backslash.
var BAD = /[\u0000-\u0020\u007f-\u00a0\u00ad\u1680\u2000-\u200f\u2028-\u202f\u205f-\u206f\u3000\u3002\ufeff\uff0e\uff61\\]/;
var BIDI = /[\u202a-\u202e\u2066-\u2069]/g;
var CONTROLS = /[\u0000-\u001f\u007f-\u009f]/g;
var CONTROL = /[\u0000-\u001f\u007f-\u009f]/;
var NAME_RULE = /^[A-Za-z0-9_]+$/;

function codePoints(s) {
  return Array.from(String(s));
}

// ---- RFC 3492 punycode ---------------------------------------------------------------

function adapt(delta, numPoints, first) {
  var d = first ? Math.floor(delta / 700) : Math.floor(delta / 2);
  d += Math.floor(d / numPoints);
  var k = 0;
  while (d > ((36 - 1) * 26) / 2) {
    d = Math.floor(d / (36 - 1));
    k += 36;
  }
  return k + Math.floor(((36 - 1 + 1) * d) / (d + 38));
}

function digit(d) {
  return String.fromCharCode(d < 26 ? 97 + d : 22 + d);
}

// punycode(label) -> RFC 3492's encoding of label (no "xn--"), or null on
// overflow. Works on code points, so astral characters count once.
function punycode(label) {
  var input = codePoints(label).map(function(ch) { return ch.codePointAt(0); });
  var n = 128, delta = 0, bias = 72, out = "";
  for (var i = 0; i < input.length; i++) if (input[i] < 128) out += String.fromCharCode(input[i]);
  var b = out.length, h = b;
  if (b > 0) out += "-";
  while (h < input.length) {
    var m = Infinity;
    for (var j = 0; j < input.length; j++) if (input[j] >= n && input[j] < m) m = input[j];
    delta += (m - n) * (h + 1);
    if (!isFinite(delta) || delta > 0x7fffffff) return null;
    n = m;
    for (var c = 0; c < input.length; c++) {
      if (input[c] < n) delta++;
      if (input[c] !== n) continue;
      var q = delta;
      for (var k = 36; ; k += 36) {
        var t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias);
        if (q < t) break;
        out += digit(t + ((q - t) % (36 - t)));
        q = Math.floor((q - t) / (36 - t));
      }
      out += digit(q);
      bias = adapt(delta, h + 1, h === b);
      delta = 0;
      h++;
    }
    delta++;
    n++;
  }
  return out;
}

// ---- the URL text rule (Ruling FB) ------------------------------------------------------

// splitUrl(s, prefixLen) -> {authority, path, lastSegment} for the text
// after the scheme's "://": the authority runs to the first /, ? or #;
// the path from that / to the first ? or #.
function splitUrl(s, prefixLen) {
  var rest = String(s).slice(prefixLen);
  var cut = rest.search(/[\/?#]/);
  var authority = cut === -1 ? rest : rest.slice(0, cut);
  var after = cut === -1 ? "" : rest.slice(cut);
  var path = "";
  if (after.charAt(0) === "/") {
    var end = after.search(/[?#]/);
    path = end === -1 ? after : after.slice(0, end);
  }
  return { authority: authority, path: path, lastSegment: path.slice(path.lastIndexOf("/") + 1) };
}

function portOk(p) {
  if (!/^[0-9]{1,5}$/.test(p)) return false;
  var n = Number(p);
  return n >= 1 && n <= 65535;
}

// hostOf(authority) -> {ok, host, userinfo}: the host as a confirm shows
// it (lower case, IDN as punycode, no port), per the contract's rule.
function hostOf(authority) {
  var a = String(authority);
  if (a.indexOf("@") !== -1) return { ok: false, userinfo: true };
  var v6 = /^\[([0-9A-Fa-f:.]*)\](?::(.*))?$/.exec(a);
  if (a.charAt(0) === "[") {
    if (!v6 || v6[1].indexOf(":") === -1) return { ok: false };
    if (v6[2] !== undefined && !portOk(v6[2])) return { ok: false };
    return { ok: true, host: "[" + v6[1].toLowerCase() + "]" };
  }
  var parts = a.split(":");
  if (parts.length > 2) return { ok: false };
  if (parts.length === 2 && !portOk(parts[1])) return { ok: false };
  var labels = parts[0].toLowerCase().split(".");
  for (var i = 0; i < labels.length; i++) {
    if (!/[^\u0000-\u007f]/.test(labels[i])) continue;
    var p = punycode(labels[i]);
    if (p === null) return { ok: false };
    labels[i] = "xn--" + p;
  }
  var host = labels.join(".");
  if (host.length < 1 || host.length > 253) return { ok: false };
  for (var j = 0; j < labels.length; j++) {
    if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(labels[j])) return { ok: false };
  }
  return { ok: true, host: host };
}

function startsWithCi(s, prefix) {
  return String(s).slice(0, prefix.length).toLowerCase() === prefix;
}

function refuse(message) {
  return { ok: false, message: message };
}

// ---- the rules (the case file's kinds) --------------------------------------------------------

// pluginUrl (i): {ok, normalised (the plugin's name), host} or {ok:false, message}.
function checkPluginUrl(input) {
  var s = typeof input === "string" ? input : "";
  if (s === "") return refuse(MSG.pluginUrlEmpty);
  if (codePoints(s).length > 2048) return refuse(MSG.pluginUrlLong);
  if (BAD.test(s) || s.indexOf("|") !== -1) return refuse(MSG.pluginUrlBad);
  if (!startsWithCi(s, "https://")) return refuse(MSG.pluginUrlScheme);
  var u = splitUrl(s, 8);
  var h = hostOf(u.authority);
  if (h.userinfo) return refuse(MSG.pluginUrlUserinfo);
  if (!h.ok) return refuse(MSG.pluginUrlHost);
  var seg = u.lastSegment;
  if (seg.length < 3 || seg.slice(-3).toLowerCase() !== ".py") return refuse(MSG.pluginUrlPy);
  var name = seg.slice(0, -3);
  if (!NAME_RULE.test(name)) return refuse(MSG.pluginName);
  return { ok: true, normalised: name, host: h.host };
}

// pageLink (d, D3): {ok, host} or {ok:false, message}.
function checkPageLink(input) {
  var s = typeof input === "string" ? input : "";
  if (s === "") return refuse(MSG.pageEmpty);
  if (BAD.test(s)) return refuse(MSG.pageBad);
  var len = startsWithCi(s, "https://") ? 8 : (startsWithCi(s, "http://") ? 7 : 0);
  if (len === 0) return refuse(MSG.pageScheme);
  var h = hostOf(splitUrl(s, len).authority);
  if (h.userinfo) return refuse(MSG.pageUserinfo);
  if (!h.ok) return refuse(MSG.pageHost);
  return { ok: true, host: h.host };
}

// addLink (qbt search add <link> [<plugin>], OV5): input is the argv
// after `add`. {ok, normalised: "add"|"plugin", host?} or a refusal.
function checkAddLink(input) {
  var argv = Array.isArray(input) ? input : [input];
  var link = typeof argv[0] === "string" ? argv[0] : "";
  var plugin = typeof argv[1] === "string" ? argv[1] : "";
  if (plugin !== "" && !NAME_RULE.test(plugin)) return refuse(MSG.pluginName);
  if (link === "" || BAD.test(link)) return refuse(MSG.noLink);
  if (/^magnet:\?/i.test(link)) return { ok: true, normalised: "add" };
  if (!startsWithCi(link, "https://")) return refuse(MSG.noLink);
  var u = splitUrl(link, 8);
  var h = hostOf(u.authority);
  if (!h.ok) return refuse(MSG.noLink);
  if (plugin !== "") return { ok: true, normalised: "plugin", host: h.host };
  var seg = u.lastSegment;
  if (seg.length > 8 && seg.slice(-8).toLowerCase() === ".torrent") return { ok: true, normalised: "add", host: h.host };
  return refuse(MSG.noLink);
}

var BASE32 = "abcdefghijklmnopqrstuvwxyz234567";

function base32Hex(s) {
  var bits = "";
  var t = s.toLowerCase();
  for (var i = 0; i < t.length; i++) {
    var v = BASE32.indexOf(t.charAt(i));
    if (v < 0) return null;
    var b = v.toString(2);
    while (b.length < 5) b = "0" + b;
    bits += b;
  }
  var hex = "";
  for (var j = 0; j + 4 <= bits.length; j += 4) hex += parseInt(bits.slice(j, j + 4), 2).toString(16);
  return hex;
}

// magnetHash (OV11): {v1, v2} (null for the missing one), or null when the
// link carries no infohash (an http(s) link never matches the library).
function magnetHash(input) {
  var s = typeof input === "string" ? input : "";
  if (!/^magnet:\?/i.test(s)) return null;
  var query = s.slice(8).split("#")[0];
  var v1 = null, v2 = null;
  var params = query.split("&");
  for (var i = 0; i < params.length; i++) {
    var eq = params[i].indexOf("=");
    if (eq < 0) continue;
    if (!/^xt(\.[0-9]+)?$/i.test(params[i].slice(0, eq))) continue;
    var val;
    try { val = decodeURIComponent(params[i].slice(eq + 1)); } catch (e) { continue; }
    var m = /^urn:btih:(.*)$/i.exec(val);
    if (m && v1 === null) {
      if (/^[0-9a-f]{40}$/i.test(m[1])) v1 = m[1].toLowerCase();
      else if (/^[a-z2-7]{32}$/i.test(m[1])) v1 = base32Hex(m[1]);
      continue;
    }
    var b = /^urn:btmh:1220([0-9a-f]{64})$/i.exec(val);
    if (b && v2 === null) v2 = b[1].toLowerCase();
  }
  if (v1 === null && v2 === null) return null;
  return { v1: v1, v2: v2 };
}

// cleanName(value) -> the row rule's name: bidi controls removed, C0/C1
// controls each a space, trimmed; over 300 code points the first 299 and
// "…"; nothing left (or not a string) is "—".
function cleanName(value) {
  if (typeof value !== "string") return EMPTY;
  var s = value.replace(BIDI, "").replace(CONTROLS, " ").trim();
  if (s === "") return EMPTY;
  var cp = codePoints(s);
  return cp.length > 300 ? cp.slice(0, 299).join("") + "…" : s;
}

function count(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 ? value : EMPTY;
}

// row (OV9, OV12): what the table shows before formatting.
function sanitizeRow(raw) {
  var r = raw && typeof raw === "object" ? raw : {};
  var pub = r.pubDate;
  return {
    name: cleanName(r.fileName),
    size: count(r.fileSize),
    seeds: count(r.nbSeeders),
    peers: count(r.nbLeechers),
    published: typeof pub === "number" && isFinite(pub) && pub > 0 ? pub : EMPTY
  };
}

function checkPluginName(input) {
  return typeof input === "string" && NAME_RULE.test(input) ? { ok: true } : refuse(MSG.pluginName);
}

// Qt's QChar::isSpace (what QString::trimmed strips, Ruling FE): Zs, Zl,
// Zp, U+0009-U+000D, U+0085 and U+00A0; not U+FEFF, which
// String.prototype.trim would also strip.
var QT_SPACE = /[\u0009-\u000d\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/;

function qtTrim(text) {
  var s = typeof text === "string" ? text : "";
  var start = 0, end = s.length;
  while (start < end && QT_SPACE.test(s.charAt(start))) start++;
  while (end > start && QT_SPACE.test(s.charAt(end - 1))) end--;
  return s.slice(start, end);
}

function checkPattern(input) {
  var s = typeof input === "string" ? input : "";
  if (CONTROL.test(s)) return refuse(MSG.patternControl);
  if (qtTrim(s) === "") return refuse(MSG.patternEmpty);
  return { ok: true };
}

function checkCategory(input) {
  return input === "all" || CATEGORY_ORDER.indexOf(input) !== -1 ? { ok: true } : refuse(MSG.category);
}

function checkSearchId(input) {
  var s = typeof input === "string" ? input : String(input);
  return /^[1-9][0-9]{0,9}$/.test(s) && Number(s) <= 2147483647 ? { ok: true } : refuse(MSG.searchId);
}

// installReadback (A3, OV4): the version before the POST and at the end.
function installReadback(input) {
  var r = input || {};
  var name = String(r.name || "");
  if (r.after !== null && r.after !== undefined && r.after !== r.before) return { ok: true };
  if (r.before !== null && r.before !== undefined && r.after === r.before) return refuse(fill(SENTENCES.alreadyInstalled, { name: name, version: r.before }));
  return refuse(fill(SENTENCES.installUnconfirmed, { name: name }));
}

// check(kind, input) -> the rule of that kind (the node test's one door).
function check(kind, input) {
  switch (kind) {
  case "pluginUrl": return checkPluginUrl(input);
  case "pageLink": return checkPageLink(input);
  case "addLink": return checkAddLink(input);
  case "pluginName": return checkPluginName(input);
  case "pattern": return checkPattern(input);
  case "category": return checkCategory(input);
  case "searchId": return checkSearchId(input);
  case "installReadback": return installReadback(input);
  case "magnetHash": { var h = magnetHash(input); return h ? { ok: true, normalised: h } : { ok: false }; }
  case "row": return { ok: true, normalised: sanitizeRow(input) };
  default: return refuse("unknown rule");
  }
}

// ---- results --------------------------------------------------------------------------------

function plainText(value) {
  return typeof value === "string" ? value : "";
}

// engineFor(engine, siteUrl, plugins) -> the plugin a result belongs to:
// its engineName, or, when that is empty, the installed plugin whose url
// is the result's siteUrl (Ruling FF); "" (the other bucket) otherwise.
function engineFor(engine, siteUrl, plugins) {
  if (engine !== "") return engine;
  var list = plugins || [];
  for (var i = 0; i < list.length; i++) {
    var p = list[i];
    if (p && typeof p.name === "string" && p.name !== "" && typeof p.url === "string" && p.url !== "" && p.url === siteUrl) return p.name;
  }
  return OTHER;
}

function enginesOf(sources, plugins) {
  var out = [];
  for (var i = 0; i < sources.length; i++) {
    var e = engineFor(sources[i].engine, sources[i].site, plugins);
    if (out.indexOf(e) === -1) out.push(e);
  }
  return out;
}

// resultFrom(raw, seq, plugins) -> the window's row: the sanitised
// fields, the raw links (checked only when used), the plugin (engine: the
// first of engines; "" is the other bucket), where each plugin's copy came
// from (sources), the infohashes and the merge key. seq is its arrival
// order.
function resultFrom(raw, seq, plugins) {
  var r = raw && typeof raw === "object" ? raw : {};
  var shown = sanitizeRow(r);
  var link = plainText(r.fileUrl);
  var hash = magnetHash(link);
  var site = plainText(r.siteUrl);
  var sources = [{ engine: plainText(r.engineName), site: site }];
  var engines = enginesOf(sources, plugins);
  var key = hash ? "h:" + (hash.v1 || hash.v2) : (link !== "" ? "u:" + link : "s:" + seq);
  return {
    key: key,
    seq: seq,
    name: shown.name,
    size: shown.size,
    seeds: shown.seeds,
    peers: shown.peers,
    published: shown.published,
    fileUrl: link,
    descrLink: plainText(r.descrLink),
    siteUrl: site,
    engine: engines[0],
    engines: engines,
    sources: sources,
    v1: hash ? hash.v1 : null,
    v2: hash ? hash.v2 : null
  };
}

function withSources(row, sources, plugins) {
  var copy = {};
  for (var k in row) copy[k] = row[k];
  copy.sources = sources;
  copy.engines = enginesOf(sources, plugins);
  copy.engine = copy.engines[0];
  return copy;
}

// mergeResults(held, raws, firstSeq, plugins) -> {rows, added, updated}:
// held (the rows so far, not changed) plus raws. A raw row whose key (its
// infohash, else its link) is already held adds its plugin to that row
// instead (OV11: rows from different plugins with the same hash are
// merged). added: the new rows, in order; updated: the keys of held rows
// that gained a plugin.
function mergeResults(held, raws, firstSeq, plugins) {
  var rows = (held || []).slice();
  var at = {};
  for (var i = 0; i < rows.length; i++) at[rows[i].key] = i;
  var heldCount = rows.length;
  var addedKeys = [], updated = [];
  var list = raws || [];
  for (var j = 0; j < list.length; j++) {
    var r = resultFrom(list[j], (Number(firstSeq) || 0) + j, plugins);
    if (Object.prototype.hasOwnProperty.call(at, r.key)) {
      var idx = at[r.key];
      var cur = rows[idx];
      if (cur.engines.indexOf(r.engine) !== -1) continue;
      rows[idx] = withSources(cur, cur.sources.concat(r.sources), plugins);
      if (idx < heldCount && updated.indexOf(r.key) === -1) updated.push(r.key);
      continue;
    }
    at[r.key] = rows.length;
    rows.push(r);
    addedKeys.push(r.key);
  }
  var added = addedKeys.map(function(key) { return rows[at[key]]; });
  return { rows: rows, added: added, updated: updated };
}

// remapEngines(rows, plugins) -> the rows with each plugin worked out
// again from the current plugin list (it may arrive after the rows).
function remapEngines(rows, plugins) {
  return (rows || []).map(function(r) { return withSources(r, r.sources || [{ engine: r.engine, site: r.siteUrl }], plugins); });
}

// pluginCounts(rows) -> {engine: n}: how many rows each plugin found ("" is
// the other bucket).
function pluginCounts(rows) {
  var out = {};
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    var e = list[i].engines || [list[i].engine];
    for (var j = 0; j < e.length; j++) out[e[j]] = (out[e[j]] || 0) + 1;
  }
  return out;
}

// pluginLabel(engine, plugins) -> the plugin's fullName when installed,
// else its name; "other" for the other bucket. Plain text, cleaned.
function pluginLabel(engine, plugins) {
  if (engine === OTHER) return OTHER_LABEL;
  var list = plugins || [];
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].name === engine) {
      var full = cleanName(list[i].fullName);
      return full !== EMPTY ? full : cleanName(engine);
    }
  }
  return cleanName(engine);
}

// pluginColumn(plugins, counts, total) -> the Plugins column's rows:
// All results first, then each enabled plugin and each plugin with
// results (installed order, then the rest), then the other bucket when it
// has any. {kind: "all"|"plugin", engine, label, count}.
function pluginColumn(plugins, counts, total, recent) {
  var c = counts || {};
  var out = [{ kind: "all", engine: null, label: "All results", count: Number(total) || 0 }];
  var seen = {};
  var list = plugins || [];
  for (var i = 0; i < list.length; i++) {
    var p = list[i];
    if (!p || typeof p.name !== "string" || p.name === OTHER) continue;
    if (p.enabled !== true && !c[p.name]) continue;
    seen[p.name] = true;
    out.push({ kind: "plugin", engine: p.name, label: pluginLabel(p.name, list), count: c[p.name] || 0 });
  }
  var rest = Object.keys(c).filter(function(e) { return e !== OTHER && !seen[e]; }).sort();
  for (var j = 0; j < rest.length; j++) out.push({ kind: "plugin", engine: rest[j], label: pluginLabel(rest[j], list), count: c[rest[j]] });
  if (c[OTHER]) out.push({ kind: "plugin", engine: OTHER, label: OTHER_LABEL, count: c[OTHER] });
  // Recent (Ruling FF): cursor rows too; Enter on one searches it again.
  var rq = recent || [];
  for (var r = 0; r < rq.length; r++) out.push({ kind: "recent", engine: null, label: String(rq[r]), query: String(rq[r]), count: null });
  return out;
}

// matchesPlugin(row, engine) -> whether the row shows under that plugin
// (null: All results).
function matchesPlugin(row, engine) {
  if (engine === null || engine === undefined) return true;
  return (row.engines || [row.engine]).indexOf(engine) !== -1;
}

// ---- the library match (OV11) -------------------------------------------------------------

// librarySet(torrents) -> {v1, v2, v2id}: each a {id: true} map,
// lowercased. v1: every torrent's hash and infohash_v1 (what a btih
// matches); v2: every infohash_v2 (what a btmh matches, 1220 stripped);
// v2id: the hash of a torrent whose row carries neither field (an older
// helper; qBittorrent's id of a v2-only torrent is its first 40 hex, so
// that hash-only row still matches a btmh).
function librarySet(torrents) {
  var out = { v1: {}, v2: {}, v2id: {} };
  var list = torrents || [];
  function put(map, id) { if (typeof id === "string" && id !== "") map[id.toLowerCase()] = true; }
  for (var i = 0; i < list.length; i++) {
    var t = list[i] || {};
    put(out.v1, t.hash);
    put(out.v1, t.infohash_v1);
    put(out.v2, t.infohash_v2);
    var none = function(x) { return typeof x !== "string" || x === ""; };
    if (none(t.infohash_v1) && none(t.infohash_v2)) put(out.v2id, t.hash);
  }
  return out;
}

// inLibrary(v1, v2, set): btih against hash/infohash_v1, btmh (1220
// already stripped) against infohash_v2, and its first 40 hex against the
// hash of a row with neither infohash field.
function inLibrary(v1, v2, set) {
  var s = set || {};
  var a = s.v1 || {}, b = s.v2 || {}, c = s.v2id || {};
  if (typeof v1 === "string" && v1 !== "" && a[v1.toLowerCase()] === true) return true;
  if (typeof v2 === "string" && v2 !== "") {
    var k = v2.toLowerCase();
    if (b[k] === true || c[k.slice(0, 40)] === true) return true;
  }
  return false;
}

// ---- the sort ------------------------------------------------------------------------------

var SORT_CYCLE = ["seeds", "name", "size", "peers", "published", "plugin"];
var SORT_DEFAULT_DESC = { seeds: true, name: false, size: true, peers: true, published: true, plugin: false };
var SORT_FIELD = { seeds: "seeds", size: "size", peers: "peers", published: "published" };
var SORT_NAMES = { seeds: "seeds", name: "name", size: "size", peers: "peers", published: "published", plugin: "plugin" };

function nextSort(mode) {
  var i = SORT_CYCLE.indexOf(mode);
  var next = SORT_CYCLE[(i + 1) % SORT_CYCLE.length];
  return { sort: next, desc: SORT_DEFAULT_DESC[next] };
}

function validSort(mode) {
  return SORT_CYCLE.indexOf(mode) !== -1 ? mode : "seeds";
}

// sortResults(rows, mode, desc, plugins) -> a sorted copy. "—" sorts last
// in either direction; ties keep the arrival order.
function sortResults(rows, mode, desc, plugins) {
  var m = validSort(mode);
  var dir = desc === true ? -1 : 1;
  var out = (rows || []).slice();
  out.sort(function(a, b) {
    var c = 0;
    if (SORT_FIELD[m]) {
      var x = a[SORT_FIELD[m]], y = b[SORT_FIELD[m]];
      var xe = typeof x !== "number", ye = typeof y !== "number";
      if (xe !== ye) return xe ? 1 : -1;
      if (!xe && x !== y) c = (x < y ? -1 : 1) * dir;
    } else {
      var sx = m === "name" ? a.name : pluginLabel(a.engine, plugins);
      var sy = m === "name" ? b.name : pluginLabel(b.engine, plugins);
      var xa = sx === EMPTY, ya = sy === EMPTY;
      if (xa !== ya) return xa ? 1 : -1;
      var lx = sx.toLowerCase(), ly = sy.toLowerCase();
      if (lx !== ly) c = (lx < ly ? -1 : 1) * dir;
    }
    return c !== 0 ? c : a.seq - b.seq;
  });
  return out;
}

// sortTitle(mode, desc) -> "sorted by seeds" (▾ descending, ▴ ascending).
function sortTitle(mode, desc) {
  return "sorted by " + SORT_NAMES[validSort(mode)] + (desc === true ? " ▾" : " ▴");
}

// ---- state copy ------------------------------------------------------------------------------

// runText(state, k) -> the query bar's right side (OV1): running (or
// starting) "searching… · k results", "done · k results", and "stopped ·
// k results" only after Esc (or when qBittorrent lost the job); nothing
// before the first search or after a failed start.
function runText(state, k) {
  var n = Number(k) || 0;
  if (state === "starting" || state === "running") return fill(WINDOW.running, { k: n });
  if (state === "done") return fill(WINDOW.done, { k: n });
  if (state === "stopped" || state === "gone") return fill(WINDOW.stopped, { k: n });
  return "";
}

function cappedText(capped, total) {
  return capped === true ? fill(WINDOW.capped, { n: Number(total) || 0 }) : "";
}

// emptyText(c) -> the results area's empty state, or "" when rows show.
// c: {pluginsLoaded, pluginCount, state, query, rows, visible, filter}:
// rows is every result, visible those the Plugins column's filter shows,
// filter that plugin's label (a filter that hides every row says so).
function emptyText(c) {
  var x = c || {};
  if ((Number(x.rows) || 0) > 0) {
    if (x.visible !== undefined && (Number(x.visible) || 0) === 0 && x.filter) return fill(WINDOW.noPluginResults, { plugin: x.filter });
    return "";
  }
  if (x.pluginsLoaded === true && (Number(x.pluginCount) || 0) === 0 && (x.state === "none" || x.state === "failed" || !x.state)) return WINDOW.noPlugins;
  if (x.state === "done" || x.state === "stopped" || x.state === "gone") return fill(WINDOW.noResults, { q: qtTrim(String(x.query || "")) });
  return WINDOW.noResultsYet;
}

// pluginsTitle(plugins) -> the plugins overlay's counter ("3 installed · 2 enabled").
function pluginsTitle(plugins) {
  var list = plugins || [];
  var on = 0;
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].enabled === true) on++;
  return list.length + " installed · " + on + " enabled";
}

function enabledCount(plugins) {
  var list = plugins || [];
  var on = 0;
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].enabled === true) on++;
  return on;
}

// ---- categories (Ruling FB) -------------------------------------------------------------------

// categoryRows(plugins) -> [{id, name}]: "all" first, then each category an
// enabled plugin lists, once, in qBittorrent's order, titled with
// qBittorrent's name for it.
function categoryRows(plugins) {
  var names = {};
  var list = plugins || [];
  for (var i = 0; i < list.length; i++) {
    var p = list[i];
    if (!p || p.enabled !== true || !Array.isArray(p.supportedCategories)) continue;
    for (var j = 0; j < p.supportedCategories.length; j++) {
      var c = p.supportedCategories[j] || {};
      var id = typeof c === "string" ? c : c.id;
      if (CATEGORY_ORDER.indexOf(id) === -1 || names[id]) continue;
      var n = typeof c === "object" ? cleanName(c.name) : EMPTY;
      names[id] = n !== EMPTY ? n : CATEGORY_NAMES[id];
    }
  }
  var out = [{ id: ALL_CATEGORIES.id, name: ALL_CATEGORIES.name }];
  for (var k = 0; k < CATEGORY_ORDER.length; k++) if (names[CATEGORY_ORDER[k]]) out.push({ id: CATEGORY_ORDER[k], name: names[CATEGORY_ORDER[k]] });
  return out;
}

// effectiveCategory(id, plugins) -> id while an enabled plugin supports
// it, else "all".
function effectiveCategory(id, plugins) {
  var rows = categoryRows(plugins);
  for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return id;
  return "all";
}

function categoryName(id, plugins) {
  var rows = categoryRows(plugins);
  for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i].name;
  return ALL_CATEGORIES.name;
}

// recentPush(list, query) -> Recent with query first, once, at most 8.
function recentPush(list, query) {
  var q = qtTrim(String(query || ""));
  var out = q === "" ? [] : [q];
  var l = list || [];
  for (var i = 0; i < l.length && out.length < RECENT_MAX; i++) if (l[i] !== q) out.push(l[i]);
  return out;
}

// ---- confirms (A1, D3, D4) and notes ------------------------------------------------------------

// resultHost(result) -> the host an add confirm names: the link's own
// (https), else the result's site, else its page, else "—".
function resultHost(result) {
  var r = result || {};
  var a = checkAddLink([r.fileUrl || "", r.engine || ""]);
  if (a.ok && a.host) return a.host;
  var site = checkPageLink(r.siteUrl || "");
  if (site.ok) return site.host;
  var page = checkPageLink(r.descrLink || "");
  if (page.ok) return page.host;
  return EMPTY;
}

// addPlan(result, librarySet) -> what Enter does: {kind: "library", note}
// (already there: adds nothing), {kind: "refuse", note}, or {kind:
// "confirm", line, link, plugin, via}.
function addPlan(result, sizeText, set) {
  var r = result || {};
  if (inLibrary(r.v1, r.v2, set)) return { kind: "library", note: WINDOW.inLibrary };
  var plugin = typeof r.engine === "string" ? r.engine : "";
  var a = checkAddLink([r.fileUrl || "", plugin]);
  if (!a.ok) return { kind: "refuse", note: a.message };
  return { kind: "confirm", line: fill(WINDOW.addConfirm, { name: r.name, size: sizeText, host: resultHost(r) }),
    link: r.fileUrl, plugin: plugin, via: a.normalised };
}

// copyableLink(link) -> whether y copies it: a magnet or an http(s) link,
// free of BAD characters (it never reaches a note).
function copyableLink(link) {
  var s = typeof link === "string" ? link : "";
  if (s === "" || BAD.test(s)) return false;
  return /^magnet:\?/i.test(s) || startsWithCi(s, "https://") || startsWithCi(s, "http://");
}

function openConfirm(host) {
  return fill(WINDOW.openConfirm, { host: host });
}

function installConfirm(name, host) {
  return { line: fill(WINDOW.installConfirm, { name: name, host: host }), detail: WINDOW.installDetail };
}

function uninstallConfirm(name) {
  return fill(WINDOW.uninstallConfirm, { name: name });
}

// addedNote(via, link, name) -> the done note once qbt search add
// succeeded: "Sent …" for via "plugin" and an https .torrent (whose hash
// isn't known), or null for a magnet, which says "Added <name>." only once
// its hash is in the library (addedWhenIn).
function addedNote(via, link, name) {
  if (via === "add" && magnetHash(link)) return null;
  return fill(WINDOW.sent, { name: name });
}

function addedText(name) {
  return fill(WINDOW.added, { name: name });
}

// ---- the sidecar's replies (OV7, Ruling FB) ------------------------------------------------------

// replyAction(reply, jobId, held) -> what the window does with a
// {"type":"search"} reply: "stale" (another job, or none), "gone" (the
// job is gone), "resend" (its offset isn't the rows held: re-send the
// watch at `held`), or "apply".
function replyAction(reply, jobId, held) {
  var r = reply || {};
  var id = Number(jobId) || 0;
  if (id <= 0 || r.id !== id) return "stale";
  if (r.error === "gone") return "gone";
  if (typeof r.offset !== "number" || !Array.isArray(r.rows) || r.offset !== (Number(held) || 0)) return "resend";
  return "apply";
}

// isFinal(reply) -> Stopped and every row up to min(total, 2000) read.
function isFinal(reply) {
  var r = reply || {};
  var rows = Array.isArray(r.rows) ? r.rows.length : 0;
  return r.status === "Stopped" && Number(r.offset) + rows === Math.min(Number(r.total) || 0, ROW_CAP);
}

if (typeof module !== "undefined") {
  module.exports = {
    EMPTY: EMPTY,
    WINDOW: WINDOW,
    SENTENCES: SENTENCES,
    MSG: MSG,
    ROW_CAP: ROW_CAP,
    RECENT_MAX: RECENT_MAX,
    OTHER: OTHER,
    OTHER_LABEL: OTHER_LABEL,
    CATEGORY_ORDER: CATEGORY_ORDER,
    fill: fill,
    punycode: punycode,
    hostOf: hostOf,
    check: check,
    checkPluginUrl: checkPluginUrl,
    checkPageLink: checkPageLink,
    checkAddLink: checkAddLink,
    magnetHash: magnetHash,
    sanitizeRow: sanitizeRow,
    cleanName: cleanName,
    checkPluginName: checkPluginName,
    checkPattern: checkPattern,
    checkCategory: checkCategory,
    checkSearchId: checkSearchId,
    installReadback: installReadback,
    resultFrom: resultFrom,
    mergeResults: mergeResults,
    pluginCounts: pluginCounts,
    pluginLabel: pluginLabel,
    pluginColumn: pluginColumn,
    matchesPlugin: matchesPlugin,
    librarySet: librarySet,
    inLibrary: inLibrary,
    SORT_CYCLE: SORT_CYCLE,
    nextSort: nextSort,
    validSort: validSort,
    sortResults: sortResults,
    sortTitle: sortTitle,
    runText: runText,
    cappedText: cappedText,
    emptyText: emptyText,
    pluginsTitle: pluginsTitle,
    enabledCount: enabledCount,
    categoryRows: categoryRows,
    effectiveCategory: effectiveCategory,
    categoryName: categoryName,
    recentPush: recentPush,
    qtTrim: qtTrim,
    engineFor: engineFor,
    remapEngines: remapEngines,
    resultHost: resultHost,
    addPlan: addPlan,
    copyableLink: copyableLink,
    openConfirm: openConfirm,
    installConfirm: installConfirm,
    uninstallConfirm: uninstallConfirm,
    addedNote: addedNote,
    addedText: addedText,
    replyAction: replyAction,
    isFinal: isFinal
  };
}
