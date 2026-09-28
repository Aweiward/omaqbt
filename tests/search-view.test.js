// Slice 5a (Task 3): SearchView.js, the Search view's pure rules, against
// every row of tests/fixtures/search-rules-cases.json and the window's copy.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadSearchView() {
  const file = path.join(__dirname, "..", "SearchView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"], { filename: file })(mod);
  return mod.exports;
}

const S = loadSearchView();
const DATA = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "search-rules-cases.json"), "utf8"));
const MAGNET = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=debian";
const V1 = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a";

// ---- every case-file row -----------------------------------------------------------------

for (const kind of ["pluginUrl", "pageLink", "addLink", "magnetHash", "row", "pluginName", "pattern", "category", "searchId", "installReadback"]) {
  test("case file: every " + kind + " row", () => {
    const rows = DATA.cases.filter((c) => c.kind === kind);
    assert.ok(rows.length > 0);
    for (const c of rows) {
      const label = c.why + " " + JSON.stringify(c.input).slice(0, 120);
      const got = S.check(kind, c.input);
      assert.equal(got.ok, c.ok, label);
      if (!c.ok && "message" in c) assert.equal(got.message, c.message, label);
      if ("normalised" in c) assert.deepEqual(got.normalised, c.normalised, label);
      if ("host" in c) assert.equal(got.host, c.host, label);
    }
  });
}

test("the window's copy and qbt's sentences are the case file's", () => {
  assert.deepEqual(S.WINDOW, DATA.window);
  for (const k of Object.keys(S.SENTENCES)) assert.equal(S.SENTENCES[k], DATA.sentences[k], k);
  const messages = new Set(DATA.cases.filter((c) => c.message).map((c) => c.message));
  for (const [k, m] of Object.entries(S.MSG)) assert.ok(messages.has(m), "MSG." + k + " is a case-file message: " + m);
});

// ---- punycode (RFC 3492) ------------------------------------------------------------------

test("punycode: RFC 3492 and IDNA sample labels", () => {
  assert.equal(S.punycode("ü"), "tda");
  assert.equal(S.punycode("bücher"), "bcher-kva");
  assert.equal(S.punycode("münchen"), "mnchen-3ya");
  assert.equal(S.punycode("mañana"), "maana-pta");
  assert.equal(S.punycode("日本語"), "wgv71a119e");
  assert.equal(S.punycode("правда"), "80aafi6cg");
  // RFC 3492 7.1 (A) Arabic (Egyptian), (L) the Japanese mixed-script sample.
  assert.equal(S.punycode("ليهمابتكلموشعربي؟"), "egbpdaj6bu4bxfgehfvwxn");
  assert.equal(S.punycode("3年b組金八先生"), "3b-ww4c5e180e575a65lsy2b");
  // An astral character counts once.
  assert.equal(S.punycode("a😀"), "a-jv3s");
});

test("hosts: lowercased before punycode, and the 2048 limit counts code points", () => {
  assert.equal(S.hostOf("BÜCHER.example").host, "xn--bcher-kva.example");
  assert.equal(S.hostOf("[2001:DB8::1]:443").host, "[2001:db8::1]");
  assert.equal(S.hostOf("[]").ok, false);
  assert.equal(S.hostOf("a:b:c").ok, false);
  const base = "https://example.org/";
  const astral = "😀".repeat(2048 - base.length - 3);
  // 2048 code points (4 more UTF-16 units each for the emoji) is fine
  // for the length rule; the name rule then refuses the emoji.
  const r = S.checkPluginUrl(base + astral + ".py");
  assert.equal(r.message, "Plugin names use only letters, digits and _.");
  assert.equal(S.checkPluginUrl(base + astral + "x.py").message, "Use a URL of at most 2048 characters.");
});

// ---- results ------------------------------------------------------------------------------

function raw(extra) {
  return Object.assign({ fileName: "debian.iso", fileUrl: MAGNET, fileSize: 1024, nbSeeders: 5, nbLeechers: 1,
    engineName: "piratebay", siteUrl: "https://thepiratebay.org", descrLink: "https://thepiratebay.org/d/1", pubDate: 100 }, extra || {});
}

