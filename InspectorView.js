.pragma library
.import "Model.js" as Model

// Pure inspector logic for the OmaqBT window's inspector pane (InspectorPane,
// InspectorList, PiecesBar, SpeedChart). No I/O, no Date, no Qt objects:
// everything comes in through arguments, so tests/inspector-view.test.js can
// run it in node. Imports only Model.js -- never ClientView.js, since two
// `.pragma library` modules must not import each other (ClientView.js may
// import this file for glue).
//
// The `.pragma library` / `.import` lines above are QML-only. The node
// test strips them and runs this file in a vm context with `Model`
// supplied (see the test's loader), because node can't parse them and QML
// can't `require`.

// --- Small formatting helpers (private) -------------------------------------

// commas(n) -> n with thousands separators: 1776 -> "1,776".
function commas(n) {
  var s = String(Math.round(Number(n) || 0));
  var neg = s.charAt(0) === "-";
  if (neg) s = s.slice(1);
  s = s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return neg ? "-" + s : s;
}

// durationText(seconds) -> "2h 14m" (no seconds shown); "0m" at zero.
function durationText(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0));
  var h = Math.floor(s / 3600);
  var m = Math.floor((s % 3600) / 60);
  if (h > 0) return h + "h " + m + "m";
  return m + "m";
}

// stripPointZero("1.0 MiB") -> "1 MiB". Only used for the Pieces field's
// piece-size text: Model.sizeText always keeps one decimal under 100 in a
// unit, which reads oddly for a piece size ("1.0 MiB" instead of "1 MiB").
function stripPointZero(text) {
  return String(text || "").replace(/\.0(?=\s|$)/, "");
}

// numOrNull(v) -> a finite Number, or null when v is missing/NaN.
function numOrNull(v) {
  var n = Number(v);
  return v === undefined || v === null || !isFinite(n) ? null : n;
}

// posOrNull(v) -> numOrNull(v), but negative values are also null: qbt's
// -1 sentinel (and any other negative) means "unknown", shown as "—".
function posOrNull(v) {
  var n = numOrNull(v);
  return n === null || n < 0 ? null : n;
}

// elideHash(hash) -> the first 8 and last 16 characters, joined by "…"
// ("223f576c…3b054ced6a8adab3"); short input is returned unchanged.
function elideHash(hash) {
  var h = String(hash || "");
  if (h.length <= 8 + 16) return h;
  return h.slice(0, 8) + "…" + h.slice(-16);
}

// --- redactUrl ----------------------------------------------------------

// scheme://authority(/path?query#fragment)? -- authority is everything up
// to the first /, ? or # (never "\" itself here -- see splitAuthoritySpan;
// this regex only finds the outer span that "\" is judged inside).
var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]+)([\s\S]*)$/;

// stripUserinfo(authority) -> authority with any "user[:pass]@" prefix
// removed, splitting at the LAST "@" (I1: a tracker's passkey can ride in
// a URL's userinfo, e.g. "https://user:abc123@t.example/announce" -- the
// shown host must never carry it). WHATWG URL parsing and qBittorrent both
// split userinfo at the last "@", not the first, so a password that itself
// contains "@" (e.g. "user:abc@123@t.example") still yields the real host.
// Used by splitAuthoritySpan once "\" has been ruled out or resolved.
function stripUserinfo(authority) {
  return String(authority === undefined || authority === null ? "" : authority).replace(/^[\s\S]*@/, "");
}

// splitAuthoritySpan(span) -> {ambiguous: true} | {ambiguous: false, host,
// tail}. `span` is the authority candidate up to the first "/", "?" or "#"
// (never itself split on "\") -- i.e. what libtorrent would treat as the
// whole authority. WHATWG URL parsing treats "\" like "/" inside a
// special-scheme authority; libtorrent does not and reads it as a literal
// userinfo/host character. When `span` contains both "\" and "@" it is
// genuinely ambiguous which parser qBittorrent's tracker is using --
// stopping at "\" (WHATWG) can turn part of the real userinfo into a fake
// "host" that gets shown ("us\SEC@t.example/x" would read host "us",
// leaking the "us" prefix of what is actually the username "us\SEC").
// Ruling V: redact the whole authority as "…" in that case, showing
// nothing. With "\" and no "@", there is nothing for the backslash to be
// ambiguous WITH, so it still terminates the authority (WHATWG's rule:
// "udp://t.example:1337\abc123" still reads host "t.example:1337"). With
// "@" and no "\", split at the last "@" as stripUserinfo always has.
function splitAuthoritySpan(span) {
  var s = String(span === undefined || span === null ? "" : span);
  var hasBackslash = s.indexOf("\\") !== -1;
  var hasAt = s.indexOf("@") !== -1;
  if (hasBackslash && hasAt) return { ambiguous: true };
  if (hasBackslash) {
    var cut = s.indexOf("\\");
    return { ambiguous: false, host: s.slice(0, cut), tail: s.slice(cut) };
  }
  return { ambiguous: false, host: stripUserinfo(s), tail: "" };
}

