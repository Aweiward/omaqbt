const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Model = require("../Model.js");

// InspectorView.js starts with QML-only `.pragma library` / `.import
// "Model.js" as Model` lines, which node can't parse. Strip them and run
// the rest as a function body in this realm, with `Model` supplied exactly
// as QML would (see tests/client-view.test.js's loadClientView, which this
// copies).
function loadInspectorView() {
  const file = path.join(__dirname, "..", "InspectorView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module", "Model"], { filename: file })(mod, Model);
  return mod.exports;
}

const I = loadInspectorView();

// --- redactUrl --------------------------------------------------------------

test("redactUrl keeps scheme://host[:port] and drops path/query", () => {
  assert.equal(I.redactUrl("https://t.example/announce?passkey=abc123"), "https://t.example/…");
  assert.equal(I.redactUrl("udp://t.example:1337/abc123/announce"), "udp://t.example:1337/…");
});

test("redactUrl with no path or query keeps the bare authority", () => {
  assert.equal(I.redactUrl("udp://t.example:1337"), "udp://t.example:1337");
});

test("redactUrl returns unparseable input unchanged", () => {
  assert.equal(I.redactUrl("not a url"), "not a url");
});

test("redactUrl never leaks the passkey/path in any case", () => {
  const cases = [
    "https://t.example/announce?passkey=abc123",
    "udp://t.example:1337/abc123/announce",
    "udp://t.example:1337/?passkey=abc123",
    "udp://t.example:1337?passkey=abc123"
  ];
  for (const c of cases) {
    assert.ok(!I.redactUrl(c).includes("abc123"), c);
  }
});

// --- trackerRows ------------------------------------------------------------

function tracker(overrides) {
  return Object.assign({ url: "https://t.example/announce", status: 2, tier: 0, num_seeds: 5, num_leeches: 3, msg: "" }, overrides || {});
}

test("trackerRows folds the three pseudo-trackers into summary and never into rows", () => {
  const list = [
    { url: "** [DHT] **", status: 1, num_seeds: -1, num_leeches: -1 },
    { url: "** [PeX] **", status: 0, num_seeds: -1, num_leeches: -1 },
    { url: "** [LSD] **", status: 1, num_seeds: -1, num_leeches: -1 },
    tracker()
  ];
  const { summary, rows } = I.trackerRows(list);
  assert.deepEqual(summary, { dht: "on", pex: "off", lsd: "on", seeds: 5, peers: 3 });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].url, "https://t.example/announce");
});

test("trackerRows summary shows — for an absent pseudo-tracker", () => {
  const { summary } = I.trackerRows([tracker()]);
  assert.deepEqual(summary, { dht: "—", pex: "—", lsd: "—", seeds: 5, peers: 3 });
});

test("trackerRows maps every status 0-6 to its glyph, tone and word", () => {
  const expect = {
    0: ["·", "muted", "disabled"],
    1: ["·", "muted", "not contacted"],
    2: ["●", "accent", "working"],
    3: ["↻", "muted", "updating"],
    4: ["!", "urgent", "not working"],
    5: ["!", "urgent", "error"],
    6: ["!", "urgent", "error"]
  };
  for (const status of Object.keys(expect)) {
    const { rows } = I.trackerRows([tracker({ status: Number(status) })]);
    const [glyph, tone, word] = expect[status];
    assert.equal(rows[0].glyph, glyph, status);
    assert.equal(rows[0].tone, tone, status);
    assert.equal(rows[0].statusWord, word, status);
  }
});

test("trackerRows shows — for -1 seeds/peers and the sums skip -1", () => {
  const { summary, rows } = I.trackerRows([
    tracker({ num_seeds: -1, num_leeches: -1 }),
    tracker({ url: "udp://t2.example:80/announce", num_seeds: 7, num_leeches: 2 })
  ]);
  assert.equal(rows[0].seeds, "—");
  assert.equal(rows[0].peers, "—");
  assert.equal(rows[1].seeds, "7");
  assert.equal(rows[1].peers, "2");
  assert.deepEqual({ seeds: summary.seeds, peers: summary.peers }, { seeds: 7, peers: 2 });
});

test("trackerRows redacts shownUrl and reports host separately", () => {
  const { rows } = I.trackerRows([tracker({ url: "udp://t.example:1337/abc123/announce" })]);
  assert.equal(rows[0].host, "t.example:1337");
  assert.equal(rows[0].shownUrl, "udp://t.example:1337/…");
  assert.equal(rows[0].key, "udp://t.example:1337/abc123/announce");
  assert.equal(rows[0].url, "udp://t.example:1337/abc123/announce");
});

