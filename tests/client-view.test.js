const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Model = require("../Model.js");
const Registry = require("../CommandRegistry.js");

// ClientView.js starts with QML-only `.import "Model.js" as Model` /
// `.import "CommandRegistry.js" as Registry` lines, which node can't parse.
// Strip `.import`/`.pragma` lines and run the rest as a function body in
// this realm (so deepEqual sees ordinary objects), with `Model` and
// `Registry` supplied exactly as QML would.
function loadClientView() {
  const file = path.join(__dirname, "..", "ClientView.js");
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module", "Model", "Registry"], { filename: file })(mod, Model, Registry);
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
  assert.deepEqual(d.keys.map((k) => k.key), ["Enter"], "no \":\" Commands hint until the palette ships (slice 1b)");
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

// --- blocking states dispatch as the table pane ---------------------------

test("dispatchPane: rows and noMatch keep the real pane", () => {
  assert.equal(V.dispatchPane("inspector", "rows"), "inspector");
  assert.equal(V.dispatchPane("filters", "noMatch"), "filters");
});

test("dispatchPane: blocking states dispatch as the table pane", () => {
  for (const st of ["loading", "gui", "notInstalled", "daemon", "api", "empty"]) {
    for (const pane of ["filters", "inspector", "table"]) {
      // Final fix wave (ruling BS, Important 4): the filters pane in the
      // empty library keeps its keys (see the next tests).
      if (st === "empty" && pane === "filters") continue;
      assert.equal(V.dispatchPane(pane, st), "table", st + "/" + pane);
    }
  }
});

test("dispatchPane makes Enter and y reach their commands from any restored pane", () => {
  // Final fix wave (ruling BS, Important 4): the filters pane in the empty
  // library now dispatches as itself; its y is covered by the test after
  // this one, and Enter there is filter.apply.
  for (const pane of ["inspector"]) {
    const base = { mode: "NORMAL", hasTorrent: false };
    // daemon / notInstalled: Enter must come back as inspector.files (the
    // window turns it into start daemon / install), not filter.apply.
    for (const st of ["daemon", "notInstalled"]) {
      const r = Registry.dispatch(Object.assign({}, base, { pane: V.dispatchPane(pane, st) }), V.keyEvent(KEY.Return, "\r", 0, 0));
      assert.equal(r.commandId, "inspector.files", st + "/" + pane);
    }
    // empty: y must come back blocked (the window reads that as add from
    // clipboard), not silently unmatched.
    const y = Registry.dispatch(Object.assign({}, base, { pane: V.dispatchPane(pane, "empty") }), V.keyEvent(0x59, "y", 0, 0));
    assert.equal(y.commandId, null);
    assert.equal(y.blocked, "needs a selected torrent", "empty/" + pane);
    // and without the fix the same key does nothing from the filters pane
    // (y is also an inspector-pane key since the Info tab lists it)
    if (pane === "filters") {
      const raw = Registry.dispatch(Object.assign({}, base, { pane: pane }), V.keyEvent(0x59, "y", 0, 0));
      assert.equal(raw.blocked, undefined);
    }
  }
});

// --- Task 8: tones ---------------------------------------------------------

test("toneColor maps tone names onto the palette it is given", () => {
  const p = { foreground: "F", accent: "A", muted: "M", urgent: "U", background: "B" };
  assert.equal(V.toneColor("accent", p), "A");
  assert.equal(V.toneColor("muted", p), "M");
  assert.equal(V.toneColor("urgent", p), "U");
  assert.equal(V.toneColor("fg", p), "F");
  assert.equal(V.toneColor("anything", p), "F");
});

// --- Task 8: VISUAL and targets ---------------------------------------------

const R = (...ls) => ls.map((l) => ({ hash: H(l) }));

test("visualRange spans anchor..cursor inclusive in the current order, either direction", () => {
  const rows = R("a", "b", "c", "d");
  assert.deepEqual(V.visualRange(rows, H("b"), H("d")), [H("b"), H("c"), H("d")]);
  assert.deepEqual(V.visualRange(rows, H("d"), H("b")), [H("b"), H("c"), H("d")]);
  assert.deepEqual(V.visualRange(rows, H("c"), H("c")), [H("c")]);
});

test("visualRange collapses to the cursor when the anchor is gone, and is empty with no cursor row", () => {
  const rows = R("a", "b", "c");
  assert.deepEqual(V.visualRange(rows, H("z"), H("b")), [H("b")]);
  assert.deepEqual(V.visualRange(rows, H("a"), H("z")), []);
  assert.deepEqual(V.visualRange([], H("a"), H("a")), []);
});

test("targetHashes: the range only while VISUAL, the cursor row otherwise", () => {
  const rows = R("a", "b", "c");
  assert.deepEqual(V.targetHashes("VISUAL", rows, H("c"), H("a")), [H("a"), H("b"), H("c")]);
  assert.deepEqual(V.targetHashes("NORMAL", rows, H("c"), H("a")), [H("c")], "a stale anchor never widens NORMAL");
  assert.deepEqual(V.targetHashes("NORMAL", rows, H("z"), ""), []);
});

test("dispatchState feeds selectionCount only in VISUAL, and blocking states dispatch as the table", () => {
  const base = { mode: "VISUAL", pane: "table", prefix: null, prefixAt: 0, pending: null };
  const st = V.dispatchState(base, "table", "rows", true, [H("a"), H("b")]);
  assert.equal(st.selectionCount, 2);
  assert.equal(st.hasTorrent, true);
  assert.equal(V.dispatchState(Object.assign({}, base, { mode: "NORMAL" }), "table", "rows", true, [H("a"), H("b")]).selectionCount, 0);
  const blocked = V.dispatchState(Object.assign({}, base, { mode: "NORMAL" }), "filters", "daemon", true, []);
  assert.equal(blocked.pane, "table");
  assert.equal(blocked.hasTorrent, false);
  assert.equal(base.selectionCount, undefined, "the input state is not mutated");
});

test("VISUAL end to end: V, j, Space acts on both rows and the range ends", () => {
  const rows = R("a", "b", "c");
  let reg = { mode: "NORMAL", pane: "table", prefix: null, prefixAt: 0, hasTorrent: false, selectionCount: 0, pending: null };
  let cursor = H("a");
  let anchor = "";
  function press(text, key) {
    const targets = V.targetHashes(reg.mode, rows, cursor, anchor);
    const st = V.dispatchState(reg, "table", "rows", V.indexOfHash(rows, cursor) >= 0, targets);
    const res = Registry.dispatch(st, V.keyEvent(key, text, 0, 0));
    reg = res.state;
    anchor = V.nextAnchor(res.state.mode, res.commandId, anchor, cursor);
    if (res.commandId === "cursor.down") cursor = V.moveCursor(rows, cursor, "cursor.down");
    return { res, targets };
  }
  press("V", 0x56);
  assert.equal(reg.mode, "VISUAL");
  assert.equal(anchor, H("a"));
  press("j", 0x4a);
  assert.deepEqual(V.targetHashes(reg.mode, rows, cursor, anchor), [H("a"), H("b")]);
  const sp = press(" ", KEY.Space);
  assert.equal(sp.res.commandId, "torrent.toggle");
  assert.deepEqual(sp.targets, [H("a"), H("b")], "targets are the range as it stood at keypress");
  assert.equal(sp.res.args.count, 2);
  assert.equal(reg.mode, "NORMAL");
  assert.equal(anchor, "");
  assert.equal(reg.selectionCount, 0);
});

test("VISUAL x and X always go through CONFIRM, even over 1 row", () => {
  const rows = R("a", "b");
  const vis = { mode: "VISUAL", pane: "table", prefix: null, prefixAt: 0, pending: null };
  const two = V.dispatchState(vis, "table", "rows", true, V.targetHashes("VISUAL", rows, H("b"), H("a")));
  assert.equal(Registry.dispatch(two, V.keyEvent(0x58, "x", 0, 0)).confirm.count, 2);
  const one = V.dispatchState(vis, "table", "rows", true, V.targetHashes("VISUAL", rows, H("a"), H("a")));
  assert.equal(Registry.dispatch(one, V.keyEvent(0x58, "x", 0, 0)).confirm.count, 1);
  assert.equal(Registry.dispatch(one, V.keyEvent(0x58, "X", V.MOD.Shift, 0)).confirm.count, 1);
});

test("nextAnchor: set by visual.enter, kept in VISUAL, cleared on leaving", () => {
  assert.equal(V.nextAnchor("VISUAL", "visual.enter", "", H("c")), H("c"));
  assert.equal(V.nextAnchor("VISUAL", "cursor.down", H("c"), H("d")), H("c"));
  assert.equal(V.nextAnchor("NORMAL", "visual.exit", H("c"), H("d")), "");
  assert.equal(V.nextAnchor("CONFIRM", null, H("c"), H("d")), "");
});

test("hashSet builds a lookup", () => {
  assert.deepEqual(V.hashSet([H("a"), H("b")]), { [H("a")]: true, [H("b")]: true });
  assert.deepEqual(V.hashSet(null), {});
});

// --- Task 8: messages --------------------------------------------------------

test("msgTrack shows progress for a real ticket and notes busy for a refused one", () => {
  const m0 = V.emptyMessages();
  const busy = V.msgTrack(m0, 0, "copy", 1, []);
  assert.deepEqual(V.messageLine(busy), { text: "Busy, try again.", tone: "muted" });
  assert.deepEqual(busy.tickets, {}, "a refused call records no ticket");
  assert.deepEqual(V.messageLine(V.msgKey(busy)), { text: "", tone: "muted" }, "one key long");
  const m1 = V.msgTrack(m0, 7, "start", 2, [H("a"), H("b")]);
  assert.deepEqual(V.messageLine(m1), { text: "Starting 2 torrents…", tone: "muted" });
  assert.equal(V.ownsTicket(m1, 7), true);
  assert.deepEqual(m0.tickets, {}, "immutable");
});

test("msgTrack with an array records one group; an array without a real ticket notes busy", () => {
  const m0 = V.emptyMessages();
  const m1 = V.msgTrack(m0, [3, 4, 5], "stop", 2500, [H("a")]);
  assert.deepEqual(V.messageLine(m1), { text: "Stopping 2500 torrents…", tone: "muted" });
  assert.equal(V.ownsTicket(m1, 3), true);
  assert.equal(V.ownsTicket(m1, 5), true);
  assert.deepEqual(m0.groups, {}, "immutable");
  const busy = V.msgTrack(m0, [], "stop", 1, []);
  assert.deepEqual(V.messageLine(busy), { text: "Busy, try again.", tone: "muted" });
  assert.deepEqual(V.msgTrack(m0, [0, 0], "stop", 1, []).tickets, {});
});

test("a grouped action shows progress until every chunk ends, then succeeds once", () => {
  let m = V.msgTrack(V.emptyMessages(), [1, 2, 3], "start", 3000, [H("a"), H("b")]);
  m = V.msgFinish(m, 1, true, "");
  assert.deepEqual(V.messageLine(m), { text: "Starting 3000 torrents…", tone: "muted" });
  m = V.msgFinish(m, 3, true, "");
  assert.deepEqual(V.messageLine(m), { text: "Starting 3000 torrents…", tone: "muted" });
  m = V.msgFinish(m, 2, true, "");
  assert.deepEqual(V.messageLine(m), { text: "", tone: "muted" });
  assert.deepEqual(m.tickets, {});
  assert.deepEqual(m.groups, {});
});

test("a grouped action reports one error, after its last chunk, if any chunk failed", () => {
  let m = V.msgTrack(V.emptyMessages(), [1, 2, 3], "delete", 2500, [H("a"), H("b")]);
  const before = m;
  m = V.msgFinish(m, 1, false, "HTTP 409");
  assert.deepEqual(V.messageLine(m), { text: "Deleting 2500 torrents and their files…", tone: "muted" }, "no error while chunks run");
  assert.equal(before.groups["1"].failed, false, "immutable");
  m = V.msgFinish(m, 2, false, "HTTP 500");
  assert.equal(m.error, "");
  m = V.msgFinish(m, 3, true, "");
  assert.deepEqual(V.messageLine(m), { text: "Couldn't delete 2500 torrents: HTTP 409", tone: "urgent" }, "one error, the first failure's");
  assert.deepEqual(m.errorHashes, [H("a"), H("b")]);
  assert.deepEqual(m.groups, {});
});

test("groups finish independently of each other and of single tickets", () => {
  let m = V.msgTrack(V.emptyMessages(), [1, 2], "stop", 2000, [H("a")]);
  m = V.msgTrack(m, 3, "recheck", 1, [H("c")]);
  m = V.msgFinish(m, 3, false, "nope");
  assert.equal(m.error, "Couldn't recheck 1 torrent: nope", "a single ticket still reports at once");
  m = V.msgKey(m);
  assert.deepEqual(V.messageLine(m), { text: "Stopping 2000 torrents…", tone: "muted" });
  m = V.msgFinish(m, 2, true, "");
  m = V.msgFinish(m, 1, true, "");
  assert.deepEqual(V.messageLine(m), { text: "", tone: "muted" });
});

test("msgFinish ignores foreign tickets (returns the same object)", () => {
  const m1 = V.msgTrack(V.emptyMessages(), 7, "start", 1, [H("a")]);
  assert.equal(V.msgFinish(m1, 8, false, "boom"), m1);
});

test("msgFinish ok clears the progress; a failure sets an urgent error and the row marks", () => {
  const m1 = V.msgTrack(V.emptyMessages(), 7, "stop", 2, [H("a"), H("b")]);
  assert.deepEqual(V.messageLine(V.msgFinish(m1, 7, true, "")), { text: "", tone: "muted" });
  const bad = V.msgFinish(m1, 7, false, "Forbidden");
  assert.deepEqual(V.messageLine(bad), { text: "Couldn't stop 2 torrents: Forbidden", tone: "urgent" });
  assert.deepEqual(bad.errorHashes, [H("a"), H("b")]);
  assert.equal(V.messageLine(V.msgFinish(V.msgTrack(V.emptyMessages(), 1, "delete", 1, []), 1, false, "")).text, "Couldn't delete 1 torrent.");
});

test("an error outlives later progress and ticks, and clears on the next key only", () => {
  let m = V.msgTrack(V.emptyMessages(), 1, "start", 1, [H("a")]);
  m = V.msgTrack(m, 2, "recheck", 1, [H("b")]);
  m = V.msgFinish(m, 1, false, "nope");
  assert.equal(V.messageLine(m).tone, "urgent");
  m = V.msgTrack(m, 3, "stop", 1, [H("c")]);
  assert.equal(V.messageLine(m).tone, "urgent", "new progress does not hide the error");
  m = V.msgKey(m);
  assert.deepEqual(m.errorHashes, []);
  assert.deepEqual(V.messageLine(m), { text: "Stopping 1 torrent…", tone: "muted" }, "the next key reveals running progress");
  m = V.msgFinish(m, 3, true, "");
  assert.deepEqual(V.messageLine(m), { text: "Rechecking 1 torrent…", tone: "muted" });
});

test("notes: one key long; a copy ticket notes Copied magnet. on success", () => {
  const n = V.msgNote(V.emptyMessages(), "The clipboard is empty.", "urgent");
  assert.deepEqual(V.messageLine(n), { text: "The clipboard is empty.", tone: "urgent" });
  assert.deepEqual(V.messageLine(V.msgKey(n)), { text: "", tone: "muted" });
  const c = V.msgFinish(V.msgTrack(V.emptyMessages(), 4, "copy", 1, [H("a")]), 4, true, "");
  assert.deepEqual(V.messageLine(c), { text: "Copied magnet.", tone: "muted" });
  const e = V.msgError(V.emptyMessages(), "Couldn't read files: x", []);
  assert.equal(V.messageLine(e).tone, "urgent");
});

test("failureText covers every progress kind", () => {
  for (const k of ["start", "stop", "remove", "delete", "recheck", "move", "startAll", "stopAll", "turtle", "add", "daemon", "install", "copy", "prio"]) {
    assert.match(V.failureText(k, 2), /^Couldn't /, k);
    assert.notEqual(V.progressText(k, 2), "Working…", k);
  }
});

// --- Task 8: clipboard ---------------------------------------------------------

test("clipboardOutcome: none, stale, empty, add, invalid", () => {
  assert.equal(V.clipboardOutcome("magnet:?xt=urn:btih:" + "c".repeat(40), 0, 10), "none");
  assert.equal(V.clipboardOutcome("x", 1000, 4001), "stale");
  assert.equal(V.clipboardOutcome("   ", 1000, 1500), "empty");
  assert.equal(V.clipboardOutcome("", 1000, 1500), "empty");
  assert.equal(V.clipboardOutcome("magnet:?xt=urn:btih:" + "c".repeat(40), 1000, 1500), "add");
  assert.equal(V.clipboardOutcome("hello", 1000, 1500), "invalid");
});

// --- Task 8: filter pane ---------------------------------------------------------

test("filterEntries flattens Model.filterGroups with a header per group", () => {
  const rows = [torrent({ hash: H("a"), category: "linux", tags: ["x"], tracker: "t.org" }), torrent({ hash: H("b"), state: "pausedDL" })];
  const e = V.filterEntries(Model.filterGroups(rows, ["anime"], []));
  const headers = e.filter((x) => x.kind === "header").map((x) => x.label);
  assert.deepEqual(headers, ["Status", "Categories", "Tags", "Trackers"]);
  const active = e.find((x) => x.kind === "item" && x.group === "status" && x.value === "Active");
  assert.equal(active.count, 1);
  const anime = e.find((x) => x.group === "category" && x.value === "anime");
  assert.equal(anime.zero, true, "zero-count items stay listed");
  const unc = e.find((x) => x.kind === "item" && x.group === "category" && x.value === "");
  assert.equal(unc.label, "Uncategorized");
});

test("filterEntries strips angle brackets from untrusted labels", () => {
  const e = V.filterEntries(Model.filterGroups([torrent({ category: "<img src=x>" })], [], []));
  assert.ok(e.some((x) => x.label === "img src=x"));
  assert.ok(e.some((x) => x.value === "<img src=x>"), "the value (the filter key) is kept exact");
});

test("moveFilterCursor skips headers and clamps; an unknown cursor starts at the first item", () => {
  const e = V.filterEntries(Model.filterGroups([torrent({ category: "c1" })], [], []));
  const all = { group: "status", value: "All" };
  assert.deepEqual(V.moveFilterCursor(e, all, -1), all);
  assert.deepEqual(V.moveFilterCursor(e, all, 1), { group: "status", value: "Active" });
  const lastStatus = { group: "status", value: "Checking" };
  assert.deepEqual(V.moveFilterCursor(e, lastStatus, 1), { group: "category", value: "" }, "crosses the Categories header");
  const items = e.filter((x) => x.kind === "item");
  const last = { group: items[items.length - 1].group, value: items[items.length - 1].value };
  assert.deepEqual(V.moveFilterCursor(e, last, 1), last);
  assert.deepEqual(V.moveFilterCursor(e, { group: "category", value: "gone" }, 1), all);
});

test("filterIndex and sameEntries", () => {
  const e = V.filterEntries(Model.filterGroups([torrent()], [], []));
  assert.equal(V.filterIndex(e, { group: "status", value: "All" }), 1);
  assert.equal(V.filterIndex(e, { group: "category", value: "gone" }), -1);
  assert.equal(V.sameEntries(e, V.filterEntries(Model.filterGroups([torrent()], [], []))), true);
  assert.equal(V.sameEntries(e, V.filterEntries(Model.filterGroups([torrent(), torrent({ hash: H("b") })], [], []))), false);
});

test("applying a filter entry through Model.matchFilter re-filters viewRows", () => {
  const list = [torrent({ hash: H("a"), category: "linux" }), torrent({ hash: H("b"), category: "" })];
  const v = V.viewRows(list, [], { group: "category", value: "" }, "", "added", true);
  assert.deepEqual(v.rows.map((r) => r.hash), [H("b")]);
});

// --- Task 8: inspector ------------------------------------------------------------

test("inspectorInfo: null with no row; the spec's fields in order", () => {
  assert.equal(V.inspectorInfo(null), null);
  const row = torrent({
    name: "Yoroi", state: "downloading", progress: 0.34, size: 1.7 * 1073741824,
    dlSpeed: 4.1 * 1048576, upSpeed: 210 * 1024, numSeeds: 14, numLeechs: 3,
    ratio: 0.03, ratioLimit: -2, category: "anime", addedOn: 1790000000, savePath: "/home/x/anime"
  });
  const info = V.inspectorInfo(row, (s) => "D" + s);
  assert.equal(info.name, "Yoroi");
  // Added omits from the top block (Ruling T): the approved mockup and the
  // spec's field list for it are State, Size, Speed, Peers, Ratio,
  // Category, Save path. Transfer (InspectorView.infoGroups) keeps Added.
  assert.deepEqual(info.fields.map((f) => f.label), ["State", "Size", "Speed", "Peers", "Ratio", "Category", "Save path"]);
  const val = (l) => info.fields.find((f) => f.label === l).value;
  assert.equal(val("State"), "● downloading · 34%");
  assert.equal(info.fields[0].tone, "accent");
  assert.equal(val("Size"), "1.7 GiB (592 MiB done)");
  assert.equal(val("Speed"), "↓ 4.1 MiB/s · ↑ 210 KiB/s");
  assert.equal(val("Peers"), "14 seeds · 3 leechers");
  assert.equal(val("Ratio"), "0.03 · limit global");
  assert.equal(val("Category"), "anime");
  assert.equal(val("Save path"), "/home/x/anime");
  assert.deepEqual(info.keys.map((k) => k.key), ["o", "y", "m", "e"]);
});

test("inspectorInfo: noMeta swaps the State field's percentage for 'waiting for metadata'", () => {
  const row = torrent({ name: "magnet", state: "stoppedDL", progress: 0, size: -1 });
  const info = V.inspectorInfo(row, (s) => "D" + s, true);
  const val = (l) => info.fields.find((f) => f.label === l).value;
  assert.equal(val("State"), "‖ stopped · waiting for metadata");
  assert.equal(info.fields[0].tone, "muted");
  // false (or omitted) keeps the plain percentage
  assert.equal(V.inspectorInfo(row, (s) => "D" + s, false).fields[0].value, "‖ stopped · 0%");
  assert.equal(V.inspectorInfo(row, (s) => "D" + s).fields[0].value, "‖ stopped · 0%");
});

test("inspectorInfo: missing fields show —, errored rows say why", () => {
  const info = V.inspectorInfo({ hash: H("a"), state: "missingFiles", progress: 0.5 });
  const val = (l) => info.fields.find((f) => f.label === l).value;
  assert.equal(info.name, "—");
  assert.equal(val("State"), "! missing files · 50%");
  assert.equal(info.fields[0].tone, "urgent");
  for (const l of ["Size", "Speed", "Peers", "Ratio", "Category", "Save path"]) assert.equal(val(l), "—", l);
});

test("filesView: loading, error, empty and rows", () => {
  assert.equal(V.filesView([], undefined).state, "loading");
  assert.equal(V.filesView([], { state: "loading" }).state, "loading");
  assert.equal(V.filesView([], { state: "error", error: "x" }).state, "error");
  assert.equal(V.filesView([], { state: "ok" }).state, "empty");
  const files = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "files.json"), "utf8"));
  const v = V.filesView(files, { state: "ok" });
  assert.equal(v.state, "rows");
  assert.deepEqual(v.rows[0], { key: 0, index: 0, name: "debian.iso", progressText: "42%", priorityText: "Low", skipped: false });
  assert.equal(v.rows[1].skipped, true);
  assert.equal(v.rows[1].priorityText, "Skip");
});