// genericHead(s) -> {head, cut, ambiguous} for a URL that isn't
// scheme://authority(...) (M5: schemeless, or otherwise unparseable, e.g.
// "t.example/abc123/announce" or a bare "?passkey=abc123"): `head` is
// everything up to the first /, ? or # with any userinfo resolved via
// splitAuthoritySpan (never carrying a userinfo passkey, and "…" alone
// when the span is Ruling-V ambiguous), and `cut` is true when there is
// something past the shown host to redact (a delimiter was found, or a
// non-ambiguous "\" inside the span itself hid content) -- so a caller can
// tell "nothing to redact" from "redacted down to nothing". `ambiguous`
// means `head` is already the complete, scheme-less redacted output ("…"),
// never to be suffixed with "/…". Shared by redactUrl (path/query never
// shown) and urlHost (the host column, which must never carry a userinfo
// passkey either).
function genericHead(s) {
  var text = String(s === undefined || s === null ? "" : s);
  var delim = -1;
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i);
    if (c === "/" || c === "?" || c === "#") { delim = i; break; }
  }
  var span = delim === -1 ? text : text.slice(0, delim);
  var split = splitAuthoritySpan(span);
  if (split.ambiguous) return { head: "…", cut: true, ambiguous: true };
  return { head: split.host, cut: delim !== -1 || split.tail !== "" };
}

// redactUrl(url) -> "scheme://host[:port]/…" when there is a path or query
// beyond "/", "scheme://host[:port]" when there is neither, "scheme://…"
// when splitAuthoritySpan finds Ruling-V's "\" + "@" ambiguity (nothing
// from the authority shown at all), or (M5) genericHead's cut-and-append
// for anything that doesn't parse as scheme://authority(...). Never
// returns any part of a path, query or userinfo.
function redactUrl(url) {
  var s = String(url === undefined || url === null ? "" : url);
  var m = URL_RE.exec(s);
  if (m) {
    var split = splitAuthoritySpan(m[2]);
    if (split.ambiguous) return m[1] + "://…";
    var rest = split.tail + (m[3] || "");
    if (rest === "" || rest === "/") return m[1] + "://" + split.host;
    return m[1] + "://" + split.host + "/…";
  }
  var g = genericHead(s);
  if (g.ambiguous) return g.head;
  return g.cut ? g.head + "/…" : g.head;
}

// urlHost(url) -> the "host[:port]" authority redactUrl also uses (never
// its userinfo), "…" when splitAuthoritySpan finds Ruling-V's ambiguity,
// or genericHead's head for a URL that doesn't parse as
// scheme://authority(...) -- so the host column can never carry a
// passkey either, scheme or not.
function urlHost(url) {
  var s = String(url === undefined || url === null ? "" : url);
  var m = URL_RE.exec(s);
  if (m) {
    var split = splitAuthoritySpan(m[2]);
    return split.ambiguous ? "…" : split.host;
  }
  return genericHead(s).head;
}

// --- trackerUrlError / peerError / hasPipe (F5, F13) -----------------------
//
// The same rules as qbt's valid_tracker_url / valid_peer, in qbt's order,
// only so the window can show an inline message; qbt still validates.

var TRACKER_URL_MAX = 2048;
var TRACKER_SCHEME_RE = /^(udp|https?|wss):\/\//;

// hasPipe(url) -> whether url has a "|": qBittorrent's WebUI joins a
// torrent's trackers with "|", so such a tracker can't be edited or
// removed through it (F13).
function hasPipe(url) {
  return String(url === undefined || url === null ? "" : url).indexOf("|") !== -1;
}

// What the window says instead of acting on such a tracker (qbt dies with
// the same words).
var PIPE_NOTE = "This tracker's URL can't be edited through the WebUI API.";
var UNUSABLE_NOTE = "This tracker's URL can't be edited here.";

// trackerUrlError(text) -> "" for a URL qbt accepts, else the message.
// Checks, in qbt's order: at most 2048 characters; udp://, http://,
// https:// or wss:// (case-sensitive, as in qbt); printable ASCII only
// (0x21-0x7E, Ruling AE: so characters and bytes agree with qbt's LC_ALL=C
// count, and no Unicode space slips through); no "|".
function trackerUrlError(text) {
  var s = String(text === undefined || text === null ? "" : text);
  if (s.length > TRACKER_URL_MAX) return "That URL is too long.";
  if (!TRACKER_SCHEME_RE.test(s)) return "Use a udp://, http://, https:// or wss:// URL.";
  if (/[\t\n\v\f\r ]/.test(s) || hasPipe(s)) return "No spaces or | in a tracker URL.";
  if (/[^\x21-\x7e]/.test(s)) return "Use only plain ASCII characters in a tracker URL.";
  return "";
}

// trackerRefusal(url) -> "" when `c` and `x` can act on a stored tracker
// URL, else the note the window shows instead: PIPE_NOTE for a "|" (F13),
// UNUSABLE_NOTE for anything else qbt's tracker-edit / tracker-remove
// would reject (trackerUrlError: an uppercase scheme, whitespace,
// non-ASCII, too long), so nobody confirms an action that can't run.
function trackerRefusal(url) {
  if (hasPipe(url)) return PIPE_NOTE;
  return trackerUrlError(url) !== "" ? UNUSABLE_NOTE : "";
}

