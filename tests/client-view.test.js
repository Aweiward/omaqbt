const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Model = require("../Model.js");
const Registry = require("../CommandRegistry.js");

// ClientView.js starts with a QML-only `.import "Model.js" as Model` line,
// which node can't parse. Strip `.import`/`.pragma` lines and run the rest
// as a function body in this realm (so deepEqual sees ordinary objects),
// with `Model` supplied exactly as QML would.
function loadClientView() {
  const file = path.join(__dirname, "..", "ClientView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module", "Model"], { filename: file })(mod, Model);
  return mod.exports;
}

const V = loadClientView();
const KEY = Registry.KEY;

const H = (c) => c.repeat(40);

function torrent(overrides) {
  return Object.assign({
    hash: H("a"), name: "a", state: "downloading", progress: 0.5,
    dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
    category: "", tags: [], tracker: ""
  }, overrides || {});
}

// --- keyEvent -------------------------------------------------------------

test("keyEvent builds exactly the dispatch event shape", () => {
  const ev = V.keyEvent(0x4a, "j", 0, 1234);
  assert.deepEqual(Object.keys(ev).sort(), ["key", "modifiers", "now", "text"]);
  assert.deepEqual(ev, { key: 0x4a, text: "j", modifiers: { ctrl: false, shift: false, alt: false }, now: 1234 });
});

test("keyEvent decodes the Qt modifier bits", () => {
  assert.deepEqual(V.keyEvent(KEY.L, "\f", 0x04000000, 0).modifiers, { ctrl: true, shift: false, alt: false });
  assert.deepEqual(V.keyEvent(0x47, "G", 0x02000000, 0).modifiers, { ctrl: false, shift: true, alt: false });
  assert.deepEqual(V.keyEvent(0x47, "g", 0x08000000, 0).modifiers, { ctrl: false, shift: false, alt: true });
  assert.deepEqual(V.keyEvent(0x47, "g", 0x02000000 | 0x04000000 | 0x08000000, 0).modifiers, { ctrl: true, shift: true, alt: true });
});

test("keyEvent tolerates missing text and modifiers", () => {
  const ev = V.keyEvent(KEY.Escape, undefined, undefined, undefined);
  assert.equal(ev.text, "");
  assert.equal(ev.now, 0);
  assert.deepEqual(ev.modifiers, { ctrl: false, shift: false, alt: false });
});

test("keyEvent output drives dispatch: Ctrl-l is pane.next, G is cursor.bottom", () => {
  const s = { mode: "NORMAL", pane: "table", hasTorrent: true };
  assert.equal(Registry.dispatch(s, V.keyEvent(KEY.L, "\f", V.MOD.Control, 0)).commandId, "pane.next");
  assert.equal(Registry.dispatch(s, V.keyEvent(0x47, "G", V.MOD.Shift, 0)).commandId, "cursor.bottom");
  assert.equal(Registry.dispatch(s, V.keyEvent(0x4a, "j", 0, 0)).commandId, "cursor.down");
});

// --- sort -----------------------------------------------------------------

test("nextSort cycles all eight modes with each mode's default direction", () => {
  let mode = "added";
  const seen = [];
  for (let i = 0; i < 8; i++) {
    const n = V.nextSort(mode);
    seen.push(n.sort + ":" + n.desc);
    mode = n.sort;
  }
  assert.deepEqual(seen, [
    "name:false", "size:true", "progress:true", "dl:true",
    "ul:true", "eta:false", "ratio:true", "added:true"
  ]);
});

test("nextSort from an unknown mode starts the cycle", () => {
  assert.equal(V.nextSort("speed").sort, "added");
});

test("sortTitle names the mode and direction; ETA desc reads longest first", () => {
  assert.equal(V.sortTitle("dl", true), "sorted by ↓ speed, fastest first");
  assert.equal(V.sortTitle("added", true), "sorted by date added, newest first");
  assert.equal(V.sortTitle("eta", true), "sorted by ETA, longest first");
  assert.equal(V.sortTitle("eta", false), "sorted by ETA, soonest first");
  assert.equal(V.sortTitle("bogus", false), "sorted by date added, oldest first");
});