test("withPriority changes one file and leaves the input alone; moveIndex clamps", () => {
  const files = [{ index: 0, name: "a", progress: 0, priority: 1 }, { index: 1, name: "b", progress: 0, priority: 6 }];
  const next = V.withPriority(files, 1, 7);
  assert.equal(next[1].priority, 7);
  assert.equal(files[1].priority, 6);
  assert.equal(next[0], files[0]);
  assert.equal(V.moveIndex(2, 1, 1), 1);
  assert.equal(V.moveIndex(2, 0, -1), 0);
  assert.equal(V.moveIndex(0, 3, 1), 0);
});

// --- Task 8: help ------------------------------------------------------------------

test("helpRows groups helpFor rows, merges duplicate ids and drops reserved rows", () => {
  const groups = V.helpRows(Registry.helpFor("NORMAL", "table"));
  assert.deepEqual(groups.map((g) => g.group), ["Torrent", "View", "Library", "App"]);
  const view = groups.find((g) => g.group === "View").items;
  const files = view.filter((i) => i.title === "Files");
  assert.equal(files.length, 1);
  assert.equal(files[0].keys, "Enter / 4");
  assert.ok(view.some((i) => i.keys === "gg" && i.title === "Top"));
  assert.ok(!view.some((i) => i.title === "Reserved"));
  const withNull = V.helpRows([{ id: null, title: "Reserved", group: "View", keys: ["2"] }]);
  assert.deepEqual(withNull, []);
});

test("helpRows for VISUAL lists the range actions and the exit", () => {
  const items = V.helpRows(Registry.helpFor("VISUAL", "table")).flatMap((g) => g.items);
  assert.ok(items.some((i) => i.title === "Exit visual" && i.keys === "Esc / V"));
  assert.ok(items.some((i) => i.title === "Delete with files"));
});

test("modeHints: VISUAL and per-pane NORMAL hints", () => {
  assert.deepEqual(V.modeHints("VISUAL").map((h) => h.key), ["Space", "x", "X", "Esc"]);
  assert.ok(V.modeHints("NORMAL", { pane: "filters" }).some((h) => h.key === "Enter" && h.label === "apply"));
  assert.ok(V.modeHints("NORMAL", { pane: "inspector", filesTab: true }).some((h) => h.label === "priority"));
  assert.ok(V.modeHints("NORMAL", { pane: "table" }).some((h) => h.key === "?"));
});

test("leaveVisualState returns to NORMAL with no range and leaves the input alone", () => {
  const vis = { mode: "VISUAL", pane: "table", prefix: "g", prefixAt: 5, hasTorrent: true, selectionCount: 3, pending: null };
  const st = V.leaveVisualState(vis);
  assert.equal(st.mode, "NORMAL");
  assert.equal(st.selectionCount, 0);
  assert.equal(st.prefix, null);
  assert.equal(vis.mode, "VISUAL");
  // Esc and j then dispatch again from the filters pane
  const esc = Registry.dispatch(Object.assign({}, st, { pane: "filters" }), V.keyEvent(KEY.Escape, "\u001b", 0, 0));
  assert.equal(esc.commandId, "filter.clearText");
  assert.equal(Registry.dispatch(Object.assign({}, st, { pane: "filters" }), V.keyEvent(0x4a, "j", 0, 0)).commandId, "filter.down");
});

// --- Task 1 (slice 1b): command palette --------------------------------------

// --- fuzzyMatch -------------------------------------------------------------

test("fuzzyMatch: an empty query matches everything with score 0", () => {
  const r = V.fuzzyMatch("", "Stop torrent");
  assert.deepEqual(r, { score: 0, indices: [] });
  assert.deepEqual(V.fuzzyMatch("", ""), { score: 0, indices: [] });
});

test("fuzzyMatch: no match returns null", () => {
  assert.equal(V.fuzzyMatch("xyz", "Stop torrent"), null);
  assert.equal(V.fuzzyMatch("stop!!", "Stop"), null, "query longer than what the title can supply");
});

test("fuzzyMatch: case-insensitive subsequence match with correct indices", () => {
  const r = V.fuzzyMatch("op", "Stop");
  assert.ok(r);
  assert.deepEqual(r.indices, [2, 3]);
  const r2 = V.fuzzyMatch("STP", "stop torrent");
  assert.ok(r2, "matching is case-insensitive on both sides");
});

test("fuzzyMatch is deterministic: repeat calls give the same result", () => {
  const a = V.fuzzyMatch("stp", "Stop torrent");
  const b = V.fuzzyMatch("stp", "Stop torrent");
  assert.deepEqual(a, b);
});

test("fuzzyMatch scoring: 'stp' ranks Stop torrent above Set upload limit", () => {
  const stop = V.fuzzyMatch("stp", "Stop torrent");
  const setUpload = V.fuzzyMatch("stp", "Set upload limit");
  assert.ok(stop, "Stop torrent should match");
  assert.ok(setUpload, "Set upload limit should match");
  assert.ok(stop.score > setUpload.score, `${stop.score} should exceed ${setUpload.score}`);
});

test("fuzzyMatch scoring: a consecutive run at the start of the title outscores a scattered match", () => {
  // Both match "st" as a subsequence: "Stop torrent" has it as a run right
  // at the start, "Set upload limit" only has the "s" at the start.
  const front = V.fuzzyMatch("st", "Stop torrent");
  const scattered = V.fuzzyMatch("st", "Set upload limit");
  assert.ok(front && scattered);
  assert.ok(front.score > scattered.score, `${front.score} should exceed ${scattered.score}`);
});

// --- mruPush ----------------------------------------------------------------

test("mruPush inserts a new id at the front", () => {
  assert.deepEqual(V.mruPush([], "torrent.remove"), ["torrent.remove"]);
  assert.deepEqual(V.mruPush(["a", "b"], "c"), ["c", "a", "b"]);
});

test("mruPush moves an existing id to the front instead of duplicating it", () => {
  assert.deepEqual(V.mruPush(["a", "b", "c"], "b"), ["b", "a", "c"]);
  assert.deepEqual(V.mruPush(["a", "b", "c"], "a"), ["a", "b", "c"]);
});

test("mruPush caps the list at 20 entries", () => {
  const full = [];
  for (let i = 0; i < 20; i++) full.push("cmd" + i);
  const r = V.mruPush(full, "new");
  assert.equal(r.length, 20);
  assert.equal(r[0], "new");
  assert.ok(!r.includes("cmd19"), "the oldest entry falls off the cap");
});

test("mruPush does not mutate its input", () => {
  const input = ["a", "b"];
  V.mruPush(input, "c");
  assert.deepEqual(input, ["a", "b"]);
});

// --- paletteRows --------------------------------------------------------------

function paletteState(overrides) {
  return Object.assign({ mode: "COMMAND", pane: "table", hasTorrent: true, selectionCount: 0 }, overrides || {});
}

test("paletteRows: empty query with no MRU lists no divider, just the grouped commands", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState());
  assert.equal(rows.some((r) => r.kind === "divider"), false, "no divider when there is nothing recent");
  assert.ok(rows.every((r) => r.kind === "command"));
});

test("paletteRows: empty query with MRU lists up to 5 recents, then a divider, then the groups", () => {
  const mru = ["torrent.recheck", "sort.next", "torrent.move"];
  const rows = V.paletteRows("", Registry.commands, mru, paletteState());
  assert.deepEqual(rows.slice(0, 3).map((r) => r.id), mru);
  assert.equal(rows[3].kind, "divider");
  assert.ok(rows.slice(4).every((r) => r.kind === "command"));
  // the recents don't repeat further down the list
  const idsAfterDivider = rows.slice(4).map((r) => r.id);
  for (const id of mru) assert.ok(!idsAfterDivider.includes(id), id);
});

test("paletteRows: MRU is capped at 5 shown even with more entries", () => {
  const mru = ["cursor.down", "cursor.up", "cursor.top", "cursor.bottom", "torrent.toggle", "torrent.move"];
  const rows = V.paletteRows("", Registry.commands, mru, paletteState());
  const dividerIndex = rows.findIndex((r) => r.kind === "divider");
  assert.equal(dividerIndex, 5);
  assert.deepEqual(rows.slice(0, 5).map((r) => r.id), mru.slice(0, 5));
});

test("paletteRows: drops MRU ids that no longer exist as commands", () => {
  const mru = ["torrent.move", "no.such.command", "sort.next"];
  const rows = V.paletteRows("", Registry.commands, mru, paletteState());
  const dividerIndex = rows.findIndex((r) => r.kind === "divider");
  assert.deepEqual(rows.slice(0, dividerIndex).map((r) => r.id), ["torrent.move", "sort.next"]);
});

test("paletteRows: the reserved row and palette.* commands never appear", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState());
  assert.ok(!rows.some((r) => r.id === null && r.kind === "command"));
  assert.ok(!rows.some((r) => typeof r.id === "string" && r.id.indexOf("palette.") === 0));
});

test("paletteRows: groups the remaining commands Torrent, View, Library, App, sorted by title within each group", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState());
  const order = ["Torrent", "View", "Library", "App"];
  let lastGroupIdx = -1;
  let lastTitle = "";
  for (const row of rows) {
    const gi = order.indexOf(row.group);
    assert.ok(gi !== -1, row.group);
    if (gi !== lastGroupIdx) {
      assert.ok(gi > lastGroupIdx, "groups appear in Torrent/View/Library/App order: " + row.group);
      lastGroupIdx = gi;
      lastTitle = "";
    } else {
      assert.ok(row.title.toLowerCase() >= lastTitle, row.title + " should sort after " + lastTitle);
    }
    lastTitle = row.title.toLowerCase();
  }
});

test("paletteRows: a torrent.* row is disabled with 'needs a selected torrent' when there is no cursor torrent", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: false }));
  const openFolder = rows.find((r) => r.id === "torrent.openFolder");
  assert.equal(openFolder.enabled, false);
  assert.equal(openFolder.reason, "needs a selected torrent");
  const move = rows.find((r) => r.id === "torrent.move");
  assert.equal(move.enabled, false);
  assert.equal(move.reason, "needs a selected torrent");
});

test("paletteRows: a torrent.* row is enabled when there is a cursor torrent", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: true }));
  const openFolder = rows.find((r) => r.id === "torrent.openFolder");
  assert.equal(openFolder.enabled, true);
  assert.equal(openFolder.reason, "");
});

test("paletteRows: file.* rows (Files-tab-only) are disabled with 'focus the inspector', even with a torrent selected", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: true }));
  for (const id of ["file.down", "file.up", "file.cycle"]) {
    const row = rows.find((r) => r.id === id);
    assert.equal(row.enabled, false, id);
    assert.equal(row.reason, "focus the inspector", id);
  }
});

test("paletteRows: filter.* rows (filters-pane-only) are disabled with 'focus the filters'", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: true }));
  for (const id of ["filter.down", "filter.up", "filter.apply"]) {
    const row = rows.find((r) => r.id === id);
    assert.equal(row.enabled, false, id);
    assert.equal(row.reason, "focus the filters", id);
  }
});

test("paletteRows: a pane-mismatch reason wins over a failed precondition when both fail", () => {
  // file.cycle needs a torrent AND only runs from the inspector; with no
  // torrent selected, both checks fail -- the pane reason must be reported.
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: false }));
  const fileCycle = rows.find((r) => r.id === "file.cycle");
  assert.equal(fileCycle.enabled, false);
  assert.equal(fileCycle.reason, "focus the inspector");
});

test("paletteRows: a command runnable from the table (any-pane or table+inspector) is enabled", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState({ hasTorrent: true }));
  const help = rows.find((r) => r.id === "help.toggle");
  assert.equal(help.enabled, true);
  const copyMagnet = rows.find((r) => r.id === "torrent.copyMagnet"); // table + inspector
  assert.equal(copyMagnet.enabled, true);
});

test("paletteRows: keys is the merged display string from every row sharing that id", () => {
  const rows = V.paletteRows("", Registry.commands, [], paletteState());
  const cursorDown = rows.find((r) => r.id === "cursor.down");
  assert.equal(cursorDown.keys, "j / Down");
  const inspectorFiles = rows.find((r) => r.id === "inspector.files");
  assert.equal(inspectorFiles.keys, "Enter / 4");
});

test("paletteRows: a non-empty query ranks by score descending, tie-broken by title, with no divider", () => {
  const rows = V.paletteRows("stp", Registry.commands, [], paletteState());
  assert.equal(rows.some((r) => r.kind === "divider"), false);
  const ids = rows.map((r) => r.id);
  assert.ok(ids.includes("all.toggle"), "sanity: 'Start/stop all' contains s-t-p as a subsequence");
  // Every returned row's title must actually fuzzy-match "stp".
  for (const row of rows) {
    assert.ok(V.fuzzyMatch("stp", row.title), row.title);
  }
  // Scores are non-increasing down the list.
  const scores = rows.map((r) => V.fuzzyMatch("stp", r.title).score);
  for (let i = 1; i < scores.length; i++) assert.ok(scores[i] <= scores[i - 1], "row " + i + " out of score order");
});

test("paletteRows: a non-empty query excludes commands whose title doesn't match at all", () => {
  const rows = V.paletteRows("zzzzz", Registry.commands, [], paletteState());
  assert.deepEqual(rows, []);
});

test("paletteRows: an empty query's MRU rows still carry indices, enabled and reason", () => {
  const rows = V.paletteRows("", Registry.commands, ["torrent.move"], paletteState({ hasTorrent: false }));
  const first = rows[0];
  assert.equal(first.id, "torrent.move");
  assert.deepEqual(first.indices, []);
  assert.equal(first.enabled, false);
  assert.equal(first.reason, "needs a selected torrent");
});

// --- command palette window helpers (slice 1b, task 2) ----------------------

const cmd = (id, enabled) => ({ kind: "command", id, title: id, group: "App", keys: "", indices: [], enabled, reason: enabled ? "" : "r" });
const DIV = { kind: "divider", id: null, title: "", group: "", keys: "", indices: [], enabled: false, reason: "" };

test("modeHints: COMMAND shows none (the palette footer has them)", () => {
  assert.deepEqual(V.modeHints("COMMAND", { pane: "table" }), []);
});

test("paletteState evaluates as NORMAL in the table pane", () => {
  const s = V.paletteState("rows", true);
  assert.equal(s.mode, "NORMAL");
  assert.equal(s.pane, "table");
  assert.equal(s.hasTorrent, true);
  assert.equal(V.paletteState("empty", true).hasTorrent, false);
});

test("paletteSegments splits a title into matched and plain runs", () => {
  assert.deepEqual(V.paletteSegments("Start/stop all", [0, 1, 9]), [
    { text: "St", matched: true },
    { text: "art/sto", matched: false },
    { text: "p", matched: true },
    { text: " all", matched: false }
  ]);
  assert.deepEqual(V.paletteSegments("Sort", []), [{ text: "Sort", matched: false }]);
  assert.deepEqual(V.paletteSegments("", [0]), []);
  // markup in a title stays text
  assert.deepEqual(V.paletteSegments("<b>x", [3]), [{ text: "<b>", matched: false }, { text: "x", matched: true }]);
});

test("paletteFirst: first enabled row, else first command row, else -1", () => {
  assert.equal(V.paletteFirst([cmd("a", false), DIV, cmd("b", true)]), 2);
  assert.equal(V.paletteFirst([DIV, cmd("a", false)]), 1);
  assert.equal(V.paletteFirst([]), -1);
  assert.equal(V.paletteFirst([DIV]), -1);
});

test("paletteMove skips dividers and disabled rows and doesn't wrap", () => {
  const rows = [cmd("a", true), DIV, cmd("b", false), cmd("c", true), cmd("d", false)];
  assert.equal(V.paletteMove(rows, 0, 1), 3);
  assert.equal(V.paletteMove(rows, 3, 1), 3);
  assert.equal(V.paletteMove(rows, 3, -1), 0);
  assert.equal(V.paletteMove(rows, 0, -1), 0);
  assert.equal(V.paletteMove([cmd("x", false)], 0, 1), 0);
  assert.equal(V.paletteMove([], -1, 1), -1);
});

test("paletteCursorFor keeps the cursor on its command if it's still enabled", () => {
  const rows = [cmd("a", true), cmd("b", true), cmd("c", false)];
  assert.equal(V.paletteCursorFor(rows, "b"), 1);
  assert.equal(V.paletteCursorFor(rows, "c"), 0, "now disabled: back to the first");
  assert.equal(V.paletteCursorFor(rows, "gone"), 0);
});

test("paletteCommandCount counts commands, not dividers", () => {
  assert.equal(V.paletteCommandCount([cmd("a", true), DIV, cmd("b", false)]), 2);
  assert.equal(V.paletteCommandCount(null), 0);
});

test("palettePane: stay where the command works, else the table", () => {
  const C = Registry.commands;
  assert.equal(V.palettePane(C, "sort.next", "filters"), "filters");
  assert.equal(V.palettePane(C, "torrent.openFolder", "inspector"), "inspector");
  assert.equal(V.palettePane(C, "torrent.toggle", "filters"), "table");
  assert.equal(V.palettePane(C, "torrent.delete", "inspector"), "table");
  assert.equal(V.palettePane(C, "cursor.down", "table"), "table");
});

test("paletteOwnsKey: the COMMAND keys and Shift-Tab, never typing", () => {
  const k = (key, text, mods) => V.keyEvent(key, text, mods || 0, 0);
  assert.equal(V.paletteOwnsKey(k(KEY.Escape, "\u001b")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Return, "\r")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Enter, "\r")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Up, "")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Down, "")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Tab, "\t")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.Backtab, "")), true);
  assert.equal(V.paletteOwnsKey(k(KEY.N, "\u000e", V.MOD.Control)), true);
  assert.equal(V.paletteOwnsKey(k(KEY.P, "\u0010", V.MOD.Control)), true);
  assert.equal(V.paletteOwnsKey(k(KEY.N, "n")), false);
  assert.equal(V.paletteOwnsKey(k(0x53, "s")), false);
  assert.equal(V.paletteOwnsKey(k(0x3a, ":")), false);
  assert.equal(V.paletteOwnsKey(k(0x20, " ")), false);
});

test("overlayOwnsKey(COMMAND, ...) matches paletteOwnsKey exactly", () => {
  const k = (key, text, mods) => V.keyEvent(key, text, mods || 0, 0);
  const cases = [
    k(KEY.Escape, "\u001b"), k(KEY.Return, "\r"), k(KEY.Enter, "\r"), k(KEY.Up, ""),
    k(KEY.Down, ""), k(KEY.Tab, "\t"), k(KEY.Backtab, ""), k(KEY.N, "\u000e", V.MOD.Control),
    k(KEY.P, "\u0010", V.MOD.Control), k(KEY.N, "n"), k(0x53, "s"), k(0x3a, ":"), k(0x20, " ")
  ];
  for (const c of cases) {
    assert.equal(V.overlayOwnsKey("COMMAND", c, true), V.paletteOwnsKey(c), JSON.stringify(c));
  }
});

test("overlayOwnsKey(PICKER, ...): Tab/Enter/Esc/Up/Down/Ctrl-p/Ctrl-n always forward; Space only while empty; nothing else does", () => {
  const k = (key, text, mods) => V.keyEvent(key, text, mods || 0, 0);
  const always = [
    k(KEY.Tab, "\t"), k(KEY.Backtab, ""), k(KEY.Escape, "\u001b"), k(KEY.Return, "\r"),
    k(KEY.Enter, "\r"), k(KEY.Up, ""), k(KEY.Down, ""),
    k(KEY.N, "\u000e", V.MOD.Control), k(KEY.P, "\u0010", V.MOD.Control)
  ];
  for (const c of always) {
    assert.equal(V.overlayOwnsKey("PICKER", c, true), true, JSON.stringify(c));
    assert.equal(V.overlayOwnsKey("PICKER", c, false), true, JSON.stringify(c));
  }
  assert.equal(V.overlayOwnsKey("PICKER", k(KEY.Space, " "), true), true, "Space, empty query");
  assert.equal(V.overlayOwnsKey("PICKER", k(KEY.Space, " "), false), false, "Space, non-empty query types");
  assert.equal(V.overlayOwnsKey("PICKER", k(KEY.N, "n"), true), false);
  assert.equal(V.overlayOwnsKey("PICKER", k(0x53, "s"), true), false);
  assert.equal(V.overlayOwnsKey("PICKER", k(0x3a, ":"), true), false);
});

test("palette notes and empty copy", () => {
  assert.equal(V.paletteReasonNote({ title: "Copy magnet", reason: "needs a selected torrent" }), "Copy magnet: needs a selected torrent.");
  assert.equal(V.paletteEmptyText("q"), "No command matches “q”");
});

// --- Responsive layout (D5) ----------------------------------------------

test("layoutFor docks, collapses and hides columns at the D5 breakpoints", () => {
  const all = { filters: "docked", inspector: "docked", hideColumns: [] };
  const noInspector = { filters: "docked", inspector: "collapsed", hideColumns: [] };
  const narrow = { filters: "collapsed", inspector: "collapsed", hideColumns: [] };
  const narrowest = { filters: "collapsed", inspector: "collapsed", hideColumns: ["ul", "eta", "ratio"] };
  assert.deepEqual(V.layoutFor(1600), all);
  assert.deepEqual(V.layoutFor(1300), all);
  assert.deepEqual(V.layoutFor(1299), noInspector);
  assert.deepEqual(V.layoutFor(900), noInspector);
  assert.deepEqual(V.layoutFor(899), narrow);
  assert.deepEqual(V.layoutFor(700), narrow);
  assert.deepEqual(V.layoutFor(699), narrowest);
});

test("layoutFor treats an unknown width as wide and never hides the core columns", () => {
  assert.deepEqual(V.layoutFor(0), V.layoutFor(1600));
  assert.deepEqual(V.layoutFor(undefined), V.layoutFor(1600));
  for (const col of ["name", "size", "progress", "dl"]) {
    assert.equal(V.layoutFor(320).hideColumns.indexOf(col), -1);
  }
  // Each call returns its own array.
  V.layoutFor(600).hideColumns.push("x");
  assert.deepEqual(V.layoutFor(600).hideColumns, ["ul", "eta", "ratio"]);
});