test("merge: same-hash rows from two plugins become one row with both plugins", () => {
  const a = S.mergeResults([], [raw(), raw({ fileName: "x", fileUrl: "https://e.org/a.torrent", engineName: "" })], 0);
  assert.equal(a.rows.length, 2);
  assert.equal(a.added.length, 2);
  const same = S.mergeResults([], [raw(), raw({ engineName: "eztv" })], 0);
  assert.deepEqual(same.added.map((r) => r.engines), [["piratebay", "eztv"]], "a merge within one batch shows on the added row");
  assert.deepEqual(same.updated, []);
  const b = S.mergeResults(a.rows, [raw({ engineName: "eztv", fileUrl: "magnet:?xt=urn:btih:" + V1.toUpperCase() }), raw()], 2);
  assert.equal(b.rows.length, 2, "base case and upper-case hash merge");
  assert.deepEqual(b.rows[0].engines, ["piratebay", "eztv"]);
  assert.deepEqual(b.updated, ["h:" + V1]);
  assert.deepEqual(a.rows[0].engines, ["piratebay"], "held rows are not changed in place");
  const counts = S.pluginCounts(b.rows);
  assert.deepEqual(counts, { piratebay: 1, eztv: 1, "": 1 });
});

test("the Plugins column: All results, enabled plugins, plugins with results, then other", () => {
  const plugins = [{ name: "piratebay", fullName: "The Pirate Bay", enabled: true }, { name: "off", fullName: "Off", enabled: false },
    { name: "eztv", fullName: "‮EZTV", enabled: false }]
  const col = S.pluginColumn(plugins, { piratebay: 3, eztv: 1, gone: 2, "": 4 }, 9);
  assert.deepEqual(col.map((r) => [r.label, r.count]), [["All results", 9], ["The Pirate Bay", 3], ["EZTV", 1], ["gone", 2], ["other", 4]]);
  assert.equal(S.matchesPlugin({ engines: ["a", "b"] }, "b"), true);
  assert.equal(S.matchesPlugin({ engines: ["a"] }, ""), false);
  assert.equal(S.matchesPlugin({ engines: ["a"] }, null), true);
});

test("the library match (OV11): btih vs hash, btmh vs infohash_v2 and the v2 id; http never", () => {
  const v2 = "ab".repeat(32);
  const set = S.librarySet([{ hash: V1.toUpperCase() }, { hash: "cd".repeat(20), infohash_v2: v2 }, { hash: "ef".repeat(32).slice(0, 40) }]);
  assert.equal(S.inLibrary(V1, null, set), true);
  assert.equal(S.inLibrary(null, v2, set), true);
  assert.equal(S.inLibrary(null, "ef".repeat(32), set), true, "a v2-only torrent's id is its first 40 hex");
  assert.equal(S.inLibrary(null, null, set), false);
  const http = S.resultFrom(raw({ fileUrl: "https://e.org/debian.torrent" }), 0);
  assert.equal(S.inLibrary(http.v1, http.v2, set), false);
  assert.equal(S.addPlan(S.resultFrom(raw(), 0), "1.0 KiB", set).kind, "library");
  assert.equal(S.addPlan(S.resultFrom(raw(), 0), "1.0 KiB", set).note, "Already in your library.");
});