// validPort: 1-5 ASCII digits (qbt bounds the length before any
// arithmetic, so a huge port can't wrap), value 1-65535.
function validPort(text) {
  if (!/^[0-9]{1,5}$/.test(text)) return false;
  var n = parseInt(text, 10);
  return n >= 1 && n <= 65535;
}

// peerError(ipPort) -> "" for exactly one IPv4:port (each octet 0-255) or
// [IPv6]:port (hex digits and colons only), port 1-65535; else a message.
// ASCII only, like qbt's [[:digit:]]/[[:xdigit:]] classes.
function peerError(ipPort) {
  var s = String(ipPort === undefined || ipPort === null ? "" : ipPort);
  var bad = "That isn't an ip:port.";
  if (s === "" || /[^\x00-\x7f]/.test(s)) return bad;
  var v6 = /^\[([0-9a-fA-F:]+)\]:([0-9]+)$/.exec(s);
  if (v6) return validPort(v6[2]) ? "" : bad;
  var v4 = /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]+)$/.exec(s);
  if (!v4) return bad;
  for (var i = 1; i <= 4; i++) {
    if (parseInt(v4[i], 10) > 255) return bad;
  }
  return validPort(v4[5]) ? "" : bad;
}

// --- trackerRows ----------------------------------------------------------

var PSEUDO_TRACKER_KIND = {
  "** [DHT] **": "dht",
  "** [PeX] **": "pex",
  "** [LSD] **": "lsd"
};

var TRACKER_STATUS = {
  0: { glyph: "·", tone: "muted", word: "disabled" },
  1: { glyph: "·", tone: "muted", word: "not contacted" },
  2: { glyph: "●", tone: "accent", word: "working" },
  3: { glyph: "↻", tone: "muted", word: "updating" },
  4: { glyph: "!", tone: "urgent", word: "not working" }
};
var TRACKER_STATUS_ERROR = { glyph: "!", tone: "urgent", word: "error" };

function trackerStatusInfo(status) {
  return TRACKER_STATUS[Number(status)] || TRACKER_STATUS_ERROR;
}

// countOrDash(v) -> "—" for a missing or negative count (qbt's -1
// sentinel), else the number as text.
function countOrDash(v) {
  var n = Number(v);
  if (v === undefined || v === null || !isFinite(n) || n < 0) return "—";
  return String(n);
}

// trackerRows(list) -> {summary, rows} from qBittorrent's
// torrents/trackers array. The three pseudo-trackers (DHT/PeX/LSD) fold
// into `summary` and never appear in `rows`; real trackers' seeds/peers
// (skipping -1) sum into summary.seeds/peers.
function trackerRows(list) {
  var input = Array.isArray(list) ? list : [];
  var summary = { dht: "—", pex: "—", lsd: "—", seeds: 0, peers: 0 };
  var rows = [];
  for (var i = 0; i < input.length; i++) {
    var t = input[i] || {};
    var url = String(t.url === undefined || t.url === null ? "" : t.url);
    var kind = PSEUDO_TRACKER_KIND[url];
    if (kind) {
      summary[kind] = Number(t.status) === 0 ? "off" : "on";
      continue;
    }
    var seeds = Number(t.num_seeds);
    if (isFinite(seeds) && seeds >= 0) summary.seeds += seeds;
    var peers = Number(t.num_leeches);
    if (isFinite(peers) && peers >= 0) summary.peers += peers;
    var info = trackerStatusInfo(t.status);
    rows.push({
      key: url,
      url: url,
      host: urlHost(url),
      shownUrl: redactUrl(url),
      // Why c and x can't act on it ("" when they can).
      refusal: trackerRefusal(url),
      glyph: info.glyph,
      tone: info.tone,
      statusWord: info.word,
      message: Model.plainText(t.msg),
      tier: t.tier,
      seeds: countOrDash(t.num_seeds),
      peers: countOrDash(t.num_leeches),
      // Seconds to the next announce (qbt 5.x); null when absent or <= 0.
      nextAnnounce: posOrNull(t.next_announce) || null
    });
  }
  return { summary: summary, rows: rows };
}

// --- peerRows / peerSummary -------------------------------------------------

// peerClientText(client, peerIdClient) -> the client name, or
// "Unknown (<peer id>)" when qbt hasn't resolved one yet, or plain
// "Unknown" with neither.
function peerClientText(client, peerIdClient) {
  var c = Model.plainText(client);
  if (c !== "") return c;
  var pid = Model.plainText(peerIdClient);
  if (pid !== "") return "Unknown (" + pid + ")";
  return "Unknown";
}