test("overlayPane is the focused pane only while it is collapsed", () => {
  const narrow = V.layoutFor(850);
  const medium = V.layoutFor(1000);
  assert.equal(V.overlayPane(narrow, "filters"), "filters");
  assert.equal(V.overlayPane(narrow, "inspector"), "inspector");
  assert.equal(V.overlayPane(narrow, "table"), "");
  assert.equal(V.overlayPane(medium, "filters"), "");
  assert.equal(V.overlayPane(medium, "inspector"), "inspector");
  assert.equal(V.overlayPane(V.layoutFor(1600), "inspector"), "");
});

test("paneStep: Ctrl-h/Ctrl-l close an overlay, Tab/Shift-Tab keep cycling", () => {
  const narrow = V.layoutFor(850);
  const ctrlH = V.keyEvent(KEY.H, "\b", V.MOD.Control, 0);
  const ctrlL = V.keyEvent(KEY.L, "\f", V.MOD.Control, 0);
  const tab = V.keyEvent(KEY.Tab, "\t", 0, 0);
  const backtab = V.keyEvent(KEY.Backtab, "", V.MOD.Shift, 0);
  // from the table, the same as nextPane
  assert.equal(V.paneStep("table", -1, narrow, ctrlH), "filters");
  assert.equal(V.paneStep("table", 1, narrow, ctrlL), "inspector");
  // the same key again closes the overlay
  assert.equal(V.paneStep("filters", -1, narrow, ctrlH), "table");
  assert.equal(V.paneStep("inspector", 1, narrow, ctrlL), "table");
  // Tab walks through each overlay in turn
  assert.equal(V.paneStep("table", 1, narrow, tab), "inspector");
  assert.equal(V.paneStep("inspector", 1, narrow, tab), "filters");
  assert.equal(V.paneStep("filters", 1, narrow, tab), "table");
  assert.equal(V.paneStep("filters", -1, narrow, backtab), "inspector");
  // docked panes cycle as before, whatever the key
  const wide = V.layoutFor(1600);
  assert.equal(V.paneStep("filters", -1, wide, ctrlH), "inspector");
  assert.equal(V.paneStep("inspector", 1, wide, ctrlL), "filters");
  // a palette-run pane.next (a neutral event) cycles
  assert.equal(V.paneStep("inspector", 1, narrow, V.keyEvent(0, "", 0, 0)), "filters");
});

test("overlayEscape only takes a NORMAL Esc while an overlay is open", () => {
  const narrow = V.layoutFor(850);
  const esc = V.keyEvent(KEY.Escape, "\u001b", 0, 0);
  assert.equal(V.overlayEscape(esc, "NORMAL", narrow, "filters"), true);
  assert.equal(V.overlayEscape(esc, "NORMAL", narrow, "table"), false);
  assert.equal(V.overlayEscape(esc, "INSERT", narrow, "filters"), false);
  assert.equal(V.overlayEscape(esc, "CONFIRM", narrow, "inspector"), false);
  assert.equal(V.overlayEscape(esc, "NORMAL", V.layoutFor(1600), "filters"), false);
  assert.equal(V.overlayEscape(V.keyEvent(0x4a, "j", 0, 0), "NORMAL", narrow, "filters"), false);
});

test("filterChip shows the active filter only while the filters are collapsed", () => {
  const seeding = { group: "status", value: "Seeding" };
  assert.equal(V.filterChip(V.layoutFor(850), seeding), "▸ Seeding");
  assert.equal(V.filterChip(V.layoutFor(850), { group: "category", value: "" }), "▸ Uncategorized");
  assert.equal(V.filterChip(V.layoutFor(850), V.defaultFilter()), "");
  assert.equal(V.filterChip(V.layoutFor(1000), seeding), "");
});

// --- browser-magnet confirm (slice 1b Task 4) -------------------------------

const MURL = (c) => "magnet:?xt=urn:btih:" + H(c);
const MREG = { mode: "NORMAL", pane: "table", prefix: null, prefixAt: 0, hasTorrent: true, selectionCount: 0, pending: null };
const MAGNET_PENDING = { kind: "magnet", commandId: "magnet.start" };
function mstate(pending, inbox, torrents) {
  return Model.magnetConfirmState(pending || [], inbox || [], torrents || [], 1000);
}
function mpend(c, extra) {
  return Object.assign({ hash: H(c), url: MURL(c), hashes: [H(c)], dn: "", addedAt: 999 }, extra || {});
}

test("magnetItemKey and magnetKeys: the url survives inbox -> pending", () => {
  assert.equal(V.magnetItemKey({ url: MURL("a"), hash: H("a") }), MURL("a"));
  assert.equal(V.magnetItemKey({ hash: H("a") }), H("a"));
  assert.equal(V.magnetItemKey(null), "");
  assert.deepEqual(V.magnetKeys([mpend("a")], [{ url: MURL("b"), ts: 1 }]), [MURL("a"), MURL("b")]);
  assert.deepEqual(V.magnetKeys(undefined, undefined), []);
});

test("magnetShown hides only the item the window already handled", () => {
  const ms = mstate([mpend("a")]);
  assert.equal(V.magnetShown(ms, ""), true);
  assert.equal(V.magnetShown(ms, MURL("a")), false);
  assert.equal(V.magnetShown(ms, MURL("b")), true);
  assert.equal(V.magnetShown(mstate(), ""), false);
});

test("magnetSync enters a magnet CONFIRM from NORMAL only", () => {
  const ms = mstate([mpend("a")]);
  const keys = [MURL("a")];
  let r = V.magnetSync(null, MREG, ms, keys, { opened: true });
  assert.equal(r.regState.mode, "CONFIRM");
  assert.deepEqual(r.regState.pending, MAGNET_PENDING);
  assert.equal(r.regState.pane, "table");
  for (const mode of ["INSERT", "COMMAND", "VISUAL"]) {
    r = V.magnetSync(null, Object.assign({}, MREG, { mode }), ms, keys, { opened: true });
    assert.equal(r.regState, null, mode);
  }
  const del = Object.assign({}, MREG, { mode: "CONFIRM", pending: { kind: "delete", commandId: "torrent.delete" } });
  assert.equal(V.magnetSync(null, del, ms, keys, { opened: true }).regState, null, "a delete CONFIRM is left alone");
  assert.equal(V.magnetSync(null, MREG, ms, keys, { opened: true, blocked: true }).regState, null, "help or an overlay waits");
  assert.equal(V.magnetSync(null, MREG, mstate(), [], { opened: true }).regState, null, "nothing waiting");
});

test("magnetSync leaves the magnet CONFIRM when no item is shown", () => {
  const confirm = Object.assign({}, MREG, { mode: "CONFIRM", pending: MAGNET_PENDING });
  let r = V.magnetSync({ seen: [MURL("a")], handled: "", focusDue: false }, confirm, mstate(), [], { opened: true });
  assert.equal(r.regState.mode, "NORMAL");
  assert.equal(r.regState.pending, null);
  // handled: back to NORMAL while the item is still queued, and not re-entered
  const ms = mstate([mpend("a")]);
  r = V.magnetSync({ seen: [MURL("a")], handled: MURL("a"), focusDue: false }, confirm, ms, [MURL("a")], { opened: true });
  assert.equal(r.regState.mode, "NORMAL");
  assert.equal(r.mem.handled, MURL("a"));
  r = V.magnetSync(r.mem, r.regState, ms, [MURL("a")], { opened: true });
  assert.equal(r.regState, null);
  // the next item is offered
  const two = mstate([mpend("b")]);
  r = V.magnetSync(r.mem, MREG, two, [MURL("b")], { opened: true });
  assert.equal(r.regState.mode, "CONFIRM");
  assert.equal(r.mem.handled, "", "a handled key is forgotten once it leaves the queue");
});

test("magnetSync asks for attention on a new key, not on inbox -> pending", () => {
  const inboxOnly = mstate([], [{ url: MURL("a"), ts: 1 }]);
  let r = V.magnetSync({ seen: [], handled: "", focusDue: false }, MREG, inboxOnly, [MURL("a")], { opened: true });
  assert.equal(r.focus, true);
  r = V.magnetSync(r.mem, r.regState, mstate([mpend("a")]), [MURL("a")], { opened: true });
  assert.equal(r.focus, false, "the drained line is the same item");
  r = V.magnetSync(r.mem, r.regState || MREG, mstate([mpend("a")], [{ url: MURL("b"), ts: 2 }]), [MURL("a"), MURL("b")], { opened: true });
  assert.equal(r.focus, true, "a second magnet is new");
  r = V.magnetSync({ seen: [], handled: "", focusDue: false }, MREG, inboxOnly, [MURL("a")], { opened: false });
  assert.equal(r.focus, false, "a closed window asks for nothing");
});

test("magnetSync holds the attention request while a text field owns the keys", () => {
  const ms = mstate([mpend("a")]);
  const palette = Object.assign({}, MREG, { mode: "COMMAND" });
  let r = V.magnetSync(null, palette, ms, [MURL("a")], { opened: true });
  assert.equal(r.focus, false);
  assert.equal(r.mem.focusDue, true);
  r = V.magnetSync(r.mem, palette, ms, [MURL("a")], { opened: true });
  assert.equal(r.focus, false);
  r = V.magnetSync(r.mem, MREG, ms, [MURL("a")], { opened: true });
  assert.equal(r.focus, true, "asked once the palette closes");
  assert.equal(r.mem.focusDue, false);
  assert.equal(r.regState.mode, "CONFIRM");
  // the queue emptying drops a held request
  r = V.magnetSync(null, palette, ms, [MURL("a")], { opened: true });
  r = V.magnetSync(r.mem, palette, mstate(), [], { opened: true });
  assert.equal(r.mem.focusDue, false);
});

test("magnetSync settle: the CONFIRM waits until 800 ms after the last key (799 waits, 800 raises)", () => {
  assert.equal(V.MAGNET_SETTLE_MS, 800);
  const ms = mstate([mpend("a")]);
  const keys = [MURL("a")];
  const k = 50000;
  for (const [dt, left] of [[0, 800], [1, 799], [400, 400], [799, 1]]) {
    const r = V.magnetSync(null, MREG, ms, keys, { opened: true, now: k + dt, lastKeyAt: k });
    assert.equal(r.regState, null, "+" + dt);
    assert.equal(r.wait, left, "+" + dt);
  }
  for (const dt of [800, 801, 9000]) {
    const r = V.magnetSync(null, MREG, ms, keys, { opened: true, now: k + dt, lastKeyAt: k });
    assert.equal(r.wait, 0, "+" + dt);
    assert.equal(r.regState.mode, "CONFIRM");
    assert.deepEqual(r.regState.pending, Object.assign({}, MAGNET_PENDING, { at: k + dt }), "the raise is stamped for the grace");
  }
  // no key yet: raised at once, stamped
  let r = V.magnetSync(null, MREG, ms, keys, { opened: true, now: 7, lastKeyAt: 0 });
  assert.equal(r.regState.mode, "CONFIRM");
  assert.equal(r.regState.pending.at, 7);
  assert.equal(r.wait, 0);
  // nothing to wait for outside NORMAL, while blocked, or with nothing shown
  for (const mode of ["INSERT", "COMMAND", "VISUAL"]) {
    r = V.magnetSync(null, Object.assign({}, MREG, { mode }), ms, keys, { opened: true, now: k + 1, lastKeyAt: k });
    assert.equal(r.wait, 0, mode);
  }
  assert.equal(V.magnetSync(null, MREG, ms, keys, { opened: true, blocked: true, now: k + 1, lastKeyAt: k }).wait, 0);
  assert.equal(V.magnetSync(null, MREG, mstate(), [], { opened: true, now: k + 1, lastKeyAt: k }).wait, 0);
  // leaving a handled magnet's CONFIRM never waits on a key
  const confirm = Object.assign({}, MREG, { mode: "CONFIRM", pending: MAGNET_PENDING });
  r = V.magnetSync({ seen: keys, handled: "", focusDue: false }, confirm, mstate(), [], { now: k + 1, lastKeyAt: k });
  assert.equal(r.regState.mode, "NORMAL");
});

test("magnetSync in INSERT or COMMAND asks for attention for the text field when the window is inactive", () => {
  const ms = mstate([mpend("a")]);
  for (const mode of ["INSERT", "COMMAND"]) {
    const typing = Object.assign({}, MREG, { mode });
    let r = V.magnetSync(null, typing, ms, [MURL("a")], { opened: true, active: false });
    assert.equal(r.focus, true, mode);
    assert.equal(r.focusField, true, mode);
    assert.equal(r.mem.focusDue, false, mode + ": asked once, not again on close");
    assert.equal(r.regState, null);
    r = V.magnetSync(r.mem, MREG, ms, [MURL("a")], { opened: true, active: true });
    assert.equal(r.focus, false, mode + ": no second request");
    // active: no request now, one once the field is closed (keyRoot)
    r = V.magnetSync(null, typing, ms, [MURL("a")], { opened: true, active: true });
    assert.equal(r.focus, false, mode);
    assert.equal(r.focusField, false, mode);
    assert.equal(r.mem.focusDue, true, mode);
    r = V.magnetSync(r.mem, MREG, ms, [MURL("a")], { opened: true, active: true });
    assert.equal(r.focus, true, mode);
    assert.equal(r.focusField, false, mode);
  }
  // NORMAL never targets a field
  const r = V.magnetSync(null, MREG, ms, [MURL("a")], { opened: true, active: false });
  assert.equal(r.focus, true);
  assert.equal(r.focusField, false);
});

test("the magnet wait note: shown while deferred, never over a message", () => {
  const confirm = Object.assign({}, MREG, { mode: "CONFIRM", pending: MAGNET_PENDING });
  const del = Object.assign({}, MREG, { mode: "CONFIRM", pending: { kind: "delete", commandId: "torrent.delete" } });
  assert.equal(V.magnetDeferred(true, MREG), true);
  assert.equal(V.magnetDeferred(true, Object.assign({}, MREG, { mode: "INSERT" })), true);
  assert.equal(V.magnetDeferred(true, Object.assign({}, MREG, { mode: "COMMAND" })), true);
  assert.equal(V.magnetDeferred(true, del), true);
  assert.equal(V.magnetDeferred(true, confirm), false);
  assert.equal(V.magnetDeferred(false, MREG), false);
  assert.equal(V.MAGNET_WAIT_NOTE, "Magnet waiting \u2014 finish, then confirm");
  const empty = { text: "", tone: "muted" };
  assert.deepEqual(V.withMagnetWait(empty, true), { text: "Magnet waiting \u2014 finish, then confirm", tone: "muted" });
  assert.deepEqual(V.withMagnetWait(empty, false), empty);
  const err = { text: "Couldn't delete 1 torrent: boom", tone: "urgent" };
  assert.deepEqual(V.withMagnetWait(err, true), err, "an error stays");
  const busy = { text: "Starting…", tone: "muted" };
  assert.deepEqual(V.withMagnetWait(busy, true), busy);
});

test("magnetAction: start needs canStart; cancel deletes, or drops an inbox line", () => {
  const fetching = mstate([mpend("a")], [], [torrent({ hash: H("a"), name: H("a"), state: "metaDL" })]);
  assert.deepEqual(V.magnetAction(fetching, "magnet.start"), { call: "", kind: "", note: "Still fetching the name…" });
  assert.deepEqual(V.magnetAction(fetching, "magnet.cancel"), { call: "cancel", kind: "delete", note: "" });
  const ready = mstate([mpend("a")], [], [torrent({ hash: H("a"), name: "Real", state: "stoppedDL" })]);
  assert.deepEqual(V.magnetAction(ready, "magnet.start"), { call: "start", kind: "start", note: "" });
  const inboxOnly = mstate([], [{ url: MURL("b"), ts: 1 }]);
  assert.deepEqual(V.magnetAction(inboxOnly, "magnet.start"), { call: "", kind: "", note: "Still fetching the name…" });
  assert.deepEqual(V.magnetAction(inboxOnly, "magnet.cancel"), { call: "drop", kind: "dropMagnet", note: "" });
  const error = mstate([], [{ url: MURL("b"), ts: 1, error: "unidentified" }]);
  assert.deepEqual(V.magnetAction(error, "magnet.start"), { call: "", kind: "", note: "" });
  assert.deepEqual(V.magnetAction(error, "magnet.cancel"), { call: "drop", kind: "dropMagnet", note: "" });
  assert.deepEqual(V.magnetAction(mstate(), "magnet.cancel"), { call: "", kind: "", note: "" });
  assert.equal(V.progressText("dropMagnet", 0), "Dropping the magnet…");
  assert.equal(V.failureText("dropMagnet", 0), "Couldn't drop the magnet");
});

test("magnetLine: the MAGNET status line, +N more, and an error line", () => {
  const ms = mstate([mpend("a"), mpend("b")], [{ url: MURL("c"), ts: 1 }], [torrent({ hash: H("a"), name: "Big Buck Bunny", state: "stoppedDL" })]);
  assert.deepEqual(V.magnetLine(ms), {
    lead: "Start \"", title: "Big Buck Bunny", tail: "\"?", more: "+2 more", error: "",
    hints: [{ key: "Enter", label: "start" }, { key: "Esc", label: "cancel" }]
  });
  assert.equal(V.magnetLine(mstate([mpend("a")])).title, "Fetching name…");
  assert.equal(V.magnetLine(mstate([mpend("a")])).more, "");
  const err = V.magnetLine(mstate([], [{ url: MURL("c"), ts: 1, error: "unidentified" }]));
  assert.equal(err.error, "unidentified");
  assert.deepEqual(err.hints, [{ key: "Esc", label: "dismiss" }]);
});

test("copyText (y on trackers/peers): Copying… while it runs, then the note Copied; its own failure text", () => {
  const t = V.msgTrack(V.emptyMessages(), 7, "copyText", 1, [H("a")]);
  assert.deepEqual(V.messageLine(t), { text: "Copying…", tone: "muted" });
  assert.deepEqual(V.messageLine(V.msgFinish(t, 7, true, "")), { text: "Copied", tone: "muted" });
  assert.deepEqual(V.messageLine(V.msgFinish(t, 7, false, "wl-copy missing")), { text: "Couldn't copy: wl-copy missing", tone: "urgent" });
});

// --- inspector actions (slice 2b, Task 3) ------------------------------------

test("progressText: the inspector actions' progress copy", () => {
  assert.equal(V.progressText("reannounce", 1), "Reannouncing…");
  assert.equal(V.progressText("trackerAdd", 1), "Adding tracker…");
  assert.equal(V.progressText("trackerEdit", 1), "Changing tracker…");
  assert.equal(V.progressText("trackerRemove", 1), "Removing tracker…");
  assert.equal(V.progressText("ban", 0), "Banning peer…");
  assert.equal(V.progressText("fetchMeta", 1), "Fetching metadata…");
});

test("msgFinish: the inspector actions' done notes and failures", () => {
  const notes = { reannounce: "Reannounced", trackerAdd: "Tracker added", trackerEdit: "Tracker changed", trackerRemove: "Tracker removed", ban: "Peer banned" };
  for (const kind of Object.keys(notes)) {
    const m = V.msgTrack(V.emptyMessages(), 9, kind, 1, [H("a")]);
    const done = V.msgFinish(m, 9, true, "");
    assert.equal(done.note, notes[kind], kind);
    assert.equal(done.progress, "", kind);
    const failed = V.msgFinish(m, 9, false, "invalid tracker url");
    assert.match(failed.error, /^Couldn't .+: invalid tracker url$/, kind);
    assert.doesNotMatch(failed.error, /The action failed/, kind);
  }
  // fetch-metadata's ticket ending isn't "metadata received": Task 5 shows
  // that note only once the torrent's size is known.
  const f = V.msgTrack(V.emptyMessages(), 4, "fetchMeta", 1, [H("a")]);
  assert.equal(V.msgFinish(f, 4, true, "").note, "");
  assert.equal(V.msgFinish(f, 4, false, "Stop it first.").error, "Couldn't fetch metadata: Stop it first.");
  assert.equal(V.FETCH_META_DONE_NOTE, "Metadata received · stopped");
});

test("confirmLine: tracker removal and peer ban", () => {
  const t = V.confirmLine({ commandId: "tracker.remove", kind: "trackerRemove", label: "tracker.example:1337", target: { kind: "tracker", value: "udp://tracker.example:1337/abc123/announce", label: "tracker.example:1337" } });
  assert.equal(t.lead + t.strong + t.tail, "Remove tracker tracker.example:1337 from this torrent?");
  assert.equal(t.accept, "remove");
  assert.doesNotMatch(t.lead + t.strong + t.tail, /abc123/);
  const p = V.confirmLine({ kind: "peerBan", label: "203.0.113.42" });
  assert.equal(p.lead + p.strong + p.tail, "Ban 203.0.113.42 from all torrents? It goes on qBittorrent's IP ban list.");
  assert.equal(p.accept, "ban");
  // the label falls back to target.label
  const fb = V.confirmLine({ kind: "trackerRemove", target: { label: "a.example" } });
  assert.equal(fb.lead + fb.strong + fb.tail, "Remove tracker a.example from this torrent?");
});

const TRACKERS = [{ key: "https://a.example/announce?passkey=abc123", url: "https://a.example/announce?passkey=abc123", host: "a.example" }, { key: "udp://b.example:1337/x", url: "udp://b.example:1337/x", host: "b.example:1337" }];
const PEERS = [{ key: "203.0.113.42:6881", ipPort: "203.0.113.42:6881" }, { key: "[2001:db8::1]:51413", ipPort: "[2001:db8::1]:51413" }];

function insp(overrides) {
  return Object.assign({
    pane: "inspector", state: "rows", tab: "trackers", trackers: TRACKERS, trackerIndex: 0, peers: PEERS, peerIndex: 0,
    row: torrent({ hash: H("a"), state: "stoppedDL", size: 0 }), cursorHash: H("a"), noMeta: false, pending: []
  }, overrides || {});
}

test("inspectorDispatch: the tracker or peer row under the inspector cursor is the target", () => {
  assert.deepEqual(V.inspectorDispatch(insp()).inspectorTarget, { kind: "tracker", value: TRACKERS[0].url, label: "a.example" });
  assert.deepEqual(V.inspectorDispatch(insp({ trackerIndex: 1 })).inspectorTarget, { kind: "tracker", value: "udp://b.example:1337/x", label: "b.example:1337" });
  assert.deepEqual(V.inspectorDispatch(insp({ tab: "peers", peerIndex: 1 })).inspectorTarget, { kind: "peer", value: "[2001:db8::1]:51413", label: "2001:db8::1" });
});

test("inspectorDispatch: no target on other tabs, empty lists, out-of-range cursors or another pane", () => {
  for (const o of [
    { tab: "info" }, { tab: "files" }, { tab: "chart" },
    { trackers: [] }, { tab: "peers", peers: [] },
    { trackerIndex: 5 }, { trackerIndex: -1 }, { tab: "peers", peerIndex: 2 },
    { pane: "table" }, { pane: "filters" },
    { state: "empty" }, { row: null },
    { trackers: undefined }, { tab: "peers", peers: null }
  ]) {
    assert.equal(V.inspectorDispatch(insp(o)).inspectorTarget, null, JSON.stringify(o));
  }
});

test("inspectorDispatch: trackersTab follows the focused trackers tab, even with no trackers", () => {
  assert.equal(V.inspectorDispatch(insp()).trackersTab, true);
  assert.equal(V.inspectorDispatch(insp({ trackers: [] })).trackersTab, true);
  assert.equal(V.inspectorDispatch(insp({ tab: "peers" })).trackersTab, false);
  assert.equal(V.inspectorDispatch(insp({ pane: "table" })).trackersTab, false);
  assert.equal(V.inspectorDispatch(insp({ row: null })).trackersTab, false, "no torrent to add a tracker to");
});

test("inspectorDispatch: the cursor torrent's metadata, stopped and pending-magnet flags", () => {
  const d = V.inspectorDispatch(insp({ noMeta: true }));
  assert.equal(d.cursorNoMetadata, true);
  assert.equal(d.cursorStopped, true);
  assert.equal(d.cursorPendingMagnet, false);
  assert.equal(V.inspectorDispatch(insp({ noMeta: true, row: null })).cursorNoMetadata, false);
  assert.equal(V.inspectorDispatch(insp({ row: torrent({ state: "pausedDL" }) })).cursorStopped, true);
  assert.equal(V.inspectorDispatch(insp({ row: torrent({ state: "metaDL" }) })).cursorStopped, false);
  assert.equal(V.inspectorDispatch(insp({ row: torrent({ state: "stoppedUP", progress: 1 }) })).cursorStopped, false, "qbt only fetches for stoppedDL/pausedDL");
  assert.equal(V.inspectorDispatch(insp({ pending: [H("b"), H("a")] })).cursorPendingMagnet, true);
  assert.equal(V.inspectorDispatch(insp({ pending: [H("b")] })).cursorPendingMagnet, false);
  assert.equal(V.inspectorDispatch(insp({ pending: undefined })).cursorPendingMagnet, false);
  // Pane-independent: f works from any pane.
  assert.equal(V.inspectorDispatch(insp({ pane: "table", noMeta: true })).cursorNoMetadata, true);
  assert.equal(V.inspectorDispatch({}).cursorStopped, false);
});

test("dispatchState copies the inspector fields, and resets them when none are given", () => {
  const extras = V.inspectorDispatch(insp({ noMeta: true, pending: [H("a")] }));
  const st = V.dispatchState({ mode: "NORMAL" }, "inspector", "rows", true, [], extras);
  assert.deepEqual(st.inspectorTarget, extras.inspectorTarget);
  assert.equal(st.trackersTab, true);
  assert.equal(st.cursorNoMetadata, true);
  assert.equal(st.cursorStopped, true);
  assert.equal(st.cursorPendingMagnet, true);
  // A regState that kept a previous dispatch's target doesn't leak it.
  const stale = V.dispatchState(st, "table", "rows", true, []);
  assert.equal(stale.inspectorTarget, null);
  assert.equal(stale.trackersTab, false);
  assert.equal(stale.cursorNoMetadata, false);
  assert.equal(stale.cursorStopped, false);
  assert.equal(stale.cursorPendingMagnet, false);
});

// The inspector rows are all real since Task 5.
const INSPECTOR_ROWS = Registry.commands;

function paletteRow(state, id) {
  return V.paletteRows("", INSPECTOR_ROWS, [], state).find((r) => r.id === id);
}

test("paletteRows: inspector-only rows say focus the inspector from another pane", () => {
  const st = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table" })), "table");
  for (const id of ["tracker.remove", "tracker.add", "peer.ban"]) {
    assert.equal(paletteRow(st, id).reason, "focus the inspector", id);
  }
});

test("paletteRows: from the inspector, tracker/peer rows name the tab they need", () => {
  const onPeers = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "peers" })), "inspector");
  assert.equal(paletteRow(onPeers, "tracker.remove").reason, "focus the trackers tab");
  assert.equal(paletteRow(onPeers, "tracker.add").reason, "focus the trackers tab");
  assert.equal(paletteRow(onPeers, "peer.ban").enabled, true);
  const onTrackers = V.paletteState("rows", true, V.inspectorDispatch(insp()), "inspector");
  assert.equal(paletteRow(onTrackers, "tracker.remove").enabled, true);
  assert.equal(paletteRow(onTrackers, "tracker.add").enabled, true);
  assert.equal(paletteRow(onTrackers, "peer.ban").reason, "focus the peers tab");
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info" })), "inspector");
  assert.equal(paletteRow(onInfo, "tracker.remove").reason, "focus the trackers tab");
  assert.equal(paletteRow(onInfo, "peer.ban").reason, "focus the peers tab");
});