// --- peerRows / peerSummary --------------------------------------------------

function peer(overrides) {
  return Object.assign({
    client: "qBittorrent/4.5.0", peer_id_client: "", country_code: "de",
    progress: 0.5, dl_speed: 1024, up_speed: 512, downloaded: 2048,
    connection: "BT", flags: "D", flags_desc: "D = interested"
  }, overrides || {});
}

test("peerRows sorts by down desc, then up desc, then key asc", () => {
  const peers = {
    "1.1.1.1:1": peer({ dl_speed: 100, up_speed: 5 }),
    "2.2.2.2:2": peer({ dl_speed: 200, up_speed: 1 }),
    "3.3.3.3:3": peer({ dl_speed: 200, up_speed: 9 }),
    "4.4.4.4:4": peer({ dl_speed: 50, up_speed: 50 })
  };
  const rows = I.peerRows(peers);
  assert.deepEqual(rows.map((r) => r.key), ["3.3.3.3:3", "2.2.2.2:2", "1.1.1.1:1", "4.4.4.4:4"]);
});

test("peerRows ties on key ascending when down and up are equal", () => {
  const peers = {
    "b.b.b.b:2": peer({ dl_speed: 10, up_speed: 10 }),
    "a.a.a.a:1": peer({ dl_speed: 10, up_speed: 10 })
  };
  const rows = I.peerRows(peers);
  assert.deepEqual(rows.map((r) => r.key), ["a.a.a.a:1", "b.b.b.b:2"]);
});

test("peerRows shows — for an unknown country", () => {
  const rows = I.peerRows({ "1.1.1.1:1": peer({ country_code: "" }) });
  assert.equal(rows[0].country, "—");
});

test("peerRows falls back to Unknown (peer_id_client) for a missing client", () => {
  const rows = I.peerRows({ "1.1.1.1:1": peer({ client: "", peer_id_client: "-XL0012-" }) });
  assert.equal(rows[0].client, "Unknown (-XL0012-)");
});

test("peerRows falls back to plain Unknown with neither client nor peer id", () => {
  const rows = I.peerRows({ "1.1.1.1:1": peer({ client: "", peer_id_client: "" }) });
  assert.equal(rows[0].client, "Unknown");
});

test("peerRows on an empty object returns []", () => {
  assert.deepEqual(I.peerRows({}), []);
});

test("peerRows carries has/downText/upText/downloaded formatted, ipPort and flags", () => {
  const rows = I.peerRows({ "1.1.1.1:51413": peer({ progress: 0.42, dl_speed: 900000, up_speed: 2048, downloaded: 5 * 1024 * 1024 }) });
  const r = rows[0];
  assert.equal(r.has, "42%");
  assert.equal(r.ipPort, "1.1.1.1:51413");
  assert.equal(r.downloaded, "5.0 MiB");
  assert.equal(r.flags, "D");
  assert.equal(r.flagsDesc, "D = interested");
  assert.equal(typeof r.downText, "string");
  assert.equal(typeof r.upText, "string");
});

test("peerSummary counts peers and rows with progress >= 1 as seeds", () => {
  const rows = [{ progress: 1 }, { progress: 1 }, { progress: 0.4 }];
  assert.deepEqual(I.peerSummary(rows), { peers: 3, seeds: 2 });
});

// --- keyedIndex ---------------------------------------------------------------

test("keyedIndex finds the row by key", () => {
  const rows = [{ key: "a" }, { key: "b" }, { key: "c" }];
  assert.equal(I.keyedIndex(rows, "b", 0), 1);
});

test("keyedIndex falls back to the clamped previous index when the key is gone", () => {
  const rows = [{ key: "a" }, { key: "b" }];
  assert.equal(I.keyedIndex(rows, "z", 5), 1);
  assert.equal(I.keyedIndex(rows, "z", -1), 0);
  assert.equal(I.keyedIndex(rows, "z", 0), 0);
});

test("keyedIndex on no rows returns -1", () => {
  assert.equal(I.keyedIndex([], "a", 0), -1);
});

// --- binPieces / piecesLegend --------------------------------------------------