// peerRows(peersObject) -> rows from sync/torrentPeers' `peers` object
// (keyed by "ip:port"), sorted by down desc, then up desc, then key asc
// (stable between refreshes since a tie always breaks the same way).
function peerRows(peersObject) {
  var obj = peersObject && typeof peersObject === "object" ? peersObject : {};
  var rows = [];
  for (var key in obj) {
    if (!Object.prototype.hasOwnProperty.call(obj, key)) continue;
    var p = obj[key] || {};
    var down = Number(p.dl_speed);
    if (!isFinite(down) || down < 0) down = 0;
    var up = Number(p.up_speed);
    if (!isFinite(up) || up < 0) up = 0;
    var progress = Number(p.progress);
    if (!isFinite(progress)) progress = 0;
    var country = Model.plainText(p.country_code).toUpperCase();
    var downloaded = Number(p.downloaded);
    if (!isFinite(downloaded) || downloaded < 0) downloaded = 0;
    rows.push({
      key: key,
      country: country === "" ? "—" : country,
      client: peerClientText(p.client, p.peer_id_client),
      has: Model.formatPercent(progress),
      progress: progress,
      down: down,
      up: up,
      downText: Model.formatCompactRate(down),
      upText: Model.formatCompactRate(up),
      ipPort: key,
      connection: Model.plainText(p.connection),
      downloaded: Model.sizeText(downloaded),
      flags: Model.plainText(p.flags),
      flagsDesc: Model.plainText(p.flags_desc)
    });
  }
  rows.sort(function(a, b) {
    if (b.down !== a.down) return b.down - a.down;
    if (b.up !== a.up) return b.up - a.up;
    if (a.key === b.key) return 0;
    return a.key < b.key ? -1 : 1;
  });
  return rows;
}

// peerSummary(rows) -> {peers, seeds} from peerRows' output (peers is the
// row count; seeds counts rows whose raw progress is >= 1). Feeds the pane
// title "17 peers · 14 seeds".
function peerSummary(rows) {
  var list = rows || [];
  var seeds = 0;
  for (var i = 0; i < list.length; i++) {
    var p = Number(list[i] && list[i].progress);
    if (isFinite(p) && p >= 1) seeds++;
  }
  return { peers: list.length, seeds: seeds };
}

// --- keyedIndex -------------------------------------------------------------

// keyedIndex(rows, key, previousIndex) -> the index of the row whose `key`
// equals `key`; else the previous index clamped into range; -1 for no rows.
function keyedIndex(rows, key, previousIndex) {
  var list = rows || [];
  if (list.length === 0) return -1;
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].key === key) return i;
  }
  var p = Number(previousIndex);
  if (!isFinite(p) || p < 0) p = 0;
  if (p > list.length - 1) p = list.length - 1;
  return p;
}

// --- binPieces / piecesLegend -----------------------------------------------

// binPieces(states, cells) -> [{glyph, tone}] of length `cells`, each cell
// covering a contiguous slice of `states` (floor(i*n/cells) ..
// floor((i+1)*n/cells)). When n < cells that slice can come out empty by
// the raw floor division at the low end (e.g. i=0 with n=10, cells=48);
// widen it to at least one piece so a piece that exists is never shown as
// "missing" purely because of where the bin boundary landed.
function binPieces(states, cells) {
  if (!Array.isArray(states) || states.length === 0) return [];
  var n = states.length;
  var c = Math.floor(Number(cells)) || 0;
  if (c <= 0) return [];
  var out = [];
  for (var i = 0; i < c; i++) {
    var start = Math.floor((i * n) / c);
    var end = Math.floor(((i + 1) * n) / c);
    if (end <= start) end = start + 1;
    if (end > n) end = n;
    var have = 0;
    var any = 0;
    for (var j = start; j < end; j++) {
      if (states[j] === 2) have++;
      if (states[j] === 1 || states[j] === 2) any++;
    }
    var total = end - start;
    if (total > 0 && have === total) out.push({ glyph: "█", tone: "accent" });
    else if (any > 0) out.push({ glyph: "▓", tone: "accent" });
    else out.push({ glyph: "░", tone: "dim" });
  }
  return out;
}

// piecesLegend(states) -> "pieces 612 of 1,776 · █ have ▓ partial ░ missing".
function piecesLegend(states) {
  var list = Array.isArray(states) ? states : [];
  var have = 0;
  for (var i = 0; i < list.length; i++) {
    if (list[i] === 2) have++;
  }
  return "pieces " + commas(have) + " of " + commas(list.length) +
    " · █ have ▓ partial ░ missing";
}

// --- noMetadata -------------------------------------------------------------

// noMetadata(row, props) -> props.has_metadata === false when props is an
// object carrying that field (true or false, either way it wins); else
// !(Number(row.size) > 0).
function noMetadata(row, props) {
  if (props && typeof props === "object" && Object.prototype.hasOwnProperty.call(props, "has_metadata")) {
    return props.has_metadata === false;
  }
  var r = row || {};
  return !(Number(r.size) > 0);
}

// --- infoGroups -------------------------------------------------------------