test("paletteRows: fetch metadata says why it's dimmed", () => {
  const has = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table", noMeta: false })), "table");
  assert.equal(paletteRow(has, "torrent.fetchMetadata").reason, "already has metadata");
  const fetching = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table", noMeta: true, pending: [H("a")] })), "table");
  assert.equal(paletteRow(fetching, "torrent.fetchMetadata").reason, "already fetching metadata");
  const ok = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table", noMeta: true })), "table");
  assert.equal(paletteRow(ok, "torrent.fetchMetadata").enabled, true);
  const none = V.paletteState("empty", false, V.inspectorDispatch(insp({ pane: "table", state: "empty", row: null })), "table");
  assert.equal(paletteRow(none, "torrent.fetchMetadata").reason, "needs a selected torrent");
});

test("paletteState keeps evaluating from the table when opened elsewhere (the old two-argument call)", () => {
  const st = V.paletteState("rows", true);
  assert.equal(st.pane, "table");
  assert.equal(st.inspectorTarget, null);
  assert.equal(paletteRow(st, "file.cycle").reason, "focus the inspector");
});

test("sameInspectorState: equal fields and target compare equal, any difference doesn't", () => {
  const a = V.inspectorDispatch(insp());
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp())), true, "a fresh but equal result");
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp({ trackerIndex: 1 }))), false);
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp({ tab: "peers" }))), false);
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp({ noMeta: true }))), false);
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp({ pending: [H("a")] }))), false);
  assert.equal(V.sameInspectorState(a, V.inspectorDispatch(insp({ row: torrent({ state: "downloading" }) }))), false);
  assert.equal(V.sameInspectorState(V.inspectorDispatch({}), V.inspectorDispatch({})), true);
  assert.equal(V.sameInspectorState(null, a), false);
});

test("paletteRows: from the inspector, Cycle file priority says focus the files tab unless Files shows", () => {
  const onPeers = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "peers" })), "inspector");
  assert.equal(paletteRow(onPeers, "file.cycle").enabled, false);
  assert.equal(paletteRow(onPeers, "file.cycle").reason, "focus the files tab");
  assert.equal(paletteRow(onPeers, "file.down").enabled, true, "j/k move the peers list");
  const onFiles = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files" })), "inspector");
  assert.equal(paletteRow(onFiles, "file.cycle").enabled, true);
  const fromTable = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files", pane: "table" })), "table");
  assert.equal(paletteRow(fromTable, "file.cycle").reason, "focus the inspector");
});

test("inspectorDispatch: filesTab follows the focused Files tab", () => {
  assert.equal(V.inspectorDispatch(insp({ tab: "files" })).filesTab, true);
  assert.equal(V.inspectorDispatch(insp({ tab: "files", pane: "table" })).filesTab, false);
  assert.equal(V.inspectorDispatch(insp()).filesTab, false);
  assert.equal(V.sameInspectorState(V.inspectorDispatch(insp({ tab: "files", trackers: [] })), V.inspectorDispatch(insp({ tab: "info", trackers: [] }))), false);
});

// --- slice 3b, Task 4: inspectorTab and the Limits placeholders ------------

test("inspectorDispatch: inspectorTab follows the focused tab exactly (D7), '' unfocused", () => {
  for (const tab of ["info", "trackers", "peers", "files", "chart"]) {
    assert.equal(V.inspectorDispatch(insp({ tab })).inspectorTab, tab, tab);
  }
  assert.equal(V.inspectorDispatch(insp({ pane: "table" })).inspectorTab, "");
  assert.equal(V.inspectorDispatch(insp({ row: null })).inspectorTab, "");
  assert.equal(V.inspectorDispatch({}).inspectorTab, "");
});

test("inspectorDispatch: limitCursorKey/limitToggle default so Task 5 can wire them in", () => {
  const d = V.inspectorDispatch(insp({ tab: "info" }));
  assert.equal(d.limitCursorKey, null);
  assert.equal(d.limitToggle, false);
});

test("dispatchState copies inspectorTab and the limit placeholders", () => {
  const st = V.dispatchState({ mode: "NORMAL" }, "inspector", "rows", true, [], V.inspectorDispatch(insp({ tab: "info" })));
  assert.equal(st.inspectorTab, "info");
  assert.equal(st.limitCursorKey, null);
  assert.equal(st.limitToggle, false);
  const stale = V.dispatchState(st, "table", "rows", true, []);
  assert.equal(stale.inspectorTab, "");
});

test("sameInspectorState: differs on inspectorTab even when trackersTab/filesTab agree (both false, e.g. Info vs Chart)", () => {
  const info = V.inspectorDispatch(insp({ tab: "info" }));
  const chart = V.inspectorDispatch(insp({ tab: "chart" }));
  assert.equal(info.trackersTab, chart.trackersTab);
  assert.equal(info.filesTab, chart.filesTab);
  assert.equal(V.sameInspectorState(info, chart), false);
});

test("paletteRows: from the inspector, Next row (file.down) names every tab it covers when off all of them", () => {
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info" })), "inspector");
  const row = paletteRow(onInfo, "file.down");
  assert.equal(row.enabled, false);
  assert.equal(row.reason, "focus the files, trackers or peers tab");
  const onChart = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "chart" })), "inspector");
  assert.equal(paletteRow(onChart, "file.down").reason, "focus the files, trackers or peers tab");
});

test("paletteRows: the Limits rows (Info only) name the info tab, and are otherwise blocked with no note", () => {
  const onFiles = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files" })), "inspector");
  for (const id of ["limit.down", "limit.up", "limit.edit", "limit.toggle"]) {
    assert.equal(paletteRow(onFiles, id).enabled, false, id);
    assert.equal(paletteRow(onFiles, id).reason, "focus the info tab", id);
  }
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info" })), "inspector");
  assert.equal(paletteRow(onInfo, "limit.down").enabled, true);
  assert.equal(paletteRow(onInfo, "limit.up").enabled, true);
  // limit.edit/limit.toggle need Task 5's state; until then, blocked with
  // an empty reason (never "needs a selected torrent" or similar).
  assert.equal(paletteRow(onInfo, "limit.edit").enabled, false);
  assert.equal(paletteRow(onInfo, "limit.edit").reason, "");
  assert.equal(paletteRow(onInfo, "limit.toggle").enabled, false);
  assert.equal(paletteRow(onInfo, "limit.toggle").reason, "");
});

// --- the trackers tab's actions (slice 2b, Task 4) -------------------------

test("paletteRows: R, a, c, x dim with the pane or tab they need, and run on the trackers tab", () => {
  const ids = ["tracker.reannounce", "tracker.add", "tracker.edit", "tracker.remove"];
  const fromTable = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table" })), "table");
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info" })), "inspector");
  const onTrackers = V.paletteState("rows", true, V.inspectorDispatch(insp()), "inspector");
  const emptyTrackers = V.paletteState("rows", true, V.inspectorDispatch(insp({ trackers: [] })), "inspector");
  for (const id of ids) {
    assert.equal(paletteRow(fromTable, id).enabled, false, id);
    assert.equal(paletteRow(fromTable, id).reason, "focus the inspector", id);
    assert.equal(paletteRow(onInfo, id).enabled, false, id);
    assert.equal(paletteRow(onInfo, id).reason, "focus the trackers tab", id);
    assert.equal(paletteRow(onTrackers, id).enabled, true, id);
  }
  // No tracker row: R and a still run (the first tracker), c and x can't.
  assert.equal(paletteRow(emptyTrackers, "tracker.reannounce").enabled, true);
  assert.equal(paletteRow(emptyTrackers, "tracker.add").enabled, true);
  assert.equal(paletteRow(emptyTrackers, "tracker.edit").enabled, false);
  assert.equal(paletteRow(emptyTrackers, "tracker.remove").enabled, false);
});

test("inputPrompt: the INSERT prompt and placeholder per purpose; trackerEdit names only the redacted URL", () => {
  assert.deepEqual(V.inputPrompt("filter", ""), { prompt: "/", placeholder: "filter by name, or paste a magnet" });
  assert.deepEqual(V.inputPrompt("", ""), { prompt: "/", placeholder: "filter by name, or paste a magnet" });
  assert.deepEqual(V.inputPrompt("move", ""), { prompt: "move to", placeholder: "/absolute/path" });
  assert.deepEqual(V.inputPrompt("trackerAdd", ""), { prompt: "Add tracker URL", placeholder: "udp://, http://, https:// or wss://" });
  assert.deepEqual(V.inputPrompt("trackerEdit", "udp://tracker.example:1337/…"), { prompt: "Change udp://tracker.example:1337/… to:", placeholder: "udp://, http://, https:// or wss://" });
});

test("modeHints: INSERT hints for adding and changing a tracker", () => {
  assert.deepEqual(V.modeHints("INSERT", { purpose: "trackerAdd" }).map((h) => h.key + " " + h.label), ["Enter add", "Esc cancel"]);
  assert.deepEqual(V.modeHints("INSERT", { purpose: "trackerEdit" }).map((h) => h.key + " " + h.label), ["Enter change", "Esc cancel"]);
});

test("inspectorDispatch: a tracker row's refusal rides on the target, only when set", () => {
  const rows = [{ url: "udp://p.example/a|b", host: "p.example", refusal: "This tracker's URL can't be edited through the WebUI API." }, { url: "udp://ok.example/a", host: "ok.example", refusal: "" }];
  const bad = V.inspectorDispatch(insp({ trackers: rows, trackerIndex: 0 })).inspectorTarget;
  assert.equal(bad.refusal, rows[0].refusal);
  const ok = V.inspectorDispatch(insp({ trackers: rows, trackerIndex: 1 })).inspectorTarget;
  assert.deepEqual(ok, { kind: "tracker", value: "udp://ok.example/a", label: "ok.example" });
});

// --- peer ban and fetch metadata (slice 2b, Task 5) ---------------------------

test("inspectorDispatch: a peer row's refusal rides on the target, only when set", () => {
  const rows = [{ key: "bogus", ipPort: "bogus", refusal: "This peer's address can't be banned from here." }, { key: "203.0.113.42:6881", ipPort: "203.0.113.42:6881", refusal: "" }];
  const bad = V.inspectorDispatch(insp({ tab: "peers", peers: rows, peerIndex: 0 })).inspectorTarget;
  assert.equal(bad.refusal, rows[0].refusal);
  const ok = V.inspectorDispatch(insp({ tab: "peers", peers: rows, peerIndex: 1 })).inspectorTarget;
  assert.deepEqual(ok, { kind: "peer", value: "203.0.113.42:6881", label: "203.0.113.42" });
});

test("peerIp: the ban confirm names the IP only (the ban is IP-wide)", () => {
  assert.equal(V.peerIp("203.0.113.42:6881"), "203.0.113.42");
  assert.equal(V.peerIp("[2001:db8::1]:51413"), "2001:db8::1");
  assert.equal(V.peerIp("[::1]:1"), "::1");
  // Anything without a recognisable :port is shown as it is.
  assert.equal(V.peerIp("bogus"), "bogus");
  assert.equal(V.peerIp(""), "");
  assert.equal(V.peerIp(undefined), "");
});

test("fetchMetaRefusal: already fetching, then running, else nothing", () => {
  const stopped = torrent({ hash: H("a"), state: "stoppedDL", size: 0 });
  assert.equal(V.fetchMetaRefusal(stopped, false), "");
  assert.equal(V.fetchMetaRefusal(torrent({ hash: H("a"), state: "pausedDL", size: -1 }), false), "");
  assert.equal(V.fetchMetaRefusal(stopped, true), "Already fetching metadata.");
  assert.equal(V.fetchMetaRefusal(torrent({ hash: H("a"), state: "metaDL", size: 0 }), true), "Already fetching metadata.");
  for (const st of ["metaDL", "downloading", "stalledDL", "queuedDL", "forcedMetaDL"]) {
    assert.equal(V.fetchMetaRefusal(torrent({ hash: H("a"), state: st, size: 0 }), false), "Stop it first.", st);
  }
  assert.equal(V.fetchMetaRefusal(null, false), "");
});

test("fetchMetaProgress: absent, waiting (running, size unknown), stopped (no size) or received (size > 0)", () => {
  const list = [torrent({ hash: H("a"), size: 0, state: "metaDL" }), torrent({ hash: H("b"), size: -1 }), torrent({ hash: H("c"), size: 4096 }),
    torrent({ hash: H("e"), size: 0, state: "stoppedDL", progress: 0 }), torrent({ hash: H("f"), size: -1, state: "pausedDL", progress: 0 })];
  assert.equal(V.fetchMetaProgress(list, H("a")), "waiting");
  assert.equal(V.fetchMetaProgress(list, H("b")), "waiting");
  assert.equal(V.fetchMetaProgress(list, H("c")), "received");
  assert.equal(V.fetchMetaProgress(list, H("d")), "absent");
  assert.equal(V.fetchMetaProgress(list, H("e")), "stopped");
  assert.equal(V.fetchMetaProgress(list, H("f")), "stopped");
  assert.equal(V.fetchMetaProgress(null, H("a")), "absent");
  assert.equal(V.FETCH_META_DONE_NOTE, "Metadata received · stopped");
});

test("fetchWatchOutcome: keep, received, or end quietly", () => {
  const running = { ticket: 4, done: false, at: 0 };
  const done = { ticket: 4, done: true, at: 1000 };
  assert.equal(V.fetchWatchOutcome(running, "received", 99999), "keep", "the ticket still runs");
  assert.equal(V.fetchWatchOutcome(done, "received", 1000), "received");
  assert.equal(V.fetchWatchOutcome(done, "waiting", 999999), "keep", "running without a size: still looking");
  assert.equal(V.fetchWatchOutcome(done, "absent", 11000), "keep", "inside the 10 s hold");
  assert.equal(V.fetchWatchOutcome(done, "absent", 11001), "quiet");
  // Stopped with no size (the user stopped it, or qBittorrent did without
  // metadata): a short grace for the status stream to catch up, then quiet.
  assert.equal(V.fetchWatchOutcome(done, "stopped", 4000), "keep");
  assert.equal(V.fetchWatchOutcome(done, "stopped", 4001), "quiet");
  assert.equal(V.fetchWatchOutcome(null, "received", 1), "quiet");
});

test("paletteRows: the real Ban peer and Fetch metadata only rows", () => {
  const onPeers = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "peers" })), "inspector");
  assert.equal(paletteRow(onPeers, "peer.ban").enabled, true);
  assert.equal(paletteRow(onPeers, "peer.ban").keys, "b");
  const fromTable = V.paletteState("rows", true, V.inspectorDispatch(insp({ pane: "table", noMeta: true })), "table");
  assert.equal(paletteRow(fromTable, "torrent.fetchMetadata").enabled, true);
  assert.equal(paletteRow(fromTable, "torrent.fetchMetadata").keys, "f");
});

test("fetchHolds: the cursor waits on a swap in flight, then up to 10 s after it succeeds", () => {
  assert.equal(V.fetchHolds(undefined, 5000), false);
  assert.equal(V.fetchHolds(null, 5000), false);
  assert.equal(V.fetchHolds({ ticket: 3, done: false, at: 0 }, 999999999), true, "in flight: no time limit");
  assert.equal(V.fetchHolds({ ticket: 3, done: true, at: 1000 }, 1000), true);
  assert.equal(V.fetchHolds({ ticket: 3, done: true, at: 1000 }, 11000), true);
  assert.equal(V.fetchHolds({ ticket: 3, done: true, at: 1000 }, 11001), false);
});

test("paletteRows: Cycle file priority is dimmed on a no-metadata Files tab (Space starts it there)", () => {
  const noMeta = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files", noMeta: true })), "inspector");
  assert.equal(paletteRow(noMeta, "file.cycle").enabled, false);
  assert.equal(paletteRow(noMeta, "file.cycle").reason, "no files yet");
  const withFiles = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files", noMeta: false })), "inspector");
  assert.equal(paletteRow(withFiles, "file.cycle").enabled, true);
  // Slice 3b Task 6, Ruling CL 3: the palette applies `when` like dispatch
  // does, so a no-metadata Info tab offers Space's Start download row
  // (was: dimmed "focus the files tab"). See the CL 3 test below.
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info", noMeta: true })), "inspector");
  assert.equal(paletteRow(onInfo, "file.cycle").enabled, true);
  assert.equal(paletteRow(onInfo, "file.cycle").title, "Start download");
});

// --- slice 3a, Task 5: the filters pane's categories and tags -----------------

function libEntries(categories, tags, rows) {
  return V.filterEntries(Model.filterGroups(rows || [torrent()], categories || [], tags || []));
}

function lib(overrides) {
  return Object.assign({
    pane: "filters", state: "rows", filterCursor: { group: "category", value: "anime" },
    filterEntries: libEntries(["anime"], ["seedbox"]), libraryReady: true
  }, overrides || {});
}

test("libraryTarget: the category or tag row under the filters cursor", () => {
  assert.deepEqual(V.inspectorDispatch(lib()).libraryTarget, { kind: "category", value: "anime", label: "anime" });
  assert.deepEqual(V.inspectorDispatch(lib({ filterCursor: { group: "tag", value: "seedbox" } })).libraryTarget, { kind: "tag", value: "seedbox", label: "seedbox" });
  assert.deepEqual(V.inspectorDispatch(lib({ filterCursor: { group: "category", value: "" } })).libraryTarget, { kind: "category", value: "", label: "" }, "Uncategorized: the group");
  assert.deepEqual(V.inspectorDispatch(lib({ filterCursor: { group: "tag", value: "" } })).libraryTarget, { kind: "tag", value: "", label: "" });
});

test("libraryTarget: none on Status/Trackers rows, another pane, a blocking state, or a cursor not in the list", () => {
  for (const o of [
    { filterCursor: { group: "status", value: "All" } },
    { filterCursor: { group: "tracker", value: "" } },
    { filterCursor: { group: "category", value: "gone" } },
    { filterCursor: null }, { filterEntries: [] }, { filterEntries: undefined },
    { pane: "table" }, { pane: "inspector" }, { state: "daemon" }
  ]) {
    assert.equal(V.inspectorDispatch(lib(o)).libraryTarget, null, JSON.stringify(o));
  }
  assert.notEqual(V.inspectorDispatch(lib({ state: "noMatch" })).libraryTarget, null, "a no-match filter keeps the pane");
  // Final fix wave (ruling BS, Important 4): so does the empty library.
  assert.notEqual(V.inspectorDispatch(lib({ state: "empty" })).libraryTarget, null, "the empty library keeps the pane");
});