test("the library match (OV11) with the status rows' infohash_v1 and infohash_v2", () => {
  const Model = (() => {
    const file = path.join(__dirname, "..", "Model.js");
    const src = fs.readFileSync(file, "utf8").split("\n").map((l) => (/^\s*\.(import|pragma)\b/.test(l) ? "" : l)).join("\n");
    return vm.runInNewContext(src + "\n;({ parseStatusJson })", {});
  })();
  const v1 = "11".repeat(20), hybridV2 = "22".repeat(32), onlyV2 = "33".repeat(32);
  // Status rows as qbt status prints them: "" when qBittorrent has no such id.
  const status = Model.parseStatusJson(JSON.stringify({ installed: true, daemon: true, api: true, torrents: [
    { hash: v1.toUpperCase(), infohash_v1: v1.toUpperCase(), infohash_v2: hybridV2.toUpperCase(), name: "hybrid", state: "uploading" },
    { hash: onlyV2.slice(0, 40), infohash_v1: "", infohash_v2: onlyV2, name: "v2 only", state: "uploading" },
    { hash: "44".repeat(20), infohash_v1: "44".repeat(20), infohash_v2: "", name: "v1 only", state: "uploading" }
  ] }));
  assert.equal(status.torrents[0].infohash_v2, hybridV2.toUpperCase());
  const set = S.librarySet(status.torrents);
  assert.equal(S.inLibrary(v1, null, set), true, "btih vs hash and infohash_v1");
  assert.equal(S.inLibrary(null, hybridV2, set), true, "btmh vs infohash_v2 (a hybrid's hash is its v1)");
  assert.equal(S.inLibrary(null, onlyV2, set), true, "btmh vs a v2-only torrent's infohash_v2");
  assert.equal(S.inLibrary("44".repeat(20), null, set), true);
  assert.equal(S.inLibrary(onlyV2.slice(0, 40), null, set), true, "a btih still meets qBittorrent's id (the hash)");
  assert.equal(S.inLibrary(null, "44".repeat(20) + "55".repeat(12), set), false, "a btmh never meets a v1 torrent whose row says it has no v2");
  assert.equal(S.inLibrary(null, v1 + "66".repeat(12), set), false, "nor a hybrid's hash, which is its v1");
  assert.equal(S.inLibrary(hybridV2.slice(0, 40), null, set), false, "a btih never meets a v2 id");
  // The fields absent (an older helper): the hash-only path still works.
  const old = S.librarySet([{ hash: v1 }, { hash: onlyV2.slice(0, 40) }]);
  assert.equal(S.inLibrary(v1, null, old), true);
  assert.equal(S.inLibrary(null, onlyV2, old), true);
  assert.equal(S.inLibrary(null, null, old), false);
  assert.equal(S.inLibrary(v1, onlyV2, {}), false, "an empty set matches nothing");
});

test("BAD refuses the soft hyphen and the IDNA dots in every URL kind", () => {
  for (const ch of ["\u00ad", "\u3002", "\uff0e", "\uff61"]) {
    const name = "U+" + ch.codePointAt(0).toString(16).toUpperCase().padStart(4, "0");
    assert.deepEqual(S.checkPluginUrl("https://example" + ch + "org/jackett.py"), { ok: false, message: S.MSG.pluginUrlBad }, "pluginUrl " + name);
    assert.deepEqual(S.checkPageLink("https://example" + ch + "org/d/1"), { ok: false, message: S.MSG.pageBad }, "pageLink " + name);
    assert.deepEqual(S.checkAddLink(["https://example" + ch + "org/d.torrent"]), { ok: false, message: S.MSG.noLink }, "addLink " + name);
    assert.deepEqual(S.checkAddLink(["https://example" + ch + "org/d/1", "piratebay"]), { ok: false, message: S.MSG.noLink }, "addLink via a plugin " + name);
    assert.equal(S.copyableLink("https://example" + ch + "org/d.torrent"), false, "y " + name);
  }
});

test("sort: seeds descending by default, — last either way, ties by arrival", () => {
  const rows = S.mergeResults([], [raw({ fileUrl: "u1", nbSeeders: 3, fileName: "b" }), raw({ fileUrl: "u2", nbSeeders: -1, fileName: "a" }),
    raw({ fileUrl: "u3", nbSeeders: 9, fileName: "c" }), raw({ fileUrl: "u4", nbSeeders: 3, fileName: "d" })], 0).rows;
  const names = (r) => r.map((x) => x.name).join("");
  assert.equal(names(S.sortResults(rows, "seeds", true)), "cbda");
  assert.equal(names(S.sortResults(rows, "seeds", false)), "bdca");
  assert.equal(names(S.sortResults(rows, "name", false)), "abcd");
  assert.deepEqual(S.nextSort("seeds"), { sort: "name", desc: false });
  assert.deepEqual(S.nextSort("plugin"), { sort: "seeds", desc: true });
  assert.equal(S.sortTitle("seeds", true), "sorted by seeds ▾");
});

// ---- the States table (as amended by OV1 and OV8) -------------------------------------------------

