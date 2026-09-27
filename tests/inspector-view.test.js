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

test("redactUrl returns unparseable input unchanged when there is nothing to cut", () => {
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

// --- I1: userinfo (a passkey riding as user:pass@host) never renders ------

test("redactUrl strips userinfo from the authority", () => {
  assert.equal(I.redactUrl("https://user:abc123@t.example/announce"), "https://t.example/…");
  assert.equal(I.redactUrl("http://abc123@t.example:80"), "http://t.example:80");
});

test("redactUrl/urlHost regressions: IPv6 host, and an @ that's in the path (not the authority)", () => {
  assert.equal(I.trackerRows([tracker({ url: "http://[::1]:8080/announce?pk=abc123" })]).rows[0].host, "[::1]:8080");
  assert.equal(I.redactUrl("https://t.example/a@abc123/x"), "https://t.example/…");
});

test("trackerRows().rows[0].host never carries a URL's userinfo", () => {
  const cases = [
    "https://user:abc123@t.example/announce",
    "http://abc123@t.example:80"
  ];
  for (const c of cases) {
    const row = I.trackerRows([tracker({ url: c })]).rows[0];
    assert.ok(!row.host.includes("abc123"), c);
    assert.ok(!I.redactUrl(c).includes("abc123"), c);
  }
});

// --- a raw "@" in the password: split at the LAST "@" of the authority ---
// (WHATWG URL parsing and qBittorrent both split userinfo at the last "@"
// of the authority, not the first.)

test("redactUrl strips userinfo at the LAST @ when the password itself carries an @", () => {
  assert.equal(I.redactUrl("http://user:abc@123@t.example/a"), "http://t.example/…");
  assert.equal(I.redactUrl("http://a@b@t.example/x"), "http://t.example/…");
});

test("trackerRows().rows[0].host splits userinfo at the LAST @ too", () => {
  const cases = [
    { url: "http://user:abc@123@t.example/a", host: "t.example" },
    { url: "http://a@b@t.example/x", host: "t.example" }
  ];
  for (const c of cases) {
    const row = I.trackerRows([tracker({ url: c.url })]).rows[0];
    assert.ok(!row.host.includes("abc"), c.url);
    assert.ok(!row.host.includes("123"), c.url);
    assert.equal(row.host, c.host, c.url);
  }
});

// --- a backslash is a path/authority terminator too (WHATWG special
// schemes treat "\" like "/") ------------------------------------------

test("redactUrl treats a backslash as a path separator, in the scheme path", () => {
  assert.equal(I.redactUrl("udp://t.example:1337\\abc123"), "udp://t.example:1337/…");
  assert.equal(I.redactUrl("https://t.example\\announce?passkey=abc123"), "https://t.example/…");
});

test("trackerRows().rows[0].host never carries what follows a backslash", () => {
  const cases = [
    { url: "udp://t.example:1337\\abc123", host: "t.example:1337" },
    { url: "https://t.example\\announce?passkey=abc123", host: "t.example" }
  ];
  for (const c of cases) {
    const row = I.trackerRows([tracker({ url: c.url })]).rows[0];
    assert.ok(!row.host.includes("abc"), c.url);
    assert.ok(!row.host.includes("123"), c.url);
    assert.equal(row.host, c.host, c.url);
  }
});

// --- M5: a schemeless or otherwise unparseable URL is cut too -------------

test("redactUrl cuts a schemeless URL at its first /, ? or #", () => {
  assert.equal(I.redactUrl("t.example/abc123/announce"), "t.example/…");
  assert.equal(I.redactUrl("?passkey=abc123").includes("abc123"), false);
  assert.equal(I.redactUrl("t.example?passkey=abc123"), "t.example/…");
  assert.equal(I.redactUrl("t.example#abc123"), "t.example/…");
});

test("redactUrl strips userinfo from a schemeless URL too", () => {
  assert.equal(I.redactUrl("user:abc123@t.example/announce"), "t.example/…");
});

test("trackerRows().rows[0].host is cut too for a schemeless/unparseable URL (the host column, not just the detail line)", () => {
  const cases = [
    "t.example/abc123/announce",
    "user:abc123@t.example/announce"
  ];
  for (const c of cases) {
    const row = I.trackerRows([tracker({ url: c })]).rows[0];
    assert.ok(!row.host.includes("abc123"), c);
    assert.equal(row.host, "t.example", c);
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

test("chartSeries nowDlText/nowUlText read the last kept sample, separately colored SpeedChart-legend style", () => {
  const now = 1000;
  const s = I.chartSeries([[now - 1, 1024 * 1024, 512], [now, 2 * 1024 * 1024, 1024]], now, 600);
  assert.equal(s.nowDlText, "↓ " + Model.sizeText(2 * 1024 * 1024) + "/s");
  assert.equal(s.nowUlText, "↑ " + Model.sizeText(1024) + "/s");
});

test("chartSeries nowDlText/nowUlText are zero (not the dash) when empty -- idle still has a direction and a rate", () => {
  const s = I.chartSeries([], 1000, 600);
  assert.equal(s.nowDlText, "↓ " + Model.sizeText(0) + "/s");
  assert.equal(s.nowUlText, "↑ " + Model.sizeText(0) + "/s");
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

// --- listTab / trackerSummaryParts / trackerDetail / peerDetail (Task 5) ----

const TRACKERS_FIXTURE = [
  { url: "** [DHT] **", status: 2, num_seeds: -1, num_leeches: -1 },
  { url: "** [PeX] **", status: 0, num_seeds: -1, num_leeches: -1 },
  { url: "https://tracker.example/announce?passkey=abc123", status: 2, tier: 0, num_seeds: 5, num_leeches: 3, msg: "" },
  { url: "udp://t.example:1337/abc123/announce", status: 4, tier: 1, num_seeds: -1, num_leeches: -1, msg: "Connection timed out" }
];

test("listTab trackers: rows, summary and a title from a fresh entry", () => {
  const t = I.listTab("trackers", { trackers: TRACKERS_FIXTURE, at: 1000 }, 900, 1000, true);
  assert.equal(t.state, "rows");
  assert.equal(t.rows.length, 2);
  assert.equal(t.rows[0].host, "tracker.example");
  assert.equal(t.summary.dht, "on");
  assert.equal(t.summary.pex, "off");
  assert.equal(t.title, "2 trackers");
  const one = I.listTab("trackers", { trackers: TRACKERS_FIXTURE.slice(0, 3), at: 1000 }, 900, 1000, true);
  assert.equal(one.title, "1 tracker");
});

test("listTab trackers: only pseudo-trackers is empty, not rows", () => {
  const t = I.listTab("trackers", { trackers: TRACKERS_FIXTURE.slice(0, 2), at: 1000 }, 900, 1000, true);
  assert.equal(t.state, "empty");
  assert.deepEqual(t.rows, []);
  assert.equal(t.title, "");
});

test("listTab: a stale entry is blank, then loading after 300 ms; error and sidecarDown win", () => {
  const e = { trackers: TRACKERS_FIXTURE, at: 500 };
  assert.equal(I.listTab("trackers", e, 900, 1000, true).state, "blank");
  assert.deepEqual(I.listTab("trackers", e, 900, 1000, true).rows, []);
  assert.equal(I.listTab("trackers", e, 900, 1200, true).state, "loading");
  assert.equal(I.listTab("trackers", undefined, 900, 1000, true).state, "blank");
  const err = I.listTab("trackers", { trackers: TRACKERS_FIXTURE, error: "boom", at: 1000 }, 900, 1000, true);
  assert.equal(err.state, "error");
  assert.deepEqual(err.rows, []);
  assert.equal(err.title, "");
  assert.equal(I.listTab("peers", { peers: {}, at: 1000 }, 900, 1000, false).state, "sidecarDown");
});

test("listTab peers: sorted rows and the 'N peers · M seeds' title", () => {
  const peers = {
    "10.0.0.1:1": { client: "A", progress: 1, dl_speed: 10, up_speed: 0 },
    "10.0.0.2:2": { client: "B", progress: 0.5, dl_speed: 30, up_speed: 0 },
    "10.0.0.3:3": { client: "C", progress: 1, dl_speed: 20, up_speed: 0 }
  };
  const t = I.listTab("peers", { peers, at: 1000 }, 900, 1000, true);
  assert.equal(t.state, "rows");
  assert.deepEqual(t.rows.map((r) => r.key), ["10.0.0.2:2", "10.0.0.3:3", "10.0.0.1:1"]);
  assert.equal(t.title, "3 peers · 2 seeds");
  assert.equal(I.listTab("peers", { peers: { "1.1.1.1:1": { progress: 1 } }, at: 1000 }, 900, 1000, true).title, "1 peer · 1 seed");
  assert.equal(I.listTab("peers", { peers: {}, at: 1000 }, 900, 1000, true).state, "empty");
});

test("listTab carries the tab's empty copy for the cursor row", () => {
  assert.equal(I.listTab("peers", { peers: {}, at: 1000 }, 900, 1000, true, { state: "stoppedDL" }).copy.body,
    "The torrent is stopped. Start it to connect.");
  assert.equal(I.listTab("peers", { peers: {}, at: 1000 }, 900, 1000, true, { state: "downloading" }).copy.body, "Looking for peers…");
  assert.equal(I.listTab("trackers", undefined, 900, 1000, true, null).copy.title, "No trackers");
});

test("trackerSummaryParts: on in accent, counts muted, plurals", () => {
  const parts = I.trackerSummaryParts({ dht: "on", pex: "off", lsd: "—", seeds: 212, peers: 1 });
  assert.equal(parts.map((p) => p.text).join(""), "DHT on · PeX off · LSD —  ·  212 seeds · 1 peer");
  assert.deepEqual(parts.filter((p) => p.tone === "accent").map((p) => p.text), ["on"]);
});

test("trackerDetail: status word urgent when failing, quoted message, redacted url, tier", () => {
  const rows = I.trackerRows(TRACKERS_FIXTURE).rows;
  const bad = I.trackerDetail(rows[1]);
  assert.deepEqual(bad.status, { text: "not working", tone: "urgent" });
  assert.equal(bad.message, "\"Connection timed out\"");
  assert.equal(bad.url, "udp://t.example:1337/…");
  assert.equal(bad.tier, "tier 1");
  const ok = I.trackerDetail(rows[0]);
  assert.equal(ok.status.tone, "fg");
  assert.equal(ok.message, "");
  assert.equal(ok.url, "https://tracker.example/…");
  assert.equal(ok.tier, "tier 0");
  assert.equal(I.trackerDetail(null).url, "");
});

test("peerDetail: ip apart from the rest, flags description on one line", () => {
  const row = I.peerRows({ "203.0.113.42:51413": { connection: "uTP", downloaded: 1024, flags: "D X", flags_desc: "D = downloading\nX = peer from PEX" } })[0];
  const d = I.peerDetail(row);
  assert.equal(d.ip, "203.0.113.42");
  assert.equal(d.rest, ":51413 · uTP · downloaded " + Model.sizeText(1024));
  assert.equal(d.flags, "D X");
  assert.equal(d.flagsDesc, "D = downloading · X = peer from PEX");
  const v6 = I.peerDetail(I.peerRows({ "[::1]:6881": { connection: "BT" } })[0]);
  assert.equal(v6.ip, "[::1]");
  assert.equal(v6.rest.indexOf(":6881 · BT"), 0);
  assert.equal(I.peerDetail(null).ip, "");
});

// --- fix round 1: next announce, error text ---------------------------------

test("trackerRows carries next_announce (seconds) as nextAnnounce, null when absent or not positive", () => {
  const rows = I.trackerRows([
    { url: "udp://a.example:1/announce", status: 2, next_announce: 840 },
    { url: "udp://b.example:1/announce", status: 2 },
    { url: "udp://c.example:1/announce", status: 2, next_announce: 0 },
    { url: "udp://d.example:1/announce", status: 2, next_announce: -1 }
  ]).rows;
  assert.deepEqual(rows.map((r) => r.nextAnnounce), [840, null, null, null]);
});

test("trackerDetail: tier line carries 'next announce in Nm', '<1m' under a minute, omitted when absent", () => {
  const mk = (next) => I.trackerRows([{ url: "udp://a.example:1/announce", status: 2, tier: 0, next_announce: next }]).rows[0];
  assert.equal(I.trackerDetail(mk(840)).tier, "tier 0 · next announce in 14m");
  assert.equal(I.trackerDetail(mk(59)).tier, "tier 0 · next announce in <1m");
  assert.equal(I.trackerDetail(mk(3900)).tier, "tier 0 · next announce in 1h 5m");
  assert.equal(I.trackerDetail(mk(undefined)).tier, "tier 0");
  assert.equal(I.trackerDetail(mk(0)).tier, "tier 0");
});

test("listTab: an error entry exposes its text and never its retained rows", () => {
  const t = I.listTab("trackers", { trackers: TRACKERS_FIXTURE, error: "HTTP 500", at: 1000 }, 900, 1000, true);
  assert.equal(t.state, "error");
  assert.equal(t.error, "HTTP 500");
  assert.deepEqual(t.rows, []);
  assert.equal(I.listTab("trackers", { trackers: TRACKERS_FIXTURE, at: 1000 }, 900, 1000, true).error, "");
});

// --- infoView (Task 6) -------------------------------------------------------

test("infoView: a fresh entry carries pieces into cells/legend and props into groups", () => {
  const props = { has_metadata: true, total_downloaded: 1073741824 };
  const pieces = [2, 2, 0, 0];
  const v = I.infoView({ props: props, pieces: pieces, at: 1000 }, 900, true, { size: 5000 }, fmtDate);
  assert.equal(v.noMeta, false);
  assert.equal(v.cells.length, 48);
  assert.equal(v.legend, I.piecesLegend(pieces));
  assert.equal(v.groups[0].fields.find((f) => f.label === "Downloaded").value, "1.0 GiB");
});

test("infoView: no entry yet shows noMeta from the row alone and every group value —", () => {
  const v = I.infoView(undefined, 900, true, { size: -1 }, fmtDate);
  assert.equal(v.noMeta, true);
  assert.deepEqual(v.cells, []);
  for (const g of v.groups) for (const f of g.fields) assert.equal(f.value, "—");
});

test("infoView: a stale entry (at < sinceMs, e.g. after A->B->A) counts as none", () => {
  const props = { has_metadata: true };
  const v = I.infoView({ props: props, pieces: [2, 2], at: 800 }, 900, true, { size: -1 }, fmtDate);
  assert.equal(v.noMeta, true, "the stale props never override the row's own size");
  assert.deepEqual(v.cells, []);
});

test("infoView: sidecar down blanks a fresh entry too", () => {
  const props = { has_metadata: true };
  const v = I.infoView({ props: props, pieces: [2, 2], at: 1000 }, 900, false, { size: -1 }, fmtDate);
  assert.equal(v.noMeta, true, "props.has_metadata is ignored once down; the row's own size wins");
  assert.deepEqual(v.cells, []);
  for (const g of v.groups) for (const f of g.fields) assert.equal(f.value, "—");
});

test("infoView: has_metadata false wins even at a nonzero size", () => {
  const v = I.infoView({ props: { has_metadata: false }, pieces: [], at: 1000 }, 900, true, { size: 5000 }, fmtDate);
  assert.equal(v.noMeta, true);
});

// --- M2: a fresh error entry shows nothing retained -------------------------

test("infoView: a fresh error entry drops retained props/pieces -- groups all —, no pieces area", () => {
  const props = { has_metadata: true, total_downloaded: 1073741824 };
  const pieces = [2, 2, 0, 0];
  const v = I.infoView({ props: props, pieces: pieces, error: "HTTP 500", at: 1000 }, 900, true, { size: 5000 }, fmtDate);
  assert.equal(v.errored, true);
  assert.equal(v.noMeta, false, "the row still has a size, so noMeta keeps its ordinary meaning");
  assert.deepEqual(v.cells, [], "no pieces bar either");
  for (const g of v.groups) for (const f of g.fields) assert.equal(f.value, "—");
});

test("infoView: a fresh error on a no-metadata torrent still reports noMeta true (State keeps 'waiting for metadata', Files keeps its no-metadata copy) -- errored only blanks the pieces area", () => {
  const props = { has_metadata: true };
  const v = I.infoView({ props: props, pieces: [2, 2], error: "HTTP 500", at: 1000 }, 900, true, { size: -1 }, fmtDate);
  assert.equal(v.errored, true);
  assert.equal(v.noMeta, true, "props is dropped on error, so the row's own size (-1) wins the fallback, same as stale/sidecar-down");
  assert.deepEqual(v.cells, []);
});

test("infoView: no error at all reports errored false", () => {
  const v = I.infoView({ props: { has_metadata: true }, pieces: [2, 2], at: 1000 }, 900, true, { size: 5000 }, fmtDate);
  assert.equal(v.errored, false);
});

test("infoView: a stale error (at < sinceMs) is not fresh, so the row-size fallback still runs", () => {
  const props = { has_metadata: true, total_downloaded: 1073741824 };
  const v = I.infoView({ props: props, pieces: [2, 2], error: "HTTP 500", at: 800 }, 900, true, { size: 5000 }, fmtDate);
  assert.deepEqual(v.cells, [], "stale either way (at < sinceMs)");
  assert.equal(v.noMeta, false, "not fresh, so error is ignored too -- the row's own size (5000) wins the fallback");
});

// --- chartTab (Task 8) -------------------------------------------------------

test("chartTab: no entry yet is blank, then loading, exactly like tabState", () => {
  assert.equal(I.chartTab(undefined, 1000, 1000, true).state, "blank");
  assert.equal(I.chartTab(undefined, 1000, 1400, true).state, "loading");
});

test("chartTab: sidecar down wins even with a fresh entry", () => {
  const v = I.chartTab({ points: [[1, 5, 0]], at: 1000 }, 900, 1000, false);
  assert.equal(v.state, "sidecarDown");
});

test("chartTab: a read error is 'error' and carries its text", () => {
  const v = I.chartTab({ error: "HTTP 500", at: 1000 }, 900, 1000, true);
  assert.equal(v.state, "error");
  assert.equal(v.error, "HTTP 500");
});

test("chartTab: a stale entry (at < sinceMs) counts as none, same as listTab", () => {
  const v = I.chartTab({ points: [[1, 5, 0]], at: 800 }, 1000, 1000, true);
  assert.equal(v.state, "blank");
});

test("chartTab: an empty points array is still 'rows' -- SpeedChart draws its own idle state", () => {
  const v = I.chartTab({ points: [], at: 1000 }, 900, 1000, true);
  assert.equal(v.state, "rows");
  assert.equal(v.series.empty, true);
});

test("chartTab: a fresh non-empty entry threads points through chartSeries, windowed off entry.at", () => {
  const atMs = 1000000;
  const v = I.chartTab({ points: [[atMs / 1000, 5000, 0]], at: atMs }, 900, atMs, true);
  assert.equal(v.state, "rows");
  assert.equal(v.series.empty, false);
  assert.equal(v.series.down.length, 1);
});

test("chartTab: points older than CHART_SPAN_SECONDS before entry.at fall outside the window", () => {
  const atMs = 1000000;
  const tooOld = atMs / 1000 - I.CHART_SPAN_SECONDS - 1;
  const v = I.chartTab({ points: [[tooOld, 5000, 0]], at: atMs }, 900, atMs, true);
  assert.equal(v.series.empty, true);
});