test("libraryTarget: a category carries the not-ready refusal until the folders are known; a tag never does", () => {
  const LNR = "Still reading qBittorrent's folders; try again in a moment.";
  assert.equal(V.inspectorDispatch(lib({ libraryReady: false })).libraryTarget.refusal, LNR);
  assert.equal(V.inspectorDispatch(lib({ libraryReady: false, filterCursor: { group: "category", value: "" } })).libraryTarget.refusal, LNR);
  assert.equal(V.inspectorDispatch(lib({ libraryReady: false, filterCursor: { group: "tag", value: "seedbox" } })).libraryTarget.refusal, undefined);
  assert.equal(V.inspectorDispatch(lib()).libraryTarget.refusal, undefined);
});

test("libraryTarget: a legacy name is the target exactly as the status spells it", () => {
  const legacy = " x//" + "y".repeat(66);
  const d = V.inspectorDispatch(lib({ filterCursor: { group: "category", value: legacy }, filterEntries: libEntries([legacy]) }));
  assert.deepEqual(d.libraryTarget, { kind: "category", value: legacy, label: legacy });
});

test("dispatchState and paletteState carry the library target; sameInspectorState compares it", () => {
  const i = V.inspectorDispatch(lib());
  const st = V.dispatchState({ mode: "NORMAL" }, "filters", "rows", true, [], i);
  assert.deepEqual(st.libraryTarget, { kind: "category", value: "anime", label: "anime" });
  assert.equal(V.dispatchState({ mode: "NORMAL", libraryTarget: { kind: "tag" } }, "table", "rows", true, [], V.inspectorDispatch({})).libraryTarget, null, "never carried over");
  assert.equal(Registry.dispatch(st, { text: "p", key: 0x50, modifiers: {}, now: 0 }).commandId, "library.path");
  const pal = V.paletteState("rows", true, i, "filters");
  assert.equal(paletteRow(pal, "library.path").enabled, true);
  assert.equal(paletteRow(V.paletteState("rows", true, V.inspectorDispatch(lib({ filterCursor: { group: "tag", value: "seedbox" } })), "filters"), "library.path").reason, "focus a category");
  assert.equal(paletteRow(V.paletteState("rows", true, i, "table"), "library.remove").reason, "focus the filters");
  assert.equal(V.sameInspectorState(i, V.inspectorDispatch(lib())), true);
  assert.equal(V.sameInspectorState(i, V.inspectorDispatch(lib({ filterCursor: { group: "tag", value: "seedbox" } }))), false);
  assert.equal(V.sameInspectorState(i, V.inspectorDispatch(lib({ libraryReady: false }))), false);
});

test("filterEntries: a muted note under an empty Categories or Tags group, never a cursor stop", () => {
  const e = libEntries([], []);
  const notes = e.filter((x) => x.kind === "note");
  assert.deepEqual(notes.map((x) => [x.group, x.label]), [["category", "No categories yet"], ["tag", "No tags yet"]]);
  const at = e.findIndex((x) => x.kind === "note" && x.group === "category");
  assert.equal(e[at - 1].kind, "item");
  assert.equal(e[at - 1].label, "Uncategorized", "right under Uncategorized");
  assert.equal(libEntries(["anime"], ["seedbox"]).some((x) => x.kind === "note"), false);
  assert.deepEqual(libEntries(["anime"], []).filter((x) => x.kind === "note").map((x) => x.group), ["tag"]);
  assert.deepEqual(V.moveFilterCursor(e, { group: "category", value: "" }, 1), { group: "tag", value: "" }, "j skips the note");
  assert.equal(V.filterIndex(e, { group: "category", value: "" }) >= 0, true);
});

test("inputPrompt and modeHints for the library INSERTs", () => {
  assert.equal(V.inputPrompt("categoryAdd", "").prompt, "New category");
  assert.equal(V.inputPrompt("tagAdd", "").prompt, "New tag");
  assert.equal(V.inputPrompt("categoryRename", "anime").prompt, "Rename anime to");
  assert.equal(V.inputPrompt("tagRename", "seedbox").prompt, "Rename seedbox to");
  assert.deepEqual(V.inputPrompt("categoryPath", "anime"), { prompt: "Save path for anime", placeholder: "empty = default" });
  const h = (p) => V.modeHints("INSERT", { purpose: p }).map((x) => x.key + " " + x.label);
  assert.deepEqual(h("categoryAdd"), ["Enter create", "Esc cancel"]);
  assert.deepEqual(h("tagAdd"), ["Enter create", "Esc cancel"]);
  assert.deepEqual(h("categoryRename"), ["Enter rename", "Esc cancel"]);
  assert.deepEqual(h("tagRename"), ["Enter rename", "Esc cancel"]);
  assert.deepEqual(h("categoryPath"), ["Enter set", "Esc cancel"]);
});

test("confirmLine: a library confirm shows the window's line with its own accept word", () => {
  const d = V.confirmLine({ kind: "libraryRemove", line: "Delete tag seedbox? It's removed from 4 torrents." });
  assert.equal(d.lead + d.strong + d.tail, "Delete tag seedbox? It's removed from 4 torrents.");
  assert.equal(d.accept, "delete");
  const r = V.confirmLine({ kind: "libraryRename", line: "animation already exists. Move 2 torrents into it and delete anime?", accept: "merge" });
  assert.equal(r.accept, "merge");
  assert.equal(r.lead, "animation already exists. Move 2 torrents into it and delete anime?");
  assert.equal(V.confirmLine({ kind: "libraryRename", line: "x" }).accept, "rename");
  assert.equal(V.confirmLine({ kind: "libraryPath", line: "x" }).accept, "change");
});

test("msgTrack/msgFinish: an action's own progress and done copy, and qbt's error as-is", () => {
  const copy = { progress: "Renaming anime → animation…", done: "Renamed anime → animation", raw: true };
  let m = V.msgTrack(V.emptyMessages(), 5, "libraryRename", 0, [], copy);
  assert.equal(V.messageLine(m).text, "Renaming anime → animation…");
  assert.equal(V.messageLine(V.msgFinish(m, 5, true, "")).text, "Renamed anime → animation");
  const inc = "Rename incomplete (12 of 21 moved); press c on anime again to finish.";
  const f = V.msgFinish(m, 5, false, inc + "\n");
  assert.equal(V.messageLine(f).text, inc);
  assert.equal(V.messageLine(f).tone, "urgent");
  // an empty error still says something
  assert.equal(V.messageLine(V.msgFinish(m, 5, false, "")).text, "The action failed.");
  // without copy, nothing changes
  assert.equal(V.messageLine(V.msgFinish(V.msgTrack(V.emptyMessages(), 1, "delete", 1, []), 1, false, "boom")).text, "Couldn't delete 1 torrent: boom");
});

test("dispatchPane: the filters pane keeps its keys in the empty library (BS, Important 4)", () => {
  assert.equal(V.dispatchPane("filters", "empty"), "filters");
  const base = { mode: "NORMAL", hasTorrent: false, pane: V.dispatchPane("filters", "empty") };
  const target = { kind: "category", value: "", label: "" };
  const a = Registry.dispatch(Object.assign({}, base, { libraryTarget: target }), V.keyEvent(0x41, "a", 0, 0));
  assert.equal(a.commandId, "library.add");
  const j = Registry.dispatch(base, V.keyEvent(0x4a, "j", 0, 0));
  assert.equal(j.commandId, "filter.down");
  // y matches nothing there; the window treats an unmatched y in the empty
  // library as add from clipboard, as it does a blocked one
  const y = Registry.dispatch(base, V.keyEvent(0x59, "y", 0, 0));
  assert.equal(y.commandId, null);
  assert.equal(V.libraryTarget({ pane: "filters", state: "empty", filterCursor: { group: "category", value: "" },
    filterEntries: V.filterEntries(Model.filterGroups([], ["anime"], [])), libraryReady: true }).kind, "category");
});

test("msgTrack/msgFinish: a copy's fail prefix names the action; qBittorrent's refusal becomes its HTTP code (BS, Minor 5)", () => {
  const copy = { progress: "Deleting category anime…", done: "Deleted category anime", fail: "Deleting category anime failed" };
  const m = V.msgTrack(V.emptyMessages(), 5, "library", 0, [], copy);
  assert.equal(V.messageLine(V.msgFinish(m, 5, false, "qBittorrent refused it (HTTP 409)\n")).text, "Deleting category anime failed: HTTP 409");
  assert.equal(V.messageLine(V.msgFinish(m, 5, false, "anime doesn't exist.")).text, "Deleting category anime failed: anime doesn't exist.");
  assert.equal(V.messageLine(V.msgFinish(m, 5, false, "")).text, "Deleting category anime failed.");
  assert.equal(V.messageLine(V.msgFinish(m, 5, true, "")).text, "Deleted category anime");
});

// --- The C and T pickers (slice 3a, Task 6) ------------------------------------

test("dispatchState passes the open picker's flags fresh, and false without one", () => {
  const st = V.dispatchState({ mode: "PICKER" }, "table", "rows", true, [H("a")], V.inspectorDispatch({}), { queryEmpty: true, multi: true });
  assert.equal(st.pickerQueryEmpty, true);
  assert.equal(st.pickerMulti, true);
  const typed = V.dispatchState(st, "table", "rows", true, [H("a")], V.inspectorDispatch({}), { queryEmpty: false, multi: true });
  assert.equal(typed.pickerQueryEmpty, false);
  const none = V.dispatchState(st, "table", "rows", true, [H("a")], V.inspectorDispatch({}));
  assert.equal(none.pickerQueryEmpty, false, "never carried over");
  assert.equal(none.pickerMulti, false);
  // end to end: Space toggles T's empty query, types into a typed one
  assert.equal(Registry.dispatch(st, { key: KEY.Space, text: " ", modifiers: {} }).commandId, "picker.toggle");
  assert.equal(Registry.dispatch(typed, { key: KEY.Space, text: " ", modifiers: {} }).commandId, null);
});

test("modeHints: a picker shows its own footer, like the palette", () => {
  assert.deepEqual(V.modeHints("PICKER", { pane: "table" }), []);
});

test("confirmLine: C's move confirm shows the window's line with y set", () => {
  const c = V.confirmLine({ kind: "categorySet", line: "Changes 2 torrents' category; 1 torrent's files move to /dl/anime." });
  assert.deepEqual(c, { lead: "Changes 2 torrents' category; 1 torrent's files move to /dl/anime.", strong: "", tail: "", accept: "set" });
});

test("magnetSync in PICKER treats the picker's field like the palette's: no CONFIRM, focus goes back to the field", () => {
  const ms = mstate([mpend("a")]);
  const picking = Object.assign({}, MREG, { mode: "PICKER" });
  let r = V.magnetSync(null, picking, ms, [MURL("a")], { opened: true, active: false });
  assert.equal(r.regState, null, "a magnet never takes over an open picker");
  assert.equal(r.focusField, true);
  r = V.magnetSync(null, picking, ms, [MURL("a")], { opened: true, active: true });
  assert.equal(r.focus, false);
  assert.equal(r.mem.focusDue, true);
});

// --- The Info Limits group (slice 3b, Task 5) -----------------------------------

test("inspectorDispatch: the Limits cursor row, only while the inspector is focused on Info", () => {
  const value = { key: "ratioLimit", label: "Ratio limit", value: "default (none)", muted: true, toggle: false };
  const toggle = { key: "seqDl", label: "Sequential", value: "off", muted: false, toggle: true };
  let d = V.inspectorDispatch(insp({ tab: "info", limitRow: value }));
  assert.equal(d.limitCursorKey, "ratioLimit");
  assert.equal(d.limitToggle, false);
  d = V.inspectorDispatch(insp({ tab: "info", limitRow: toggle }));
  assert.equal(d.limitCursorKey, "seqDl");
  assert.equal(d.limitToggle, true);
  for (const off of [insp({ tab: "files", limitRow: toggle }), insp({ tab: "info", pane: "table", limitRow: toggle }), insp({ tab: "info", row: null, limitRow: toggle })]) {
    d = V.inspectorDispatch(off);
    assert.equal(d.limitCursorKey, null);
    assert.equal(d.limitToggle, false);
  }
  const st = V.dispatchState({ mode: "NORMAL" }, "inspector", "rows", true, [], V.inspectorDispatch(insp({ tab: "info", limitRow: toggle })));
  assert.equal(st.limitCursorKey, "seqDl");
  assert.equal(st.limitToggle, true);
  assert.equal(V.sameInspectorState(V.inspectorDispatch(insp({ tab: "info", limitRow: value })), V.inspectorDispatch(insp({ tab: "info", limitRow: toggle }))), false);
});

test("confirmLine: the share-limit confirm carries its own line, accept set", () => {
  const line = "Set the ratio limit to 0? 1 torrent already meets it and will be removed with its files.";
  assert.deepEqual(V.confirmLine({ commandId: "limit.edit", kind: "limitSet", line: line }), { lead: line, strong: "", tail: "", accept: "set" });
});

test("inputPrompt/modeHints: the Limits INSERT names the row and the torrent", () => {
  assert.deepEqual(V.inputPrompt("limit:dlLimit", "debian.iso"), { prompt: "↓ limit for debian.iso", placeholder: "500K, 1.5M, 0 or u" });
  assert.deepEqual(V.inputPrompt("limit:upLimit", "debian.iso"), { prompt: "↑ limit for debian.iso", placeholder: "500K, 1.5M, 0 or u" });
  assert.deepEqual(V.inputPrompt("limit:ratioLimit", "debian.iso"), { prompt: "Ratio limit for debian.iso", placeholder: "1.5, g or n" });
  assert.deepEqual(V.inputPrompt("limit:seedingTimeLimit", "debian.iso"), { prompt: "Seed time for debian.iso", placeholder: "90m, 2h, 3d, g or n" });
  for (const p of ["limit:dlLimit", "limit:upLimit", "limit:ratioLimit", "limit:seedingTimeLimit"]) {
    assert.deepEqual(V.modeHints("INSERT", { purpose: p }), [{ key: "Enter", label: "set" }, { key: "Esc", label: "cancel" }], p);
  }
});

test("msgTrack/msgFinish: a guard copy prefixes only qBittorrent's bare refusal; qbt's own sentences stand alone", () => {
  const copy = { progress: "Setting the ratio limit…", done: "Ratio limit set to 0", fail: "Setting the ratio limit failed", guard: true };
  const m = V.msgTrack(V.emptyMessages(), 7, "library", 1, [H("a")], copy);
  assert.equal(V.messageLine(m).text, "Setting the ratio limit…");
  assert.equal(V.messageLine(V.msgFinish(m, 7, false, "qBittorrent refused it (HTTP 409)\n")).text, "Setting the ratio limit failed: HTTP 409");
  assert.equal(V.messageLine(V.msgFinish(m, 7, false, "qBittorrent refused it (couldn't reach qBittorrent)")).text, "Setting the ratio limit failed: couldn't reach qBittorrent");
  const guard = "1 torrent already meets that limit, and qBittorrent would remove it with its files.";
  assert.equal(V.messageLine(V.msgFinish(m, 7, false, guard + "\n")).text, guard);
  const partial = "Share limits set on 3 of 5 torrents; qBittorrent refused the rest (HTTP 409)";
  assert.equal(V.messageLine(V.msgFinish(m, 7, false, partial)).text, partial);
  assert.equal(V.messageLine(V.msgFinish(m, 7, false, "")).text, "Setting the ratio limit failed.");
  assert.equal(V.messageLine(V.msgFinish(m, 7, true, "")).text, "Ratio limit set to 0");
  assert.deepEqual(V.msgFinish(m, 7, false, guard).errorHashes, [H("a")]);
});

test("paletteReasonNote: a row blocked with no note says nothing (the Limits rows, D12)", () => {
  assert.equal(V.paletteReasonNote({ title: "Toggle limit", reason: "" }), "");
  assert.equal(V.paletteReasonNote({ title: "Edit limit", reason: "focus the info tab" }), "Edit limit: focus the info tab.");
});

// --- slice 3b, Task 6: bulk limits, and Ruling CL's fold-ins ---------------------

test("CL 1: a limit failure shows qbt's guard sentence and its partial write as they are; everything else gets the action", () => {
  const copy = { progress: "Setting the ratio limit…", done: "Ratio limit set to 0", fail: "Setting the ratio limit failed", guard: true };
  const m = V.msgTrack(V.emptyMessages(), 7, "library", 1, [H("a")], copy);
  const fin = (err) => V.messageLine(V.msgFinish(m, 7, false, err)).text;
  assert.equal(fin("3 torrents already meet that limit, and qBittorrent would remove them."), "3 torrents already meet that limit, and qBittorrent would remove them.");
  assert.equal(fin("Share limits set on 3 of 5 torrents; qBittorrent refused the rest (couldn't reach qBittorrent)"), "Share limits set on 3 of 5 torrents; qBittorrent refused the rest (couldn't reach qBittorrent)");
  assert.equal(fin("2 of those torrents are gone."), "Setting the ratio limit failed: 2 of those torrents are gone.");
  assert.equal(fin("usage: qbt share-limits <hash|list> [--ratio R]"), "Setting the ratio limit failed: usage: qbt share-limits <hash|list> [--ratio R]");
  assert.equal(fin("Could not run the qbt helper"), "Setting the ratio limit failed: Could not run the qbt helper");
});

test("CL 3: the palette applies each row's `when`, taking the title and needs of the row that exists here", () => {
  const onInfo = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info", noMeta: true })), "inspector");
  const row = paletteRow(onInfo, "file.cycle");
  assert.equal(row.title, "Start download");
  assert.equal(row.enabled, true);
  assert.equal(row.keys, "Space");
  // Typing matches the title shown, and the highlight follows it.
  const typed = V.paletteRows("start dow", Registry.commands, [], onInfo).find((r) => r.id === "file.cycle");
  assert.ok(typed, "Start download matches what it says");
  assert.equal(typed.indices.map((i) => typed.title.charAt(i)).join("").toLowerCase(), "start dow");
  // With metadata the Info row doesn't exist: the Files row, dimmed as before.
  const withMeta = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "info", noMeta: false })), "inspector");
  assert.equal(paletteRow(withMeta, "file.cycle").title, "Cycle file priority");
  assert.equal(paletteRow(withMeta, "file.cycle").reason, "focus the files tab");
  // The Files tab keeps its own row and its "no files yet".
  const onFiles = V.paletteState("rows", true, V.inspectorDispatch(insp({ tab: "files", noMeta: true })), "inspector");
  assert.equal(paletteRow(onFiles, "file.cycle").title, "Cycle file priority");
  assert.equal(paletteRow(onFiles, "file.cycle").reason, "no files yet");
});

test("the bulk limit rows show in the palette with no key, enabled on a cursor row", () => {
  const st = V.paletteState("rows", true);
  for (const [id, title] of [["limit.setDownload", "Set download limit"], ["limit.setUpload", "Set upload limit"], ["limit.setRatio", "Set ratio limit"]]) {
    const row = paletteRow(st, id);
    assert.equal(row.title, title);
    assert.equal(row.keys, "");
    assert.equal(row.enabled, true);
    assert.equal(row.group, "Torrent");
  }
  assert.equal(paletteRow(V.paletteState("empty", false), "limit.setRatio").reason, "needs a selected torrent");
});

test("inputPrompt/modeHints: the bulk limit INSERT names the torrents", () => {
  assert.deepEqual(V.inputPrompt("limit:bulk:dlLimit", "3 torrents"), { prompt: "Download limit for 3 torrents", placeholder: "500K, 1.5M, 0 or u" });
  assert.deepEqual(V.inputPrompt("limit:bulk:upLimit", "debian.iso"), { prompt: "Upload limit for debian.iso", placeholder: "500K, 1.5M, 0 or u" });
  assert.deepEqual(V.inputPrompt("limit:bulk:ratioLimit", "2 torrents"), { prompt: "Ratio limit for 2 torrents", placeholder: "1.5, g or n" });
  for (const p of ["limit:bulk:dlLimit", "limit:bulk:upLimit", "limit:bulk:ratioLimit"]) {
    assert.deepEqual(V.modeHints("INSERT", { purpose: p }), [{ key: "Enter", label: "set" }, { key: "Esc", label: "cancel" }], p);
  }
});

test("msgTrack/msgFinish: a chunked limit write that fails part-way says how many changed", () => {
  const many = [];
  for (let i = 0; i < 1001; i++) many.push(("0000000000" + i.toString(16)).slice(-10).repeat(4));
  const copy = { progress: "Setting the ↓ limit…", done: "↓ limit set to 500 KiB/s on 1001 torrents", fail: "Setting the ↓ limit failed", tally: "↓ limit set" };
  const m = V.msgTrack(V.emptyMessages(), [5, 6], "library", 1001, many, copy);
  // the second chunk (1 torrent) fails
  let a = V.msgFinish(m, 5, true, "");
  assert.equal(V.messageLine(a).text, "Setting the ↓ limit…", "still running");
  a = V.msgFinish(a, 6, false, "qBittorrent refused it (HTTP 409)");
  assert.equal(V.messageLine(a).text, "↓ limit set on 1000 of 1001 torrents; the rest failed (HTTP 409)");
  assert.equal(V.messageLine(a).tone, "urgent");
  // the first chunk fails, the second lands: 1 of 1001
  let b = V.msgFinish(m, 5, false, "qBittorrent refused it (HTTP 409)");
  b = V.msgFinish(b, 6, true, "");
  assert.equal(V.messageLine(b).text, "↓ limit set on 1 of 1001 torrents; the rest failed (HTTP 409)");
  // every chunk fails: the plain failure line
  let c = V.msgFinish(m, 5, false, "qBittorrent refused it (HTTP 409)");
  c = V.msgFinish(c, 6, false, "qBittorrent refused it (HTTP 403)");
  assert.equal(V.messageLine(c).text, "Setting the ↓ limit failed: HTTP 409");
  // all land: the done note
  let d = V.msgFinish(V.msgFinish(m, 5, true, ""), 6, true, "");
  assert.equal(V.messageLine(d).text, "↓ limit set to 500 KiB/s on 1001 torrents");
  // a guard sentence in a later chunk, after one that landed, is the reason
  const g = V.msgTrack(V.emptyMessages(), [8, 9], "library", 1001, many, Object.assign({}, copy, { guard: true, tally: "Ratio limit set" }));
  const ge = V.msgFinish(V.msgFinish(g, 8, true, ""), 9, false, "1 torrent already meets that limit, and qBittorrent would remove it.");
  assert.equal(V.messageLine(ge).text, "Ratio limit set on 1000 of 1001 torrents; the rest failed (1 torrent already meets that limit, and qBittorrent would remove it)");
  // a busy (refused) chunk counts as not landed
  const r = V.msgTrack(V.emptyMessages(), [0, 11], "library", 1001, many, copy);
  assert.equal(V.messageLine(V.msgFinish(r, 11, false, "qBittorrent refused it (HTTP 409)")).text, "Setting the ↓ limit failed: HTTP 409");
});

// --- Settings (slice 4a Task 5) ---------------------------------------------