test("binPieces: all have -> every cell is full, none dim", () => {
  const states = new Array(48).fill(2);
  const cells = I.binPieces(states, 48);
  assert.equal(cells.length, 48);
  for (const c of cells) assert.deepEqual(c, { glyph: "█", tone: "accent" });
});

test("binPieces: a full bin next to an all-missing bin renders full and dim, not mixed", () => {
  const states = [2, 2, 0, 0];
  const cells = I.binPieces(states, 2);
  assert.deepEqual(cells[0], { glyph: "█", tone: "accent" });
  assert.deepEqual(cells[1], { glyph: "░", tone: "dim" });
});

test("binPieces: a bin covering both a have and a missing piece is partial ▓", () => {
  const cells = I.binPieces([2, 0], 1);
  assert.deepEqual(cells[0], { glyph: "▓", tone: "accent" });
});

test("binPieces: a bin with only downloading pieces (no have) is partial ▓", () => {
  const states = [1, 1];
  const cells = I.binPieces(states, 1);
  assert.deepEqual(cells[0], { glyph: "▓", tone: "accent" });
});

test("binPieces: 10 pieces into 48 cells covers every piece (no false-empty ░)", () => {
  const states = new Array(10).fill(2);
  const cells = I.binPieces(states, 48);
  assert.equal(cells.length, 48);
  for (const c of cells) assert.equal(c.glyph, "█", JSON.stringify(cells));
});

test("binPieces: mixed have/missing at n much smaller than cells stays crisp (no spurious ▓ from the empty-slice widening)", () => {
  // n < cells means every cell's slice, once widened past empty, covers
  // exactly one piece (the widening never merges two differently-valued
  // pieces into one cell) -- so a mixed torrent here separates cleanly
  // into a run of full cells and a run of dim cells, never a stray ▓.
  const states = [2, 2, 2, 2, 2, 0, 0, 0, 0, 0];
  const cells = I.binPieces(states, 48);
  assert.equal(cells.length, 48);
  assert.ok(cells.slice(0, 24).every((c) => c.glyph === "█"), JSON.stringify(cells));
  assert.ok(cells.slice(24).every((c) => c.glyph === "░"), JSON.stringify(cells));
});

test("binPieces: a cell spanning a have/missing boundary (n just above cells) is partial ▓", () => {
  const states = new Array(96).fill(2);
  states[93] = 0;
  states[94] = 0;
  states[95] = 0;
  const cells = I.binPieces(states, 48);
  assert.equal(cells.length, 48);
  assert.equal(cells[46].glyph, "▓");
  assert.equal(cells[47].glyph, "░");
  assert.equal(cells[0].glyph, "█");
});

test("binPieces: 20,000 pieces into 48 cells still returns exactly 48 cells", () => {
  const states = new Array(20000).fill(0);
  states[0] = 2;
  const cells = I.binPieces(states, 48);
  assert.equal(cells.length, 48);
});

test("binPieces on [] or a non-array returns []", () => {
  assert.deepEqual(I.binPieces([], 48), []);
  assert.deepEqual(I.binPieces(null, 48), []);
  assert.deepEqual(I.binPieces(undefined, 48), []);
});

test("piecesLegend formats with thousands separators", () => {
  const states = new Array(1776).fill(0);
  for (let i = 0; i < 612; i++) states[i] = 2;
  assert.equal(I.piecesLegend(states), "pieces 612 of 1,776 · █ have ▓ partial ░ missing");
});

// --- noMetadata -----------------------------------------------------------

test("noMetadata: props.has_metadata false wins even when the row has a size", () => {
  assert.equal(I.noMetadata({ size: 5000 }, { has_metadata: false }), true);
});

test("noMetadata: props.has_metadata true means metadata exists even at size 0", () => {
  assert.equal(I.noMetadata({ size: 0 }, { has_metadata: true }), false);
});

test("noMetadata falls back to row.size when there is no has_metadata field", () => {
  assert.equal(I.noMetadata({ size: -1 }, null), true);
  assert.equal(I.noMetadata({ size: 1 }, null), false);
  assert.equal(I.noMetadata({ size: 1 }, {}), false);
});

// --- infoGroups -------------------------------------------------------------

function fmtDate(s) {
  return "DATE(" + s + ")";
}

test("infoGroups(null) returns two groups with every value —", () => {
  const groups = I.infoGroups(null, fmtDate);
  assert.equal(groups.length, 2);
  assert.equal(groups[0].title, "Transfer");
  assert.equal(groups[1].title, "Torrent");
  for (const g of groups) {
    for (const f of g.fields) assert.equal(f.value, "—", f.label);
  }
});