test("the query bar and the empty states", () => {
  assert.equal(S.runText("running", 41), "searching… · 41 results");
  assert.equal(S.runText("starting", 0), "searching… · 0 results");
  assert.equal(S.runText("done", 64), "done · 64 results");
  assert.equal(S.runText("stopped", 3), "stopped · 3 results");
  assert.equal(S.runText("none", 0), "");
  assert.equal(S.cappedText(true, 5120), "showing 2000 of 5120");
  assert.equal(S.cappedText(false, 5), "");
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 0, state: "none", rows: 0 }), "No search plugins yet");
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 1, state: "running", rows: 0 }), "No results yet");
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 1, state: "done", query: " xyz ", rows: 0 }),
    "No results for \"xyz\". Try fewer words, or check which plugins are on (P).");
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 1, state: "done", rows: 3 }), "");
  assert.equal(S.pluginsTitle([{ enabled: true }, { enabled: false }, { enabled: true }]), "3 installed · 2 enabled");
});

test("categories: all first, then what enabled plugins support, in qBittorrent's order", () => {
  const plugins = [
    { name: "a", enabled: true, supportedCategories: [{ id: "tv", name: "TV shows" }, { id: "movies", name: "Movies" }, { id: "bogus", name: "X" }] },
    { name: "b", enabled: false, supportedCategories: [{ id: "anime", name: "Anime" }] },
    { name: "c", enabled: true, supportedCategories: [{ id: "movies", name: "Movies" }, { id: "books", name: "Books" }] }
  ];
  assert.deepEqual(S.categoryRows(plugins).map((r) => r.id), ["all", "books", "movies", "tv"]);
  assert.equal(S.categoryRows(plugins)[0].name, "All categories");
  assert.equal(S.effectiveCategory("anime", plugins), "all", "an off plugin's category falls back to all");
  assert.equal(S.effectiveCategory("tv", plugins), "tv");
  assert.deepEqual(S.categoryRows([]).map((r) => r.id), ["all"]);
});

test("recent keeps the last 8, newest first, once each", () => {
  let r = [];
  for (let i = 0; i < 10; i++) r = S.recentPush(r, "q" + i);
  assert.deepEqual(r, ["q9", "q8", "q7", "q6", "q5", "q4", "q3", "q2"]);
  assert.deepEqual(S.recentPush(r, " q5 ").slice(0, 3), ["q5", "q9", "q8"]);
});

// ---- confirms and notes (A1, D3, D4) ------------------------------------------------------------------

test("the CONFIRM lines", () => {
  const plan = S.addPlan(S.resultFrom(raw(), 0), "650.0 MiB", {});
  assert.equal(plan.kind, "confirm");
  assert.equal(plan.line, "Add debian.iso (650.0 MiB) from thepiratebay.org?", "a magnet names the plugin's site");
  assert.equal(plan.via, "add");
  const https = S.addPlan(S.resultFrom(raw({ fileUrl: "https://Dl.Example.org:8443/x/123" }), 0), "1 B", {});
  assert.equal(https.line, "Add debian.iso (1 B) from dl.example.org?");
  assert.equal(https.via, "plugin");
  assert.equal(https.plugin, "piratebay");
  const bad = S.addPlan(S.resultFrom(raw({ fileUrl: "http://e.org/a.torrent" }), 0), "1 B", {});
  assert.deepEqual([bad.kind, bad.note], ["refuse", "That result has no usable link."]);
  assert.equal(S.openConfirm("linuxtracker.org"), "Open linuxtracker.org in your browser? It won't go through the VPN.");
  assert.deepEqual(S.installConfirm("jackett", "example.org"),
    { line: "Install jackett from example.org?", detail: "This runs Python code as qBittorrent, with access to your downloads." });
  assert.equal(S.uninstallConfirm("jackett"), "Uninstall jackett?");
});

test("done notes: Added only for a magnet once it's in; Sent for a plugin or an https .torrent", () => {
  assert.equal(S.addedNote("add", MAGNET, "debian"), null);
  assert.equal(S.addedNote("plugin", "https://e.org/dl/1", "debian"), "Sent debian to qBittorrent · it appears when its download finishes.");
  assert.equal(S.addedNote("add", "https://e.org/debian.torrent", "debian"), "Sent debian to qBittorrent · it appears when its download finishes.");
  assert.equal(S.addedText("debian"), "Added debian.");
});

// ---- sidecar replies (OV7, Ruling FB) --------------------------------------------------------------------