test("dispatchPane: a Settings column passes through, whatever the torrent view shows", () => {
  for (const pane of ["settingsSections", "settingsKeys"]) {
    for (const st of ["loading", "gui", "notInstalled", "daemon", "api", "empty", "noMatch", "rows"]) {
      assert.equal(V.dispatchPane(pane, st), pane, pane + " " + st);
    }
    assert.equal(V.dispatchState({ mode: "NORMAL" }, pane, "api", false, [], null).pane, pane);
  }
  assert.equal(V.dispatchPane("inspector", "api"), "table", "the torrent panes are unchanged");
});

test("paletteRows: :Settings is there and enabled; the Settings navigation rows are not", () => {
  // Slice 4b Task 1: the palette shows the Settings actions (x clears a
  // secret, u undoes, a/x in a list); from the torrents they can't run.
  const actions = ["settings.clearSecret", "settings.undo", "list.add", "list.remove"];
  for (const pane of ["table", "filters", "inspector"]) {
    const rows = V.paletteRows("", Registry.commands, [], paletteState({ pane: pane }));
    const open = rows.find((r) => r.id === "settings.open");
    assert.equal(open.title, "Settings");
    assert.equal(open.keys, ",");
    assert.equal(open.enabled, true, pane);
    assert.ok(!rows.some((r) => /^(settings|list)\.(?!open)/.test(r.id) && !actions.includes(r.id)), pane);
    for (const id of actions) assert.equal(rows.find((r) => r.id === id).enabled, false, pane + " " + id);
  }
  assert.equal(V.paletteRows("sett", Registry.commands, [], paletteState())[0].id, "settings.open");
});

test("palettePane: from Settings, : and ? stay in Settings and every other command runs on the torrents", () => {
  for (const pane of ["settingsSections", "settingsKeys"]) {
    assert.equal(V.palettePane(Registry.commands, "help.toggle", pane), pane);
    for (const id of ["sort.next", "turtle.toggle", "settings.open", "torrent.move", "filter.down"]) {
      assert.notEqual(V.palettePane(Registry.commands, id, pane), pane, id);
    }
  }
});

test("modeHints: the Settings columns and the search field have their own hints", () => {
  assert.deepEqual(V.modeHints("NORMAL", { pane: "settingsSections" }).map((h) => h.key + " " + h.label),
    ["j/k section", "l keys", "/ search all", "Esc back", "? keys"]);
  assert.deepEqual(V.modeHints("NORMAL", { pane: "settingsKeys" }).map((h) => h.key + " " + h.label),
    ["j/k move", "h sections", "/ search", "Esc back", "? keys"]);
  assert.deepEqual(V.modeHints("NORMAL", { pane: "settingsKeys", searching: true }).map((h) => h.key + " " + h.label),
    ["j/k move", "h sections", "/ search", "Esc clear search", "? keys"]);
  assert.deepEqual(V.modeHints("INSERT", { purpose: "settingsSearch" }).map((h) => h.key + " " + h.label),
    ["Enter keep results", "Esc clear"]);
  assert.ok(!V.modeHints("NORMAL", { pane: "settingsKeys" }).some((h) => h.key === "Space" || h.key === "q"), "no torrent keys");
});

test("inputPrompt: the Settings search has its own prompt, not the filter's magnet placeholder", () => {
  assert.deepEqual(V.inputPrompt("settingsSearch"), { prompt: "Search settings", placeholder: "label, help or key" });
});

test("settingsSectionStep: moves over the sections, skipping the dimmed RSS row and stopping at the ends", () => {
  const secs = [{ name: "A" }, { name: "B" }, { name: "Other" }, { name: "RSS", dimmed: true }];
  assert.equal(V.settingsSectionStep(secs, 0, 1), 1);
  assert.equal(V.settingsSectionStep(secs, 2, 1), 2, "RSS is never a cursor stop");
  assert.equal(V.settingsSectionStep(secs, 0, -1), 0);
  assert.equal(V.settingsSectionStep(secs, 7, 0), 2, "a stale index clamps to the last stop");
  assert.equal(V.settingsSectionStep([{ name: "A", dimmed: true }, { name: "B" }], 0, 0), 1);
  assert.equal(V.settingsSectionStep([], 3, 1), 0);
});

test("settingsDownCopy: the torrent view's own blocking copy, else the api-down copy, with keys that work in Settings", () => {
  for (const st of ["gui", "notInstalled", "daemon", "api"]) {
    const c = V.settingsDownCopy(st);
    assert.equal(c.title, V.stateCopy(st).title, st);
    assert.equal(c.body, V.stateCopy(st).body, st);
    assert.deepEqual(c.keys, [{ key: "Esc", label: "Back to torrents" }], st);
  }
  for (const st of ["rows", "empty", "noMatch", "loading"]) {
    assert.equal(V.settingsDownCopy(st).title, V.stateCopy("api").title, st);
  }
});

test("settingsTitle: a section names its count; a search names its query and matches", () => {
  assert.deepEqual(V.settingsTitle("Speed", 12, ""), { title: "Speed", right: "12 settings" });
  assert.deepEqual(V.settingsTitle("Other", 1, ""), { title: "Other", right: "1 setting" });
  assert.deepEqual(V.settingsTitle("Speed", 7, " port "), { title: "Search", right: "“port” · 7 matches" });
  assert.deepEqual(V.settingsTitle("Speed", 1, "dht"), { title: "Search", right: "“dht” · 1 match" });
});

test("settingsFooterKeys: each column lists the keys that apply there", () => {
  const f = (col, s) => V.settingsFooterKeys(col, s).map((h) => h.key + " " + h.label);
  assert.deepEqual(f("settingsSections", false), ["j/k section", "l keys", "/ search all", "Esc back"]);
  assert.deepEqual(f("settingsKeys", false), ["j/k move", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("settingsKeys", true), ["j/k move", "h sections", "/ search", "Esc clear search"]);
});

test("settingsEntries: a group header before each group's first row; a search lists rows alone", () => {
  const rows = [{ key: "a", group: "G1" }, { key: "b", group: "G1" }, { key: "c", group: "G2" }];
  assert.deepEqual(V.settingsEntries(rows, false).map((e) => e.kind === "header" ? "#" + e.label : e.row.key + e.index),
    ["#G1", "a0", "b1", "#G2", "c2"]);
  assert.deepEqual(V.settingsEntries(rows, true).map((e) => e.kind + e.index), ["row0", "row1", "row2"]);
  assert.deepEqual(V.settingsEntries(null, false), []);
});

// --- Settings editors (slice 4a, Task 6) ---------------------------------------------

test("dispatchState carries the Settings cursor key and its editor flags, off by default", () => {
  const st = V.dispatchState({ mode: "NORMAL" }, "settingsKeys", "rows", true, [], null, null, { key: "dht", toggle: true, editable: false });
  assert.equal(st.settingsKey, "dht");
  assert.equal(st.settingsToggle, true);
  assert.equal(st.settingsEditable, false);
  const none = V.dispatchState({ mode: "NORMAL", settingsKey: "stale", settingsToggle: true, settingsEditable: true }, "settingsKeys", "rows", true, []);
  assert.equal(none.settingsKey, null, "a key a previous dispatch left behind never carries over");
  assert.equal(none.settingsToggle, false);
  assert.equal(none.settingsEditable, false);
  assert.equal(Registry.dispatch(st, { key: KEY.Space, text: " ", modifiers: {}, now: 0 }).args.settingKey, "dht");
});

test("confirmLine: a setting's CONFIRM names what y writes, then the consequence", () => {
  const c = V.confirmLine({ kind: "settingConfirm", line: "Turn DHT off?", detail: "Magnets without trackers will stop finding peers.", accept: "turn off" });
  assert.deepEqual(c, { lead: "Turn DHT off? ", strong: "", tail: "Magnets without trackers will stop finding peers.", accept: "turn off" });
  assert.equal(V.confirmLine({ kind: "settingConfirm", line: "Set Encryption to Require?", detail: "x" }).accept, "set");
  assert.ok(!/torrent/.test(V.confirmLine({ kind: "settingConfirm", line: "q?", detail: "d" }).lead), "never the torrent remove line");
});

test("settingQuestion: Turn <label> on/off for a toggle, Set <label> to <value> otherwise", () => {
  assert.deepEqual(V.settingQuestion("DHT", true, false, "off"), { line: "Turn DHT off?", accept: "turn off" });
  assert.deepEqual(V.settingQuestion("UPnP / NAT-PMP port forwarding", true, true, "on"), { line: "Turn UPnP / NAT-PMP port forwarding on?", accept: "turn on" });
  assert.deepEqual(V.settingQuestion("Port for incoming connections", false, 51414, "51414"), { line: "Set Port for incoming connections to 51414?", accept: "set" });
  assert.deepEqual(V.settingQuestion("Command on added", false, "", "empty"), { line: "Set Command on added to empty?", accept: "set" });
});

test("settingFailure: qbt's own sentences show as they are; anything else names the setting", () => {
  const f = (e) => V.settingFailure("DHT", e);
  assert.equal(f("qBittorrent ignored DHT"), "qBittorrent ignored DHT");
  assert.equal(f("Couldn't confirm DHT (HTTP 409)\n"), "Couldn't confirm DHT (HTTP 409)");
  assert.equal(f("Set by OmaqBT's setup."), "Set by OmaqBT's setup.");
  assert.equal(f("OmaqBT needs this as it is."), "OmaqBT needs this as it is.");
  assert.equal(f("qBittorrent doesn't let this be changed."), "qBittorrent doesn't let this be changed.");
  assert.equal(f("OmaqBT won't change this setting."), "OmaqBT won't change this setting.");
  assert.equal(f("qBittorrent has no setting called foo_bar."), "qBittorrent has no setting called foo_bar.");
  assert.equal(f("qBittorrent refused it (HTTP 409)"), "Setting DHT failed: HTTP 409");
  assert.equal(f("Use a whole number from 1 to 65535, or 0 for random."), "Setting DHT failed: Use a whole number from 1 to 65535, or 0 for random.");
  assert.equal(f("Could not run the qbt helper"), "Setting DHT failed: Could not run the qbt helper");
  assert.equal(f(""), "Setting DHT failed.");
});

test("settingsReadNote: a failed read names itself when qBittorrent is up, and stays quiet on a down screen", () => {
  assert.equal(V.settingsReadNote("rows", true, "qBittorrent refused it (HTTP 403)"), "Couldn't read settings: HTTP 403");
  assert.equal(V.settingsReadNote("empty", true, "Could not read preferences"), "Couldn't read settings: Could not read preferences");
  assert.equal(V.settingsReadNote("rows", true, ""), "Couldn't read settings.");
  for (const st of ["gui", "notInstalled", "daemon", "api", "loading"]) assert.equal(V.settingsReadNote(st, true, "x"), "", st);
  assert.equal(V.settingsReadNote("rows", false, "x"), "");
});

test("settingsFooterKeys and modeHints: the settings list names its editor's key", () => {
  const f = (ed) => V.settingsFooterKeys("settingsKeys", false, ed).map((h) => h.key + " " + h.label);
  assert.deepEqual(f("toggle"), ["j/k move", "Space toggle", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("input"), ["j/k move", "Enter edit", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("picker"), ["j/k move", "Enter choose", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("none"), ["j/k move", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(V.settingsFooterKeys("settingsSections", false, "toggle").map((h) => h.key), ["j/k", "l", "/", "Esc"], "the sections never edit");
  assert.deepEqual(V.modeHints("NORMAL", { pane: "settingsKeys", editor: "toggle" }).map((h) => h.key + " " + h.label),
    ["j/k move", "Space toggle", "h sections", "/ search", "Esc back", "? keys"]);
  assert.deepEqual(V.modeHints("INSERT", { purpose: "settingEdit" }).map((h) => h.key + " " + h.label), ["Enter set", "Esc cancel"]);
  assert.deepEqual(V.inputPrompt("settingEdit", "Port for incoming connections"), { prompt: "Port for incoming connections", placeholder: "" });
});

// --- Slice 4a final fix wave (Ruling DU) ---------------------------------------------------

test("settingsFooterKeys: the sections column's Esc clears a live search", () => {
  const esc = (keys) => keys.find((k) => k.key === "Esc").label;
  assert.equal(esc(V.settingsFooterKeys("settingsSections", true)), "clear search");
  assert.equal(esc(V.settingsFooterKeys("settingsSections", false)), "back");
});

test("palette: Settings is disabled, with a reason, while Settings is open", () => {
  const find = (st) => V.paletteRows("", Registry.commands, [], st).find((r) => r.id === "settings.open");
  const open = find(V.paletteState("rows", true, null, "table", true));
  assert.equal(open.enabled, false);
  assert.equal(open.reason, "already open");
  assert.equal(V.paletteReasonNote(open), "Settings: already open.");
  const closed = find(V.paletteState("rows", true, null, "table", false));
  assert.equal(closed.enabled, true);
  assert.equal(find(V.paletteState("rows", true, null, "table")).enabled, true, "omitted means closed");
});

// PREF_SENTENCES is copied by hand from qbt's pref-set sentences: each must
// still be in qbt, or a failure would lose its bare sentence.
// Slice 4b: Task 2's qbt sentences, pinned below as shown unchanged.
const TASK2_SENTENCES = [
  "OmaqBT keeps this read-only: it has no effect while the Web UI only listens on 127.0.0.1.",
  "Send this password with --stdin, never as an argument.",
  "Only the proxy, Dynamic DNS and SMTP passwords take --stdin or --clear.",
  "The value didn't arrive within 5 seconds.", "Use valid UTF-8 text.",
  "The ban list changed while OmaqBT saved it; check it.",
  "Use an IPv4 or IPv6 address.", "Use an http, https or udp tracker URL.", "Keep each pattern to one line.",
  "Type a value, or use --clear.", "Use a value without NUL characters.", "Use at most 1024 characters."
];

test("PREF_SENTENCES: every sentence is still one qbt says", () => {
  const qbt = fs.readFileSync(path.join(__dirname, "..", "qbt"), "utf8");
  assert.ok(Array.isArray(V.PREF_SENTENCES) && V.PREF_SENTENCES.length > 0);
  assert.equal(new Set(V.PREF_SENTENCES).size, V.PREF_SENTENCES.length, "no duplicates");
  for (const s of V.PREF_SENTENCES) {
    assert.ok(qbt.includes(s), "qbt still says: " + s);
  }
});

test("4b PREF_SENTENCES: the 4a stand-ins are retired and Task 2's sentences show as they are", () => {
  assert.ok(!V.PREF_SENTENCES.includes("OmaqBT doesn't change secrets yet."));
  assert.ok(!V.PREF_SENTENCES.includes("Editing multi-line settings arrives in 4b."));
  for (const s of TASK2_SENTENCES) {
    assert.ok(V.PREF_SENTENCES.includes(s), s);
    assert.equal(V.settingFailure("Banned IPs", s), s);
  }
  // Keep it to one line. is 4a's already; the ban read-backs name their address.
  assert.equal(V.settingFailure("Password", "Keep it to one line."), "Keep it to one line.");
  assert.equal(V.settingFailure("Banned IPs", "qBittorrent didn't ban 2001:db8::5."), "qBittorrent didn't ban 2001:db8::5.");
  assert.equal(V.settingFailure("Banned IPs", "qBittorrent still bans 10.0.0.1."), "qBittorrent still bans 10.0.0.1.");
});

test("settingFailure: qbt's validation sentences (Rulings DQ, DR, DS) show as they are", () => {
  for (const s of ["Use a clean path without //, /./ or /../.", "Use an IPv4 or IPv6 address, or leave it empty.",
    "Use at least 3 characters and no colon."]) {
    assert.equal(V.settingFailure("Default save path", s), s);
  }
});

// --- Slice 4b Task 3: the list editor, secrets and the narrow Settings ----------------------

test("4b settingsNarrow: below the 1b filters breakpoint (900); an unknown width is wide", () => {
  assert.equal(V.settingsNarrow(899), true);
  assert.equal(V.settingsNarrow(640), true);
  assert.equal(V.settingsNarrow(900), false);
  assert.equal(V.settingsNarrow(1600), false);
  assert.equal(V.settingsNarrow(0), false);
  assert.equal(V.settingsNarrow(undefined), false);
  // The same breakpoint the torrent view's filters collapse at.
  assert.equal(V.settingsNarrow(899), V.layoutFor(899).filters === "collapsed");
});

test("4b settingsChip: the narrow sections chip names the section", () => {
  assert.equal(V.settingsChip("Speed"), "Speed ▾");
  assert.equal(V.settingsChip(""), "Sections ▾");
});

test("4b dispatchState: carries the six Settings fields, all off by default", () => {
  const st = V.dispatchState({ mode: "NORMAL" }, "settingsKeys", "rows", false, [], null, null, {
    key: "proxy_password", toggle: false, editable: true, listRow: false, secretSet: true,
    listEditable: false, listItem: null, narrow: true, undoCount: 0
  });
  assert.equal(st.settingsKey, "proxy_password");
  assert.equal(st.settingsEditable, true);
  assert.equal(st.settingsSecretSet, true);
  assert.equal(st.narrow, true);
  assert.equal(st.settingsUndoCount, 0);
  const off = V.dispatchState({ mode: "NORMAL" }, "table", "rows", false, [], null, null, null);
  for (const k of ["settingsListRow", "settingsSecretSet", "listEditable", "narrow"]) assert.equal(off[k], false, k);
  assert.equal(off.listItem, null);
  assert.equal(off.settingsUndoCount, 0);
  const list = V.dispatchState({ mode: "NORMAL" }, "settingsList", "rows", false, [], null, null, {
    key: "add_trackers", listEditable: true, listItem: { index: 1, value: "", tierBreak: true }, undoCount: 2
  });
  assert.deepEqual(list.listItem, { index: 1, value: "", tierBreak: true });
  assert.equal(list.listEditable, true);
  assert.equal(list.settingsUndoCount, 2);
  // Through the registry: Enter on a list row opens it; x in a list removes the cursor line.
  const enter = Registry.dispatch(V.dispatchState({ mode: "NORMAL" }, "settingsKeys", "rows", false, [], null, null,
    { key: "add_trackers", listRow: true }), { key: Registry.KEY.Enter, text: "", modifiers: {}, now: 1 });
  assert.equal(enter.commandId, "settings.openList");
  assert.equal(enter.args.settingKey, "add_trackers");
  const x = Registry.dispatch(list, { key: "x".charCodeAt(0), text: "x", modifiers: {}, now: 1 });
  assert.equal(x.commandId, "list.remove");
  assert.deepEqual(Object.assign({}, x.args.listItem), { index: 1, value: "", tierBreak: true });
});

test("4b paletteRows: the Settings actions are dimmed with the step they need, never 'focus the inspector'", () => {
  const reason = (id, st) => V.paletteRows("", Registry.commands, [], st).find((r) => r.id === id);
  for (const pane of ["table", "filters", "inspector"]) {
    const st = V.paletteState("rows", true, V.inspectorDispatch({}), pane, false);
    assert.equal(reason("settings.clearSecret", st).reason, "open Settings", pane);
    assert.equal(reason("settings.undo", st).reason, "open Settings", pane);
    assert.equal(reason("list.add", st).reason, "open a list", pane);
    assert.equal(reason("list.remove", st).reason, "open a list", pane);
  }
  // From the settings: the list rows want a list; clearSecret runs there.
  const keys = V.paletteState("rows", false, V.inspectorDispatch({}), "settingsKeys", true, { key: "proxy_password", secretSet: true });
  assert.equal(reason("list.add", keys).reason, "open a list");
  assert.equal(reason("settings.clearSecret", keys).enabled, true);
  assert.equal(reason("settings.undo", keys).reason, "nothing to undo");
  // From the sections: clearSecret wants the settings column.
  const secs = V.paletteState("rows", false, V.inspectorDispatch({}), "settingsSections", true, null);
  assert.equal(reason("settings.clearSecret", secs).reason, "focus the settings");
  assert.equal(reason("list.add", secs).reason, "open a list");
  // From a list: a/x run there; clearSecret wants the settings column.
  const list = V.paletteState("rows", false, V.inspectorDispatch({}), "settingsList", true,
    { key: "excluded_file_names", listEditable: true, listItem: { index: 0, value: "*.exe", tierBreak: false } });
  assert.equal(reason("list.add", list).enabled, true);
  assert.equal(reason("list.remove", list).enabled, true);
  assert.equal(reason("settings.clearSecret", list).reason, "focus the settings");
  // As the window passes it: the torrent pane, and the Settings column apart.
  const both = V.paletteState("rows", true, V.inspectorDispatch({}), "inspector", true, { key: "proxy_password", secretSet: true }, "settingsKeys");
  assert.equal(reason("settings.clearSecret", both).enabled, true, "judged in the settings column");
  assert.equal(reason("file.cycle", both).reason, "focus the files tab", "the inspector rows as before, from the torrent pane");
  assert.equal(reason("list.add", both).reason, "open a list");
  // The torrent panes' own reasons are unchanged.
  const table = V.paletteState("rows", true, V.inspectorDispatch({}), "table", false);
  assert.equal(reason("file.cycle", table).reason, "focus the inspector");
  assert.equal(reason("filter.down", table).reason, "focus the filters");
});

test("4b settingsFooterKeys: list and secret rows, the list column, and the narrow Tab", () => {
  const f = (col, ed, ctx) => V.settingsFooterKeys(col, false, ed, ctx).map((h) => h.key + " " + h.label);
  assert.deepEqual(f("settingsKeys", "list"), ["j/k move", "Enter open", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("settingsKeys", "secret"), ["j/k move", "Enter set", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("settingsKeys", "secret", { secretSet: true }), ["j/k move", "Enter set", "x clear", "h sections", "/ search", "Esc back"]);
  assert.deepEqual(f("settingsKeys", "input", { narrow: true }), ["j/k move", "Enter edit", "Tab sections", "/ search", "Esc back"]);
  assert.deepEqual(f("settingsSections", "none", { narrow: true }), ["j/k section", "Enter choose", "/ search all", "Esc close"]);
  // Ruling EF: on a list section (Banned IPs) the overlay's Esc leaves Settings.
  assert.deepEqual(f("settingsSections", "none", { narrow: true, listSection: true }), ["j/k section", "Enter choose", "/ search all", "Esc back"]);
  // W2: opening the overlay ends a search, but one typed from it is live: Esc clears it.
  assert.deepEqual(V.settingsFooterKeys("settingsSections", true, "none", { narrow: true, listSection: true }).map((h) => h.key + " " + h.label),
    ["j/k section", "Enter choose", "/ search all", "Esc clear search"]);
  assert.deepEqual(f("settingsList", "none", { listEditable: true, listItem: { index: 0 } }), ["j/k move", "a add", "x remove", "Esc back"]);
  assert.deepEqual(f("settingsList", "none", { listEditable: true, listItem: null }), ["j/k move", "a add", "Esc back"]);
  assert.deepEqual(f("settingsList", "none", {}), ["j/k move", "Esc back"], "saving: nothing to add or remove yet");
  assert.deepEqual(V.modeHints("NORMAL", { pane: "settingsList", listEditable: true }).map((h) => h.key + " " + h.label),
    ["j/k move", "a add", "Esc back", "? keys"]);
});

test("4b confirmLine: the secret clear names the secret, never a value", () => {
  assert.deepEqual(V.confirmLine({ kind: "secretClear", line: "Clear the proxy password?" }),
    { lead: "Clear the proxy password? ", strong: "", tail: "qBittorrent forgets it.", accept: "clear" });
});

test("4b settingFailure: the list-rules sentences show as they are", () => {
  for (const s of ["Use an IPv4 or IPv6 address.", "Use an http, https or udp tracker URL.",
    "Keep each pattern to one line.", "Type a value, or use --clear.", "Keep it to one line.",
    "Use a value without NUL characters.", "Use at most 1024 characters."]) {
    assert.equal(V.settingFailure("Banned IPs", s), s);
  }
  const fromFile = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "list-rules-cases.json"), "utf8"))
    .cases.filter((c) => !c.ok).map((c) => c.message);
  // The empty pattern is refused in the field only (qbt keeps empty entries).
  for (const m of fromFile) if (m !== "Use a pattern such as *.exe.") assert.ok(V.PREF_SENTENCES.includes(m), m);
});

// --- Views and Search (slice 5a, Task 1) -------------------------------------------

test("5a: dispatchPane keeps every Settings and Search pane, whatever the torrent view shows", () => {
  for (const pane of Registry.SETTINGS_PANES.concat(Registry.SEARCH_PANES)) {
    for (const st of ["rows", "loading", "api", "empty", "daemon"]) assert.equal(V.dispatchPane(pane, st), pane, pane + " " + st);
  }
});

test("5a: dispatchState carries Search's flags, and narrow from whichever view shows", () => {
  const result = { fileName: "x" }, plugin = { name: "p" };
  const st = V.dispatchState({ mode: "NORMAL" }, "searchResults", "rows", true, [], {}, null, null,
    { narrow: true, result: result, plugin: plugin, plugins: 3, enabledPlugins: 2, pluginsBusy: true, running: true });
  assert.deepEqual([st.pane, st.narrow, st.searchResult, st.searchPlugin, st.searchPluginCount, st.searchEnabledPlugins, st.searchPluginsBusy],
    ["searchResults", true, result, plugin, 3, 2, true]);
  const none = V.dispatchState({ mode: "NORMAL", searchResult: result, searchPluginsBusy: true }, "table", "rows", true, [], {}, null, null);
  assert.deepEqual([none.narrow, none.searchResult, none.searchPlugin, none.searchPluginCount, none.searchEnabledPlugins, none.searchPluginsBusy],
    [false, null, null, 0, 0, false], "always written, so nothing carries over from a previous dispatch");
  assert.equal(V.dispatchState({}, "settingsKeys", "rows", true, [], {}, null, { narrow: true }).narrow, true, "Settings' narrow still counts");
  assert.equal(V.dispatchState({}, "searchResults", "rows", true, [], {}, null, null, { plugins: "2" }).searchPluginCount, 0, "counts are numbers");
});

test("5a: the Search footers", () => {
  const f = (pane, flags) => V.searchFooterKeys(pane, flags).map((h) => h.key + " " + h.label);
  const plugin = { name: "p" };
  assert.deepEqual(f("searchResults", {}), ["j/k move", "h plugins column", "P plugins", "Esc back"]);
  assert.deepEqual(f("searchResults", { result: {}, enabledPlugins: 1, running: true }),
    ["j/k move", "Enter add", "d page", "/ search", "c category", "h plugins column", "P plugins", "Esc stop"]);
  assert.deepEqual(f("searchResults", { narrow: true, enabledPlugins: 1 }), ["j/k move", "/ search", "c category", "Tab plugins column", "P plugins", "Esc back"]);
  assert.deepEqual(f("searchPlugins", { enabledPlugins: 1 }), ["j/k filter", "l results", "/ search", "c category", "P plugins", "Esc back"]);
  assert.deepEqual(f("searchPlugins", { enabledPlugins: 1, running: true }), ["j/k filter", "l results", "/ search", "c category", "P plugins", "Esc stop"]);
  assert.deepEqual(f("searchPlugins", { narrow: true }), ["j/k filter", "l results", "P plugins", "Esc close"]);
  // Narrow, Esc in the Plugins column closes it (search.pluginsClose), even
  // while a search runs: the footer says what the registry does.
  assert.deepEqual(f("searchPlugins", { narrow: true, running: true }), ["j/k filter", "l results", "P plugins", "Esc close"]);
  for (const [pane, narrow, running] of [["searchPlugins", true, true], ["searchPlugins", false, true], ["searchResults", true, true], ["searchResults", false, false]]) {
    const esc = V.searchFooterKeys(pane, { narrow: narrow, running: running }).find((h) => h.key === "Esc").label;
    const id = Registry.dispatch({ mode: "NORMAL", pane: pane, narrow: narrow }, V.keyEvent(Registry.KEY.Escape, "\u001b", 0, 0)).commandId;
    assert.equal(esc, id === "search.pluginsClose" ? "close" : (running ? "stop" : "back"), pane + " narrow " + narrow + " running " + running + ": " + id);
  }
  assert.deepEqual(f("searchPluginList", {}), ["j/k move", "i install", "Esc close"]);
  assert.deepEqual(f("searchPluginList", { plugin: plugin, plugins: 2 }), ["j/k move", "Space on/off", "i install", "x uninstall", "U update all", "Esc close"]);
  assert.deepEqual(f("searchPluginList", { plugin: plugin, plugins: 2, pluginsBusy: true }), ["j/k move", "Esc close"]);
  // modeHints routes a Search pane there, with ? at the end.
  const hints = V.modeHints("NORMAL", { pane: "searchResults", search: { result: {} } }).map((h) => h.key);
  assert.deepEqual(hints.slice(-2), ["Esc", "?"]);
  assert.ok(hints.includes("Enter"));
  assert.deepEqual(V.modeHints("NORMAL", { pane: "searchPluginList", search: null }).map((h) => h.key), ["j/k", "i", "Esc", "?"]);
});

test("5a: the Search INSERTs' prompts and hints", () => {
  assert.deepEqual(V.inputPrompt("searchQuery"), { prompt: "Search", placeholder: "what to look for" });
  assert.deepEqual(V.inputPrompt("pluginInstall"), { prompt: "Install plugin from", placeholder: "https://…/name.py" });
  assert.deepEqual(V.modeHints("INSERT", { purpose: "searchQuery" }).map((h) => h.key + " " + h.label), ["Enter search", "Esc cancel"]);
  assert.deepEqual(V.modeHints("INSERT", { purpose: "pluginInstall" }).map((h) => h.key + " " + h.label), ["Enter install", "Esc cancel"]);
  assert.deepEqual(V.SEARCH_INPUT_PURPOSES, ["searchQuery", "pluginInstall"]);
  assert.deepEqual(V.VIEW_INPUT_PURPOSES, ["settingsSearch", "settingEdit", "searchQuery", "pluginInstall", "rssFeedUrl", "rssFeedName", "rssFolderName", "rssRename"]);
});

test("5a: Search's confirms show the window's line, an optional detail and their word", () => {
  assert.deepEqual(V.confirmLine({ kind: "searchAdd", line: "Add debian.iso (650 MiB) from example.org?" }),
    { lead: "Add debian.iso (650 MiB) from example.org?", strong: "", tail: "", accept: "add" });
  assert.deepEqual(V.confirmLine({ kind: "searchOpenPage", line: "Open example.org in your browser? It won't go through the VPN." }).accept, "open");
  assert.deepEqual(V.confirmLine({ kind: "pluginInstall", line: "Install jackett from example.org?", detail: "This runs Python code as qBittorrent, with access to your downloads." }),
    { lead: "Install jackett from example.org? ", strong: "", tail: "This runs Python code as qBittorrent, with access to your downloads.", accept: "install" });
  assert.equal(V.confirmLine({ kind: "pluginUninstall", line: "Uninstall jackett?" }).accept, "uninstall");
  assert.deepEqual(V.SEARCH_ACCEPT, { searchAdd: "add", searchOpenPage: "open", pluginInstall: "install", pluginUninstall: "uninstall" });
});

test("5a: paletteState takes the active view (4b's true still means Settings)", () => {
  const legacy = V.paletteState("rows", true, {}, "table", true, {}, "settingsKeys");
  assert.deepEqual([legacy.activeView, legacy.viewPane, legacy.settingsOpen, legacy.settingsPane], ["settings", "settingsKeys", true, "settingsKeys"]);
  const search = V.paletteState("rows", true, {}, "inspector", "search", null, "searchResults", { result: { fileName: "x" }, enabledPlugins: 1 });
  assert.deepEqual([search.activeView, search.viewPane, search.settingsOpen, search.settingsPane, search.pane], ["search", "searchResults", false, "", "inspector"]);
  assert.deepEqual(search.searchResult, { fileName: "x" });
  const torrents = V.paletteState("rows", true, {}, "table", "torrents", null, "table");
  assert.deepEqual([torrents.activeView, torrents.viewPane, torrents.settingsOpen], ["torrents", "", false]);
  assert.equal(V.paletteState("rows", true).activeView, "torrents");
  assert.equal(V.paletteState("rows", true, {}, "table", false).activeView, "torrents");
});

function rowOf(rows, id) { return rows.find((r) => r.id === id); }

const SEARCH_ACTIONS = ["search.new", "search.category", "search.add", "search.copyLink", "search.openPage", "search.sort", "search.sortReverse", "search.plugins",
  "plugin.toggle", "plugin.install", "plugin.uninstall", "plugin.updateAll", "plugin.copyListUrl"];

test("5a: outside Search the palette lists only :Search of Search's rows, so the torrent and Settings palettes are unchanged", () => {
  for (const st of [V.paletteState("rows", true, {}, "table", "torrents"), V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys")]) {
    const rows = V.paletteRows("", Registry.commands, [], st);
    assert.equal(rowOf(rows, "search.open").keys, "F");
    for (const id of SEARCH_ACTIONS) assert.equal(rowOf(rows, id), undefined, id + " in " + st.activeView);
    assert.deepEqual(V.paletteRows("sort", Registry.commands, [], st).map((r) => r.id).filter((id) => /^(search|plugin)\./.test(id)), [], "sort");
  }
  const inSearch = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchResults"));
  for (const id of SEARCH_ACTIONS) assert.ok(rowOf(inSearch, id), id + " is listed in Search");
  for (const id of ["search.down", "search.up", "search.back", "search.focusResults", "search.focusPlugins", "search.pluginsOverlay", "search.pluginsClose",
    "plugin.down", "plugin.up", "plugin.close"]) assert.equal(rowOf(inSearch, id), undefined, id + " is palette-hidden");
  // Judged outside Search, a Search row still names the step it needs.
  const addRows = Registry.commands.filter((r) => r.id === "search.add");
  assert.equal(V.paletteSearchReason(addRows, V.paletteState("rows", true, {}, "table", "torrents")), "open Search");
  assert.equal(V.paletteListed({ rows: addRows }, V.paletteState("rows", true, {}, "table", "torrents")), false);
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "search.open") }, null), true);
});

test("5a: the palette in Search judges Search's rows from its pane, with their reasons", () => {
  const flags = { result: { fileName: "x" }, plugin: { name: "p" }, plugins: 2, enabledPlugins: 1 };
  const inResults = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchResults", flags));
  for (const id of ["search.new", "search.category", "search.add", "search.copyLink", "search.openPage", "search.sort", "search.sortReverse", "search.plugins", "plugin.copyListUrl"]) {
    assert.equal(rowOf(inResults, id).enabled, true, id);
  }
  assert.equal(rowOf(inResults, "search.category").keys, "c");
  assert.deepEqual([rowOf(inResults, "search.open").enabled, rowOf(inResults, "search.open").reason], [false, "already open"]);
  assert.equal(rowOf(inResults, "settings.open").enabled, true, ":Settings runs (the window leaves Search first)");
  for (const id of ["plugin.toggle", "plugin.install", "plugin.uninstall", "plugin.updateAll"]) {
    assert.deepEqual([rowOf(inResults, id).enabled, rowOf(inResults, id).reason], [false, "open the plugins (P)"], id);
  }
  const noResult = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchResults", { enabledPlugins: 0, plugins: 1 }));
  assert.equal(rowOf(noResult, "search.add").reason, "needs a result");
  assert.equal(rowOf(noResult, "search.new").reason, "all plugins are off (P)");
  assert.equal(rowOf(noResult, "search.category").reason, "all plugins are off (P)");
  const inPlugins = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchPlugins", flags));
  assert.deepEqual([rowOf(inPlugins, "search.add").enabled, rowOf(inPlugins, "search.add").reason], [false, "focus the results"]);
  assert.equal(rowOf(inPlugins, "search.new").enabled, true);
  const inList = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchPluginList", flags));
  for (const id of ["plugin.toggle", "plugin.install", "plugin.uninstall", "plugin.updateAll", "plugin.copyListUrl"]) assert.equal(rowOf(inList, id).enabled, true, id);
  const busy = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "search", null, "searchPluginList", Object.assign({}, flags, { pluginsBusy: true })));
  assert.equal(rowOf(busy, "plugin.updateAll").reason, "wait for the plugin change to finish");
  // Settings' rows from Search still say to open Settings.
  assert.equal(rowOf(inResults, "settings.undo").reason, "open Settings");
  // And :Search from Settings runs (the window leaves Settings first).
  const inSettings = V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys"));
  assert.equal(rowOf(inSettings, "search.open").enabled, true);
  assert.deepEqual([rowOf(inSettings, "settings.open").enabled, rowOf(inSettings, "settings.open").reason], [false, "already open"]);
});