// infoGroups(props, fmtDate) -> [{title, fields:[{label, value, tone, note}]}]
// for the Info tab's Transfer and Torrent groups. Any missing or negative
// field shows "—"; props null shows every value as "—". `note` is "" on
// every field but Downloaded, which carries the muted "this session"
// suffix as a separate string so the pane can render it in its own tone.
function infoGroups(props, fmtDate) {
  var p = props && typeof props === "object" ? props : null;
  var fmt = typeof fmtDate === "function" ? fmtDate : function(s) { return Model.formatDate(s); };

  function get(key) { return p ? p[key] : undefined; }

  var downloaded = posOrNull(get("total_downloaded"));
  var downloadedSession = posOrNull(get("total_downloaded_session"));
  var uploaded = posOrNull(get("total_uploaded"));
  var wasted = posOrNull(get("total_wasted"));
  var nbConnections = posOrNull(get("nb_connections"));
  var nbConnectionsLimit = posOrNull(get("nb_connections_limit"));
  var timeElapsed = posOrNull(get("time_elapsed"));
  var seedingTime = posOrNull(get("seeding_time"));
  var additionDate = posOrNull(get("addition_date"));
  var piecesNum = numOrNull(get("pieces_num"));
  var pieceSize = posOrNull(get("piece_size"));
  var hash = p ? String(p.hash === undefined || p.hash === null ? "" : p.hash) : "";
  var isPrivate = p ? p.is_private : undefined;
  var comment = Model.plainText(p ? p.comment : "");

  var downloadedNote = "";
  if (downloadedSession !== null && downloadedSession > 0) {
    downloadedNote = "· " + Model.sizeText(downloadedSession) + " this session";
  }

  var activeValue = "—";
  if (timeElapsed !== null) {
    var seedingText = seedingTime === null ? "—" : durationText(seedingTime);
    activeValue = durationText(timeElapsed) + " · seeding " + seedingText;
  }

  var piecesValue = "—";
  if (piecesNum !== null && piecesNum > 0) {
    var sizeOfPiece = pieceSize === null ? 0 : pieceSize;
    piecesValue = commas(piecesNum) + " × " + stripPointZero(Model.sizeText(sizeOfPiece));
  }

  var privateValue = "—";
  if (isPrivate === true) privateValue = "yes";
  else if (isPrivate === false) privateValue = "no";

  function field(label, value, note) {
    return { label: label, value: value, tone: "fg", note: note || "" };
  }

  return [
    {
      title: "Transfer",
      fields: [
        field("Downloaded", downloaded === null ? "—" : Model.sizeText(downloaded), downloadedNote),
        field("Uploaded", uploaded === null ? "—" : Model.sizeText(uploaded)),
        field("Wasted", wasted === null ? "—" : Model.sizeText(wasted)),
        field("Connections", nbConnections === null || nbConnectionsLimit === null ? "—" : (nbConnections + " of " + nbConnectionsLimit)),
        field("Active", activeValue),
        field("Added", additionDate === null ? "—" : String(fmt(additionDate)))
      ]
    },
    {
      title: "Torrent",
      fields: [
        field("Hash", hash === "" ? "—" : elideHash(hash)),
        field("Pieces", piecesValue),
        field("Private", privateValue),
        field("Comment", comment === "" ? "—" : comment)
      ]
    }
  ];
}

// --- chartSeries -------------------------------------------------------------

// niceMax(sampleBytes) -> the smallest "nice" value >= sampleBytes: divide
// into the same 1024-based unit Model.sizeText would pick (so the result
// re-displays in that unit, or the next one up), then round the mantissa
// up to the nearest of {1, 2, 5, 10} × 10^k. A 5.8 MiB/s spike lands on 10
// MiB/s, not some odd decimal -- "a rounded-up maximum" reads cleanly.
var NICE_STEPS = [1, 2, 5, 10];
function niceMax(sampleBytes) {
  var n = Number(sampleBytes);
  if (!(n > 0)) return 1;
  var unitScale = 1;
  var steps = 0;
  while (n >= 1024 && steps < 4) {
    n = n / 1024;
    unitScale *= 1024;
    steps++;
  }
  var k = Math.floor(Math.log(n) / Math.LN10);
  var mantissa = 10 * Math.pow(10, k);
  for (var i = 0; i < NICE_STEPS.length; i++) {
    var v = NICE_STEPS[i] * Math.pow(10, k);
    if (v >= n - 1e-9) {
      mantissa = v;
      break;
    }
  }
  return mantissa * unitScale;
}

// speedPairText(dl, ul) -> "↓ 5.8 MiB/s · ↑ 402 KiB/s", the same
// down/up convention inspectorInfo's Speed field uses.
function speedPairText(dl, ul) {
  return "↓ " + Model.sizeText(dl) + "/s · ↑ " + Model.sizeText(ul) + "/s";
}