test("infoGroups renders a full properties fixture", () => {
  const props = {
    addition_date: 1700000000,
    comment: "hello",
    hash: "223f576c19a3c0c4e5c6b7d8e9f0a1b2c3d4e5f6",
    is_private: false,
    nb_connections: 17,
    nb_connections_limit: 100,
    piece_size: 1048576,
    pieces_num: 1776,
    pieces_have: 612,
    time_elapsed: 8040,
    seeding_time: 0,
    total_downloaded: 1073741824,
    total_downloaded_session: 1048576,
    total_uploaded: 2147483648,
    total_wasted: 0,
    has_metadata: true,
    total_size: 5000000000
  };
  const groups = I.infoGroups(props, fmtDate);
  const byLabel = {};
  for (const g of groups) for (const f of g.fields) byLabel[f.label] = f;

  assert.equal(byLabel.Downloaded.value, "1.0 GiB");
  assert.equal(byLabel.Downloaded.note, "· 1.0 MiB this session");
  assert.equal(byLabel.Uploaded.value, "2.0 GiB");
  assert.equal(byLabel.Wasted.value, "0 B");
  assert.equal(byLabel.Connections.value, "17 of 100");
  assert.equal(byLabel.Active.value, "2h 14m · seeding 0m");
  assert.equal(byLabel.Added.value, "DATE(1700000000)");
  assert.equal(byLabel.Hash.value, "223f576c…e9f0a1b2c3d4e5f6");
  assert.equal(byLabel.Pieces.value, "1,776 × 1 MiB");
  assert.equal(byLabel.Private.value, "no");
  assert.equal(byLabel.Comment.value, "hello");
});

test("infoGroups: is_private null shows —, and an empty comment shows —", () => {
  const props = { is_private: null, comment: "" };
  const groups = I.infoGroups(props, fmtDate);
  const byLabel = {};
  for (const g of groups) for (const f of g.fields) byLabel[f.label] = f;
  assert.equal(byLabel.Private.value, "—");
  assert.equal(byLabel.Comment.value, "—");
});

test("infoGroups: pieces_num <= 0 shows — for Pieces", () => {
  const groups = I.infoGroups({ pieces_num: 0, piece_size: 1048576 }, fmtDate);
  const pieces = groups[1].fields.find((f) => f.label === "Pieces");
  assert.equal(pieces.value, "—");
});

// --- chartSeries --------------------------------------------------------------

test("chartSeries with no positive sample is empty", () => {
  const s = I.chartSeries([[0, 0, 0], [1, 0, 0]], 1, 600);
  assert.equal(s.empty, true);
  assert.equal(s.maxText, "—");
  assert.equal(s.peakText, "—");
  assert.equal(s.avgText, "—");
  assert.deepEqual(s.down, []);
  assert.deepEqual(s.up, []);
});

test("chartSeries with no points at all is empty", () => {
  const s = I.chartSeries([], 1000, 600);
  assert.equal(s.empty, true);
});

test("chartSeries: a 5.8 MiB/s spike gets a nice max >= the sample, via sizeText", () => {
  const spike = 5.8 * 1024 * 1024;
  const now = 1000;
  const s = I.chartSeries([[now, spike, 0]], now, 600);
  assert.equal(s.empty, false);
  assert.ok(s.max >= spike, "max " + s.max + " should be >= sample " + spike);
  assert.match(s.maxText, /^[\d.,]+ \S+\/s$/);
  for (const p of s.down.concat(s.up)) {
    assert.ok(p.y >= 0 && p.y <= 1, JSON.stringify(p));
    assert.ok(p.x >= 0 && p.x <= 1, JSON.stringify(p));
  }
});

test("chartSeries peakText/avgText carry both directions, Speed-field convention", () => {
  const dl1 = 5 * 1024 * 1024, ul1 = 1 * 1024 * 1024;
  const dl2 = 1 * 1024 * 1024, ul2 = 400 * 1024;
  const s = I.chartSeries([[1000, dl1, ul1], [1001, dl2, ul2]], 1001, 600);
  const peakDl = Math.max(dl1, dl2), peakUl = Math.max(ul1, ul2);
  const avgDl = (dl1 + dl2) / 2, avgUl = (ul1 + ul2) / 2;
  assert.equal(s.peakText, "↓ " + Model.sizeText(peakDl) + "/s · ↑ " + Model.sizeText(peakUl) + "/s");
  assert.equal(s.avgText, "↓ " + Model.sizeText(avgDl) + "/s · ↑ " + Model.sizeText(avgUl) + "/s");
  assert.match(s.peakText, /^↓ .+\/s · ↑ .+\/s$/);
  assert.match(s.avgText, /^↓ .+\/s · ↑ .+\/s$/);
});