test("5a: paletteView names the view a palette row runs in (the window leaves the other one first)", () => {
  const C = Registry.commands;
  assert.equal(V.paletteView(C, "search.add", "searchResults"), "search");
  assert.equal(V.paletteView(C, "palette.open", "searchResults"), "search");
  assert.equal(V.paletteView(C, "sort.next", "searchResults"), "torrents", "a torrent row runs on the torrents");
  assert.equal(V.paletteView(C, "search.open", "settingsKeys"), "torrents", ":Search leaves Settings");
  assert.equal(V.paletteView(C, "settings.open", "searchResults"), "torrents", ":Settings leaves Search");
  assert.equal(V.paletteView(C, "settings.undo", "settingsKeys"), "settings");
  assert.equal(V.paletteView(C, "list.add", "settingsList"), "settings");
  assert.equal(V.paletteView(C, "torrent.toggle", "inspector"), "torrents");
  assert.deepEqual(V.VIEW_OPENERS, { "settings.open": "settings", "search.open": "search", "rss.open": "rss" });
});

test("5a: the ? overlay names a view by its view", () => {
  for (const p of Registry.SETTINGS_PANES) assert.equal(V.helpPaneName(p), "settings");
  for (const p of Registry.SEARCH_PANES) assert.equal(V.helpPaneName(p), "search");
  for (const p of ["table", "filters", "inspector"]) assert.equal(V.helpPaneName(p), p);
});

// --- 5b0 (Task 1): pins for the view-host refactor -----------------------------------
// What ClientView.js says today at every site the refactor rewrites, so a
// table-driven rewrite has to give the same answers.

// paletteSettingsReason and paletteFocusReason aren't exported, so their
// answers are read off a palette row for a made-up command with these panes.
function reasonFor(panes, state) {
  const cmd = { id: "x.probe", title: "Probe", group: "App", keys: ["k"], modes: ["NORMAL"], panes: panes, needs: "none" };
  const rows = V.paletteRows("", [cmd], [], state);
  assert.equal(rows.length, 1, panes.join(",") + " is listed");
  return rows[0].enabled ? "" : rows[0].reason;
}

test("5b0: a Settings row from elsewhere names the Settings step it needs (paletteSettingsReason)", () => {
  const torrents = V.paletteState("rows", true, {}, "table", "torrents");
  const settingsSections = V.paletteState("rows", true, {}, "table", "settings", {}, "settingsSections");
  assert.equal(reasonFor(["settingsKeys"], torrents), "open Settings");
  assert.equal(reasonFor(["settingsKeys"], V.paletteState("rows", true, {}, "table", "search", null, "searchResults")), "open Settings");
  assert.equal(reasonFor(["settingsKeys"], settingsSections), "focus the settings");
  assert.equal(reasonFor(["settingsKeys", "settingsList"], settingsSections), "focus the settings", "a keys row wins over a list row");
  assert.equal(reasonFor(["settingsList"], settingsSections), "open a list");
  assert.equal(reasonFor(["settingsList"], torrents), "open a list", "a list row never says to open Settings");
  assert.equal(reasonFor(["settingsKeys"], V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys")), "", "runs from its own column");
});

test("5b0: paletteFocusReason asks Settings first, then Search, then the torrent panes", () => {
  const torrents = V.paletteState("rows", true, {}, "table", "torrents");
  const search = V.paletteState("rows", true, {}, "table", "search", null, "searchResults");
  const settings = V.paletteState("rows", true, {}, "table", "settings", {}, "settingsSections");
  assert.equal(reasonFor(["settingsKeys", "searchResults"], settings), "focus the settings", "Settings' answer comes first");
  assert.equal(reasonFor(["searchPlugins", "settingsList"], torrents), "open a list");
  assert.equal(reasonFor(["searchPluginList", "filters"], search), "open the plugins (P)", "a Search reason beats the torrent panes'");
  assert.equal(reasonFor(["filters"], torrents), "focus the filters");
  assert.equal(reasonFor(["filters"], V.paletteState("rows", true, {}, "filters", "torrents", null, "filters")), "", "runs from its own pane");
  assert.equal(reasonFor(["inspector"], torrents), "focus the inspector");
  assert.equal(reasonFor(["inspector", "filters"], torrents), "focus the inspector", "the first pane with a reason");
  assert.equal(reasonFor(["filters"], settings), "focus the filters");
});

test("5b0: paletteSearchReason names the Search step a row needs", () => {
  const rows = (...panes) => panes.map((p) => ({ panes: [p] }));
  const inSearch = { activeView: "search" };
  assert.equal(V.paletteSearchReason(rows("table", "settingsKeys"), inSearch), "", "no Search pane, no reason");
  assert.equal(V.paletteSearchReason([{}], inSearch), "");
  assert.equal(V.paletteSearchReason(rows("searchResults"), null), "open Search");
  assert.equal(V.paletteSearchReason(rows("searchResults"), { activeView: "settings" }), "open Search");
  assert.equal(V.paletteSearchReason(rows("searchPluginList"), { activeView: "torrents" }), "open Search", "opening comes before anything else");
  assert.equal(V.paletteSearchReason(rows("searchPluginList"), inSearch), "open the plugins (P)");
  assert.equal(V.paletteSearchReason(rows("searchResults"), inSearch), "focus the results");
  assert.equal(V.paletteSearchReason(rows("searchResults", "searchPlugins"), inSearch), "focus the results");
  assert.equal(V.paletteSearchReason(rows("searchResults", "searchPluginList"), inSearch), "focus the results", "results win over the list");
  assert.equal(V.paletteSearchReason(rows("searchPlugins"), inSearch), "leave the plugins");
  assert.equal(V.paletteSearchReason(rows("searchPlugins", "searchPluginList"), inSearch), "open the plugins (P)", "a list row without a results row");
});

test("5b0: the palette from each view: :Search and :Settings, their reasons and which rows are listed", () => {
  const from = (view, pane) => V.paletteRows("", Registry.commands, [], V.paletteState("rows", true, {}, "table", view, view === "settings" ? {} : null, pane));
  const torrents = from("torrents", "table");
  const settings = from("settings", "settingsKeys");
  const search = from("search", "searchResults");
  const pair = (rows, id) => [rowOf(rows, id).enabled, rowOf(rows, id).reason];
  assert.deepEqual(pair(torrents, "search.open"), [true, ""]);
  assert.deepEqual(pair(torrents, "settings.open"), [true, ""]);
  assert.deepEqual(pair(settings, "search.open"), [true, ""], ":Search from Settings");
  assert.deepEqual(pair(settings, "settings.open"), [false, "already open"]);
  assert.deepEqual(pair(search, "settings.open"), [true, ""], ":Settings from Search");
  assert.deepEqual(pair(search, "search.open"), [false, "already open"]);
  // A Settings row is listed from every view and says to open Settings from the other two.
  assert.deepEqual(pair(torrents, "settings.undo"), [false, "open Settings"]);
  assert.deepEqual(pair(search, "settings.undo"), [false, "open Settings"]);
  assert.deepEqual(pair(settings, "settings.undo"), [false, "nothing to undo"]);
  assert.deepEqual(pair(torrents, "list.add"), [false, "open a list"]);
  // A Search row is listed only in Search.
  for (const rows of [torrents, settings]) {
    assert.deepEqual(rows.filter((r) => /^(search|plugin)\./.test(String(r.id))).map((r) => r.id), ["search.open"]);
  }
  assert.ok(rowOf(search, "search.add"));
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "settings.undo") }, V.paletteState("rows", true, {}, "table", "torrents")), true);
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "search.add") }, V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys")), false);
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "search.add") }, V.paletteState("rows", true, {}, "table", "search", null, "searchResults")), true);
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "search.add") }, undefined), false);
  assert.equal(V.paletteListed({ rows: Registry.commands.filter((r) => r.id === "torrent.toggle") }, V.paletteState("rows", true)), true);
});

test("5b0: only a view's opener says 'already open', and only while that view shows", () => {
  const states = { torrents: V.paletteState("rows", true, {}, "table", "torrents"),
    settings: V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys"),
    search: V.paletteState("rows", true, {}, "table", "search", null, "searchResults") };
  for (const [view, st] of Object.entries(states)) {
    const dimmed = V.paletteRows("", Registry.commands, [], st).filter((r) => r.reason === "already open").map((r) => r.id);
    assert.deepEqual(dimmed, view === "settings" ? ["settings.open"] : (view === "search" ? ["search.open"] : []), view);
  }
});

test("5b0: paletteState carries the view, its pane, and each view's flags", () => {
  const t = V.paletteState("rows", true, {}, "table", "torrents", null, "searchResults");
  assert.deepEqual([t.activeView, t.viewPane, t.settingsPane, t.settingsOpen], ["torrents", "", "", false], "no view pane for the torrents");
  assert.equal(V.paletteState("rows", true, {}, "table", "", null, "x").activeView, "torrents", "an empty name is the torrents");
  assert.equal(V.paletteState("rows", true, {}, "table", "search", null, "").viewPane, "", "no pane given");
  const se = V.paletteState("rows", true, {}, "table", "settings", { key: "dht", toggle: true, editable: true, undoCount: 3 }, "settingsKeys");
  assert.deepEqual([se.settingsKey, se.settingsToggle, se.settingsEditable, se.settingsUndoCount, se.settingsPane, se.activeView],
    ["dht", true, true, 3, "settingsKeys", "settings"]);
  const sr = V.paletteState("rows", true, {}, "table", "search", null, "searchPluginList", { down: true, narrow: true, plugins: 2, enabledPlugins: 1, pluginsBusy: true });
  assert.deepEqual([sr.searchDown, sr.narrow, sr.searchPluginCount, sr.searchEnabledPlugins, sr.searchPluginsBusy, sr.settingsPane, sr.mode],
    [true, true, 2, 1, true, "", "NORMAL"]);
  assert.equal(V.paletteState("rows", true, {}, "table", "search", null, "searchResults", null).searchDown, false);
});