// chartSeries(points, nowSec, spanSec) -> {down, up, max, maxText,
// peakText, avgText, nowDlText, nowUlText, empty} for the SpeedChart.
// `points` is [[t, dl, ul], …] (seconds, bytes/s); points older than the
// span are dropped. `x` runs 0..1 across [nowSec - spanSec, nowSec]; `y`
// is sample / max. peakText/avgText each carry both directions in one
// string, "↓ <dl> · ↑ <ul>" -- the peak (or mean) of down and of up over
// the kept points, independently (the mockup's "Peak ↓ 5.8 MiB/s ·
// ↑ 402 KiB/s" / "Average ↓ 3.6 MiB/s · ↑ 180 KiB/s"). nowDlText/
// nowUlText are the *last* kept sample, each on its own (the legend's
// "━ ↓ 4.1 MiB/s" accent / "━ ↑ 210 KiB/s" fg, two independently-colored
// spans rather than peakText/avgText's combined convention). Unlike
// maxText/peakText/avgText's "—" (no data to summarize), an idle chart's
// legend still has a direction and a rate -- zero -- so it reads "↓ 0 B/s"
// / "↑ 0 B/s", the mockup's "━ ↓ 0" / "━ ↑ 0" in this codebase's own
// rate-formatting convention.
function chartSeries(points, nowSec, spanSec) {
  var list = Array.isArray(points) ? points : [];
  var now = Number(nowSec) || 0;
  var span = Number(spanSec) || 0;
  var startT = now - span;
  var kept = [];
  var largest = 0;
  var anyPositive = false;
  for (var i = 0; i < list.length; i++) {
    var row = list[i] || [];
    var t = Number(row[0]);
    if (!isFinite(t) || t < startT) continue;
    var dl = Number(row[1]);
    if (!isFinite(dl) || dl < 0) dl = 0;
    var ul = Number(row[2]);
    if (!isFinite(ul) || ul < 0) ul = 0;
    if (dl > 0 || ul > 0) anyPositive = true;
    if (dl > largest) largest = dl;
    if (ul > largest) largest = ul;
    var x = span > 0 ? (t - startT) / span : 0;
    if (x < 0) x = 0;
    else if (x > 1) x = 1;
    kept.push({ x: x, dl: dl, ul: ul });
  }
  if (!anyPositive) {
    return {
      down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—",
      nowDlText: "↓ " + Model.sizeText(0) + "/s", nowUlText: "↑ " + Model.sizeText(0) + "/s",
      empty: true
    };
  }
  var max = niceMax(largest);
  var down = [];
  var up = [];
  var peakDl = 0;
  var peakUl = 0;
  var sumDl = 0;
  var sumUl = 0;
  for (var j = 0; j < kept.length; j++) {
    down.push({ x: kept[j].x, y: max > 0 ? kept[j].dl / max : 0 });
    up.push({ x: kept[j].x, y: max > 0 ? kept[j].ul / max : 0 });
    if (kept[j].dl > peakDl) peakDl = kept[j].dl;
    if (kept[j].ul > peakUl) peakUl = kept[j].ul;
    sumDl += kept[j].dl;
    sumUl += kept[j].ul;
  }
  var avgDl = kept.length > 0 ? sumDl / kept.length : 0;
  var avgUl = kept.length > 0 ? sumUl / kept.length : 0;
  var lastKept = kept[kept.length - 1];
  return {
    down: down,
    up: up,
    max: max,
    // max is always a round {1,2,5,10}x10^k mantissa, so drop the
    // trailing ".0" sizeText's "one decimal under 100" rule would add
    // (the Pieces field in infoGroups does the same for the same reason).
    maxText: stripPointZero(Model.sizeText(max)) + "/s",
    peakText: speedPairText(peakDl, peakUl),
    avgText: speedPairText(avgDl, avgUl),
    nowDlText: "↓ " + Model.sizeText(lastKept.dl) + "/s",
    nowUlText: "↑ " + Model.sizeText(lastKept.ul) + "/s",
    empty: false
  };
}

// --- chartTab -----------------------------------------------------------------

// The chart tab's window: 600 s (10 min), matching the sidecar ring
// buffer's own retention (F9's MAX_SLOTS) one-for-one, so every buffered
// sample the chart watch can possibly deliver is always inside it.
var CHART_SPAN_SECONDS = 600;

// chartTab(entry, sinceMs, nowMs, sidecarUp) -> {state, series, error} for
// the chart tab (InspectorPane's `chart` property). `entry` is Service's
// inspectByKey[hash+"|chart"] ({points, error, at}) or undefined.
//
// Unlike listTab, the chart tab never reads as tabState's "empty": there
// are no rows to show or not show, and SpeedChart draws its own "No
// traffic in the last 10 minutes." straight from series.empty -- so a
// fresh, error-free entry always reads "rows" here, however many points
// it carries. `data` is passed as a constant non-empty placeholder;
// tabState's error branch is checked before it ever looks at `data`.
//
// `nowSec` comes from entry.at, not the caller's clock: nowMs (Client's
// inspectNow) only moves once, past the 300 ms blank window, so it can't
// track the chart's own "now" -- entry.at, in contrast, is set fresh by
// Service on every inspect line while chart is watched.
function chartTab(entry, sinceMs, nowMs, sidecarUp) {
  var probe = entry ? { at: entry.at, error: entry.error, data: [1] } : undefined;
  var state = tabState(probe, sinceMs, nowMs, sidecarUp);
  var points = entry && Array.isArray(entry.points) ? entry.points : [];
  var nowSec = entry ? (Number(entry.at) || 0) / 1000 : 0;
  return {
    state: state,
    series: chartSeries(points, nowSec, CHART_SPAN_SECONDS),
    error: state === "error" ? String(entry.error) : ""
  };
}

// --- tabState -----------------------------------------------------------------

// A stale/absent entry reads as "blank" for this long after `sinceMs`
// (the moment the current key -- hash+tab -- became current), then
// "loading". Chosen to absorb one status tick's worth of latency without
// a flash of "blank" on every ordinary tab switch.
var TAB_BLANK_MS = 300;

