.pragma library

// The link and text rules Search and RSS share (slice 5b0, eng D10), moved
// verbatim out of SearchView.js: the URL text rule (Ruling FB: split by
// hand, never a URL library; a non-ASCII host label becomes xn-- plus RFC
// 3492 punycode), the page-link rule, the magnet infohash match, the
// library match (OV11), and the text helpers (row-name cleaning, Qt's trim).
// No I/O, no Date, no Qt objects. It imports nothing.
// tests/link-rules.test.js runs it in node against
// tests/fixtures/link-rules-cases.json; lib/linkrules.py is the python twin
// of the page-link rule (magnetHash is JS-only).
//
// The `.pragma library` line above is QML-only; the node test strips it.

var EMPTY = "—";

// The rules' own messages (the case file's `message`s).
var MSG_LINK = {
  pageEmpty: "That result has no page link.",
  pageBad: "That page link has spaces, control characters or \\ in it.",
  pageScheme: "That page link isn't http or https.",
  pageUserinfo: "That page link has a user name or password in it.",
  pageHost: "That page link has no valid host."
};

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

// pageLink (d, D3): {ok, host} or {ok:false, message}.
function checkPageLink(input) {
  var s = typeof input === "string" ? input : "";
  if (s === "") return refuse(MSG_LINK.pageEmpty);
  if (BAD.test(s)) return refuse(MSG_LINK.pageBad);
  var len = startsWithCi(s, "https://") ? 8 : (startsWithCi(s, "http://") ? 7 : 0);
  if (len === 0) return refuse(MSG_LINK.pageScheme);
  var h = hostOf(splitUrl(s, len).authority);
  if (h.userinfo) return refuse(MSG_LINK.pageUserinfo);
  if (!h.ok) return refuse(MSG_LINK.pageHost);
  return { ok: true, host: h.host };
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

function plainText(value) {
  return typeof value === "string" ? value : "";
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

// check(kind, input) -> the rule of that kind, {ok, message, normalised, host}
// as SearchView.check shapes it, for the two kinds this file owns.
function check(kind, input) {
  switch (kind) {
  case "pageLink": return checkPageLink(input);
  case "magnetHash": { var h = magnetHash(input); return h ? { ok: true, normalised: h } : { ok: false }; }
  default: return refuse("unknown rule");
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    EMPTY: EMPTY, MSG_LINK: MSG_LINK,
    BAD: BAD, BIDI: BIDI, CONTROLS: CONTROLS, CONTROL: CONTROL, QT_SPACE: QT_SPACE,
    codePoints: codePoints, punycode: punycode, splitUrl: splitUrl, portOk: portOk, hostOf: hostOf,
    startsWithCi: startsWithCi, qtTrim: qtTrim, cleanName: cleanName, plainText: plainText,
    base32Hex: base32Hex, magnetHash: magnetHash, checkPageLink: checkPageLink,
    librarySet: librarySet, inLibrary: inLibrary, refuse: refuse, fill: fill, check: check
  };
}