test("replies: stale ids dropped, a wrong offset re-sent, gone, and the final rule", () => {
  const r = (o) => Object.assign({ type: "search", id: 7, status: "Running", total: 10, offset: 0, rows: [], capped: false }, o);
  assert.equal(S.replyAction(r({}), 0, 0), "stale", "no job");
  assert.equal(S.replyAction(r({ id: 6 }), 7, 0), "stale", "another job");
  assert.equal(S.replyAction(r({ offset: 3 }), 7, 5), "resend", "a duplicate");
  assert.equal(S.replyAction(r({ offset: 8 }), 7, 5), "resend", "a gap");
  assert.equal(S.replyAction(r({ offset: 5 }), 7, 5), "apply");
  assert.equal(S.replyAction({ type: "search", id: 7, error: "gone" }, 7, 5), "gone");
  assert.equal(S.isFinal(r({ status: "Stopped", total: 3, offset: 1, rows: [{}, {}] })), true);
  assert.equal(S.isFinal(r({ status: "Stopped", total: 3, offset: 0, rows: [{}] })), false, "Stopped with rows left to read");
  assert.equal(S.isFinal(r({ status: "Running", total: 2, offset: 0, rows: [{}, {}] })), false);
  assert.equal(S.isFinal(r({ status: "Stopped", total: 5000, offset: 2000, rows: [] })), true, "the cap");
  assert.equal(S.isFinal(r({ status: "Stopped", total: 0, offset: 0, rows: [] })), true, "an empty final reply");
});

// ---- fix round 1 (Rulings FD, FE, FF) ----------------------------------------------------------------

test("FE: the pattern trims with Qt's isSpace set, not String.prototype.trim", () => {
  const spaces = "\t\n\u000b\f\r \u0085         　";
  assert.equal(S.qtTrim(spaces + "deb ian" + spaces), "deb ian");
  assert.equal(S.qtTrim("﻿x﻿"), "﻿x﻿", "U+FEFF isn't a space to Qt");
  assert.equal(S.qtTrim("​x"), "​x", "nor a zero-width space (Cf)");
  assert.equal(S.checkPattern("﻿").ok, true);
  assert.equal(S.checkPattern(" 　 ").message, "Type something to search for.");
  assert.deepEqual(S.recentPush([], "　debian "), ["debian"]);
});

test("FF: an empty engineName is the plugin whose url is the row's siteUrl, else other", () => {
  const plugins = [{ name: "linuxtracker", fullName: "Linux Tracker", url: "https://linuxtracker.org", enabled: true }];
  const a = S.resultFrom(raw({ engineName: "", siteUrl: "https://linuxtracker.org" }), 0, plugins);
  assert.equal(a.engine, "linuxtracker");
  assert.equal(S.resultFrom(raw({ engineName: "", siteUrl: "https://linuxtracker.org/" }), 0, plugins).engine, "", "exactly equal only");
  assert.equal(S.resultFrom(raw({ engineName: "", siteUrl: "" }), 0, [{ name: "x", url: "" }]).engine, "", "an empty url never matches");
  const rows = S.mergeResults([], [raw({ engineName: "", siteUrl: "https://linuxtracker.org", fileUrl: "https://lt.example/d/1" })], 0, []).rows;
  assert.deepEqual(S.pluginCounts(rows), { "": 1 }, "before the plugin list arrives: other");
  const again = S.remapEngines(rows, plugins);
  assert.deepEqual(S.pluginCounts(again), { linuxtracker: 1 });
  const plan = S.addPlan(again[0], "1 B", {});
  assert.equal(plan.plugin, "linuxtracker", "the mapped name goes to qbt search add");
  assert.equal(plan.via, "plugin");
});

test("FF: Recent rows follow the plugins in the column", () => {
  const col = S.pluginColumn([], {}, 0, ["ubuntu", "debian"]);
  assert.deepEqual(col.map((r) => [r.kind, r.label]), [["all", "All results"], ["recent", "ubuntu"], ["recent", "debian"]]);
  assert.equal(col[1].query, "ubuntu");
});

test("FD: a filter that hides every row says so", () => {
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 1, state: "running", rows: 3, visible: 0, filter: "EZTV" }), "No results from EZTV.");
  assert.equal(S.emptyText({ pluginsLoaded: true, pluginCount: 1, state: "running", rows: 3, visible: 2, filter: "EZTV" }), "");
});