// tabState(entry, sinceMs, nowMs, sidecarUp) -> "blank" | "loading" |
// "rows" | "empty" | "error" | "sidecarDown". `entry` is Service's latest
// {data|error, at} for this hash+tab, or undefined. `sidecarUp` means "the
// sidecar is not down" (false -> "sidecarDown", pass-through otherwise).
// An entry whose `at` is earlier than `sinceMs` (a stale reply under the
// current key, e.g. after A->B->A or info->trackers->info) counts as no
// entry at all.
function tabState(entry, sinceMs, nowMs, sidecarUp) {
  if (!sidecarUp) return "sidecarDown";
  var since = Number(sinceMs) || 0;
  var now = Number(nowMs) || 0;
  var e = entry;
  var fresh = !!e && Number(e.at) >= since;
  if (!fresh) {
    return now - since < TAB_BLANK_MS ? "blank" : "loading";
  }
  if (e.error) return "error";
  var d = e.data;
  var empty;
  if (Array.isArray(d)) empty = d.length === 0;
  else if (d && typeof d === "object") empty = Object.keys(d).length === 0;
  else empty = !d;
  return empty ? "empty" : "rows";
}

// --- emptyCopy --------------------------------------------------------------

// emptyCopy(tab, row) -> {title, body, keys} for the states table's empty
// state. `keys` are empty in 2a (Space and `f` arrive in 2b).
function emptyCopy(tab, row) {
  if (tab === "peers") {
    var stopped = Model.statusGroup(row) === "stopped";
    return {
      title: "No peers",
      body: stopped ? "The torrent is stopped. Start it to connect." : "Looking for peers…",
      keys: []
    };
  }
  if (tab === "trackers") {
    return { title: "No trackers", body: "This torrent only finds peers through DHT and PeX.", keys: [] };
  }
  if (tab === "files") {
    return { title: "No file list yet", body: "qBittorrent needs the torrent's metadata first.", keys: [] };
  }
  return { title: "", body: "", keys: [] };
}

// --- listTab and the trackers/peers detail lines ---------------------------