test("chartSeries maxText has no trailing .0 (max is always a round mantissa)", () => {
  const spike = 5.8 * 1024 * 1024;
  const s = I.chartSeries([[1000, spike, 0]], 1000, 600);
  assert.equal(/\.0(\s|$)/.test(s.maxText), false, s.maxText);
});

test("chartSeries drops points older than the span", () => {
  const now = 1000;
  const span = 600;
  const s = I.chartSeries([[now - span - 1, 5000, 0], [now, 8000, 0]], now, span);
  assert.equal(s.down.length, 1);
  assert.equal(s.up.length, 1);
});

test("chartSeries x is within 0..1 across the window", () => {
  const now = 1000;
  const span = 600;
  const s = I.chartSeries([[now - span, 100, 0], [now, 200, 0]], now, span);
  for (const p of s.down) assert.ok(p.x >= 0 && p.x <= 1);
});

// --- tabState -----------------------------------------------------------------

test("tabState: sidecar down wins over everything else", () => {
  assert.equal(I.tabState({ data: [1], at: 500 }, 0, 1000, false), "sidecarDown");
});

test("tabState: blank until 300ms after sinceMs, then loading, when there is no entry", () => {
  assert.equal(I.tabState(undefined, 1000, 1000, true), "blank");
  assert.equal(I.tabState(undefined, 1000, 1299, true), "blank");
  assert.equal(I.tabState(undefined, 1000, 1300, true), "loading");
  assert.equal(I.tabState(undefined, 1000, 5000, true), "loading");
});

test("tabState: an entry with at < sinceMs counts as none (stale)", () => {
  assert.equal(I.tabState({ data: [1], at: 900 }, 1000, 1000, true), "blank");
  assert.equal(I.tabState({ data: [1], at: 900 }, 1000, 1400, true), "loading");
});

test("tabState: entry.error is error", () => {
  assert.equal(I.tabState({ error: "boom", at: 1000 }, 1000, 1000, true), "error");
});

test("tabState: empty array or object data is empty", () => {
  assert.equal(I.tabState({ data: [], at: 1000 }, 1000, 1000, true), "empty");
  assert.equal(I.tabState({ data: {}, at: 1000 }, 1000, 1000, true), "empty");
});

test("tabState: non-empty data is rows", () => {
  assert.equal(I.tabState({ data: [1, 2], at: 1000 }, 1000, 1000, true), "rows");
  assert.equal(I.tabState({ data: { a: 1 }, at: 1000 }, 1000, 1000, true), "rows");
});

// --- emptyCopy ------------------------------------------------------------

test("emptyCopy peers: stopped torrent explains why", () => {
  const c = I.emptyCopy("peers", { state: "pausedDL", progress: 0.2 });
  assert.equal(c.title, "No peers");
  assert.equal(c.body, "The torrent is stopped. Start it to connect.");
  assert.deepEqual(c.keys, []);
});

test("emptyCopy peers: a running torrent is still looking", () => {
  const c = I.emptyCopy("peers", { state: "downloading", progress: 0.2 });
  assert.equal(c.title, "No peers");
  assert.equal(c.body, "Looking for peers…");
});

test("emptyCopy trackers: DHT/PeX explanation", () => {
  const c = I.emptyCopy("trackers", {});
  assert.equal(c.title, "No trackers");
  assert.equal(c.body, "This torrent only finds peers through DHT and PeX.");
});

test("emptyCopy peers: a null row is treated as stopped, and never throws", () => {
  const c = I.emptyCopy("peers", null);
  assert.equal(c.title, "No peers");
  assert.equal(c.body, "The torrent is stopped. Start it to connect.");
});

test("emptyCopy files: no metadata copy, no keys in 2a", () => {
  const c = I.emptyCopy("files", {});
  assert.equal(c.title, "No file list yet");
  assert.equal(c.body, "qBittorrent needs the torrent's metadata first.");
  assert.deepEqual(c.keys, []);
});