test("sortColumn maps modes to table columns; added has none", () => {
  assert.equal(V.sortColumn("added"), "");
  assert.equal(V.sortColumn("dl"), "dl");
  assert.equal(V.sortColumn("name"), "name");
  assert.equal(V.sortMarker(true), "▾");
  assert.equal(V.sortMarker(false), "▴");
});

// --- filters --------------------------------------------------------------

test("filterLabel maps sentinel values to their sidebar labels", () => {
  assert.equal(V.filterLabel({ group: "status", value: "Seeding" }), "Seeding");
  assert.equal(V.filterLabel({ group: "category", value: "" }), "Uncategorized");
  assert.equal(V.filterLabel({ group: "tag", value: "" }), "Untagged");
  assert.equal(V.filterLabel({ group: "tracker", value: "" }), "Trackerless");
  assert.equal(V.filterLabel({ group: "tracker", value: "x.org" }), "x.org");
  assert.equal(V.filterLabel(null), "All");
});

test("paneTitle lowercases status labels only and adds the query", () => {
  assert.equal(V.paneTitle({ group: "status", value: "Active" }, "", "dl", true), "active · sorted by ↓ speed, fastest first");
  assert.equal(V.paneTitle({ group: "category", value: "Anime" }, " ghost ", "added", true), "Anime · “ghost” · sorted by date added, newest first");
});

// --- rows -----------------------------------------------------------------

test("sizeText matches the mockup: one decimal under 100, none above", () => {
  assert.equal(V.sizeText(512), "512 B");
  assert.equal(V.sizeText(1.3 * 1024 ** 3), "1.3 GiB");
  assert.equal(V.sizeText(754 * 1024 ** 2), "754 MiB");
  assert.equal(V.sizeText(-5), "0 B");
});

test("rateText is compact: 0, K without decimals, M/G with one under 100", () => {
  assert.equal(V.rateText(0), "0");
  assert.equal(V.rateText(100), "1K");
  assert.equal(V.rateText(820 * 1024), "820K");
  assert.equal(V.rateText(4.1 * 1024 * 1024), "4.1M");
  assert.equal(V.rateText(12.4 * 1024 * 1024), "12.4M");
  assert.equal(V.rateText(NaN), "0");
});

test("barText is 10 cells; only 100% fills all ten", () => {
  assert.equal(V.barText(0.61), "██████▒▒▒▒");
  assert.equal(V.barText(0.08), "█▒▒▒▒▒▒▒▒▒");
  assert.equal(V.barText(0.99), "█████████▒");
  assert.equal(V.barText(1), "██████████");
  assert.equal(V.barText(-1), "▒▒▒▒▒▒▒▒▒▒");
});

test("projectRow: downloading row", () => {
  const r = V.projectRow(torrent({ progress: 0.61, dlSpeed: 12.4 * 1024 * 1024, upSpeed: 820 * 1024, eta: 60, ratio: 0.123 }));
  assert.equal(r.glyph, "●");
  assert.equal(r.glyphTone, "accent");
  assert.equal(r.bar, "██████▒▒▒▒");
  assert.equal(r.progressText, "61%");
  assert.equal(r.dlText, "12.4M");
  assert.equal(r.ulText, "820K");
  assert.equal(r.etaText, "1m");
  assert.equal(r.ratioText, "0.12");
});

test("projectRow: seeding shows — for ↓ and ∞ for ETA", () => {
  const r = V.projectRow(torrent({ state: "uploading", progress: 1, eta: 8640000, upSpeed: 1.1 * 1024 * 1024, ratio: 3.41 }));
  assert.equal(r.glyph, "▲");
  assert.equal(r.glyphTone, "fg");
  assert.equal(r.dlText, "—");
  assert.equal(r.ulText, "1.1M");
  assert.equal(r.etaText, "∞");
  assert.equal(r.progressText, "100%");
});

