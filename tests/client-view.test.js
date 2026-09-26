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

// --- blocking states dispatch as the table pane ---------------------------

test("dispatchPane: rows and noMatch keep the real pane", () => {
  assert.equal(V.dispatchPane("inspector", "rows"), "inspector");
  assert.equal(V.dispatchPane("filters", "noMatch"), "filters");
});

test("dispatchPane: blocking states dispatch as the table pane", () => {
  for (const st of ["loading", "gui", "notInstalled", "daemon", "api", "empty"]) {
    for (const pane of ["filters", "inspector", "table"]) {
      assert.equal(V.dispatchPane(pane, st), "table", st + "/" + pane);
    }
  }
});

test("dispatchPane makes Enter and y reach their commands from any restored pane", () => {
  for (const pane of ["filters", "inspector"]) {
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

test("VISUAL x over 2 rows and X over 1 row go through CONFIRM; x over 1 row does not", () => {
  const rows = R("a", "b");
  const vis = { mode: "VISUAL", pane: "table", prefix: null, prefixAt: 0, pending: null };
  const two = V.dispatchState(vis, "table", "rows", true, V.targetHashes("VISUAL", rows, H("b"), H("a")));
  assert.equal(Registry.dispatch(two, V.keyEvent(0x58, "x", 0, 0)).confirm.count, 2);
  const one = V.dispatchState(vis, "table", "rows", true, V.targetHashes("VISUAL", rows, H("a"), H("a")));
  assert.equal(Registry.dispatch(one, V.keyEvent(0x58, "x", 0, 0)).confirm, undefined);
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
  assert.deepEqual(info.fields.map((f) => f.label), ["State", "Size", "Speed", "Peers", "Ratio", "Category", "Added", "Save path"]);
  const val = (l) => info.fields.find((f) => f.label === l).value;
  assert.equal(val("State"), "● downloading · 34%");
  assert.equal(info.fields[0].tone, "accent");
  assert.equal(val("Size"), "1.7 GiB (592 MiB done)");
  assert.equal(val("Speed"), "↓ 4.1 MiB/s · ↑ 210 KiB/s");
  assert.equal(val("Peers"), "14 seeds · 3 leechers");
  assert.equal(val("Ratio"), "0.03 · limit global");
  assert.equal(val("Category"), "anime");
  assert.equal(val("Added"), "D1790000000");
  assert.equal(val("Save path"), "/home/x/anime");
  assert.deepEqual(info.keys.map((k) => k.key), ["o", "y", "m", "e"]);
});

test("inspectorInfo: missing fields show —, errored rows say why", () => {
  const info = V.inspectorInfo({ hash: H("a"), state: "missingFiles", progress: 0.5 });
  const val = (l) => info.fields.find((f) => f.label === l).value;
  assert.equal(info.name, "—");
  assert.equal(val("State"), "! missing files · 50%");
  assert.equal(info.fields[0].tone, "urgent");
  for (const l of ["Size", "Speed", "Peers", "Ratio", "Category", "Added", "Save path"]) assert.equal(val(l), "—", l);
});

test("filesView: loading, error, empty and rows", () => {
  assert.equal(V.filesView([], undefined).state, "loading");
  assert.equal(V.filesView([], { state: "loading" }).state, "loading");
  assert.equal(V.filesView([], { state: "error", error: "x" }).state, "error");
  assert.equal(V.filesView([], { state: "ok" }).state, "empty");
  const files = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "files.json"), "utf8"));
  const v = V.filesView(files, { state: "ok" });
  assert.equal(v.state, "rows");
  assert.deepEqual(v.rows[0], { index: 0, name: "debian.iso", progressText: "42%", priorityText: "Low", skipped: false });
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