test("5b0: dispatchState writes Search's down flag every time", () => {
  const down = V.dispatchState({ mode: "NORMAL" }, "searchResults", "rows", true, [], {}, null, null, { down: true });
  assert.equal(down.searchDown, true);
  assert.equal(V.dispatchState(down, "searchResults", "rows", true, [], {}, null, null, {}).searchDown, false);
  assert.equal(V.dispatchState(down, "table", "rows", true, [], {}, null, null, null).searchDown, false);
  assert.equal(V.dispatchState({}, "searchResults", "rows", true, [], {}, null, null, { down: "yes" }).searchDown, false, "only true counts");
});

test("5b0: a view's dispatch flags are written every time, so nothing carries over from another view", () => {
  const set = V.dispatchState({ mode: "NORMAL" }, "settingsKeys", "rows", false, [], {}, null,
    { key: "dht", toggle: true, editable: true, listRow: true, secretSet: true, listEditable: true, listItem: { index: 0 }, narrow: true, undoCount: 2 });
  assert.deepEqual([set.settingsKey, set.settingsToggle, set.settingsEditable, set.settingsListRow, set.settingsSecretSet, set.listEditable, set.narrow, set.settingsUndoCount],
    ["dht", true, true, true, true, true, true, 2]);
  const off = V.dispatchState(set, "searchResults", "rows", false, [], {}, null, null, { result: { fileName: "x" } });
  assert.deepEqual([off.settingsKey, off.settingsToggle, off.settingsEditable, off.settingsListRow, off.settingsSecretSet, off.listEditable, off.listItem, off.narrow, off.settingsUndoCount],
    [null, false, false, false, false, false, null, false, 0]);
  assert.deepEqual(off.searchResult, { fileName: "x" });
  const back = V.dispatchState(off, "table", "rows", true, [], {}, null, null, null);
  assert.deepEqual([back.searchResult, back.searchPlugin, back.searchPluginCount], [null, null, 0]);
});

test("5b0: the view tables: input purposes, openers and the views they name", () => {
  assert.deepEqual(V.SEARCH_INPUT_PURPOSES, ["searchQuery", "pluginInstall"]);
  assert.deepEqual(V.VIEW_INPUT_PURPOSES, ["settingsSearch", "settingEdit"].concat(V.SEARCH_INPUT_PURPOSES, V.VIEW_INPUT_PURPOSES_BY_VIEW.rss));
  assert.deepEqual(V.VIEW_OPENERS, { "settings.open": "settings", "search.open": "search", "rss.open": "rss" });
  for (const [id, view] of Object.entries(V.VIEW_OPENERS)) {
    assert.ok(Registry.VIEWS.includes(view), view);
    assert.ok(Registry.commands.some((r) => r.id === id), id);
  }
  assert.deepEqual(Registry.VIEWS, ["torrents", "settings", "search", "rss"]);
  // A view's INSERT prompts and hints exist for each purpose it owns.
  // (the fallback, "Enter keep filter", is what a purpose no view names gets)
  const fallback = JSON.stringify(V.modeHints("INSERT", { purpose: "noSuchPurpose" }));
  for (const p of V.VIEW_INPUT_PURPOSES) assert.notEqual(JSON.stringify(V.modeHints("INSERT", { purpose: p })), fallback, p);
  for (const p of V.SEARCH_INPUT_PURPOSES) assert.notEqual(V.inputPrompt(p).prompt, "", p);
});

test("5b0: every view but the torrents is in every per-view table", () => {
  for (const v of Registry.VIEWS) {
    if (v === "torrents") continue;
    assert.equal(typeof V.VIEW_FLAG_STATE[v], "function", "VIEW_FLAG_STATE." + v);
    assert.ok(Array.isArray(V.VIEW_INPUT_PURPOSES_BY_VIEW[v]) && V.VIEW_INPUT_PURPOSES_BY_VIEW[v].length > 0, "VIEW_INPUT_PURPOSES_BY_VIEW." + v);
    assert.equal(typeof V.PALETTE_VIEW_REASON[v], "function", "PALETTE_VIEW_REASON." + v);
    assert.ok(Registry.VIEW_META[v], "VIEW_META." + v);
    assert.equal(V.VIEW_OPENERS[Registry.VIEW_META[v].opener], v, "VIEW_OPENERS " + v);
  }
});

test("5b0: the footer takes the view's flags the way Client passes them", () => {
  // Client: View.copyState(settingsCmds.flags() || {}, { accept, purpose, pane: keyPane, search, searching, editor, filesTab }).
  const copyState = (base, patch) => Object.assign({}, base, patch);
  const hints = (settings, patch) => V.modeHints("NORMAL", copyState(settings || {}, patch)).map((h) => h.key + " " + h.label);
  assert.deepEqual(hints(null, { pane: "searchResults", search: null }), ["j/k move", "h plugins column", "P plugins", "Esc back", "? keys"]);
  assert.deepEqual(hints(null, { pane: "searchResults", search: { enabledPlugins: 1 } }),
    ["j/k move", "/ search", "c category", "h plugins column", "P plugins", "Esc back", "? keys"]);
  assert.deepEqual(hints({ key: "dht", toggle: true }, { pane: "settingsKeys", searching: false, editor: "toggle", search: null }),
    ["j/k move", "Space toggle", "h sections", "/ search", "Esc back", "? keys"]);
  assert.deepEqual(hints({ key: "dht" }, { pane: "settingsKeys", searching: true, editor: "toggle", search: null }),
    ["j/k move", "Space toggle", "h sections", "/ search", "Esc clear search", "? keys"], "a search in progress changes only Esc");
  assert.deepEqual(V.modeHints("CONFIRM", copyState({}, { accept: V.confirmLine({ kind: "searchAdd", line: "x" }).accept })).map((h) => h.key + " " + h.label), ["y add", "n/Esc keep"]);
  assert.deepEqual(V.modeHints("INSERT", copyState({}, { purpose: "settingsSearch" })).map((h) => h.key + " " + h.label), ["Enter keep results", "Esc clear"]);
});

// --- Slice 5b0: per-view tables ---------------------------------------------

test("views map: a flags entry for a new view reaches its mapper", () => {
  V.VIEW_FLAG_STATE.demo = (f, st) => { st.demoSeen = !!(f && f.x === 1); };
  const st = V.dispatchState({ mode: "NORMAL" }, "table", "rows", true, [], null, null, null, null, { demo: { x: 1 } });
  assert.equal(st.demoSeen, true);
  delete V.VIEW_FLAG_STATE.demo;
});

test("views map: a mapper runs with null flags when its view is absent", () => {
  const st = V.dispatchState({ mode: "NORMAL" }, "table", "rows", true, [], null, null, null, null);
  assert.equal(st.searchResult, null);
  assert.equal(st.settingsKey, null);
});

test("derived constants equal 5a's literals, plus 5b1's RSS", () => {
  assert.deepEqual(V.SEARCH_INPUT_PURPOSES, ["searchQuery", "pluginInstall"]);
  assert.deepEqual(V.VIEW_INPUT_PURPOSES, ["settingsSearch", "settingEdit", "searchQuery", "pluginInstall", "rssFeedUrl", "rssFeedName", "rssFolderName", "rssRename"]);
  assert.deepEqual(V.VIEW_OPENERS, { "settings.open": "settings", "search.open": "search", "rss.open": "rss" });
});

// --- Slice 5b1: RSS (Task 1, the contract) --------------------------------------

const RSS_CASES = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "rss-rules-cases.json"), "utf8"));
const RSS_WIN = RSS_CASES.window;
const RSS_ITEM_V = { path: "Linux\\Debian security", name: "Debian security", folder: false, feeds: 0 };
const RSS_ARTICLE_V = { feedPath: "Linux\\Debian security", guid: "dsa-6000", title: "DSA-6000 openssl", isRead: false, hasTorrent: true, inLibrary: false,
  link: "https://www.debian.org/security/2026/dsa-6000", torrentURL: "magnet:?xt=urn:btih:" + "ab".repeat(20), host: "www.debian.org" };
// RssPane.flags, all on.
const RSS_FLAGS = { rssItem: RSS_ITEM_V, rssFeedRow: true, rssArticle: RSS_ARTICLE_V, rssUnread: 3, rssProcessingOff: true, rssUp: true, narrow: false, wide: false };
const rssKeys = (pane, flags) => V.rssFooterKeys(pane, flags).map((h) => h.key + " " + h.label);

test("5b1: the RSS tables: flags, input purposes, palette reason, footer and confirms", () => {
  assert.equal(typeof V.VIEW_FLAG_STATE.rss, "function");
  assert.deepEqual(V.VIEW_INPUT_PURPOSES_BY_VIEW.rss, ["rssFeedUrl", "rssFeedName", "rssFolderName", "rssRename"]);
  assert.equal(typeof V.PALETTE_VIEW_REASON.rss, "function");
  assert.equal(typeof V.rssFooterKeys, "function");
  assert.deepEqual(V.RSS_ACCEPT, { rssAdd: "add", rssOpenPage: "open", rssRemove: "remove", rssMarkRead: "mark read", rssProcessingOn: "turn on" });
});

test("5b1: VIEW_FLAG_STATE.rss writes RssPane.flags into the dispatch state, always", () => {
  const on = V.dispatchState({ mode: "NORMAL" }, "rssFeeds", "rows", false, [], null, null, null, null, { rss: RSS_FLAGS });
  assert.deepEqual([on.rssItem, on.rssFeedRow, on.rssArticle, on.rssUnread, on.rssProcessingOff, on.rssUp, on.narrow, on.rssWide],
    [RSS_ITEM_V, true, RSS_ARTICLE_V, 3, true, true, false, false]);
  const narrow = V.dispatchState({ mode: "NORMAL" }, "rssArticles", "rows", false, [], null, null, null, null, { rss: Object.assign({}, RSS_FLAGS, { narrow: true, wide: true }) });
  assert.deepEqual([narrow.narrow, narrow.rssWide], [true, true], "narrow comes from whichever view shows; wide is rssWide");
  // Stale RSS fields in regState never carry over once RSS is gone.
  const off = V.dispatchState(on, "table", "rows", true, [], null, null, null, null, {});
  assert.deepEqual([off.rssItem, off.rssFeedRow, off.rssArticle, off.rssUnread, off.rssProcessingOff, off.rssUp, off.rssWide], [null, false, null, 0, false, false, false]);
  // Wrong types are dropped, not trusted.
  const bad = V.dispatchState({ mode: "NORMAL" }, "rssFeeds", "rows", false, [], null, null, null, null,
    { rss: { rssItem: "Linux", rssFeedRow: 1, rssArticle: "x", rssUnread: "3", rssProcessingOff: "yes", rssUp: 1 } });
  assert.deepEqual([bad.rssItem, bad.rssFeedRow, bad.rssArticle, bad.rssUnread, bad.rssProcessingOff, bad.rssUp], [null, false, null, 0, false, false]);
  // And the registry reads them: x on a feed, A with unread.
  const x = Registry.dispatch(on, { text: "x", key: 0x58, modifiers: {}, now: 0 });
  assert.deepEqual([x.commandId, x.args.item.path], ["rss.remove", "Linux\\Debian security"]);
});

test("5b1: every RSS row's needs reason is the case file's muted sentence", () => {
  const up = { rssUp: true };
  const sentence = (r) => (/^(RSS|qBittorrent)/.test(r) ? r : r.charAt(0).toUpperCase() + r.slice(1)) + ".";
  assert.equal(sentence(Registry.needsReason("rssItem", up)), RSS_WIN.reasonItem);
  assert.equal(sentence(Registry.needsReason("rssArticle", up)), RSS_WIN.reasonArticle);
  assert.equal(sentence(Registry.needsReason("rssUnread", up)), RSS_WIN.reasonUnread);
  assert.equal(sentence(Registry.needsReason("rssProcessingOff", up)), RSS_WIN.reasonProcessingOn);
  assert.equal(sentence(Registry.needsReason("rssUp", {})), RSS_WIN.reasonDown);
  for (const need of ["rssItem", "rssArticle", "rssUnread", "rssProcessingOff", "rssUp"]) assert.equal(sentence(Registry.needsReason(need, {})), RSS_WIN.reasonDown, need);
  // Every RSS row's need is one of these (or none / rssFeedRow, which is silent).
  for (const row of Registry.commands.filter((r) => /^rss\./.test(r.id))) {
    assert.ok(["none", "rssFeedRow", "rssItem", "rssArticle", "rssUnread", "rssProcessingOff", "rssUp"].includes(row.needs), row.id);
  }
});

test("5b1: rssFooterKeys for each RSS pane, ending with ?", () => {
  const f = (patch) => Object.assign({}, RSS_FLAGS, patch);
  // The Feeds column: the same keys wide and narrow.
  assert.deepEqual(rssKeys("rssFeeds", f({})), ["j/k move", "l articles", "a add feed", "x remove", "r refresh", "A mark read", "O turn on RSS", "Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssFeeds", f({ narrow: true })), rssKeys("rssFeeds", f({})));
  assert.deepEqual(rssKeys("rssFeeds", f({ rssItem: null, rssUnread: 0, rssProcessingOff: false })), ["j/k move", "l articles", "a add feed", "r refresh", "Esc back", "? keys"],
    "Unread or All, nothing unread, RSS on");
  // The Articles column, with and without an article; O only while processing is off.
  assert.deepEqual(rssKeys("rssArticles", f({})), ["j/k move", "Space read", "Enter add", "d page", "h feeds", "A mark read", "O turn on RSS", "Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssArticles", f({ rssProcessingOff: false })), ["j/k move", "Space read", "Enter add", "d page", "h feeds", "A mark read", "Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssArticles", f({ rssArticle: null, rssUnread: 0, rssProcessingOff: false })), ["j/k move", "h feeds", "Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssArticles", f({ rssArticle: Object.assign({}, RSS_ARTICLE_V, { isRead: true, hasTorrent: false }), rssUnread: 0 })),
    ["j/k move", "d page", "h feeds", "O turn on RSS", "Esc back", "? keys"], "read, no torrent: no Space, no Enter");
  assert.deepEqual(rssKeys("rssArticles", f({ rssArticle: Object.assign({}, RSS_ARTICLE_V, { inLibrary: true }) })).slice(0, 3), ["j/k move", "Space read", "d page"], "in library: no Enter");
  // Narrow: Tab opens the feeds overlay, l shows the article full width; h brings it back.
  assert.deepEqual(rssKeys("rssArticles", f({ narrow: true })), ["j/k move", "Space read", "Enter add", "d page", "l article", "Tab feeds", "A mark read", "O turn on RSS", "Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssArticles", f({ narrow: true, wide: true })), ["j/k move", "Space read", "Enter add", "d page", "h back", "Esc back", "? keys"]);
  // The feeds overlay.
  assert.deepEqual(rssKeys("rssFeedList", f({ narrow: true })), ["j/k move", "Enter choose", "Esc close", "? keys"]);
  // qBittorrent down: only the way out.
  assert.deepEqual(rssKeys("rssFeeds", f({ rssUp: false })), ["Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssArticles", f({ rssUp: false })), ["Esc back", "? keys"]);
  assert.deepEqual(rssKeys("rssFeedList", f({ rssUp: false })), ["j/k move", "Esc close", "? keys"]);
  for (const pane of Registry.RSS_PANES) for (const flags of [{}, null, RSS_FLAGS]) assert.deepEqual(V.rssFooterKeys(pane, flags).slice(-1), [{ key: "?", label: "keys" }], pane);
  // modeHints routes an RSS pane there, with the flags Client passes as `rss`.
  const copyState = (base, patch) => Object.assign({}, base, patch);
  assert.deepEqual(V.modeHints("NORMAL", copyState({}, { pane: "rssArticles", rss: RSS_FLAGS, search: null })).map((h) => h.key + " " + h.label), rssKeys("rssArticles", RSS_FLAGS));
  assert.deepEqual(V.modeHints("NORMAL", copyState({}, { pane: "rssFeeds", rss: null })).map((h) => h.key + " " + h.label), ["Esc back", "? keys"]);
});

test("5b1: the RSS INSERTs' prompts and hints", () => {
  assert.deepEqual(V.inputPrompt("rssFeedUrl"), { prompt: RSS_WIN.promptFeedUrl, placeholder: RSS_WIN.placeholderFeedUrl });
  assert.deepEqual(V.inputPrompt("rssFeedName", "www.debian.org"), { prompt: RSS_WIN.promptFeedName, placeholder: "www.debian.org" }, "the host");
  assert.deepEqual(V.inputPrompt("rssFeedName"), { prompt: RSS_WIN.promptFeedName, placeholder: "" });
  assert.deepEqual(V.inputPrompt("rssFolderName"), { prompt: RSS_WIN.promptFolderName, placeholder: "" });
  assert.deepEqual(V.inputPrompt("rssRename", "Debian security"), { prompt: RSS_WIN.promptRename, placeholder: "Debian security" }, "the current name");
  const hints = (p) => V.modeHints("INSERT", { purpose: p }).map((h) => h.key + " " + h.label);
  for (const p of ["rssFeedUrl", "rssFeedName", "rssFolderName"]) assert.deepEqual(hints(p), ["Enter add", "Esc cancel"], p);
  assert.deepEqual(hints("rssRename"), ["Enter rename", "Esc cancel"]);
});

test("5b1: RSS's confirms show the window's line and their word", () => {
  for (const [kind, word] of Object.entries(V.RSS_ACCEPT)) {
    assert.deepEqual(V.confirmLine({ kind: kind, line: "Remove Debian security? This can't be undone." }),
      { lead: "Remove Debian security? This can't be undone.", strong: "", tail: "", accept: word }, kind);
  }
  assert.deepEqual(V.modeHints("CONFIRM", { accept: V.confirmLine({ kind: "rssMarkRead", line: "x" }).accept }).map((h) => h.key + " " + h.label), ["y mark read", "n/Esc keep"]);
  assert.equal(V.confirmLine({ kind: "rssAdd", line: "x", accept: "send" }).accept, "send", "a line may carry its own word");
});

test("5b1: paletteListed hides RSS's rows outside RSS; :RSS is listed everywhere", () => {
  const rows = (id) => ({ rows: Registry.commands.filter((r) => r.id === id) });
  const torrents = V.paletteState("rows", true, {}, "table", "torrents");
  const settings = V.paletteState("rows", true, {}, "table", "settings", {}, "settingsKeys");
  const search = V.paletteState("rows", true, {}, "table", "search", null, "searchResults");
  const rss = V.paletteState("rows", true, {}, "table", "rss", null, "rssFeeds", null, { rss: RSS_FLAGS });
  for (const id of Registry.commands.filter((r) => /^rss\./.test(r.id) && r.id !== "rss.open").map((r) => r.id)) {
    for (const st of [torrents, settings, search]) assert.equal(V.paletteListed(rows(id), st), false, id + " from " + st.activeView);
    assert.equal(V.paletteListed(rows(id), rss), true, id + " inside RSS");
  }
  for (const st of [torrents, settings, search, rss, null]) assert.equal(V.paletteListed(rows("rss.open"), st), true);
  // The torrent view's palette gains ":RSS" and nothing else.
  const titles = (st) => V.paletteRows("", Registry.commands, [], st).filter((r) => r.kind === "command").map((r) => r.id);
  assert.deepEqual(titles(torrents).filter((id) => /^rss\./.test(id)), ["rss.open"]);
  assert.deepEqual(titles(rss).filter((id) => /^rss\./.test(id)).sort(),
    ["rss.add", "rss.addFeed", "rss.addFolder", "rss.markAllRead", "rss.markRead", "rss.open", "rss.openPage", "rss.processingOn", "rss.refresh", "rss.remove", "rss.rename"]);
  const row = (st, id) => V.paletteRows("", Registry.commands, [], st).find((r) => r.id === id);
  assert.deepEqual([row(rss, "rss.open").enabled, row(rss, "rss.open").reason], [false, "already open"]);
  assert.deepEqual([row(rss, "rss.remove").enabled, row(rss, "rss.remove").keys], [true, "x"]);
  assert.deepEqual([row(rss, "rss.processingOn").title, row(rss, "rss.processingOn").enabled], ["RSS processing on", true]);
});

test("5b1: PALETTE_VIEW_REASON.rss: open RSS from elsewhere, then the column the row needs", () => {
  const R = V.PALETTE_VIEW_REASON.rss;
  const rows = (id) => Registry.commands.filter((r) => r.id === id);
  const inRss = { activeView: "rss" };
  for (const st of [{ activeView: "torrents" }, { activeView: "search" }, null]) {
    assert.equal(R(rows("rss.add"), st), "open RSS");
    assert.equal(R(rows("rss.remove"), st), "open RSS");
  }
  assert.equal(R(rows("rss.add"), inRss), "focus the articles");
  assert.equal(R(rows("rss.markRead"), inRss), "focus the articles");
  assert.equal(R(rows("rss.remove"), inRss), "focus the feeds");
  assert.equal(R(rows("rss.addFolder"), inRss), "focus the feeds");
  assert.equal(R(rows("search.add"), inRss), "", "not an RSS row");
  assert.equal(R(rows("rss.open"), { activeView: "torrents" }), "", ":RSS names only torrent panes");
  // Through the palette: an Articles row from the Feeds column, and the reverse.
  const fromFeeds = V.paletteState("rows", true, {}, "table", "rss", null, "rssFeeds", null, { rss: RSS_FLAGS });
  const fromArticles = V.paletteState("rows", true, {}, "table", "rss", null, "rssArticles", null, { rss: RSS_FLAGS });
  const row = (st, id) => V.paletteRows("", Registry.commands, [], st).find((r) => r.id === id);
  assert.deepEqual([row(fromFeeds, "rss.add").enabled, row(fromFeeds, "rss.add").reason], [false, "focus the articles"]);
  assert.deepEqual([row(fromArticles, "rss.remove").enabled, row(fromArticles, "rss.remove").reason], [false, "focus the feeds"]);
  assert.equal(row(fromArticles, "rss.add").enabled, true);
  // A need the flags don't meet dims the row with its reason.
  const none = V.paletteState("rows", true, {}, "table", "rss", null, "rssArticles", null, { rss: Object.assign({}, RSS_FLAGS, { rssArticle: null }) });
  assert.deepEqual([row(none, "rss.add").enabled, row(none, "rss.add").reason], [false, "no article here"]);
});

test("5b1: the ? overlay names RSS's panes by the view", () => {
  for (const p of Registry.RSS_PANES) assert.equal(V.helpPaneName(p), "rss");
  assert.equal(V.paletteView(Registry.commands, "rss.remove", "rssFeeds"), "rss");
  assert.equal(V.paletteView(Registry.commands, "rss.open", "searchResults"), "torrents", ":RSS leaves Search");
  assert.equal(V.paletteView(Registry.commands, "search.open", "rssFeeds"), "torrents", ":Search leaves RSS");
});