function countWord(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

// listTab(tab, entry, sinceMs, nowMs, sidecarUp, row) -> {state, rows,
// summary, title, copy, error} for the trackers or peers tab. `entry` is Service's
// inspectByKey[hash + "|" + tab] ({trackers|peers, error, at}); tabState
// decides on the *shaped* rows, so a trackers reply holding only
// DHT/PeX/LSD reads "empty". `rows` is empty unless state is "rows";
// `title` is the pane title's right side ("8 trackers", "17 peers · 14
// seeds"), "" otherwise. `copy` is emptyCopy(tab, row) for the cursor
// torrent `row`. `error` is the entry's (Service-sanitized) error text in
// the "error" state, else "": the error screen wins over any rows Service
// kept alongside it.
function listTab(tab, entry, sinceMs, nowMs, sidecarUp, row) {
  var shaped, summary, title;
  if (tab === "peers") {
    shaped = peerRows(entry ? entry.peers : null);
    summary = peerSummary(shaped);
    title = countWord(summary.peers, "peer", "peers") + " · " + countWord(summary.seeds, "seed", "seeds");
  } else {
    var t = trackerRows(entry ? entry.trackers : null);
    shaped = t.rows;
    summary = t.summary;
    title = countWord(shaped.length, "tracker", "trackers");
  }
  var probe = entry ? { at: entry.at, error: entry.error, data: shaped } : undefined;
  var state = tabState(probe, sinceMs, nowMs, sidecarUp);
  var shown = state === "rows";
  return {
    state: state,
    rows: shown ? shaped : [],
    summary: summary,
    title: shown ? title : "",
    copy: emptyCopy(tab, row),
    error: state === "error" ? String(entry.error) : ""
  };
}

// trackerSummaryParts(summary) -> [{text, tone}] for the trackers tab's
// summary line: "DHT on · PeX on · LSD on  ·  212 seeds · 48 peers", with
// each "on" in accent and everything else muted.
function trackerSummaryParts(summary) {
  var s = summary || {};
  var parts = [];
  var kinds = [["DHT", s.dht], ["PeX", s.pex], ["LSD", s.lsd]];
  for (var i = 0; i < kinds.length; i++) {
    var v = String(kinds[i][1] === undefined ? "—" : kinds[i][1]);
    parts.push({ text: (i > 0 ? " · " : "") + kinds[i][0] + " ", tone: "muted" });
    parts.push({ text: v, tone: v === "on" ? "accent" : "muted" });
  }
  var seeds = Number(s.seeds) || 0;
  var peers = Number(s.peers) || 0;
  parts.push({ text: "  ·  " + countWord(seeds, "seed", "seeds") + " · " + countWord(peers, "peer", "peers"), tone: "muted" });
  return parts;
}

// trackerDetail(row) -> the cursor tracker's detail lines: {status: {text,
// tone} (urgent when failing, else fg), message ('"…"', or "" when the
// tracker said nothing), url (redacted: never the path or query), tier
// ("tier N · next announce in 14m"; "<1m" under a minute; no announce
// part when nextAnnounce is absent)}.
function trackerDetail(row) {
  var r = row || {};
  var msg = String(r.message || "");
  var tier = numOrNull(r.tier);
  var next = posOrNull(r.nextAnnounce);
  var announce = !next ? "" : " · next announce in " + (next < 60 ? "<1m" : durationText(next));
  return {
    status: { text: String(r.statusWord || ""), tone: r.tone === "urgent" ? "urgent" : "fg" },
    message: msg === "" ? "" : "\"" + msg + "\"",
    url: String(r.shownUrl || ""),
    tier: "tier " + (tier === null ? "—" : tier) + announce
  };
}

// --- infoView -----------------------------------------------------------

// The pieces bar's cell count (mockup row 1, col 1): PiecesBar draws one
// line of this many glyphs, whatever `states.length` is.
var PIECES_CELLS = 48;

// infoView(entry, sinceMs, sidecarUp, row, fmtDate) -> {noMeta, cells,
// legend, groups} for the Info tab's pieces bar and Transfer/Torrent
// groups. `entry` is Service's inspectByKey[hash+"|info"] ({props, pieces,
// error, at}) or undefined, read independent of whichever inspector tab is
// currently shown -- a switch to Files, Trackers or Peers still needs this
// torrent's no-metadata state. An entry older than sinceMs (stale, e.g.
// after A->B->A or a switch away from the Info tab and back) or a down
// sidecar counts as none: `cells` is then [], every group value reads "—"
// (infoGroups(null)), and `noMeta` falls back to the row's own size
// (noMetadata's fallback) -- exactly right for a torrent whose Info tab
// hasn't been read yet, and for the primary case, every stopped magnet in
// the user's library today.
//
// M2: a fresh entry carrying `error` never hands its retained props or
// pieces onward, even though Service keeps them around for a transient
// failure -- the states table says "Values stay '—'; the status line
// shows the error" for Info's Error column. `props` drops to null exactly
// like the stale/sidecar-down paths, so `noMeta` still runs its normal
// row-size fallback (a real no-metadata torrent keeps reading
// "waiting for metadata" and "No file list yet" through an unrelated
// info-read error, since those come from the row and from Files, not
// from this reply) -- `errored` is returned separately so the pane can
// blank only the pieces area (InspectorPane: no bar, and the
// "no metadata yet" line suppressed by `errored`, not by `noMeta`). The
// slice-1 label/value block (read from the row, not from this) is
// unaffected either way.
function infoView(entry, sinceMs, sidecarUp, row, fmtDate) {
  var since = Number(sinceMs) || 0;
  var fresh = sidecarUp !== false && !!entry && Number(entry.at) >= since;
  var errored = fresh && !!entry.error;
  var props = fresh && !errored && entry.props ? entry.props : null;
  var pieces = fresh && !errored && Array.isArray(entry.pieces) ? entry.pieces : [];
  return {
    noMeta: noMetadata(row, props),
    errored: errored,
    cells: binPieces(pieces, PIECES_CELLS),
    legend: piecesLegend(pieces),
    groups: infoGroups(props, fmtDate)
  };
}

// peerDetail(row) -> the cursor peer's detail lines: {ip (shown in fg),
// rest (":port · connection · downloaded N"), flags, flagsDesc (qbt's
// one-meaning-per-line description joined with " · ")}.
function peerDetail(row) {
  var r = row || {};
  var addr = String(r.ipPort || "");
  var cut = addr.lastIndexOf(":");
  var ip = cut > 0 ? addr.slice(0, cut) : addr;
  var rest = cut > 0 ? addr.slice(cut) : "";
  var bits = [];
  if (r.connection) bits.push(String(r.connection));
  if (r.downloaded) bits.push("downloaded " + r.downloaded);
  if (bits.length > 0) rest += (rest !== "" ? " · " : "") + bits.join(" · ");
  var desc = String(r.flagsDesc || "").split(/\s*\n\s*/).filter(function(x) { return x !== ""; }).join(" · ");
  return { ip: ip, rest: rest, flags: String(r.flags || ""), flagsDesc: desc };
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    redactUrl: redactUrl,
    trackerUrlError: trackerUrlError,
    peerError: peerError,
    hasPipe: hasPipe,
    PIPE_NOTE: PIPE_NOTE,
    UNUSABLE_NOTE: UNUSABLE_NOTE,
    trackerRefusal: trackerRefusal,
    trackerRows: trackerRows,
    peerRows: peerRows,
    peerSummary: peerSummary,
    keyedIndex: keyedIndex,
    binPieces: binPieces,
    piecesLegend: piecesLegend,
    noMetadata: noMetadata,
    infoGroups: infoGroups,
    chartSeries: chartSeries,
    chartTab: chartTab,
    CHART_SPAN_SECONDS: CHART_SPAN_SECONDS,
    tabState: tabState,
    emptyCopy: emptyCopy,
    listTab: listTab,
    trackerSummaryParts: trackerSummaryParts,
    trackerDetail: trackerDetail,
    peerDetail: peerDetail,
    infoView: infoView
  };
}
