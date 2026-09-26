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
// to the first /, ? or # (so a userinfo@ or :port stays in the shown
// host, but nothing past it ever does).
var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]+)([\s\S]*)$/;

// redactUrl(url) -> "scheme://host[:port]/…" when there is a path or query
// beyond "/", "scheme://host[:port]" when there is neither, or the input
// unchanged when it doesn't parse as scheme://authority(...). Never
// returns any part of the path or query.
function redactUrl(url) {
  var s = String(url === undefined || url === null ? "" : url);
  var m = URL_RE.exec(s);
  if (!m) return s;
  var rest = m[3] || "";
  if (rest === "" || rest === "/") return m[1] + "://" + m[2];
  return m[1] + "://" + m[2] + "/…";
}

// urlHost(url) -> the "host[:port]" authority redactUrl also uses, or the
// input unchanged when it doesn't parse.
function urlHost(url) {
  var s = String(url === undefined || url === null ? "" : url);
  var m = URL_RE.exec(s);
  return m ? m[2] : s;
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
      glyph: info.glyph,
      tone: info.tone,
      statusWord: info.word,
      message: Model.plainText(t.msg),
      tier: t.tier,
      seeds: countOrDash(t.num_seeds),
      peers: countOrDash(t.num_leeches)
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

// chartSeries(points, nowSec, spanSec) -> {down, up, max, maxText,
// peakText, avgText, empty} for the SpeedChart. `points` is
// [[t, dl, ul], …] (seconds, bytes/s); points older than the span are
// dropped. `x` runs 0..1 across [nowSec - spanSec, nowSec]; `y` is
// sample / max. peak/avg are the download series' peak and mean over the
// kept points -- the download line is the pane's primary metric (the
// Info tab's Downloaded field gets the same emphasis).
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
    return { down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—", empty: true };
  }
  var max = niceMax(largest);
  var down = [];
  var up = [];
  var peak = 0;
  var sum = 0;
  for (var j = 0; j < kept.length; j++) {
    down.push({ x: kept[j].x, y: max > 0 ? kept[j].dl / max : 0 });
    up.push({ x: kept[j].x, y: max > 0 ? kept[j].ul / max : 0 });
    if (kept[j].dl > peak) peak = kept[j].dl;
    sum += kept[j].dl;
  }
  var avg = kept.length > 0 ? sum / kept.length : 0;
  return {
    down: down,
    up: up,
    max: max,
    // max is always a round {1,2,5,10}x10^k mantissa, so drop the
    // trailing ".0" sizeText's "one decimal under 100" rule would add
    // (the Pieces field in infoGroups does the same for the same reason).
    maxText: stripPointZero(Model.sizeText(max)) + "/s",
    peakText: Model.sizeText(peak) + "/s",
    avgText: Model.sizeText(avg) + "/s",
    empty: false
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    redactUrl: redactUrl,
    trackerRows: trackerRows,
    peerRows: peerRows,
    peerSummary: peerSummary,
    keyedIndex: keyedIndex,
    binPieces: binPieces,
    piecesLegend: piecesLegend,
    noMetadata: noMetadata,
    infoGroups: infoGroups,
    chartSeries: chartSeries,
    tabState: tabState,
    emptyCopy: emptyCopy
  };
}