test("projectRow: checking and moving use a state word in muted", () => {
  const c = V.projectRow(torrent({ state: "checkingDL", progress: 0.4 }));
  assert.equal(c.glyph, "↻");
  assert.equal(c.glyphTone, "muted");
  assert.equal(c.progressText, "checking");
  assert.equal(c.dlText, "—");
  assert.equal(c.etaText, "—");
  assert.equal(V.projectRow(torrent({ state: "moving" })).progressText, "moving");
});

test("projectRow: missing files is ! in urgent, no bar, and says why", () => {
  const r = V.projectRow(torrent({ state: "missingFiles", progress: 0.3 }));
  assert.equal(r.glyph, "!");
  assert.equal(r.glyphTone, "urgent");
  assert.equal(r.bar, "");
  assert.equal(r.progressText, "missing files");
  assert.equal(r.progressTone, "urgent");
  assert.equal(V.projectRow(torrent({ state: "error" })).progressText, "error");
});

test("projectRow: stopped is ‖ in muted with a percent", () => {
  const r = V.projectRow(torrent({ state: "stoppedDL", progress: 0.25 }));
  assert.equal(r.glyph, "‖");
  assert.equal(r.glyphTone, "muted");
  assert.equal(r.progressText, "25%");
  assert.equal(r.ulText, "—");
});

test("projectRow: every role is a string, keys are identical, tags are not a role", () => {
  const rows = [
    torrent({ tags: ["x", "y"] }),
    torrent({ hash: H("b"), state: "uploading", progress: 1 }),
    torrent({ hash: H("c"), state: "missingFiles" }),
    torrent({ hash: H("d"), name: null, size: undefined, ratio: undefined })
  ].map(V.projectRow);
  const keys = Object.keys(rows[0]).sort();
  assert.deepEqual(keys, ["hash"].concat(V.DISPLAY_FIELDS).sort());
  for (const r of rows) {
    assert.deepEqual(Object.keys(r).sort(), keys);
    for (const k of keys) assert.equal(typeof r[k], "string", k);
  }
  assert.equal("tags" in rows[0], false);
});

test("projectRow strips angle brackets from untrusted names", () => {
  assert.equal(V.projectRow(torrent({ name: "<img src=x>evil" })).name, "img src=xevil");
});

test("viewRows excludes pending magnets, applies filter, query and sort", () => {
  const list = [
    torrent({ hash: H("a"), name: "alpha", addedOn: 1, state: "uploading", progress: 1 }),
    torrent({ hash: H("b"), name: "beta", addedOn: 3 }),
    torrent({ hash: H("c"), name: "gamma", addedOn: 2 }),
    torrent({ hash: H("d"), name: "delta pending", addedOn: 4 })
  ];
  const all = V.viewRows(list, [H("d")], V.defaultFilter(), "", "added", true);
  assert.deepEqual(all.rows.map((r) => r.name), ["beta", "gamma", "alpha"]);
  assert.deepEqual(all.raw.map((r) => r.hash), [H("b"), H("c"), H("a")]);

  const seeding = V.viewRows(list, [H("d")], { group: "status", value: "Seeding" }, "", "added", true);
  assert.deepEqual(seeding.rows.map((r) => r.name), ["alpha"]);

  const q = V.viewRows(list, [], V.defaultFilter(), "TA", "name", false);
  assert.deepEqual(q.rows.map((r) => r.name), ["beta", "delta pending"]);

  const unknown = V.viewRows(list, [], { group: "bogus", value: "x" }, "", "added", true);
  assert.equal(unknown.rows.length, 0, "an unknown filter group fails closed");
});

test("viewRows feeds diffRows: a speed tick under sort dl reorders by moves and sets", () => {
  const before = [
    torrent({ hash: H("a"), dlSpeed: 300 }),
    torrent({ hash: H("b"), dlSpeed: 200 }),
    torrent({ hash: H("c"), dlSpeed: 100 })
  ];
  const after = [
    torrent({ hash: H("a"), dlSpeed: 300 }),
    torrent({ hash: H("b"), dlSpeed: 200 }),
    torrent({ hash: H("c"), dlSpeed: 900 * 1024 })
  ];
  const oldRows = V.viewRows(before, [], V.defaultFilter(), "", "dl", true).rows;
  const newRows = V.viewRows(after, [], V.defaultFilter(), "", "dl", true).rows;
  const ops = Model.diffRows(oldRows, newRows, V.DISPLAY_FIELDS);
  assert.ok(Array.isArray(ops));
  assert.deepEqual(Model.applyOps(oldRows, ops), newRows);
});

// --- cursor ---------------------------------------------------------------

const rows3 = [{ hash: "a" }, { hash: "b" }, { hash: "c" }];

test("resolveCursor keeps the hash while it is present, whatever its index", () => {
  assert.equal(V.resolveCursor([{ hash: "c" }, { hash: "a" }, { hash: "b" }], "b", 1), "b");
});

test("resolveCursor: a gone hash falls to the row at its old index, clamped", () => {
  assert.equal(V.resolveCursor([{ hash: "a" }, { hash: "c" }], "b", 1), "c");
  assert.equal(V.resolveCursor([{ hash: "a" }], "c", 2), "a");
});

test("resolveCursor: a restored hash that is gone goes to the first row", () => {
  assert.equal(V.resolveCursor(rows3, "zzz", -1), "a");
  assert.equal(V.resolveCursor(rows3, "", -1), "a");
});

test("resolveCursor keeps a restored hash while there are no rows yet", () => {
  assert.equal(V.resolveCursor([], "b", -1), "b");
});

test("moveCursor clamps at both ends and handles gg / G", () => {
  assert.equal(V.moveCursor(rows3, "a", "cursor.down"), "b");
  assert.equal(V.moveCursor(rows3, "c", "cursor.down"), "c");
  assert.equal(V.moveCursor(rows3, "a", "cursor.up"), "a");
  assert.equal(V.moveCursor(rows3, "b", "cursor.top"), "a");
  assert.equal(V.moveCursor(rows3, "a", "cursor.bottom"), "c");
  assert.equal(V.moveCursor(rows3, "gone", "cursor.down"), "a");
  assert.equal(V.moveCursor([], "x", "cursor.down"), "x");
});

// --- panes and states -----------------------------------------------------

test("nextPane cycles filters -> table -> inspector and back", () => {
  assert.equal(V.nextPane("table", 1), "inspector");
  assert.equal(V.nextPane("inspector", 1), "filters");
  assert.equal(V.nextPane("filters", -1), "inspector");
  assert.equal(V.nextPane("table", -1), "filters");
  assert.equal(V.nextPane("bogus", 1), "inspector");
});

const up = { installed: true, daemon: true, lockHolder: "none", api: true, liveCount: 3, visibleCount: 3 };

test("tableState priority: loading, Qt GUI, not installed, daemon, api, empty, no match", () => {
  assert.equal(V.tableState(Object.assign({}, up, { loading: true })), "loading");
  assert.equal(V.tableState(Object.assign({}, up, { lockHolder: "gui", daemon: false })), "gui");
  assert.equal(V.tableState(Object.assign({}, up, { installed: false, daemon: false })), "notInstalled");
  assert.equal(V.tableState(Object.assign({}, up, { daemon: false, api: false })), "daemon");
  assert.equal(V.tableState(Object.assign({}, up, { api: false })), "api");
  assert.equal(V.tableState(Object.assign({}, up, { liveCount: 0, visibleCount: 0 })), "empty");
  assert.equal(V.tableState(Object.assign({}, up, { visibleCount: 0 })), "noMatch");
  assert.equal(V.tableState(up), "rows");
});

test("stateCopy: daemon down, Qt open and empty use the final copy", () => {
  const d = V.stateCopy("daemon");
  assert.equal(d.title, "qbittorrent-nox isn't running");
  assert.equal(d.body, "Your library and settings are untouched. Start the daemon to see them.");
  assert.deepEqual(d.keys.map((k) => k.key), ["Enter", ":"]);
  const g = V.stateCopy("gui");
  assert.equal(g.title, "qBittorrent (Qt) is open");
  assert.equal(g.tone, "urgent");
  assert.deepEqual(g.keys, [{ key: "r", label: "Check again" }]);
  const e = V.stateCopy("empty");
  assert.equal(e.title, "No torrents yet");
  assert.equal(e.body, "Click a magnet link in your browser, or add one here.");
  assert.deepEqual(e.keys.map((k) => k.key), ["/", "y"]);
});

test("stateCopy: no match names the query, the filter and the All count", () => {
  const c = V.stateCopy("noMatch", { query: "ghost", filter: { group: "status", value: "Seeding" }, matchesInAll: 2 });
  assert.equal(c.title, "Nothing matches “ghost” in Seeding");
  assert.equal(c.body, "2 matches in All.");
  assert.deepEqual(c.keys, [
    { key: "Esc", label: "Clear the text filter" },
    { key: "Esc Esc", label: "Clear filter, show All" }
  ]);
  assert.equal(V.stateCopy("noMatch", { query: "x", filter: null, matchesInAll: 1 }).body, "1 match in All.");
  const f = V.stateCopy("noMatch", { query: "", filter: { group: "tag", value: "" }, matchesInAll: 4 });
  assert.equal(f.title, "Nothing in Untagged");
  assert.deepEqual(f.keys.map((k) => k.key), ["Esc Esc"]);
});

// --- actions --------------------------------------------------------------

test("toggleStarts only when every target is stopped", () => {
  assert.equal(V.toggleStarts([{ state: "stoppedDL", progress: 0.2 }]), true);
  assert.equal(V.toggleStarts([{ state: "stoppedUP", progress: 1 }, { state: "pausedDL", progress: 0 }]), true);
  assert.equal(V.toggleStarts([{ state: "stoppedDL", progress: 0 }, { state: "downloading", progress: 0 }]), false);
  assert.equal(V.toggleStarts([]), false);
});

test("progressText pluralizes", () => {
  assert.equal(V.progressText("remove", 2), "Removing 2 torrents…");
  assert.equal(V.progressText("delete", 1), "Deleting 1 torrent and their files…");
  assert.equal(V.progressText("start", 1), "Starting 1 torrent…");
});

test("confirmLine matches the spec's CONFIRM copy", () => {
  const d = V.confirmLine({ commandId: "torrent.delete", count: 2, withFiles: true });
  assert.equal(d.lead + d.strong + d.tail, "Delete 2 torrents and their files from disk?");
  assert.equal(d.strong, "and their files");
  assert.equal(d.accept, "delete");
  const r = V.confirmLine({ commandId: "torrent.remove", count: 3, withFiles: false });
  assert.equal(r.accept, "remove");
  assert.match(r.lead, /^Remove 3 torrents/);
});

test("modeHints: CONFIRM and INSERT hints", () => {
  assert.deepEqual(V.modeHints("CONFIRM", { accept: "delete" }).map((h) => h.key + " " + h.label), ["y delete", "n/Esc keep"]);
  assert.equal(V.modeHints("INSERT", { purpose: "move" })[0].label, "move");
  assert.ok(V.modeHints("NORMAL").some((h) => h.key === "q"));
});

test("vpnPart: none, bound, unbound", () => {
  assert.equal(V.vpnPart("", "", false), null);
  assert.deepEqual(V.vpnPart("wg0", "wg0", false), { text: "wg0 bound", tone: "fg" });
  assert.deepEqual(V.vpnPart("wg0", "eth0", true), { text: "wg0 not bound", tone: "urgent" });
});

test("isAbsolutePath rejects relative, ~ and bare / paths", () => {
  assert.equal(V.isAbsolutePath("/dl/iso"), true);
  assert.equal(V.isAbsolutePath("  /dl  "), true);
  assert.equal(V.isAbsolutePath("dl/iso"), false);
  assert.equal(V.isAbsolutePath("~/dl"), false);
  assert.equal(V.isAbsolutePath("/"), false);
  assert.equal(V.isAbsolutePath(""), false);
});
