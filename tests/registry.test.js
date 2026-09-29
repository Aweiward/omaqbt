const { test } = require("node:test");
const assert = require("node:assert/strict");
const Registry = require("../CommandRegistry.js");

const KEY = Registry.KEY;
const dispatch = Registry.dispatch;
const helpFor = Registry.helpFor;
const commands = Registry.commands;

// --- test helpers ---------------------------------------------------------

// Builds an event the way the window will: `key` is the Qt int code,
// `text` is event.text (Qt gives special keys non-empty text too, e.g.
// Escape -> "\u001b", Return -> "\r" -- these are deliberately realistic,
// not "").
function ev(text, key, mods, now) {
  return {
    text: text === undefined ? "" : text,
    key: key === undefined ? 0 : key,
    modifiers: mods || { ctrl: false, shift: false, alt: false },
    now: now === undefined ? 0 : now
  };
}

function state(overrides) {
  var base = {
    mode: "NORMAL",
    pane: "table",
    prefix: null,
    prefixAt: 0,
    hasTorrent: true,
    selectionCount: 0,
    pending: null
  };
  var out = {};
  var k;
  for (k in base) out[k] = base[k];
  for (k in overrides || {}) out[k] = overrides[k];
  return out;
}

function keyOf(ch) {
  return ch.toUpperCase().charCodeAt(0);
}

// --- KEY constants ---------------------------------------------------------

test("KEY constants match Qt::Key values", () => {
  assert.equal(KEY.Escape, 0x01000000);
  assert.equal(KEY.Tab, 0x01000001);
  assert.equal(KEY.Backtab, 0x01000002);
  assert.equal(KEY.Return, 0x01000004);
  assert.equal(KEY.Enter, 0x01000005);
  assert.equal(KEY.Up, 0x01000013);
  assert.equal(KEY.Down, 0x01000015);
  assert.equal(KEY.Space, 0x20);
  assert.equal(KEY.H, 0x48);
  assert.equal(KEY.L, 0x4c);
  assert.equal(KEY.N, 0x4e);
  assert.equal(KEY.P, 0x50);
});

// --- NORMAL, table pane: one test per table row -----------------------------

test("j and Down move the cursor down", () => {
  for (const e of [ev("j", keyOf("j")), ev("", KEY.Down)]) {
    const r = dispatch(state(), e);
    assert.equal(r.commandId, "cursor.down", JSON.stringify(e));
  }
});

test("k and Up move the cursor up", () => {
  for (const e of [ev("k", keyOf("k")), ev("", KEY.Up)]) {
    const r = dispatch(state(), e);
    assert.equal(r.commandId, "cursor.up", JSON.stringify(e));
  }
});

test("g g moves the cursor to the top", () => {
  const s0 = state();
  const first = dispatch(s0, ev("g", keyOf("g"), null, 1000));
  assert.equal(first.commandId, null);
  assert.equal(first.state.prefix, "g");
  assert.equal(first.state.prefixAt, 1000);

  const second = dispatch(first.state, ev("g", keyOf("g"), null, 1200));
  assert.equal(second.commandId, "cursor.top");
  assert.equal(second.state.prefix, null);
});

test("G moves the cursor to the bottom", () => {
  const r = dispatch(state(), ev("G", keyOf("g")));
  assert.equal(r.commandId, "cursor.bottom");
});

test("Space toggles the torrent under the cursor", () => {
  const r = dispatch(state({ hasTorrent: true }), ev(" ", KEY.Space));
  assert.equal(r.commandId, "torrent.toggle");
  assert.equal(r.args.count, 1);
});

test("Enter in the table pane opens the files tab", () => {
  const r = dispatch(state({ pane: "table" }), ev("\r", KEY.Return));
  assert.equal(r.commandId, "inspector.files");
});

test("o opens the containing folder", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("o", keyOf("o")));
  assert.equal(r.commandId, "torrent.openFolder");
});

test("x always asks for confirmation, even for one torrent", () => {
  const confirmStep = dispatch(state({ hasTorrent: true }), ev("x", keyOf("x")));
  assert.equal(confirmStep.commandId, null);
  assert.deepEqual(confirmStep.confirm, { commandId: "torrent.remove", count: 1, withFiles: false });
  assert.equal(confirmStep.state.mode, "CONFIRM");

  const accepted = dispatch(confirmStep.state, ev("y", keyOf("y")));
  assert.equal(accepted.commandId, "torrent.remove");
  assert.deepEqual(accepted.args, { count: 1, confirmed: true });
  assert.equal(accepted.state.mode, "NORMAL");

  const cancelStep = dispatch(confirmStep.state, ev("n", keyOf("n")));
  assert.equal(cancelStep.commandId, "confirm.cancel");
  assert.equal(cancelStep.state.mode, "NORMAL");
});

test("X always asks for confirmation, even for one torrent", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("X", keyOf("x")));
  assert.equal(r.commandId, null);
  assert.deepEqual(r.confirm, { commandId: "torrent.delete", count: 1, withFiles: true });
  assert.equal(r.state.mode, "CONFIRM");
});

test("y copies the magnet link", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("y", keyOf("y")));
  assert.equal(r.commandId, "torrent.copyMagnet");
});

test("m moves the torrent", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("m", keyOf("m")));
  assert.equal(r.commandId, "torrent.move");
});

test("e rechecks the torrent", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("e", keyOf("e")));
  assert.equal(r.commandId, "torrent.recheck");
});

test("V enters visual mode", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("V", keyOf("v")));
  assert.equal(r.commandId, "visual.enter");
  assert.equal(r.state.mode, "VISUAL");
});

// --- NORMAL, any pane --------------------------------------------------

test("t toggles showing all torrents", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const r = dispatch(state({ pane }), ev("t", keyOf("t")));
    assert.equal(r.commandId, "all.toggle", pane);
  }
});

test("s advances the sort order", () => {
  const r = dispatch(state(), ev("s", keyOf("s")));
  assert.equal(r.commandId, "sort.next");
});

test("S reverses the sort order", () => {
  const r = dispatch(state(), ev("S", keyOf("s")));
  assert.equal(r.commandId, "sort.reverse");
});

test("z toggles alternative speed limits", () => {
  const r = dispatch(state(), ev("z", keyOf("z")));
  assert.equal(r.commandId, "turtle.toggle");
});

test("/ opens the filter text field and enters INSERT", () => {
  const r = dispatch(state(), ev("/", 0x2f));
  assert.equal(r.commandId, "filter.text");
  assert.equal(r.state.mode, "INSERT");
});

test("r refreshes", () => {
  const r = dispatch(state(), ev("r", keyOf("r")));
  assert.equal(r.commandId, "refresh");
});

test("1 opens the info tab", () => {
  const r = dispatch(state(), ev("1", 0x31));
  assert.equal(r.commandId, "inspector.info");
});

test("4 opens the files tab from any pane", () => {
  const r = dispatch(state({ pane: "filters" }), ev("4", 0x34));
  assert.equal(r.commandId, "inspector.files");
});

test("5 opens the chart tab from every pane, with no torrent needed (Task 8: no longer reserved)", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const r = dispatch(state({ pane, hasTorrent: false }), ev("5", 0x35));
    assert.equal(r.commandId, "inspector.chart", pane);
    assert.equal(r.blocked, undefined, pane);
  }
  assert.equal(commands.filter((c) => c.id === null).length, 0, "no reserved rows remain");
  assert.equal(commands.find((c) => c.id === "inspector.chart").title, "Chart");
});

test("2 opens trackers, 3 opens peers and 5 opens chart from every pane, with no torrent needed", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const two = dispatch(state({ pane, hasTorrent: false }), ev("2", 0x32));
    assert.equal(two.commandId, "inspector.trackers", pane);
    assert.equal(two.blocked, undefined, pane);
    const three = dispatch(state({ pane, hasTorrent: false }), ev("3", 0x33));
    assert.equal(three.commandId, "inspector.peers", pane);
    const five = dispatch(state({ pane, hasTorrent: false }), ev("5", 0x35));
    assert.equal(five.commandId, "inspector.chart", pane);
  }
  const t = commands.find((c) => c.id === "inspector.trackers");
  assert.equal(t.title, "Trackers");
  assert.equal(commands.find((c) => c.id === "inspector.peers").title, "Peers");
  assert.equal(commands.find((c) => c.id === "inspector.chart").title, "Chart");
});

test("file.down/file.up keep their ids and read as generic row moves", () => {
  assert.equal(commands.find((c) => c.id === "file.down").title, "Next row");
  assert.equal(commands.find((c) => c.id === "file.up").title, "Previous row");
});

test("Tab and Ctrl-l move to the next pane", () => {
  const r1 = dispatch(state(), ev("\t", KEY.Tab));
  assert.equal(r1.commandId, "pane.next");
  const r2 = dispatch(state(), ev("\f", KEY.L, { ctrl: true }));
  assert.equal(r2.commandId, "pane.next");
});

test("Shift-Tab and Ctrl-h move to the previous pane", () => {
  const r1 = dispatch(state(), ev("\t", KEY.Backtab, { shift: true }));
  assert.equal(r1.commandId, "pane.prev");
  const r2 = dispatch(state(), ev("\b", KEY.H, { ctrl: true }));
  assert.equal(r2.commandId, "pane.prev");
});

test("bare h and l do not move panes (ctrl is required)", () => {
  const r1 = dispatch(state(), ev("l", KEY.L));
  assert.equal(r1.commandId, null);
  const r2 = dispatch(state(), ev("h", KEY.H));
  assert.equal(r2.commandId, null);
});

test("? toggles help", () => {
  const r = dispatch(state(), ev("?", 0x3f));
  assert.equal(r.commandId, "help.toggle");
});

test("q closes the window", () => {
  const r = dispatch(state(), ev("q", keyOf("q")));
  assert.equal(r.commandId, "window.close");
});

test("Esc clears the filter text", () => {
  const r = dispatch(state(), ev("\u001b", KEY.Escape));
  assert.equal(r.commandId, "filter.clearText");
  assert.equal(r.state.prefix, "Esc");
});

test("Esc Esc within 600ms resets filters", () => {
  const first = dispatch(state(), ev("\u001b", KEY.Escape, null, 0));
  assert.equal(first.commandId, "filter.clearText");
  const second = dispatch(first.state, ev("\u001b", KEY.Escape, null, 500));
  assert.equal(second.commandId, "filter.reset");
  assert.equal(second.state.prefix, null);
});

// Every "NORMAL, any pane" row, pinned across all three controller-named
// panes -- not just table (which every other test already exercises) or a
// single spot-check pane. "inspector" is the controller's name for the
// third pane; the table/filters/inspector triad is what the window will
// actually pass as `state.pane`.
const ANY_PANE_ROWS = [
  { id: "all.toggle", evs: [ev("t", keyOf("t"))] },
  { id: "sort.next", evs: [ev("s", keyOf("s"))] },
  { id: "sort.reverse", evs: [ev("S", keyOf("s"))] },
  { id: "turtle.toggle", evs: [ev("z", keyOf("z"))] },
  { id: "filter.text", evs: [ev("/", 0x2f)] },
  { id: "refresh", evs: [ev("r", keyOf("r"))] },
  { id: "inspector.info", evs: [ev("1", 0x31)] },
  { id: "inspector.files", evs: [ev("4", 0x34)] },
  { id: "inspector.chart", evs: [ev("5", 0x35)] },
  { id: "pane.next", evs: [ev("\t", KEY.Tab), ev("\f", KEY.L, { ctrl: true })] },
  { id: "pane.prev", evs: [ev("\t", KEY.Backtab, { shift: true }), ev("\b", KEY.H, { ctrl: true })] },
  { id: "help.toggle", evs: [ev("?", 0x3f)] },
  { id: "window.close", evs: [ev("q", keyOf("q"))] }
];

test("every NORMAL, any-pane row fires its command in table, filters and inspector alike", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    for (const row of ANY_PANE_ROWS) {
      for (const e of row.evs) {
        const r = dispatch(state({ pane }), e);
        assert.equal(r.commandId, row.id, pane + " " + JSON.stringify(e));
      }
    }
  }
});

test("Esc and Esc Esc behave the same in table, filters and inspector", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const first = dispatch(state({ pane }), ev("\u001b", KEY.Escape, null, 0));
    assert.equal(first.commandId, "filter.clearText", pane);
    const second = dispatch(first.state, ev("\u001b", KEY.Escape, null, 500));
    assert.equal(second.commandId, "filter.reset", pane);
  }
});

// --- NORMAL, filters pane -------------------------------------------------

test("j and k move within the filters pane instead of the cursor", () => {
  const rj = dispatch(state({ pane: "filters" }), ev("j", keyOf("j")));
  assert.equal(rj.commandId, "filter.down");
  const rk = dispatch(state({ pane: "filters" }), ev("k", keyOf("k")));
  assert.equal(rk.commandId, "filter.up");
});

test("Enter in the filters pane applies the filter", () => {
  const r = dispatch(state({ pane: "filters" }), ev("\r", KEY.Return));
  assert.equal(r.commandId, "filter.apply");
});

// --- VISUAL -----------------------------------------------------------------

test("j/k extend the visual range instead of just moving", () => {
  const s = state({ mode: "VISUAL", selectionCount: 2 });
  const r = dispatch(s, ev("j", keyOf("j")));
  assert.equal(r.commandId, "cursor.down");
  assert.equal(r.args.extend, true);
  assert.equal(r.state.mode, "VISUAL");
});

test("Space/x/X/e act on the visual range and carry its count", () => {
  const s = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 3 });

  const toggle = dispatch(s, ev(" ", KEY.Space));
  assert.equal(toggle.commandId, "torrent.toggle");
  assert.equal(toggle.args.count, 3);
  assert.equal(toggle.args.range, true);
  assert.equal(toggle.state.mode, "NORMAL", "acting on the range exits VISUAL");

  const recheck = dispatch(s, ev("e", keyOf("e")));
  assert.equal(recheck.commandId, "torrent.recheck");
  assert.equal(recheck.args.count, 3);

  const remove = dispatch(s, ev("x", keyOf("x")));
  assert.equal(remove.commandId, null);
  assert.deepEqual(remove.confirm, { commandId: "torrent.remove", count: 3, withFiles: false });

  const del = dispatch(s, ev("X", keyOf("x")));
  assert.equal(del.commandId, null);
  assert.deepEqual(del.confirm, { commandId: "torrent.delete", count: 3, withFiles: true });
});

test("Esc and V exit visual mode", () => {
  const s = state({ mode: "VISUAL" });
  const r1 = dispatch(s, ev("\u001b", KEY.Escape));
  assert.equal(r1.commandId, "visual.exit");
  assert.equal(r1.state.mode, "NORMAL");
  const r2 = dispatch(s, ev("V", keyOf("v")));
  assert.equal(r2.commandId, "visual.exit");
  assert.equal(r2.state.mode, "NORMAL");
});

test("q, ? and t do nothing in VISUAL: they are NORMAL-only any-pane rows", () => {
  const s = state({ mode: "VISUAL" });
  for (const e of [ev("q", keyOf("q")), ev("?", 0x3f), ev("t", keyOf("t"))]) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
  }
});

// --- INSERT ------------------------------------------------------------

test("Esc cancels insert mode", () => {
  const r = dispatch(state({ mode: "INSERT" }), ev("\u001b", KEY.Escape));
  assert.equal(r.commandId, "insert.cancel");
  assert.equal(r.state.mode, "NORMAL");
});

test("Enter commits insert mode", () => {
  const r = dispatch(state({ mode: "INSERT" }), ev("\r", KEY.Return));
  assert.equal(r.commandId, "insert.commit");
  assert.equal(r.state.mode, "NORMAL");
});

test("other keys in INSERT mode are left to the TextField", () => {
  for (const e of [ev("q", keyOf("q")), ev("j", keyOf("j")), ev(" ", KEY.Space)]) {
    const r = dispatch(state({ mode: "INSERT" }), e);
    assert.equal(r.commandId, null, JSON.stringify(e));
  }
});

// --- CONFIRM -----------------------------------------------------------

test("y in CONFIRM runs the pending command with confirmed: true", () => {
  const pending = { commandId: "torrent.delete", args: { count: 1 }, count: 1, withFiles: true };
  const s = state({ mode: "CONFIRM", pending });
  const r = dispatch(s, ev("y", keyOf("y")));
  assert.equal(r.commandId, "torrent.delete");
  assert.deepEqual(r.args, { count: 1, confirmed: true });
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.state.pending, null);
});

test("n in CONFIRM cancels", () => {
  const pending = { commandId: "torrent.delete", args: {}, count: 1, withFiles: true };
  const r = dispatch(state({ mode: "CONFIRM", pending }), ev("n", keyOf("n")));
  assert.equal(r.commandId, "confirm.cancel");
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.state.pending, null);
});

test("Esc in CONFIRM cancels", () => {
  const pending = { commandId: "torrent.remove", args: {}, count: 2, withFiles: false };
  const r = dispatch(state({ mode: "CONFIRM", pending }), ev("\u001b", KEY.Escape));
  assert.equal(r.commandId, "confirm.cancel");
  assert.equal(r.state.mode, "NORMAL");
});

test("any other key in CONFIRM is ignored", () => {
  const pending = { commandId: "torrent.delete", args: {}, count: 1, withFiles: true };
  const s = state({ mode: "CONFIRM", pending });
  const r = dispatch(s, ev("z", keyOf("z")));
  assert.equal(r.commandId, null);
  assert.equal(r.state.mode, "CONFIRM");
  assert.equal(r.state.pending, pending);
});

// --- brief's edge cases --------------------------------------------------

test("the table wins on y: it is torrent.copyMagnet in NORMAL/table, and y never confirms outside CONFIRM", () => {
  // Mode is NORMAL, not CONFIRM: y must resolve through the normal table
  // (torrent.copyMagnet), never through state.pending, even if a pending
  // confirm is (incorrectly) still sitting in state.
  const stalePending = { commandId: "torrent.delete", args: {}, count: 1, withFiles: true };
  const r = dispatch(state({ hasTorrent: true, pending: stalePending }), ev("y", keyOf("y")));
  assert.equal(r.commandId, "torrent.copyMagnet");
});

test("y does nothing outside the table pane (and outside CONFIRM)", () => {
  const r = dispatch(state({ pane: "filters", hasTorrent: true }), ev("y", keyOf("y")));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
});

test("y is blocked without a torrent under the cursor", () => {
  const r = dispatch(state({ pane: "table", hasTorrent: false }), ev("y", keyOf("y")));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, "needs a selected torrent");
});

test("the g prefix expires after 600ms", () => {
  const first = dispatch(state(), ev("g", keyOf("g"), null, 1000));
  assert.equal(first.state.prefix, "g");

  // Exactly 600ms later: still valid.
  const stillValid = dispatch(first.state, ev("g", keyOf("g"), null, 1600));
  assert.equal(stillValid.commandId, "cursor.top");

  // Restart, then 601ms later: expired -- the second g starts a *new* prefix
  // rather than firing cursor.top.
  const started = dispatch(state(), ev("g", keyOf("g"), null, 1000));
  const expired = dispatch(started.state, ev("g", keyOf("g"), null, 1601));
  assert.equal(expired.commandId, null);
  assert.equal(expired.state.prefix, "g");
  assert.equal(expired.state.prefixAt, 1601);
});

test("any other key clears the g prefix without eating it", () => {
  const started = dispatch(state(), ev("g", keyOf("g"), null, 0));
  assert.equal(started.state.prefix, "g");
  const next = dispatch(started.state, ev("j", keyOf("j"), null, 50));
  assert.equal(next.commandId, "cursor.down");
  assert.equal(next.state.prefix, null);
});

test("Esc Esc after 600ms just clears the filter text again", () => {
  const first = dispatch(state(), ev("\u001b", KEY.Escape, null, 0));
  assert.equal(first.commandId, "filter.clearText");
  const late = dispatch(first.state, ev("\u001b", KEY.Escape, null, 601));
  assert.equal(late.commandId, "filter.clearText");
  assert.notEqual(late.commandId, "filter.reset");
});

test("digit 5 opens the chart tab in every pane (Task 8: no longer a no-op)", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    assert.equal(dispatch(state({ pane }), ev("5", 0x35)).commandId, "inspector.chart", pane);
  }
});

test("VISUAL actions carry the range through args and confirm", () => {
  const s = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 5 });
  const toggle = dispatch(s, ev(" ", KEY.Space));
  assert.equal(toggle.args.count, 5);
  const del = dispatch(s, ev("X", keyOf("x")));
  assert.equal(del.confirm.count, 5);
});

test("blocked preconditions: needs torrent", () => {
  const noTorrent = state({ hasTorrent: false });
  for (const e of [ev("o", keyOf("o")), ev("y", keyOf("y")), ev("m", keyOf("m")), ev("V", keyOf("v"))]) {
    const r = dispatch(noTorrent, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
    assert.equal(r.blocked, "needs a selected torrent", JSON.stringify(e));
  }
});

test("blocked preconditions: needs selection (no cursor row, no range)", () => {
  const noSelection = state({ hasTorrent: false, selectionCount: 0 });
  for (const e of [ev(" ", KEY.Space), ev("x", keyOf("x")), ev("X", keyOf("x")), ev("e", keyOf("e"))]) {
    const r = dispatch(noSelection, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
    assert.equal(r.blocked, "needs a selected torrent", JSON.stringify(e));
  }
});

test("a VISUAL range alone satisfies 'selection' even with no cursor row", () => {
  const rangeOnly = state({ mode: "VISUAL", hasTorrent: false, selectionCount: 4 });
  const r = dispatch(rangeOnly, ev("x", keyOf("x")));
  assert.equal(r.confirm.count, 4);
});

test("unmatched is not the same as blocked", () => {
  // o in the filters pane: no row matches at all, so no `blocked` field.
  // (Slice 3a binds x there to library.remove, so this uses o.)
  const r = dispatch(state({ pane: "filters", hasTorrent: false }), ev("o", keyOf("o")));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
});

test("torrent.remove always confirms, even for one target", () => {
  const single = dispatch(state({ mode: "VISUAL", selectionCount: 1 }), ev("x", keyOf("x")));
  assert.equal(single.commandId, null);
  assert.deepEqual(single.confirm, { commandId: "torrent.remove", count: 1, withFiles: false });

  const many = dispatch(state({ mode: "VISUAL", selectionCount: 2 }), ev("x", keyOf("x")));
  assert.equal(many.commandId, null);
  assert.equal(many.confirm.count, 2);
});

test("torrent.delete always confirms, even for one target", () => {
  const r = dispatch(state({ mode: "VISUAL", selectionCount: 1 }), ev("X", keyOf("x")));
  assert.equal(r.commandId, null);
  assert.deepEqual(r.confirm, { commandId: "torrent.delete", count: 1, withFiles: true });
});

// A VISUAL range must not leak into NORMAL. Each of these leaves VISUAL by
// a different path (visual.exit, an EXITS_VISUAL action that fires directly,
// and a CONFIRM resolution) and then re-feeds the *returned* state -- the
// way the window will -- to check that Space/e/x see a plain single-cursor
// target (count 1, no range) instead of the old selection.
function assertNoLeftoverRange(freshState) {
  const toggle = dispatch(freshState, ev(" ", KEY.Space));
  assert.equal(toggle.commandId, "torrent.toggle");
  assert.equal(toggle.args.count, 1);
  assert.equal(toggle.args.range, undefined);

  const recheck = dispatch(freshState, ev("e", keyOf("e")));
  assert.equal(recheck.commandId, "torrent.recheck");
  assert.equal(recheck.args.count, 1);
  assert.equal(recheck.args.range, undefined);

  const remove = dispatch(freshState, ev("x", keyOf("x")));
  assert.equal(remove.commandId, null);
  assert.deepEqual(remove.confirm, { commandId: "torrent.remove", count: 1, withFiles: false });
  assert.deepEqual(remove.state.pending.args, { count: 1 });
}

test("leaving VISUAL via visual.exit (Esc) clears the range for what follows", () => {
  const inVisual = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 3 });
  const exited = dispatch(inVisual, ev("\u001b", KEY.Escape));
  assert.equal(exited.commandId, "visual.exit");
  assert.equal(exited.state.mode, "NORMAL");
  assert.equal(exited.state.selectionCount, 0);
  assertNoLeftoverRange(exited.state);
});

test("leaving VISUAL via an EXITS_VISUAL action (Space) clears the range for what follows", () => {
  const inVisual = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 3 });
  const acted = dispatch(inVisual, ev(" ", KEY.Space));
  assert.equal(acted.commandId, "torrent.toggle");
  assert.equal(acted.state.mode, "NORMAL");
  assert.equal(acted.state.selectionCount, 0);
  assertNoLeftoverRange(acted.state);
});

test("leaving VISUAL via CONFIRM resolution clears the range for what follows", () => {
  const inVisual = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 3 });
  const confirmStep = dispatch(inVisual, ev("X", keyOf("x")));
  assert.equal(confirmStep.state.mode, "CONFIRM");
  const accepted = dispatch(confirmStep.state, ev("y", keyOf("y")));
  assert.equal(accepted.commandId, "torrent.delete");
  assert.equal(accepted.state.mode, "NORMAL");
  assert.equal(accepted.state.selectionCount, 0);
  assertNoLeftoverRange(accepted.state);
});

test("VISUAL delete through CONFIRM carries the range end to end, then confirmed: true", () => {
  const s = state({ mode: "VISUAL", hasTorrent: true, selectionCount: 2 });

  const confirmStep = dispatch(s, ev("X", keyOf("x")));
  assert.equal(confirmStep.commandId, null);
  assert.deepEqual(confirmStep.confirm, { commandId: "torrent.delete", count: 2, withFiles: true });
  assert.equal(confirmStep.state.mode, "CONFIRM");
  assert.deepEqual(confirmStep.state.pending.args, { count: 2, range: true });

  const accepted = dispatch(confirmStep.state, ev("y", keyOf("y")));
  assert.equal(accepted.commandId, "torrent.delete");
  assert.deepEqual(accepted.args, { count: 2, range: true, confirmed: true });
  assert.equal(accepted.state.mode, "NORMAL");
});

// --- purity ---------------------------------------------------------------

test("dispatch does not mutate its state or event arguments", () => {
  const s = state({ hasTorrent: true, selectionCount: 2 });
  const e = ev("j", keyOf("j"), { ctrl: false, shift: false, alt: false }, 123);
  const sBefore = JSON.stringify(s);
  const eBefore = JSON.stringify(e);
  dispatch(s, e);
  assert.equal(JSON.stringify(s), sBefore);
  assert.equal(JSON.stringify(e), eBefore);
});

test("dispatch never calls Date (repeat calls with the same event are identical)", () => {
  const s = state();
  const e = ev("j", keyOf("j"), null, 42);
  const r1 = dispatch(s, e);
  const r2 = dispatch(s, e);
  assert.deepEqual(r1, r2);
});

test("unrelated state fields pass through unchanged", () => {
  const s = state({ pane: "table", hasTorrent: true, selectionCount: 0 });
  const r = dispatch(s, ev("j", keyOf("j")));
  assert.equal(r.state.pane, "table");
  assert.equal(r.state.hasTorrent, true);
  assert.equal(r.state.selectionCount, 0);
});

// --- helpFor ----------------------------------------------------------

test("helpFor(NORMAL, table) lists the table-pane and any-pane rows", () => {
  const rows = helpFor("NORMAL", "table");
  const ids = rows.map((r) => r.id);
  assert.ok(ids.includes("cursor.down"));
  assert.ok(ids.includes("torrent.remove"));
  assert.ok(ids.includes("help.toggle"), "any-pane rows show up in table pane too");
  assert.ok(!ids.includes(null), "reserved rows are not commands");
});

test("helpFor titles t (all.toggle) Start/stop all", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const row = helpFor("NORMAL", pane).find((r) => r.id === "all.toggle");
    assert.ok(row, pane);
    assert.equal(row.title, "Start/stop all", pane);
  }
  assert.equal(commands.find((c) => c.id === "all.toggle").title, "Start/stop all");
});

test("helpFor(NORMAL, filters) excludes table-only rows", () => {
  const rows = helpFor("NORMAL", "filters");
  const ids = rows.map((r) => r.id);
  assert.ok(!ids.includes("cursor.down"));
  for (const id of ["torrent.openFolder", "torrent.copyMagnet", "torrent.move", "torrent.recheck"]) assert.ok(!ids.includes(id), id);
  assert.ok(ids.includes("filter.down"));
  assert.ok(ids.includes("help.toggle"));
});

test("helpFor(VISUAL, table) lists the visual-mode rows", () => {
  const rows = helpFor("VISUAL", "table");
  const ids = rows.map((r) => r.id);
  assert.ok(ids.includes("visual.exit"));
  assert.ok(ids.includes("torrent.remove"));
  assert.ok(!ids.includes("torrent.openFolder"), "openFolder has no VISUAL row");
});

test("helpFor(CONFIRM, table) lists accept and cancel", () => {
  const rows = helpFor("CONFIRM", "table");
  const ids = rows.map((r) => r.id);
  assert.ok(ids.includes("confirm.accept"));
  assert.ok(ids.includes("confirm.cancel"));
});

test("helpFor is generated straight from the commands table", () => {
  const rows = helpFor("NORMAL", "table");
  for (const row of rows) {
    assert.ok(commands.indexOf(row) !== -1);
  }
});

// --- commands table shape ------------------------------------------------

test("every command row has the documented shape", () => {
  const validGroups = ["Torrent", "View", "Library", "App"];
  // tracker/peer/trackersTab/noMetadata: slice 2b (Task 3's preconditions).
  // libraryGroup/libraryName/categoryName: slice 3a (Task 5's filters-pane rows).
  // limitRow/limitToggle: slice 3b Task 4, for Task 5's Info-tab Limits cursor.
  // toggleRow/editableRow: slice 4a Task 6, the Settings editors.
  // listRow/secretSet/undoEntry/listEditable/listItem/narrow: slice 4b Task 1.
  // searchResult/searchPluginOn/searchPlugin/pluginsIdle: slice 5a Task 1.
  const validNeeds = ["none", "torrent", "selection", "tracker", "peer", "trackersTab", "noMetadata", "libraryGroup", "libraryName", "categoryName", "limitRow", "limitToggle", "toggleRow", "editableRow",
    "listRow", "secretSet", "undoEntry", "listEditable", "listItem", "narrow",
    "searchResult", "searchPluginOn", "searchPlugin", "pluginsIdle"];
  const validTabs = ["info", "trackers", "peers", "files", "chart"];
  for (const row of commands) {
    assert.ok(row.id === null || typeof row.id === "string");
    assert.equal(typeof row.title, "string");
    assert.ok(validGroups.includes(row.group), row.id + " group " + row.group);
    // A palette-only row (slice 3b Task 6's bulk limits) has no key.
    assert.ok(Array.isArray(row.keys) && (row.keys.length > 0) !== (row.paletteOnly === true), row.id);
    assert.ok(Array.isArray(row.modes) && row.modes.length > 0, row.id);
    assert.ok(Array.isArray(row.panes) && row.panes.length > 0, row.id);
    assert.ok(validNeeds.includes(row.needs), row.id + " needs " + row.needs);
    // tabs (D7) is optional, and only ever appears on inspector-pane rows.
    if (row.tabs !== undefined) {
      assert.ok(Array.isArray(row.tabs) && row.tabs.length > 0, row.id + " tabs");
      for (const t of row.tabs) assert.ok(validTabs.includes(t), row.id + " tab " + t);
      assert.deepEqual(row.panes, ["inspector"], row.id + " tabs only make sense on the inspector pane");
    }
  }
});

// --- NORMAL, inspector pane: the Files tab list --------------------------

// Slice 3b Task 4 (D7): j/k/Space are now tab-scoped, so this pins them
// with inspectorTab explicitly "files" -- the bare pane, before Task 4,
// was enough on its own, but a bare inspector pane no longer names a tab.
test("j/k/Down/Up and Space in the inspector pane are the file list's keys", () => {
  const s = state({ pane: "inspector", hasTorrent: true, inspectorTab: "files" });
  assert.equal(dispatch(s, ev("j", keyOf("j"))).commandId, "file.down");
  assert.equal(dispatch(s, ev("", KEY.Down)).commandId, "file.down");
  assert.equal(dispatch(s, ev("k", keyOf("k"))).commandId, "file.up");
  assert.equal(dispatch(s, ev("", KEY.Up)).commandId, "file.up");
  assert.equal(dispatch(s, ev(" ", KEY.Space)).commandId, "file.cycle");
});

test("file.cycle needs a torrent; the file rows stay out of the table and filters panes", () => {
  const blocked = dispatch(state({ pane: "inspector", hasTorrent: false }), ev(" ", KEY.Space));
  assert.equal(blocked.commandId, null);
  assert.ok(blocked.blocked);
  assert.equal(dispatch(state({ pane: "table", hasTorrent: true }), ev("j", keyOf("j"))).commandId, "cursor.down");
  assert.equal(dispatch(state({ pane: "filters" }), ev("j", keyOf("j"))).commandId, "filter.down");
  assert.equal(dispatch(state({ pane: "table", hasTorrent: true }), ev(" ", KEY.Space)).commandId, "torrent.toggle");
});

test("helpFor(NORMAL, inspector) lists the file rows and not the table's", () => {
  const ids = helpFor("NORMAL", "inspector").map((r) => r.id);
  assert.ok(ids.includes("file.down"));
  assert.ok(ids.includes("file.cycle"));
  assert.ok(!ids.includes("cursor.down"));
  assert.ok(!ids.includes("torrent.toggle"));
});

// --- slice 3b, Task 4: keys belong to their tab (D6/D7) --------------------

// Every j/k/Down/Up/Space/Enter x tab combination in the inspector pane,
// pinned in one place. hasTorrent is true throughout (Info's Space carve-out
// and file.cycle both need one; cursorNoMetadata false unless noted).
function onTab(tab, overrides) {
  return state(Object.assign({ pane: "inspector", hasTorrent: true, inspectorTab: tab }, overrides || {}));
}

test("j/k/Down/Up: Files/Trackers/Peers move the list, Info moves the Limits cursor, Chart gets neither", () => {
  for (const tab of ["files", "trackers", "peers"]) {
    assert.equal(dispatch(onTab(tab), ev("j", keyOf("j"))).commandId, "file.down", tab);
    assert.equal(dispatch(onTab(tab), ev("", KEY.Down)).commandId, "file.down", tab);
    assert.equal(dispatch(onTab(tab), ev("k", keyOf("k"))).commandId, "file.up", tab);
    assert.equal(dispatch(onTab(tab), ev("", KEY.Up)).commandId, "file.up", tab);
  }
  for (const e of [ev("j", keyOf("j")), ev("", KEY.Down)]) {
    assert.equal(dispatch(onTab("info"), e).commandId, "limit.down", JSON.stringify(e));
  }
  for (const e of [ev("k", keyOf("k")), ev("", KEY.Up)]) {
    assert.equal(dispatch(onTab("info"), e).commandId, "limit.up", JSON.stringify(e));
  }
  for (const e of [ev("j", keyOf("j")), ev("k", keyOf("k")), ev("", KEY.Down), ev("", KEY.Up)]) {
    const r = dispatch(onTab("chart"), e);
    assert.equal(r.commandId, null, "chart " + JSON.stringify(e));
    assert.equal("blocked" in r, false, "chart has no j/k at all, not even a blocked note");
  }
});

test("Space: file.cycle on Files, limit.toggle (blocked, no note) on Info, inert on Trackers/Peers/Chart", () => {
  assert.equal(dispatch(onTab("files"), ev(" ", KEY.Space)).commandId, "file.cycle");
  const infoSpace = dispatch(onTab("info"), ev(" ", KEY.Space));
  assert.equal(infoSpace.commandId, null);
  assert.equal(infoSpace.blocked, "", "blocked with no note, per the brief, until Task 5 wires limitToggle");
  for (const tab of ["trackers", "peers", "chart"]) {
    const r = dispatch(onTab(tab), ev(" ", KEY.Space));
    assert.equal(r.commandId, null, tab);
    assert.equal("blocked" in r, false, tab + ": file.cycle's own needs (torrent) is met, so no note either");
  }
});

test("Enter: limit.edit (blocked, no note) on Info, otherwise unbound in the inspector pane", () => {
  const infoEnter = dispatch(onTab("info"), ev("\r", KEY.Return));
  assert.equal(infoEnter.commandId, null);
  assert.equal(infoEnter.blocked, "", "blocked with no note until Task 5 wires limitCursorKey");
  for (const tab of ["files", "trackers", "peers", "chart"]) {
    const r = dispatch(onTab(tab), ev("\r", KEY.Return));
    assert.equal(r.commandId, null, tab);
  }
});

test("limit.down/limit.up/limit.edit/limit.toggle are real rows, Info only, NORMAL", () => {
  const want = {
    "limit.down": ["j", "Down"],
    "limit.up": ["k", "Up"],
    "limit.edit": ["Enter"],
    "limit.toggle": ["Space"]
  };
  for (const id of Object.keys(want)) {
    const rows = rowsFor(id);
    assert.equal(rows.length, 1, id);
    assert.deepEqual(rows[0].keys, want[id], id);
    assert.deepEqual(rows[0].modes, ["NORMAL"], id);
    assert.deepEqual(rows[0].panes, ["inspector"], id);
    assert.deepEqual(rows[0].tabs, ["info"], id);
  }
  assert.equal(rowsFor("limit.edit")[0].needs, "limitRow");
  assert.equal(rowsFor("limit.toggle")[0].needs, "limitToggle");
  const help = helpFor("NORMAL", "inspector", "info").map((r) => r.id);
  for (const id of Object.keys(want)) assert.ok(help.includes(id), id + " in the Info tab's help");
  assert.ok(!helpFor("NORMAL", "inspector", "files").map((r) => r.id).includes("limit.down"));
});

test("limit.edit/limit.toggle fire once Task 5's state fields are set", () => {
  const edit = dispatch(onTab("info", { limitCursorKey: "ratio" }), ev("\r", KEY.Return));
  assert.equal(edit.commandId, "limit.edit");
  const toggle = dispatch(onTab("info", { limitCursorKey: "sequential", limitToggle: true }), ev(" ", KEY.Space));
  assert.equal(toggle.commandId, "limit.toggle");
});

test("preconditionMet/needsReason: limitRow and limitToggle, blocked with no note", () => {
  const pm = Registry.preconditionMet;
  const nr = Registry.needsReason;
  assert.equal(pm("limitRow", { limitCursorKey: "ratio" }), true);
  assert.equal(pm("limitRow", { limitCursorKey: null }), false);
  assert.equal(pm("limitRow", { limitCursorKey: "" }), false);
  assert.equal(pm("limitRow", {}), false);
  assert.equal(pm("limitToggle", { limitToggle: true }), true);
  assert.equal(pm("limitToggle", { limitToggle: false }), false);
  assert.equal(pm("limitToggle", {}), false);
  assert.equal(nr("limitRow", {}), "");
  assert.equal(nr("limitToggle", {}), "");
});

test("Deviation 3 carve-out: Space on Info still starts a no-metadata torrent, never limit.toggle", () => {
  const r = dispatch(onTab("info", { cursorNoMetadata: true }), ev(" ", KEY.Space));
  assert.equal(r.commandId, "file.cycle", "the window's existing file.cycle handler covers Info's noMeta case");
  // Off Info (or with metadata), the carve-out doesn't apply -- ordinary
  // Info Space (limit.toggle, blocked with no note) or file.cycle (Files).
  const withMeta = dispatch(onTab("info", { cursorNoMetadata: false }), ev(" ", KEY.Space));
  assert.equal(withMeta.commandId, null);
  assert.equal(withMeta.blocked, "");
});

test("x/R/a/c/b off their tab still name it (needsReason), unless the row would run unconditionally", () => {
  for (const tab of ["info", "files", "chart"]) {
    for (const k of ["R", "a", "c", "x"]) {
      const r = dispatch(onTab(tab), ev(k, keyOf(k)));
      assert.equal(r.commandId, null, tab + "/" + k);
      assert.equal(r.blocked, "focus the trackers tab", tab + "/" + k);
    }
    const b = dispatch(onTab(tab), ev("b", keyOf("b")));
    assert.equal(b.commandId, null, tab);
    assert.equal(b.blocked, "focus the peers tab", tab);
  }
  // On Peers, R/a/c/x still name the trackers tab; on Trackers, b still
  // names the peers tab (the two only ever collide with each other's keys
  // through this fallback, since neither tab's own rows use R/a/c/x/b).
  for (const k of ["R", "a", "c", "x"]) {
    assert.equal(dispatch(onTab("peers"), ev(k, keyOf(k))).blocked, "focus the trackers tab", k);
  }
  assert.equal(dispatch(onTab("trackers"), ev("b", keyOf("b"))).blocked, "focus the peers tab");
});

// --- o, y, m, e from the inspector pane ------------------------------------

test("o, y, m and e work in the table and inspector panes, not in filters", () => {
  const cases = [["o", "torrent.openFolder"], ["y", "torrent.copyMagnet"], ["m", "torrent.move"], ["e", "torrent.recheck"]];
  for (const pane of ["table", "inspector"]) {
    for (const [k, id] of cases) {
      const r = dispatch(state({ pane, hasTorrent: true }), ev(k, keyOf(k)));
      assert.equal(r.commandId, id, pane + "/" + k);
      assert.equal(r.args.count, 1, pane + "/" + k + " acts on the cursor torrent");
    }
  }
  for (const [k] of cases) {
    const r = dispatch(state({ pane: "filters", hasTorrent: true }), ev(k, keyOf(k)));
    assert.equal(r.commandId, null, "filters/" + k);
  }
});

test("o, y, m and e in the inspector need a torrent", () => {
  for (const k of ["o", "y", "m", "e"]) {
    const r = dispatch(state({ pane: "inspector", hasTorrent: false }), ev(k, keyOf(k)));
    assert.equal(r.commandId, null, k);
    assert.ok(r.blocked, k);
  }
});

test("helpFor(NORMAL, inspector) lists o, y, m and e", () => {
  const ids = helpFor("NORMAL", "inspector").map((r) => r.id);
  for (const id of ["torrent.openFolder", "torrent.copyMagnet", "torrent.move", "torrent.recheck"]) assert.ok(ids.includes(id), id);
});

// --- COMMAND mode (command palette) ----------------------------------------

test(": opens the command palette from every pane, in NORMAL", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const r = dispatch(state({ pane }), ev(":", 0x3a));
    assert.equal(r.commandId, "palette.open", pane);
    assert.equal(r.state.mode, "COMMAND", pane);
    assert.equal(r.state.pane, pane, "pane is untouched");
  }
});

// Slice 3b Task 6: VISUAL opens the palette too (its bulk limit rows act on
// the range; see ": opens the palette from VISUAL too" below), so only
// INSERT is left here.
test(": does nothing in INSERT", () => {
  for (const mode of ["INSERT"]) {
    const r = dispatch(state({ mode }), ev(":", 0x3a));
    assert.equal(r.commandId, null, mode);
  }
});

test("Esc closes the palette back to NORMAL", () => {
  const r = dispatch(state({ mode: "COMMAND" }), ev("\u001b", KEY.Escape));
  assert.equal(r.commandId, "palette.close");
  assert.equal(r.state.mode, "NORMAL");
});

test("Enter and Return run the highlighted palette row", () => {
  for (const e of [ev("\r", KEY.Return), ev("\r", KEY.Enter)]) {
    const r = dispatch(state({ mode: "COMMAND" }), e);
    assert.equal(r.commandId, "palette.run", JSON.stringify(e));
    assert.equal(r.state.mode, "NORMAL");
  }
});

test("Up and Ctrl-p move the palette selection up", () => {
  for (const e of [ev("", KEY.Up), ev("", KEY.P, { ctrl: true })]) {
    const r = dispatch(state({ mode: "COMMAND" }), e);
    assert.equal(r.commandId, "palette.up", JSON.stringify(e));
    assert.equal(r.state.mode, "COMMAND");
  }
});

test("Down and Ctrl-n move the palette selection down", () => {
  for (const e of [ev("", KEY.Down), ev("", KEY.N, { ctrl: true })]) {
    const r = dispatch(state({ mode: "COMMAND" }), e);
    assert.equal(r.commandId, "palette.down", JSON.stringify(e));
    assert.equal(r.state.mode, "COMMAND");
  }
});

test("Tab completes the palette query", () => {
  const r = dispatch(state({ mode: "COMMAND" }), ev("\t", KEY.Tab));
  assert.equal(r.commandId, "palette.complete");
  assert.equal(r.state.mode, "COMMAND");
});

test("every other key in COMMAND is left to the TextField, including y/n/g/q/Space", () => {
  const s = state({ mode: "COMMAND" });
  for (const e of [
    ev("y", keyOf("y")), ev("n", keyOf("n")), ev("g", keyOf("g")),
    ev("q", keyOf("q")), ev(" ", KEY.Space), ev(":", 0x3a)
  ]) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
    assert.equal(r.state.mode, "COMMAND", JSON.stringify(e));
  }
});

test("helpFor(COMMAND, pane) lists exactly the palette keys, in every pane", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const ids = helpFor("COMMAND", pane).map((r) => r.id);
    assert.deepEqual(
      ids.slice().sort(),
      ["palette.close", "palette.complete", "palette.down", "palette.run", "palette.up"].sort(),
      pane
    );
  }
});

// --- exported precondition/pane helpers (reused by ClientView.paletteRows) --

test("preconditionMet is exported and matches dispatch's own precondition logic", () => {
  assert.equal(Registry.preconditionMet("none", state()), true);
  assert.equal(Registry.preconditionMet("torrent", state({ hasTorrent: false })), false);
  assert.equal(Registry.preconditionMet("torrent", state({ hasTorrent: true })), true);
  assert.equal(Registry.preconditionMet("selection", state({ hasTorrent: false, selectionCount: 0 })), false);
  assert.equal(Registry.preconditionMet("selection", state({ hasTorrent: false, mode: "VISUAL", selectionCount: 2 })), true);
});

test("paneMatches is exported and matches dispatch's own pane logic", () => {
  const tableRow = commands.find((c) => c.id === "cursor.down");
  const fileRow = commands.find((c) => c.id === "file.down");
  assert.equal(Registry.paneMatches(tableRow, "table"), true);
  assert.equal(Registry.paneMatches(fileRow, "table"), false);
  assert.equal(Registry.paneMatches(fileRow, "inspector"), true);
});

// --- dispatchCommand (the palette runs a command by id) ---------------------

test("dispatchCommand resolves an id exactly as its key would", () => {
  const s = state({ hasTorrent: true });
  assert.deepEqual(Registry.dispatchCommand(s, "sort.reverse"), dispatch(s, ev("S")));
  assert.deepEqual(Registry.dispatchCommand(s, "torrent.recheck"), dispatch(s, ev("e")));
  const v = Registry.dispatchCommand(s, "visual.enter");
  assert.equal(v.commandId, "visual.enter");
  assert.equal(v.state.mode, "VISUAL");
  assert.equal(Registry.dispatchCommand(s, "filter.text").state.mode, "INSERT");
});

test("dispatchCommand still raises CONFIRM for x and X", () => {
  const s = state({ hasTorrent: true });
  const del = Registry.dispatchCommand(s, "torrent.delete");
  assert.equal(del.commandId, null);
  assert.equal(del.state.mode, "CONFIRM");
  assert.deepEqual(del.confirm, { commandId: "torrent.delete", count: 1, withFiles: true });
  assert.equal(Registry.dispatchCommand(s, "torrent.remove").state.mode, "CONFIRM");
});

test("dispatchCommand blocks an unmet precondition and ignores wrong-pane ids", () => {
  const blocked = Registry.dispatchCommand(state({ hasTorrent: false }), "torrent.toggle");
  assert.equal(blocked.commandId, null);
  assert.equal(blocked.blocked, "needs a selected torrent");
  const wrongPane = Registry.dispatchCommand(state({ pane: "filters", hasTorrent: true }), "torrent.toggle");
  assert.equal(wrongPane.commandId, null);
  assert.equal(wrongPane.blocked, undefined);
  assert.equal(Registry.dispatchCommand(state(), "no.such").commandId, null);
  assert.equal(Registry.dispatchCommand(state(), null).commandId, null);
});

// --- magnet CONFIRM (slice 1b Task 4) ---------------------------------------

const MAGNET_PENDING = { kind: "magnet", commandId: "magnet.start" };

test("x and X raise CONFIRM pendings of kind remove and delete", () => {
  assert.equal(dispatch(state(), ev("x", keyOf("x"))).state.pending.kind, "remove");
  assert.equal(dispatch(state(), ev("X", keyOf("X"), { ctrl: false, shift: true, alt: false })).state.pending.kind, "delete");
});

test("magnet CONFIRM: Enter, Return and y ask to start; the state stays CONFIRM", () => {
  const s = state({ mode: "CONFIRM", pending: MAGNET_PENDING });
  for (const e of [ev("\r", KEY.Return), ev("\u0003", KEY.Enter), ev("y", keyOf("y"))]) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, "magnet.start");
    assert.deepEqual(r.args, {});
    assert.equal(r.state.mode, "CONFIRM");
    assert.deepEqual(r.state.pending, MAGNET_PENDING);
  }
});

test("magnet CONFIRM: Esc and n ask to cancel; the state stays CONFIRM", () => {
  const s = state({ mode: "CONFIRM", pending: MAGNET_PENDING });
  for (const e of [ev("\u001b", KEY.Escape), ev("n", keyOf("n"))]) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, "magnet.cancel");
    assert.equal(r.state.mode, "CONFIRM");
    assert.deepEqual(r.state.pending, MAGNET_PENDING);
  }
});

test("magnet CONFIRM: every other key does nothing", () => {
  const s = state({ mode: "CONFIRM", pending: MAGNET_PENDING });
  const others = [
    ev("j", keyOf("j")), ev("x", keyOf("x")), ev(":", 0x3a), ev("q", keyOf("q")), ev("/", 0x2f),
    ev(" ", KEY.Space), ev("\t", KEY.Tab), ev("V", keyOf("V")), ev("?", 0x3f),
    ev("\u0019", keyOf("y"), { ctrl: true, shift: false, alt: false }),
    ev("\u000e", keyOf("n"), { ctrl: true, shift: false, alt: false })
  ];
  for (const e of others) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
    assert.equal(r.state.mode, "CONFIRM");
    assert.deepEqual(r.state.pending, MAGNET_PENDING);
  }
});

test("magnet CONFIRM grace: Esc and n do nothing for 600 ms after the raise (599 ignored, 600 cancels)", () => {
  assert.equal(Registry.MAGNET_GRACE_MS, 600);
  const at = 10000;
  const s = state({ mode: "CONFIRM", pending: Object.assign({}, MAGNET_PENDING, { at }) });
  for (const [text, key] of [["\u001b", KEY.Escape], ["n", keyOf("n")]]) {
    for (const dt of [0, 1, 300, 599]) {
      const r = dispatch(s, ev(text, key, undefined, at + dt));
      assert.equal(r.commandId, null, text + " +" + dt);
      assert.equal(r.state.mode, "CONFIRM");
      assert.equal(r.state.pending.at, at);
    }
    for (const dt of [600, 601, 5000]) {
      assert.equal(dispatch(s, ev(text, key, undefined, at + dt)).commandId, "magnet.cancel", text + " +" + dt);
    }
  }
});

test("magnet CONFIRM grace never holds Enter or y", () => {
  const at = 10000;
  const s = state({ mode: "CONFIRM", pending: Object.assign({}, MAGNET_PENDING, { at }) });
  for (const e of [ev("\r", KEY.Return, undefined, at), ev("\u0003", KEY.Enter, undefined, at + 1), ev("y", keyOf("y"), undefined, at + 599)]) {
    assert.equal(dispatch(s, e).commandId, "magnet.start");
  }
});

test("magnet CONFIRM with no raise stamp has no grace", () => {
  const s = state({ mode: "CONFIRM", pending: Object.assign({}, MAGNET_PENDING, { at: 0 }) });
  assert.equal(dispatch(s, ev("\u001b", KEY.Escape, undefined, 5)).commandId, "magnet.cancel");
});

test("a delete CONFIRM still resolves y/n/Esc as before (Enter does nothing)", () => {
  const pending = { kind: "delete", commandId: "torrent.delete", args: {}, count: 1, withFiles: true };
  const s = state({ mode: "CONFIRM", pending });
  assert.equal(dispatch(s, ev("y", keyOf("y"))).commandId, "torrent.delete");
  assert.equal(dispatch(s, ev("\u001b", KEY.Escape)).commandId, "confirm.cancel");
  const enter = dispatch(s, ev("\r", KEY.Return));
  assert.equal(enter.commandId, null);
  assert.equal(enter.state.mode, "CONFIRM");
});

// --- inspector targets (slice 2b, Task 3) ------------------------------------

const TRACKER_A = { kind: "tracker", value: "https://a.example/announce?passkey=abc123", label: "a.example" };
const TRACKER_B = { kind: "tracker", value: "udp://b.example:1337/announce", label: "b.example:1337" };
const PEER_A = { kind: "peer", value: "203.0.113.42:6881", label: "203.0.113.42:6881" };

// Slice 3b, Task 4: dispatch now needs to know the focused inspector tab
// (inspectorTab, D7) to tell file/tracker/peer/limit rows sharing a key
// apart. Every pre-existing caller here identifies its tab through
// trackersTab or inspectorTarget.kind instead (the fields slice 2b already
// tested), so this helper derives inspectorTab from those when the test
// doesn't set it explicitly -- one change here instead of touching every
// tracker/peer test below.
function inspector(overrides) {
  var o = overrides || {};
  var tab = o.inspectorTab;
  if (tab === undefined) {
    if (o.trackersTab === true) tab = "trackers";
    else if (o.inspectorTarget && o.inspectorTarget.kind === "tracker") tab = "trackers";
    else if (o.inspectorTarget && o.inspectorTarget.kind === "peer") tab = "peers";
  }
  var merged = Object.assign({ pane: "inspector" }, o);
  if (tab !== undefined) merged.inspectorTab = tab;
  return state(merged);
}

test("preconditionMet: tracker and peer need that kind of inspector target", () => {
  const pm = Registry.preconditionMet;
  assert.equal(pm("tracker", { inspectorTarget: TRACKER_A }), true);
  assert.equal(pm("tracker", { inspectorTarget: PEER_A }), false);
  assert.equal(pm("tracker", { inspectorTarget: null }), false);
  assert.equal(pm("tracker", {}), false);
  assert.equal(pm("peer", { inspectorTarget: PEER_A }), true);
  assert.equal(pm("peer", { inspectorTarget: TRACKER_A }), false);
  assert.equal(pm("peer", { inspectorTarget: null }), false);
});

test("preconditionMet: trackersTab needs the trackers tab, noMetadata a no-metadata torrent that isn't pending", () => {
  const pm = Registry.preconditionMet;
  assert.equal(pm("trackersTab", { trackersTab: true }), true);
  assert.equal(pm("trackersTab", { trackersTab: false }), false);
  assert.equal(pm("trackersTab", {}), false);
  assert.equal(pm("noMetadata", { cursorNoMetadata: true, cursorPendingMagnet: false }), true);
  assert.equal(pm("noMetadata", { cursorNoMetadata: true, cursorPendingMagnet: true }), false);
  assert.equal(pm("noMetadata", { cursorNoMetadata: false }), false);
  assert.equal(pm("noMetadata", {}), false);
});

test("needsReason names what an unmet need is missing", () => {
  const nr = Registry.needsReason;
  assert.equal(nr("tracker", { inspectorTarget: null }), "focus the trackers tab");
  assert.equal(nr("trackersTab", { trackersTab: false }), "focus the trackers tab");
  assert.equal(nr("peer", { inspectorTarget: TRACKER_A }), "focus the peers tab");
  assert.equal(nr("noMetadata", { hasTorrent: true, cursorNoMetadata: false }), "already has metadata");
  assert.equal(nr("noMetadata", { hasTorrent: true, cursorNoMetadata: true, cursorPendingMagnet: true }), "already fetching metadata");
  assert.equal(nr("noMetadata", { hasTorrent: false }), "needs a selected torrent");
  assert.equal(nr("torrent", { hasTorrent: false }), "needs a selected torrent");
  assert.equal(nr("tracker", { inspectorTarget: TRACKER_A }), "", "met: no reason");
});

test("needsConfirm: tracker.remove and peer.ban confirm, like torrent remove/delete", () => {
  assert.equal(Registry.needsConfirm("tracker.remove", {}), true);
  assert.equal(Registry.needsConfirm("peer.ban", {}), true);
  assert.equal(Registry.needsConfirm("torrent.remove", {}), true);
  assert.equal(Registry.needsConfirm("tracker.add", {}), false);
});

test("x on a tracker raises a trackerRemove CONFIRM that captures the target", () => {
  const r = dispatch(inspector({ inspectorTarget: TRACKER_A }), ev("x", keyOf("x")));
  assert.equal(r.commandId, null);
  assert.equal(r.state.mode, "CONFIRM");
  assert.equal(r.state.pending.kind, "trackerRemove");
  assert.equal(r.state.pending.commandId, "tracker.remove");
  assert.deepEqual(r.state.pending.target, TRACKER_A);
  assert.deepEqual(r.state.pending.args, { target: TRACKER_A });
  assert.deepEqual(r.confirm, { commandId: "tracker.remove", kind: "trackerRemove", label: "a.example", target: TRACKER_A });
});

test("b on a peer raises a peerBan CONFIRM that captures the target", () => {
  const r = dispatch(inspector({ inspectorTarget: PEER_A }), ev("b", keyOf("b")));
  assert.equal(r.state.mode, "CONFIRM");
  assert.equal(r.state.pending.kind, "peerBan");
  assert.deepEqual(r.state.pending.target, PEER_A);
  assert.deepEqual(r.confirm, { commandId: "peer.ban", kind: "peerBan", label: "203.0.113.42:6881", target: PEER_A });
});

test("y acts on the target captured at key time, even when the cursor row changed since", () => {
  const target = Object.assign({}, TRACKER_A);
  const step = dispatch(inspector({ inspectorTarget: target }), ev("x", keyOf("x")));
  // The captured copy is independent of the object the window passed in.
  target.value = "mutated";
  // The next dispatch sees whatever row now sits under the cursor.
  const moved = Object.assign({}, step.state, { inspectorTarget: TRACKER_B });
  const y = dispatch(moved, ev("y", keyOf("y")));
  assert.equal(y.commandId, "tracker.remove");
  assert.deepEqual(y.args, { target: TRACKER_A, confirmed: true });
  assert.equal(y.state.mode, "NORMAL");
  assert.equal(y.state.pending, null);
});

test("x / b with no matching target are silent no-ops: no CONFIRM, no command", () => {
  const cases = [
    [inspector({ inspectorTarget: null }), "x"],
    [inspector({ inspectorTarget: PEER_A }), "x"],
    [inspector({ inspectorTarget: null }), "b"],
    [inspector({ inspectorTarget: TRACKER_A }), "b"]
  ];
  for (const [s, k] of cases) {
    const r = dispatch(s, ev(k, keyOf(k)));
    assert.equal(r.commandId, null, k);
    assert.equal(r.state.mode, "NORMAL", k);
    assert.equal(r.state.pending, null, k);
    assert.equal(r.confirm, undefined, k);
    assert.ok(r.blocked, k);
  }
  // x in the table pane is still the torrent remove CONFIRM.
  const t = dispatch(state({ inspectorTarget: TRACKER_A }), ev("x", keyOf("x")));
  assert.equal(t.state.pending.kind, "remove");
  assert.deepEqual(t.confirm, { commandId: "torrent.remove", count: 1, withFiles: false });
});

test("trackersTab and noMetadata rows run without a CONFIRM when met", () => {
  const a = dispatch(inspector({ trackersTab: true }), ev("a", keyOf("a")));
  assert.equal(a.commandId, "tracker.add");
  assert.equal(a.state.mode, "NORMAL");
  assert.equal(dispatch(inspector({ trackersTab: false }), ev("a", keyOf("a"))).commandId, null);
  const f = dispatch(state({ cursorNoMetadata: true }), ev("f", keyOf("f")));
  assert.equal(f.commandId, "torrent.fetchMetadata");
  const pending = dispatch(state({ cursorNoMetadata: true, cursorPendingMagnet: true }), ev("f", keyOf("f")));
  assert.equal(pending.commandId, null);
  assert.equal(pending.blocked, "already fetching metadata");
});

test("dispatch keeps the inspector fields through normalizeState", () => {
  const r = dispatch(inspector({ inspectorTarget: TRACKER_A, trackersTab: true, cursorNoMetadata: true, cursorStopped: true, cursorPendingMagnet: true }), ev("", 0));
  assert.deepEqual(r.state.inspectorTarget, TRACKER_A);
  assert.equal(r.state.trackersTab, true);
  assert.equal(r.state.cursorNoMetadata, true);
  assert.equal(r.state.cursorStopped, true);
  assert.equal(r.state.cursorPendingMagnet, true);
  const d = dispatch(state(), ev("", 0));
  assert.equal(d.state.inspectorTarget, null);
  assert.equal(d.state.trackersTab, false);
  assert.equal(d.state.cursorNoMetadata, false);
});

test("the captured target is frozen: no consumer can change what y acts on", () => {
  const step = dispatch(inspector({ inspectorTarget: TRACKER_A }), ev("x", keyOf("x")));
  assert.ok(Object.isFrozen(step.state.pending.target));
  assert.ok(Object.isFrozen(step.confirm.target));
  assert.ok(Object.isFrozen(step.state.pending.args.target));
});

// --- the trackers tab's actions (slice 2b, Task 4) -------------------------

const PIPE_TRACKER = { kind: "tracker", value: "udp://p.example:1337/a|b", label: "p.example:1337", refusal: "This tracker's URL can't be edited through the WebUI API." };

function rowsFor(id) {
  return commands.filter((r) => r.id === id);
}

test("the trackers tab rows: R, a, c, x in NORMAL on the inspector pane only", () => {
  const want = {
    "tracker.reannounce": ["Reannounce", "R", "trackersTab"],
    "tracker.add": ["Add tracker", "a", "trackersTab"],
    "tracker.edit": ["Change tracker URL", "c", "tracker"],
    "tracker.remove": ["Remove tracker", "x", "tracker"]
  };
  for (const id of Object.keys(want)) {
    const rows = rowsFor(id);
    assert.equal(rows.length, 1, id);
    const r = rows[0];
    assert.equal(r.title, want[id][0], id);
    assert.deepEqual(r.keys, [want[id][1]], id);
    assert.equal(r.needs, want[id][2], id);
    assert.deepEqual(r.modes, ["NORMAL"], id);
    assert.deepEqual(r.panes, ["inspector"], id);
    assert.equal(r.group, "Torrent", id);
  }
  const help = Registry.helpFor("NORMAL", "inspector").map((r) => r.id);
  for (const id of Object.keys(want)) assert.ok(help.includes(id), id + " in the inspector's help");
  const tableHelp = Registry.helpFor("NORMAL", "table").map((r) => r.id);
  for (const id of Object.keys(want)) assert.ok(!tableHelp.includes(id), id + " not in the table's help");
});

test("R and a run on the trackers tab, even with no tracker row", () => {
  const s = inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: null });
  const R = dispatch(s, ev("R", keyOf("R")));
  assert.equal(R.commandId, "tracker.reannounce");
  assert.equal(R.state.mode, "NORMAL");
  assert.equal(R.confirm, undefined);
  const a = dispatch(s, ev("a", keyOf("a")));
  assert.equal(a.commandId, "tracker.add");
  assert.equal(a.state.mode, "NORMAL");
});

test("c runs with the tracker captured at key time, and no CONFIRM", () => {
  const target = Object.assign({}, TRACKER_A);
  const c = dispatch(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: target }), ev("c", keyOf("c")));
  assert.equal(c.commandId, "tracker.edit");
  assert.equal(c.state.mode, "NORMAL");
  assert.equal(c.confirm, undefined);
  assert.deepEqual(c.args.target, TRACKER_A);
  target.value = "mutated";
  assert.equal(c.args.target.value, TRACKER_A.value, "a copy");
  assert.ok(Object.isFrozen(c.args.target));
});

test("R, a, c, x are silent no-ops off the trackers tab", () => {
  const cases = [
    state({ hasTorrent: true }),                                        // table: x is the torrent remove, tested below
    inspector({ hasTorrent: true }),                                   // Info/Files/Chart
    inspector({ hasTorrent: true, inspectorTarget: PEER_A })           // Peers
  ];
  for (const s of cases.slice(1)) {
    for (const k of ["R", "a", "c", "x"]) {
      const r = dispatch(s, ev(k, keyOf(k)));
      assert.equal(r.commandId, null, k);
      assert.equal(r.state.mode, "NORMAL", k);
      assert.equal(r.state.pending, null, k);
      assert.equal(r.confirm, undefined, k);
      assert.equal(r.blocked, "focus the trackers tab", k);
    }
  }
  // In the table R, a, c do nothing and x stays the torrent remove CONFIRM.
  for (const k of ["R", "a", "c"]) assert.equal(dispatch(cases[0], ev(k, keyOf(k))).commandId, null, k);
  const x = dispatch(cases[0], ev("x", keyOf("x")));
  assert.equal(x.state.pending.kind, "remove");
  assert.equal(x.state.pending.commandId, "torrent.remove");
});

test("x on a tracker with a refusal (a | in its URL, F13) raises no CONFIRM: the command comes back unconfirmed", () => {
  const r = dispatch(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: PIPE_TRACKER }), ev("x", keyOf("x")));
  assert.equal(r.commandId, "tracker.remove");
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.state.pending, null);
  assert.equal(r.confirm, undefined);
  assert.deepEqual(r.args.target, PIPE_TRACKER);
  assert.notEqual(r.args.confirmed, true);
  // The palette resolves it the same way.
  const p = Registry.dispatchCommand(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: PIPE_TRACKER }), "tracker.remove");
  assert.equal(p.commandId, "tracker.remove");
  assert.equal(p.confirm, undefined);
  // A plain URL still confirms.
  const ok = Registry.dispatchCommand(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: TRACKER_A }), "tracker.remove");
  assert.equal(ok.state.mode, "CONFIRM");
  assert.equal(ok.confirm.kind, "trackerRemove");
});

test("a target's refusal is copied only when set; kind/value/label stay as they were", () => {
  const c = dispatch(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: PIPE_TRACKER }), ev("c", keyOf("c")));
  assert.equal(c.args.target.refusal, PIPE_TRACKER.refusal);
  assert.ok(Object.isFrozen(c.args.target));
  const plain = dispatch(inspector({ hasTorrent: true, trackersTab: true, inspectorTarget: TRACKER_A }), ev("c", keyOf("c")));
  assert.deepEqual(plain.args.target, TRACKER_A);
  assert.equal("refusal" in plain.args.target, false);
});

// --- peer ban and fetch metadata (slice 2b, Task 5) ---------------------------

test("b and f rows: Ban peer on the inspector, Fetch metadata only from any pane", () => {
  assert.deepEqual(rowsFor("peer.ban").map((r) => [r.title, r.keys, r.modes, r.panes, r.needs, r.group]),
    [["Ban peer", ["b"], ["NORMAL"], ["inspector"], "peer", "Torrent"]]);
  assert.deepEqual(rowsFor("torrent.fetchMetadata").map((r) => [r.title, r.keys, r.modes, r.panes, r.needs, r.group]),
    [["Fetch metadata only", ["f"], ["NORMAL"], ["*"], "noMetadata", "Torrent"]]);
  const inspectorHelp = JSON.stringify(helpFor("NORMAL", "inspector"));
  assert.ok(inspectorHelp.includes("Ban peer"));
  assert.ok(inspectorHelp.includes("Fetch metadata only"));
  const tableHelp = JSON.stringify(helpFor("NORMAL", "table"));
  assert.ok(!tableHelp.includes("Ban peer"));
  assert.ok(tableHelp.includes("Fetch metadata only"));
});

test("f: a torrent with metadata, or a pending browser magnet, is a silent no-op with the reason", () => {
  const has = dispatch(state({ hasTorrent: true, cursorNoMetadata: false }), ev("f", keyOf("f")));
  assert.equal(has.commandId, null);
  assert.equal(has.blocked, "already has metadata");
  assert.equal(has.state.mode, "NORMAL");
  const pending = dispatch(state({ hasTorrent: true, cursorNoMetadata: true, cursorPendingMagnet: true }), ev("f", keyOf("f")));
  assert.equal(pending.commandId, null);
  assert.equal(pending.blocked, "already fetching metadata");
  // From the inspector too (panes: any), with no CONFIRM.
  const ok = dispatch(inspector({ hasTorrent: true, cursorNoMetadata: true }), ev("f", keyOf("f")));
  assert.equal(ok.commandId, "torrent.fetchMetadata");
  assert.equal(ok.state.mode, "NORMAL");
  assert.equal(ok.confirm, undefined);
});

test("b on a peer the window refuses comes back unconfirmed, through the key and the palette", () => {
  const bad = { kind: "peer", value: "1.2.3.4:1|5.6.7.8:9", label: "1.2.3.4:1|5.6.7.8:9", refusal: "This peer's address can't be banned from here." };
  const k = dispatch(inspector({ inspectorTarget: bad }), ev("b", keyOf("b")));
  assert.equal(k.commandId, "peer.ban");
  assert.equal(k.state.mode, "NORMAL");
  assert.equal(k.confirm, undefined);
  assert.equal(k.args.confirmed, undefined);
  assert.equal(k.args.target.refusal, bad.refusal);
  const p = Registry.dispatchCommand(inspector({ inspectorTarget: bad }), "peer.ban");
  assert.equal(p.commandId, "peer.ban");
  assert.equal(p.state.mode, "NORMAL");
  assert.equal(p.args.confirmed, undefined);
  // A plain peer still confirms.
  assert.equal(dispatch(inspector({ inspectorTarget: PEER_A }), ev("b", keyOf("b"))).state.mode, "CONFIRM");
});

// --- PICKER mode (slice 3a Task 4: category/tag pickers, ListOverlay) ------

function picker(overrides) {
  return state(Object.assign({ mode: "PICKER", pickerQueryEmpty: true, pickerMulti: false }, overrides || {}));
}

test("Enter accepts the picker and returns to NORMAL", () => {
  for (const e of [ev("\r", KEY.Return), ev("\r", KEY.Enter)]) {
    const r = dispatch(picker(), e);
    assert.equal(r.commandId, "picker.accept", JSON.stringify(e));
    assert.equal(r.state.mode, "NORMAL");
  }
});

test("Esc cancels the picker and returns to NORMAL, clearing any prefix", () => {
  const r = dispatch(picker({ prefix: "g", prefixAt: 5 }), ev("\u001b", KEY.Escape));
  assert.equal(r.commandId, "picker.cancel");
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.state.prefix, null);
});

test("Up/Ctrl-p and Down/Ctrl-n move the picker cursor and stay in PICKER", () => {
  for (const e of [ev("", KEY.Up), ev("", KEY.P, { ctrl: true })]) {
    const r = dispatch(picker(), e);
    assert.equal(r.commandId, "picker.up", JSON.stringify(e));
    assert.equal(r.state.mode, "PICKER");
  }
  for (const e of [ev("", KEY.Down), ev("", KEY.N, { ctrl: true })]) {
    const r = dispatch(picker(), e);
    assert.equal(r.commandId, "picker.down", JSON.stringify(e));
    assert.equal(r.state.mode, "PICKER");
  }
});

test("Space toggles only with an empty query on a multi-select picker", () => {
  const r = dispatch(picker({ pickerQueryEmpty: true, pickerMulti: true }), ev(" ", KEY.Space));
  assert.equal(r.commandId, "picker.toggle");
  assert.equal(r.state.mode, "PICKER");
});

test("Space is text (no command, not blocked) once the query has anything typed", () => {
  const r = dispatch(picker({ pickerQueryEmpty: false, pickerMulti: true }), ev(" ", KEY.Space));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
  assert.equal(r.state.mode, "PICKER");
});

test("Space is text (no command, not blocked) on a single-choice picker, even with an empty query", () => {
  const r = dispatch(picker({ pickerQueryEmpty: true, pickerMulti: false }), ev(" ", KEY.Space));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
  assert.equal(r.state.mode, "PICKER");
});

test("Tab toggles on a multi-select picker regardless of the query", () => {
  for (const empty of [true, false]) {
    const r = dispatch(picker({ pickerQueryEmpty: empty, pickerMulti: true }), ev("\t", KEY.Tab));
    assert.equal(r.commandId, "picker.toggle", "queryEmpty=" + empty);
    assert.equal(r.state.mode, "PICKER");
  }
});

test("Tab does nothing (no command, not blocked) on a single-choice picker", () => {
  const r = dispatch(picker({ pickerMulti: false }), ev("\t", KEY.Tab));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
  assert.equal(r.state.mode, "PICKER");
});

test("typing letters, y, n and : in PICKER is left to the TextField", () => {
  const s = picker({ pickerMulti: true });
  for (const e of [
    ev("a", keyOf("a")), ev("y", keyOf("y")), ev("n", keyOf("n")), ev(":", 0x3a)
  ]) {
    const r = dispatch(s, e);
    assert.equal(r.commandId, null, JSON.stringify(e));
    assert.equal(r.blocked, undefined, JSON.stringify(e));
    assert.equal(r.state.mode, "PICKER", JSON.stringify(e));
  }
});

test("helpFor(PICKER, pane) lists exactly the picker keys, in every pane", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    const ids = helpFor("PICKER", pane).map((r) => r.id);
    assert.deepEqual(
      ids.slice().sort(),
      ["picker.accept", "picker.cancel", "picker.down", "picker.toggle", "picker.up"].sort(),
      pane
    );
  }
});

test("unrelated state fields pass through unchanged for PICKER too", () => {
  const r = dispatch(picker({ pickerMulti: true }), ev("", KEY.Down));
  assert.equal(r.state.pickerMulti, true);
});

// --- NORMAL, filters pane: categories and tags (slice 3a, Task 5) ------------

const CAT = { kind: "category", value: "anime", label: "anime" };
const CAT_GROUP = { kind: "category", value: "", label: "" };
const TAG = { kind: "tag", value: "seedbox", label: "seedbox" };
const TAG_GROUP = { kind: "tag", value: "", label: "" };
const CAT_NOT_READY = { kind: "category", value: "anime", label: "anime", refusal: "Still reading qBittorrent's folders; try again in a moment." };

function filters(overrides) {
  return state(Object.assign({ pane: "filters", hasTorrent: true }, overrides || {}));
}

test("the four library rows: a c p x, NORMAL, filters pane only, group Library", () => {
  const want = { "library.add": ["a", "libraryGroup"], "library.rename": ["c", "libraryName"], "library.path": ["p", "categoryName"], "library.remove": ["x", "libraryName"] };
  for (const id of Object.keys(want)) {
    const rows = commands.filter((c) => c.id === id);
    assert.equal(rows.length, 1, id);
    assert.deepEqual(rows[0].keys, [want[id][0]], id);
    assert.deepEqual(rows[0].modes, ["NORMAL"], id);
    assert.deepEqual(rows[0].panes, ["filters"], id);
    assert.equal(rows[0].needs, want[id][1], id);
    assert.equal(rows[0].group, "Library", id);
  }
  const ids = helpFor("NORMAL", "filters").map((r) => r.id);
  for (const id of Object.keys(want)) assert.ok(ids.includes(id), id);
  const tableIds = helpFor("NORMAL", "table").map((r) => r.id);
  for (const id of Object.keys(want)) assert.ok(!tableIds.includes(id), "not in the table: " + id);
});

test("library needs: a group row, a named row, a named category row", () => {
  const pm = (needs, o) => Registry.preconditionMet(needs, filters(o));
  assert.equal(pm("libraryGroup", { libraryTarget: CAT }), true);
  assert.equal(pm("libraryGroup", { libraryTarget: CAT_GROUP }), true);
  assert.equal(pm("libraryGroup", { libraryTarget: TAG_GROUP }), true);
  assert.equal(pm("libraryGroup", { libraryTarget: null }), false);
  assert.equal(pm("libraryGroup", { libraryTarget: { kind: "tracker", value: "x", label: "x" } }), false);
  assert.equal(pm("libraryName", { libraryTarget: CAT }), true);
  assert.equal(pm("libraryName", { libraryTarget: TAG }), true);
  assert.equal(pm("libraryName", { libraryTarget: CAT_GROUP }), false, "Uncategorized can't be renamed or deleted");
  assert.equal(pm("libraryName", { libraryTarget: TAG_GROUP }), false);
  assert.equal(pm("categoryName", { libraryTarget: CAT }), true);
  assert.equal(pm("categoryName", { libraryTarget: TAG }), false, "tags have no save path");
  assert.equal(pm("categoryName", { libraryTarget: CAT_GROUP }), false);
  const nr = (needs, o) => Registry.needsReason(needs, filters(o));
  assert.equal(nr("libraryGroup", { libraryTarget: null }), "focus a category or tag");
  assert.equal(nr("libraryName", { libraryTarget: CAT_GROUP }), "focus a category or tag");
  assert.equal(nr("categoryName", { libraryTarget: TAG }), "focus a category");
  assert.equal(nr("categoryName", { libraryTarget: CAT }), "");
});

test("a, c and p fire with the target captured at key time; a status row blocks them", () => {
  for (const [k, id, t] of [["a", "library.add", CAT_GROUP], ["a", "library.add", TAG], ["c", "library.rename", TAG], ["p", "library.path", CAT]]) {
    const r = dispatch(filters({ libraryTarget: t }), ev(k, keyOf(k)));
    assert.equal(r.commandId, id, k);
    assert.deepEqual(r.args.target, t, k);
    assert.ok(Object.isFrozen(r.args.target), "a copy nobody can change");
    assert.notEqual(r.args.target, t, "a copy, not the state's object");
    assert.equal(r.state.mode, "NORMAL", "the handler opens INSERT itself");
  }
  for (const k of ["a", "c", "p", "x"]) {
    const r = dispatch(filters({ libraryTarget: null }), ev(k, keyOf(k)));
    assert.equal(r.commandId, null, k);
    assert.equal(r.blocked, k === "p" ? "focus a category" : "focus a category or tag", k);
  }
  assert.equal(dispatch(filters({ libraryTarget: TAG }), ev("p", keyOf("p"))).blocked, "focus a category");
  assert.equal(dispatch(filters({ libraryTarget: CAT_GROUP }), ev("c", keyOf("c"))).blocked, "focus a category or tag");
});

test("x on a category or tag raises a libraryRemove CONFIRM with the captured target", () => {
  for (const t of [CAT, TAG]) {
    const r = dispatch(filters({ libraryTarget: t }), ev("x", keyOf("x")));
    assert.equal(r.commandId, null);
    assert.equal(r.state.mode, "CONFIRM");
    assert.equal(r.state.pending.kind, "libraryRemove");
    assert.equal(r.state.pending.commandId, "library.remove");
    assert.deepEqual(r.confirm, { commandId: "library.remove", kind: "libraryRemove", label: t.label, target: t });
    // the cursor moving while the question is up changes nothing
    const moved = Object.assign({}, r.state, { libraryTarget: TAG_GROUP });
    const y = dispatch(moved, ev("y", keyOf("y")));
    assert.equal(y.commandId, "library.remove");
    assert.equal(y.args.confirmed, true);
    assert.deepEqual(y.args.target, t);
    assert.equal(y.state.mode, "NORMAL");
  }
});

test("x on a category whose folders aren't read yet comes back unconfirmed with the refusal", () => {
  const r = dispatch(filters({ libraryTarget: CAT_NOT_READY }), ev("x", keyOf("x")));
  assert.equal(r.commandId, "library.remove");
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.confirm, undefined);
  assert.equal(r.args.confirmed, undefined);
  assert.equal(r.args.target.refusal, CAT_NOT_READY.refusal);
});

test("raiseConfirm puts a window-raised CONFIRM in the shape y resolves", () => {
  const args = { target: CAT, newName: "animation", merge: true };
  const r = Registry.raiseConfirm(filters({ mode: "NORMAL", libraryTarget: CAT }), "library.rename", "libraryRename", args);
  assert.equal(r.state.mode, "CONFIRM");
  assert.equal(r.state.pending.kind, "libraryRename");
  assert.equal(r.state.pending.commandId, "library.rename");
  assert.deepEqual(r.state.pending.target, CAT);
  assert.equal(r.confirm.kind, "libraryRename");
  assert.equal(r.confirm.commandId, "library.rename");
  assert.equal(r.confirm.label, "anime");
  args.newName = "changed later";
  const y = dispatch(r.state, ev("y", keyOf("y")));
  assert.equal(y.commandId, "library.rename");
  assert.equal(y.args.confirmed, true);
  assert.equal(y.args.newName, "animation", "the args were copied when asked");
  assert.equal(y.args.merge, true);
  assert.deepEqual(y.args.target, CAT);
  const n = dispatch(r.state, ev("n", keyOf("n")));
  assert.equal(n.commandId, "confirm.cancel");
  assert.equal(n.state.mode, "NORMAL");
});

test("dispatchCommand runs the library rows from the filters pane only", () => {
  assert.equal(Registry.dispatchCommand(filters({ libraryTarget: CAT }), "library.path").commandId, "library.path");
  assert.equal(Registry.dispatchCommand(state({ pane: "table", libraryTarget: CAT }), "library.path").commandId, null);
});

// --- NORMAL/VISUAL, table: the C and T pickers (slice 3a, Task 6) ------------

test("C and T: torrent.category and torrent.tags, NORMAL and VISUAL, table pane, needs a selection", () => {
  const want = { "torrent.category": "C", "torrent.tags": "T" };
  for (const id of Object.keys(want)) {
    const rows = commands.filter((c) => c.id === id);
    assert.equal(rows.length, 1, id);
    assert.deepEqual(rows[0].keys, [want[id]], id);
    assert.deepEqual(rows[0].modes, ["NORMAL", "VISUAL"], id);
    assert.deepEqual(rows[0].panes, ["table"], id);
    assert.equal(rows[0].needs, "selection", id);
    assert.equal(rows[0].group, "Torrent", id);
  }
  assert.ok(helpFor("NORMAL", "table").some((r) => r.id === "torrent.category"));
  assert.ok(!helpFor("NORMAL", "filters").some((r) => r.id === "torrent.tags"), "table pane only");
});

test("C and T open PICKER on the cursor row", () => {
  for (const [text, id] of [["C", "torrent.category"], ["T", "torrent.tags"]]) {
    const r = dispatch(state({ hasTorrent: true }), ev(text, keyOf(text)));
    assert.equal(r.commandId, id);
    assert.equal(r.state.mode, "PICKER");
    assert.equal(r.args.count, 1);
    assert.equal(r.args.range, undefined);
  }
});

test("C from VISUAL opens PICKER on the range and drops the stale range count", () => {
  const r = dispatch(state({ mode: "VISUAL", selectionCount: 3, hasTorrent: true }), ev("C", keyOf("C")));
  assert.equal(r.commandId, "torrent.category");
  assert.equal(r.state.mode, "PICKER");
  assert.equal(r.args.count, 3);
  assert.equal(r.args.range, true);
  assert.equal(r.state.selectionCount, 0, "PICKER never carries a VISUAL range count");
});

test("C and T are blocked with no torrent, and do nothing outside the table", () => {
  const r = dispatch(state({ hasTorrent: false }), ev("T", keyOf("T")));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, "needs a selected torrent");
  assert.equal(r.state.mode, "NORMAL");
  const f = dispatch(state({ pane: "filters" }), ev("C", keyOf("C")));
  assert.equal(f.commandId, null);
  assert.equal(f.state.mode, "NORMAL");
});

test("the palette opens the pickers the same way", () => {
  const r = Registry.dispatchCommand(state({ hasTorrent: true }), "torrent.tags");
  assert.equal(r.commandId, "torrent.tags");
  assert.equal(r.state.mode, "PICKER");
});

// --- slice 3b, Task 5: the Info Limits keys (Ruling CJ) ---------------------

test("CJ: Space on a no-metadata Info tab toggles a toggle row, else starts the download", () => {
  // The cursor on Sequential/First-last: limit.toggle, even with no metadata.
  const toggle = dispatch(onTab("info", { cursorNoMetadata: true, limitCursorKey: "seqDl", limitToggle: true }), ev(" ", KEY.Space));
  assert.equal(toggle.commandId, "limit.toggle");
  assert.equal(toggle.args.limitKey, "seqDl", "the row under the cursor, captured at key time");
  // A value row: the 2b start-only carve-out (file.cycle's Start download).
  const value = dispatch(onTab("info", { cursorNoMetadata: true, limitCursorKey: "ratioLimit", limitToggle: false }), ev(" ", KEY.Space));
  assert.equal(value.commandId, "file.cycle");
  // No Limits cursor at all: the carve-out too.
  const none = dispatch(onTab("info", { cursorNoMetadata: true }), ev(" ", KEY.Space));
  assert.equal(none.commandId, "file.cycle");
  // With metadata: a toggle row toggles, a value row is blocked with no note.
  assert.equal(dispatch(onTab("info", { limitCursorKey: "firstLast", limitToggle: true }), ev(" ", KEY.Space)).commandId, "limit.toggle");
  const inert = dispatch(onTab("info", { limitCursorKey: "dlLimit" }), ev(" ", KEY.Space));
  assert.equal(inert.commandId, null);
  assert.equal(inert.blocked, "");
  // Files keeps its own Space, metadata or not.
  assert.equal(dispatch(onTab("files", { limitCursorKey: "seqDl", limitToggle: true }), ev(" ", KEY.Space)).commandId, "file.cycle");
});

test("CJ: the Start download row is Info-only and never reachable from the palette's Files row", () => {
  const rows = rowsFor("file.cycle");
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0].tabs, ["files"], "the Files row stays first (the palette reads the first row)");
  assert.equal(rows[0].title, "Cycle file priority");
  assert.deepEqual(rows[1].tabs, ["info"]);
  assert.equal(rows[1].title, "Start download");
  // dispatchCommand honours the same condition.
  assert.equal(Registry.dispatchCommand(onTab("info", { cursorNoMetadata: true }), "file.cycle").commandId, "file.cycle");
  assert.equal(Registry.dispatchCommand(onTab("info"), "file.cycle").commandId, null);
  assert.equal(Registry.dispatchCommand(onTab("info", { cursorNoMetadata: true, limitCursorKey: "seqDl", limitToggle: true }), "file.cycle").commandId, null);
});

test("CJ: ? shows Space as Start download on a no-metadata Info tab unless the cursor is on a toggle row", () => {
  function spaceTitles(st) {
    return helpFor("NORMAL", "inspector", "info", st).filter((r) => r.keys.includes("Space")).map((r) => r.title);
  }
  assert.deepEqual(spaceTitles({ cursorNoMetadata: true }), ["Start download"]);
  assert.deepEqual(spaceTitles({ cursorNoMetadata: true, limitCursorKey: "dlLimit" }), ["Start download"]);
  assert.deepEqual(spaceTitles({ cursorNoMetadata: true, limitCursorKey: "seqDl", limitToggle: true }), ["Toggle limit"]);
  assert.deepEqual(spaceTitles({ limitCursorKey: "seqDl", limitToggle: true }), ["Toggle limit"]);
  assert.deepEqual(spaceTitles({}), ["Toggle limit"]);
  // No state: as before Task 5.
  assert.deepEqual(helpFor("NORMAL", "inspector", "info").filter((r) => r.keys.includes("Space")).map((r) => r.title), ["Toggle limit"]);
  // Files is untouched.
  assert.deepEqual(helpFor("NORMAL", "inspector", "files", { cursorNoMetadata: true }).filter((r) => r.keys.includes("Space")).map((r) => r.title), ["Cycle file priority"]);
});

test("limit.edit captures the Limits row under the cursor at key time", () => {
  const r = dispatch(onTab("info", { limitCursorKey: "ratioLimit" }), ev("\r", KEY.Return));
  assert.equal(r.commandId, "limit.edit");
  assert.equal(r.args.limitKey, "ratioLimit");
});

// --- slice 3b, Task 6: the palette's bulk limits ------------------------------

const BULK = { "limit.setDownload": "Set download limit", "limit.setUpload": "Set upload limit", "limit.setRatio": "Set ratio limit" };

test("the bulk limit rows: palette-only, NORMAL and VISUAL, table and inspector, need a selection", () => {
  for (const id of Object.keys(BULK)) {
    const rows = rowsFor(id);
    assert.equal(rows.length, 1, id);
    assert.equal(rows[0].title, BULK[id]);
    assert.equal(rows[0].group, "Torrent");
    assert.deepEqual(rows[0].keys, [], id + " has no key");
    assert.equal(rows[0].paletteOnly, true);
    assert.deepEqual(rows[0].modes, ["NORMAL", "VISUAL"]);
    assert.deepEqual(rows[0].panes, ["table", "inspector"]);
    assert.equal(rows[0].needs, "selection");
  }
});

test("the bulk limit rows resolve from the palette on the cursor row or a VISUAL range, and leave VISUAL", () => {
  for (const id of Object.keys(BULK)) {
    const one = Registry.dispatchCommand(state({ hasTorrent: true }), id);
    assert.equal(one.commandId, id);
    assert.equal(one.args.count, 1);
    assert.equal(one.state.mode, "NORMAL", "the window opens INSERT itself");
    const range = Registry.dispatchCommand(state({ mode: "VISUAL", hasTorrent: true, selectionCount: 3 }), id);
    assert.equal(range.commandId, id);
    assert.equal(range.args.count, 3);
    assert.equal(range.args.range, true);
    assert.equal(range.state.mode, "NORMAL", "acting on the range ends VISUAL");
    assert.equal(range.state.selectionCount, 0, "no stale range count");
    const none = Registry.dispatchCommand(state({ hasTorrent: false }), id);
    assert.equal(none.commandId, null);
    assert.equal(none.blocked, "needs a selected torrent");
    assert.equal(Registry.dispatchCommand(state({ pane: "inspector", hasTorrent: true, inspectorTab: "info" }), id).commandId, id);
  }
});

test("no key reaches a palette-only row, and ? leaves them out", () => {
  for (const mode of ["NORMAL", "VISUAL"]) {
    for (const pane of ["table", "inspector"]) {
      const ids = helpFor(mode, pane).map((r) => r.id);
      for (const id of Object.keys(BULK)) assert.ok(!ids.includes(id), mode + " " + pane + " " + id);
    }
  }
});

test(": opens the palette from VISUAL too, remembering it was a range", () => {
  const r = dispatch(state({ mode: "VISUAL", selectionCount: 3 }), ev(":", 0x3a));
  assert.equal(r.commandId, "palette.open");
  assert.equal(r.state.mode, "COMMAND");
  assert.equal(r.state.selectionCount, 0, "COMMAND never carries the range count");
  assert.equal(r.args.range, true, "the window keeps the range it captured");
  const n = dispatch(state({}), ev(":", 0x3a));
  assert.equal(n.args.range, undefined, "NORMAL has no range");
});

// --- Settings (slice 4a Task 5) ---------------------------------------------

// The two columns (slice 4a); slice 4b adds the list editor's pane.
const SETTINGS_PANES = ["settingsSections", "settingsKeys"];
const ALL_SETTINGS_PANES = SETTINGS_PANES.concat(["settingsList"]);
const TORRENT_PANES = ["filters", "table", "inspector"];

// An event that matches `label` exactly as matchLabel reads it.
function evFor(label) {
  const ctrl = { ctrl: true, shift: false, alt: false };
  switch (label) {
    case "Tab": return ev("\t", KEY.Tab);
    case "Shift-Tab": return ev("", KEY.Backtab);
    case "Ctrl-l": return ev("\f", KEY.L, ctrl);
    case "Ctrl-h": return ev("\b", KEY.H, ctrl);
    case "Ctrl-p": return ev("\u0010", KEY.P, ctrl);
    case "Ctrl-n": return ev("\u000e", KEY.N, ctrl);
    case "Enter": return ev("\r", KEY.Return);
    case "Esc": return ev("\u001b", KEY.Escape);
    case "Up": return ev("", KEY.Up);
    case "Down": return ev("", KEY.Down);
    case "Space": return ev(" ", KEY.Space);
    default: return ev(label, label.toUpperCase().charCodeAt(0));
  }
}

test(", opens Settings from every torrent pane in NORMAL, and nowhere else", () => {
  for (const pane of TORRENT_PANES) {
    const r = dispatch(state({ pane: pane, inspectorTab: pane === "inspector" ? "info" : "" }), evFor(","));
    assert.equal(r.commandId, "settings.open", pane);
    assert.equal(r.state.mode, "NORMAL", pane);
  }
  assert.equal(dispatch(state({ mode: "VISUAL", selectionCount: 2 }), evFor(",")).commandId, null, "not from VISUAL");
  for (const pane of SETTINGS_PANES) assert.equal(dispatch(state({ pane: pane }), evFor(",")).commandId, null, pane);
  const row = commands.find((r) => r.id === "settings.open");
  assert.deepEqual(row.keys, [","]);
  assert.deepEqual(row.panes, TORRENT_PANES, "never PANE_ANY: it must not live inside Settings");
  assert.equal(row.title, "Settings", "the palette shows it as :Settings");
});

test("Settings: j/k/Down/Up move in both columns", () => {
  for (const pane of SETTINGS_PANES) {
    for (const label of ["j", "Down"]) assert.equal(dispatch(state({ pane: pane }), evFor(label)).commandId, "settings.down", pane + " " + label);
    for (const label of ["k", "Up"]) assert.equal(dispatch(state({ pane: pane }), evFor(label)).commandId, "settings.up", pane + " " + label);
  }
});

test("Settings: l/Enter/Tab go from the sections to the settings, and h/Shift-Tab come back", () => {
  for (const label of ["l", "Enter", "Tab"]) {
    assert.equal(dispatch(state({ pane: "settingsSections" }), evFor(label)).commandId, "settings.enter", label);
    assert.equal(dispatch(state({ pane: "settingsKeys" }), evFor(label)).commandId, null, "settings list " + label);
  }
  for (const label of ["h", "Shift-Tab"]) {
    assert.equal(dispatch(state({ pane: "settingsKeys" }), evFor(label)).commandId, "settings.leave", label);
    assert.equal(dispatch(state({ pane: "settingsSections" }), evFor(label)).commandId, null, "sections " + label);
  }
});

test("Settings: Esc is settings.back in both columns, and / opens the search INSERT", () => {
  for (const pane of SETTINGS_PANES) {
    const back = dispatch(state({ pane: pane }), evFor("Esc"));
    assert.equal(back.commandId, "settings.back", pane);
    assert.equal(back.state.prefix, null, "no Esc Esc prefix inside Settings");
    const again = dispatch(back.state, ev("\u001b", KEY.Escape, undefined, 100));
    assert.equal(again.commandId, "settings.back", "a second Esc is another back, never filter.reset");
    const search = dispatch(state({ pane: pane }), evFor("/"));
    assert.equal(search.commandId, "settings.search", pane);
    assert.equal(search.state.mode, "INSERT", pane);
  }
});

test("Settings: a stale Esc or g prefix never reaches the torrent view's sequences", () => {
  for (const pane of SETTINGS_PANES) {
    const esc = dispatch(state({ pane: pane, prefix: "Esc", prefixAt: 0 }), ev("\u001b", KEY.Escape, undefined, 10));
    assert.equal(esc.commandId, "settings.back", pane);
    const g = dispatch(state({ pane: pane, prefix: "g", prefixAt: 0 }), ev("g", keyOf("g"), undefined, 10));
    assert.equal(g.commandId, null, pane);
  }
});

// The any-pane audit (Review Focus 5). Every NORMAL/VISUAL row on PANE_ANY
// is a torrent-view key; inside Settings only : and ? stay live. The modal
// rows (INSERT, COMMAND, CONFIRM, PICKER) are gated by their mode and stay
// live, or the search field, the palette and Task 6's confirms would break.
const ANY_PANE_LIVE_IN_SETTINGS = ["palette.open", "help.toggle"];
const ANY_PANE_TORRENT_ROWS = ["all.toggle", "sort.next", "sort.reverse", "turtle.toggle", "filter.text", "refresh",
  "inspector.info", "inspector.files", "inspector.trackers", "inspector.peers", "inspector.chart", "pane.next", "pane.prev",
  "help.toggle", "window.close", "filter.clearText", "filter.reset", "palette.open", "torrent.fetchMetadata"];

function anyPaneViewRows() {
  return commands.filter((r) => r.panes.includes("*") && (r.modes.includes("NORMAL") || r.modes.includes("VISUAL")));
}

test("any-pane audit: the NORMAL/VISUAL any-pane rows are exactly the audited list", () => {
  const ids = Array.from(new Set(anyPaneViewRows().map((r) => r.id))).sort();
  assert.deepEqual(ids, ANY_PANE_TORRENT_ROWS.slice().sort(), "a new any-pane row needs a Settings decision here");
});

test("any-pane audit: only : and ? stay live inside Settings; every other any-pane key is dead in both columns and the list", () => {
  for (const pane of ALL_SETTINGS_PANES) {
    for (const row of anyPaneViewRows()) {
      for (const label of row.keys) {
        if (label === "g g" || label === "Esc Esc") continue;
        for (const mode of row.modes.filter((m) => m === "NORMAL" || m === "VISUAL")) {
          const r = dispatch(state({ pane: pane, mode: mode, cursorNoMetadata: true, hasTorrent: true, selectionCount: 2 }), evFor(label));
          if (ANY_PANE_LIVE_IN_SETTINGS.includes(row.id)) {
            assert.equal(r.commandId, row.id, pane + " " + mode + " " + label);
          } else {
            assert.notEqual(r.commandId, row.id, row.id + " must be dead in " + pane + " (" + mode + " " + label + ")");
            assert.ok(r.commandId === null || /^(settings|list)\./.test(r.commandId), row.id + " " + label + " resolved to " + r.commandId);
            assert.equal(r.blocked, undefined, row.id + " " + label + " says nothing");
          }
        }
      }
    }
    for (const id of ANY_PANE_TORRENT_ROWS.filter((x) => !ANY_PANE_LIVE_IN_SETTINGS.includes(x))) {
      assert.equal(Registry.dispatchCommand(state({ pane: pane, cursorNoMetadata: true }), id).commandId, null, id + ": the palette can't reach it either");
    }
  }
});

test("any-pane audit: the torrent panes keep every any-pane row", () => {
  for (const pane of TORRENT_PANES) {
    for (const row of anyPaneViewRows()) assert.ok(Registry.paneMatches(row, pane), row.id + " " + pane);
  }
});

test("any-pane audit: the modal rows stay live inside Settings", () => {
  for (const pane of ALL_SETTINGS_PANES) {
    assert.equal(dispatch(state({ pane: pane, mode: "INSERT" }), evFor("Esc")).commandId, "insert.cancel", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "INSERT" }), evFor("Enter")).commandId, "insert.commit", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "COMMAND" }), evFor("Esc")).commandId, "palette.close", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "COMMAND" }), evFor("Enter")).commandId, "palette.run", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "PICKER" }), evFor("Enter")).commandId, "picker.accept", pane);
    const confirm = Registry.raiseConfirm(state({ pane: pane }), "settings.write", "settingConfirm", {});
    assert.equal(dispatch(confirm.state, evFor("y")).commandId, "settings.write", pane);
    assert.equal(dispatch(confirm.state, evFor("n")).commandId, "confirm.cancel", pane);
  }
});

test("? in Settings lists the Settings keys, plus : and ?", () => {
  for (const pane of SETTINGS_PANES) {
    const ids = Array.from(new Set(helpFor("NORMAL", pane).map((r) => r.id))).sort();
    const want = ["help.toggle", "palette.open", "settings.back", "settings.down", "settings.search", "settings.up",
      pane === "settingsSections" ? "settings.enter" : "settings.leave"]
      // slice 4b: x clears a set secret and u undoes (settings.openList and
      // the narrow rows need their `when`, so the empty state leaves them out).
      .concat(pane === "settingsKeys" ? ["settings.edit", "settings.toggle", "settings.clearSecret", "settings.undo"] : []).sort();
    assert.deepEqual(ids, want, pane);
  }
  assert.ok(helpFor("NORMAL", "table").some((r) => r.id === "settings.open"), "the torrent view's ? lists ,");
  assert.ok(!helpFor("NORMAL", "table").some((r) => /^settings\.(?!open)/.test(r.id)), "and none of the Settings keys");
});

// Slice 4b: the palette shows the Settings actions (clear a secret, undo,
// add and remove a list line) besides :Settings; navigation and the edit
// rows stay palette-hidden (Ruling DP).
const SETTINGS_PALETTE_VISIBLE = ["settings.open", "settings.clearSecret", "settings.undo", "list.add", "list.remove"];

test("the Settings navigation rows stay out of the palette; :Settings and the 4b actions are there", () => {
  for (const row of commands.filter((r) => /^(settings|list)\./.test(r.id))) {
    assert.equal(row.paletteHidden === true, !SETTINGS_PALETTE_VISIBLE.includes(row.id), row.id);
    for (const p of row.panes) assert.ok(row.id === "settings.open" ? TORRENT_PANES.includes(p) : ALL_SETTINGS_PANES.includes(p), row.id + " " + p);
  }
});

// --- Settings editors (slice 4a, Task 6) ---------------------------------------------

test("Settings: Space toggles and Enter edits the setting under the cursor, captured at key time", () => {
  const t = dispatch(state({ pane: "settingsKeys", settingsToggle: true, settingsKey: "dht" }), evFor("Space"));
  assert.equal(t.commandId, "settings.toggle");
  assert.equal(t.args.settingKey, "dht", "the key under the cursor when Space was pressed");
  assert.equal(t.state.mode, "NORMAL");
  const e = dispatch(state({ pane: "settingsKeys", settingsEditable: true, settingsKey: "listen_port" }), evFor("Enter"));
  assert.equal(e.commandId, "settings.edit");
  assert.equal(e.args.settingKey, "listen_port");
  assert.equal(e.state.mode, "NORMAL", "the window picks INSERT or PICKER from the editor");
});

test("Settings: a row with no editor (locked, read-only, secret, multi-line, dimmed, saving) does nothing, with no note", () => {
  for (const label of ["Space", "Enter"]) {
    const r = dispatch(state({ pane: "settingsKeys", settingsKey: "web_ui_port" }), evFor(label));
    assert.equal(r.commandId, null, label);
    assert.equal(r.blocked, "", label + ": the help line already says why");
  }
  // Space on an input row and Enter on a toggle row are not edits either.
  assert.equal(dispatch(state({ pane: "settingsKeys", settingsEditable: true, settingsKey: "listen_port" }), evFor("Space")).commandId, null);
  assert.equal(dispatch(state({ pane: "settingsKeys", settingsToggle: true, settingsKey: "dht" }), evFor("Enter")).commandId, null);
  // Enter on the sections column is still settings.enter.
  assert.equal(dispatch(state({ pane: "settingsSections", settingsEditable: true, settingsKey: "x" }), evFor("Enter")).commandId, "settings.enter");
  assert.equal(dispatch(state({ pane: "settingsSections", settingsToggle: true, settingsKey: "x" }), evFor("Space")).commandId, null);
});

test("Settings: the edit rows need their flags, which default off", () => {
  assert.equal(Registry.preconditionMet("toggleRow", {}), false);
  assert.equal(Registry.preconditionMet("editableRow", {}), false);
  assert.equal(Registry.preconditionMet("toggleRow", { settingsToggle: true }), true);
  assert.equal(Registry.preconditionMet("editableRow", { settingsEditable: true }), true);
  assert.equal(Registry.needsReason("toggleRow", {}), "");
  assert.equal(Registry.needsReason("editableRow", {}), "");
});

test("Settings: settings.write has no key or palette row; only its CONFIRM's y reaches it", () => {
  assert.ok(!commands.some((r) => r.id === "settings.write"));
  for (const pane of SETTINGS_PANES.concat(TORRENT_PANES)) {
    assert.equal(Registry.dispatchCommand(state({ pane: pane, settingsToggle: true, settingsEditable: true, settingsKey: "dht" }), "settings.write").commandId, null, pane);
  }
  const args = { key: "dht", value: false, from: true, label: "DHT" };
  const c = Registry.raiseConfirm(state({ pane: "settingsKeys" }), "settings.write", "settingConfirm", args);
  const y = dispatch(c.state, evFor("y"));
  assert.equal(y.commandId, "settings.write");
  assert.deepEqual(y.args, { key: "dht", value: false, from: true, label: "DHT", confirmed: true });
  assert.equal(y.state.mode, "NORMAL");
  const n = dispatch(c.state, evFor("n"));
  assert.equal(n.commandId, "confirm.cancel");
  assert.equal(dispatch(c.state, evFor("Esc")).commandId, "confirm.cancel");
  // Space/Enter while the question is up never start another edit.
  assert.equal(dispatch(assign(c.state, { settingsToggle: true, settingsEditable: true, settingsKey: "upnp" }), evFor("Space")).commandId, null);
  assert.equal(dispatch(assign(c.state, { settingsToggle: true, settingsEditable: true, settingsKey: "upnp" }), evFor("Enter")).commandId, null);
  // A palette- or key-resolved settings.toggle/edit never carries confirmed.
  const t = Registry.dispatchCommand(state({ pane: "settingsKeys", settingsToggle: true, settingsKey: "dht" }), "settings.toggle");
  assert.equal(t.commandId, "settings.toggle");
  assert.equal(t.args.confirmed, undefined);
});

function assign(a, b) { return Object.assign({}, a, b); }

// --- Settings 4b contract (slice 4b, Task 1) ---------------------------------------------

// Every key the Settings panes care about, plus the ones that must stay dead.
const KEYS_4B = ["j", "k", "Down", "Up", "l", "h", "Enter", "Tab", "Shift-Tab", "Esc", "/", "Space", "x", "a", "u", "?", ":",
  "t", "s", "q", "r", "1", "Ctrl-l", "Ctrl-h"];

// Every flag on: each row's need is met, except settingsListRow (Enter's
// list/edit split is pinned on its own below).
const ALL_ON = {
  settingsKey: "proxy_password", settingsToggle: true, settingsEditable: true, settingsSecretSet: true,
  settingsUndoCount: 2, listEditable: true, listItem: { index: 0, value: "203.0.113.5", tierBreak: false }
};

const SECTIONS_WIDE = { j: "settings.down", Down: "settings.down", k: "settings.up", Up: "settings.up",
  l: "settings.enter", Enter: "settings.enter", Tab: "settings.enter", Esc: "settings.back", "/": "settings.search",
  "?": "help.toggle", ":": "palette.open" };
const KEYS_WIDE = { j: "settings.down", Down: "settings.down", k: "settings.up", Up: "settings.up",
  h: "settings.leave", "Shift-Tab": "settings.leave", Enter: "settings.edit", Esc: "settings.back", "/": "settings.search",
  Space: "settings.toggle", x: "settings.clearSecret", u: "settings.undo", "?": "help.toggle", ":": "palette.open" };
const LIST_ANY = { j: "list.down", Down: "list.down", k: "list.up", Up: "list.up", a: "list.add", x: "list.remove",
  Esc: "list.back", u: "settings.undo", "?": "help.toggle", ":": "palette.open" };
// D13: narrow remaps Tab, h and Shift-Tab (settings list) to the sections
// overlay, and Esc in the overlay (the sections column) closes it first.
const KEY_MAP_4B = {
  settingsSections: { wide: SECTIONS_WIDE, narrow: Object.assign({}, SECTIONS_WIDE, { Esc: "settings.sectionsClose" }) },
  settingsKeys: { wide: KEYS_WIDE, narrow: Object.assign({}, KEYS_WIDE, { h: "settings.sections", Tab: "settings.sections", "Shift-Tab": "settings.sections" }) },
  settingsList: { wide: LIST_ANY, narrow: LIST_ANY }
};

test("4b: every key x Settings pane x narrow resolves as pinned, and nothing else resolves", () => {
  for (const pane of ALL_SETTINGS_PANES) {
    for (const width of ["wide", "narrow"]) {
      const want = KEY_MAP_4B[pane][width];
      for (const label of KEYS_4B) {
        const r = dispatch(state(Object.assign({ pane: pane, narrow: width === "narrow" }, ALL_ON)), evFor(label));
        assert.equal(r.commandId, want[label] || null, pane + " " + width + " " + label);
      }
    }
  }
});

test("4b: narrow never changes a torrent pane's keys", () => {
  for (const pane of TORRENT_PANES) {
    for (const tab of pane === "inspector" ? ["info", "trackers", "peers", "files", "chart"] : [""]) {
      for (const label of KEYS_4B.concat(["V", "C", "T", "o", "y", "m", "e", "f", "b", "R", "c", "p", "G", ","])) {
        const base = state(Object.assign({ pane: pane, inspectorTab: tab }, ALL_ON));
        const wide = dispatch(base, evFor(label));
        const narrow = dispatch(Object.assign({}, base, { narrow: true }), evFor(label));
        assert.deepEqual(narrow.commandId, wide.commandId, pane + " " + tab + " " + label);
        assert.deepEqual(narrow.blocked, wide.blocked, pane + " " + tab + " " + label);
      }
    }
  }
});

test("4b: Enter on a list row opens the list (settings.openList, before settings.edit), with the key captured", () => {
  const r = dispatch(state({ pane: "settingsKeys", settingsKey: "add_trackers", settingsListRow: true }), evFor("Enter"));
  assert.equal(r.commandId, "settings.openList");
  assert.deepEqual(r.args, { settingKey: "add_trackers" });
  assert.equal(r.state.mode, "NORMAL", "the window focuses settingsList");
  // Even when the window also calls the row editable, the list wins.
  assert.equal(dispatch(state({ pane: "settingsKeys", settingsKey: "add_trackers", settingsListRow: true, settingsEditable: true }), evFor("Enter")).commandId, "settings.openList");
  // Not a list row: Enter is settings.edit as in 4a, or blocked silently.
  assert.equal(dispatch(state({ pane: "settingsKeys", settingsKey: "listen_port", settingsEditable: true }), evFor("Enter")).commandId, "settings.edit");
  const none = dispatch(state({ pane: "settingsKeys", settingsKey: "web_ui_port" }), evFor("Enter"));
  assert.deepEqual([none.commandId, none.blocked], [null, ""]);
  // Only in the settings list: the sections' Enter stays settings.enter.
  assert.equal(dispatch(state({ pane: "settingsSections", settingsListRow: true }), evFor("Enter")).commandId, "settings.enter");
  const row = commands.find((c) => c.id === "settings.openList");
  assert.ok(commands.indexOf(row) < commands.indexOf(commands.find((c) => c.id === "settings.edit")));
  assert.deepEqual([row.keys, row.panes, row.needs, row.when], [["Enter"], ["settingsKeys"], "listRow", "listRow"]);
});

test("4b: x clears a set, writable secret; the window confirms, so a key never carries confirmed", () => {
  const r = dispatch(state({ pane: "settingsKeys", settingsKey: "dyndns_password", settingsSecretSet: true }), evFor("x"));
  assert.equal(r.commandId, "settings.clearSecret");
  assert.deepEqual(r.args, { settingKey: "dyndns_password" });
  assert.equal(r.state.mode, "NORMAL");
  assert.equal(r.confirm, undefined, "the window raises the confirm (design D8)");
  // Not set, not writable, saving or not a secret: silent (the row says why).
  const off = dispatch(state({ pane: "settingsKeys", settingsKey: "dyndns_password" }), evFor("x"));
  assert.deepEqual([off.commandId, off.blocked], [null, ""]);
  // The window's confirm: y resolves to settings.clearSecret with confirmed.
  const c = Registry.raiseConfirm(state({ pane: "settingsKeys" }), "settings.clearSecret", "secretClear", { settingKey: "dyndns_password" });
  const y = dispatch(c.state, evFor("y"));
  assert.equal(y.commandId, "settings.clearSecret");
  assert.deepEqual(y.args, { settingKey: "dyndns_password", confirmed: true });
  assert.equal(dispatch(c.state, evFor("n")).commandId, "confirm.cancel");
  const p = Registry.dispatchCommand(state({ pane: "settingsKeys", settingsKey: "proxy_password", settingsSecretSet: true }), "settings.clearSecret");
  assert.deepEqual([p.commandId, p.args.confirmed], ["settings.clearSecret", undefined]);
});

test("4b: u undoes in the settings list and the list editor, and says so when there's nothing to undo", () => {
  for (const pane of ["settingsKeys", "settingsList"]) {
    const r = dispatch(state({ pane: pane, settingsUndoCount: 1 }), evFor("u"));
    assert.equal(r.commandId, "settings.undo", pane);
    assert.deepEqual(r.args, {}, pane);
    assert.equal(r.state.mode, "NORMAL", pane);
    const none = dispatch(state({ pane: pane, settingsUndoCount: 0 }), evFor("u"));
    assert.deepEqual([none.commandId, none.blocked], [null, "nothing to undo"], pane);
    assert.equal(Registry.dispatchCommand(state({ pane: pane, settingsUndoCount: 3 }), "settings.undo").commandId, "settings.undo", pane);
  }
  assert.equal(dispatch(state({ pane: "settingsSections", settingsUndoCount: 1 }), evFor("u")).commandId, null, "not from the sections");
  for (const pane of TORRENT_PANES) {
    assert.equal(Registry.dispatchCommand(state({ pane: pane, settingsUndoCount: 1 }), "settings.undo").commandId, null, pane);
  }
});

test("4b: the list editor's a, x and Esc, with the list's key and the line captured at key time", () => {
  const item = { index: 2, value: "", tierBreak: true, extra: "dropped" };
  const s = state({ pane: "settingsList", settingsKey: "add_trackers", listEditable: true, listItem: item });
  const add = dispatch(s, evFor("a"));
  assert.equal(add.commandId, "list.add");
  assert.deepEqual(add.args, { settingKey: "add_trackers" });
  assert.equal(add.state.mode, "NORMAL", "the window opens INSERT");
  const rm = dispatch(s, evFor("x"));
  assert.equal(rm.commandId, "list.remove");
  assert.deepEqual(rm.args, { settingKey: "add_trackers", listItem: { index: 2, value: "", tierBreak: true } });
  assert.ok(Object.isFrozen(rm.args.listItem), "a later refresh can't change what x removes");
  item.value = "changed";
  assert.equal(rm.args.listItem.value, "");
  assert.equal(rm.confirm, undefined, "no confirm: unbanning and removals are undoable (design, D11)");
  const back = dispatch(s, evFor("Esc"));
  assert.deepEqual([back.commandId, back.state.prefix], ["list.back", null]);
  // A stale Esc prefix never reaches filter.reset from the list.
  assert.equal(dispatch(state({ pane: "settingsList", prefix: "Esc", prefixAt: 0 }), ev("\u001b", KEY.Escape, undefined, 10)).commandId, "list.back");
  // Not editable (saving) or no line under the cursor: silent.
  for (const [over, label] of [[{ listEditable: false }, "a"], [{ listEditable: false }, "x"], [{ listItem: null }, "x"]]) {
    const r = dispatch(Object.assign({}, s, over), evFor(label));
    assert.deepEqual([r.commandId, r.blocked], [null, ""], JSON.stringify(over) + " " + label);
  }
  // The empty list still adds.
  assert.equal(dispatch(state({ pane: "settingsList", settingsKey: "banned_IPs", listEditable: true }), evFor("a")).commandId, "list.add");
});

test("4b: narrow's rows: Tab, h and Shift-Tab open the sections; Esc in the overlay closes it first", () => {
  for (const label of ["Tab", "h", "Shift-Tab"]) {
    const r = dispatch(state({ pane: "settingsKeys", narrow: true }), evFor(label));
    assert.deepEqual([r.commandId, r.args, r.state.mode], ["settings.sections", {}, "NORMAL"], label);
  }
  const close = dispatch(state({ pane: "settingsSections", narrow: true }), evFor("Esc"));
  assert.equal(close.commandId, "settings.sectionsClose");
  assert.equal(close.state.prefix, null);
  // Choosing a section is settings.enter, as when wide; the window closes the overlay.
  assert.equal(dispatch(state({ pane: "settingsSections", narrow: true }), evFor("Enter")).commandId, "settings.enter");
  // In the settings list, Esc is still settings.back.
  assert.equal(dispatch(state({ pane: "settingsKeys", narrow: true }), evFor("Esc")).commandId, "settings.back");
  for (const id of ["settings.sections", "settings.sectionsClose"]) {
    const row = commands.find((c) => c.id === id);
    assert.deepEqual([row.needs, row.when, row.paletteHidden], ["narrow", "narrow", true], id);
  }
});

test("4b: ? follows the width and the cursor row (helpFor's state)", () => {
  const ids = (pane, st) => Array.from(new Set(helpFor("NORMAL", pane, undefined, st).map((r) => r.id))).sort();
  assert.deepEqual(ids("settingsKeys", { narrow: true }), ["help.toggle", "palette.open", "settings.back", "settings.clearSecret",
    "settings.down", "settings.edit", "settings.search", "settings.sections", "settings.toggle", "settings.undo", "settings.up"]);
  assert.ok(ids("settingsKeys", { settingsListRow: true }).includes("settings.openList"));
  assert.deepEqual(ids("settingsSections", { narrow: true }), ["help.toggle", "palette.open", "settings.down", "settings.enter",
    "settings.search", "settings.sectionsClose", "settings.up"]);
  for (const st of [{}, { narrow: true }]) {
    assert.deepEqual(ids("settingsList", st), ["help.toggle", "list.add", "list.back", "list.down", "list.remove", "list.up",
      "palette.open", "settings.undo"], JSON.stringify(st));
  }
  const titles = {};
  for (const r of helpFor("NORMAL", "settingsList")) titles[r.id] = r.title;
  assert.equal(titles["list.add"], "Add to the list");
  assert.equal(titles["list.remove"], "Remove from the list");
  assert.equal(helpFor("NORMAL", "settingsKeys").find((r) => r.id === "settings.undo").title, "Undo the last settings change");
  assert.equal(helpFor("NORMAL", "settingsKeys").find((r) => r.id === "settings.clearSecret").title, "Clear the secret");
});

test("4b: settingsList is a Settings pane", () => {
  assert.deepEqual(Registry.SETTINGS_PANES, ALL_SETTINGS_PANES);
  assert.equal(Registry.isSettingsPane("settingsList"), true);
});

test("4b: the new needs default unmet, and only undo names a reason", () => {
  for (const need of ["listRow", "secretSet", "undoEntry", "listEditable", "listItem", "narrow"]) {
    assert.equal(Registry.preconditionMet(need, {}), false, need);
  }
  assert.equal(Registry.preconditionMet("listRow", { settingsListRow: true }), true);
  assert.equal(Registry.preconditionMet("secretSet", { settingsSecretSet: true }), true);
  assert.equal(Registry.preconditionMet("undoEntry", { settingsUndoCount: 1 }), true);
  assert.equal(Registry.preconditionMet("undoEntry", { settingsUndoCount: "1" }), false, "a number, never a string");
  assert.equal(Registry.preconditionMet("listEditable", { listEditable: true }), true);
  assert.equal(Registry.preconditionMet("listItem", { listEditable: true, listItem: { index: 0, value: "x" } }), true);
  assert.equal(Registry.preconditionMet("listItem", { listEditable: false, listItem: { index: 0, value: "x" } }), false);
  assert.equal(Registry.preconditionMet("narrow", { narrow: true }), true);
  for (const need of ["listRow", "secretSet", "listEditable", "listItem", "narrow"]) assert.equal(Registry.needsReason(need, {}), "", need);
  assert.equal(Registry.needsReason("undoEntry", {}), "nothing to undo");
  assert.equal(Registry.needsReason("undoEntry", { settingsUndoCount: 1 }), "");
});

// --- Views and Search (slice 5a, Task 1: eng C1, OV2) ---------------------------------

const SEARCH_PANES = ["searchResults", "searchPlugins", "searchPluginList"];
const VIEW_PANES = ALL_SETTINGS_PANES.concat(SEARCH_PANES);
// A row "touches torrents" when its need is about a torrent, a torrent's
// tracker or peer, the Info tab's Limits or the filters' categories/tags.
const TORRENT_NEEDS = ["torrent", "selection", "noMetadata", "tracker", "peer", "trackersTab", "limitRow", "limitToggle",
  "libraryGroup", "libraryName", "categoryName"];
// The only rows allowed to be live in every view: help, the palette, and
// the view openers (which live on the torrent panes only, see below).
const VIEW_EXEMPT = ["help.toggle", "palette.open", "settings.open", "search.open"];

test("views: every pane belongs to exactly one view, and the view pane lists derive from the map", () => {
  assert.deepEqual(Registry.VIEWS, ["torrents", "settings", "search"]);
  for (const p of TORRENT_PANES) assert.equal(Registry.viewOfPane(p), "torrents", p);
  for (const p of ALL_SETTINGS_PANES) assert.equal(Registry.viewOfPane(p), "settings", p);
  for (const p of SEARCH_PANES) assert.equal(Registry.viewOfPane(p), "search", p);
  assert.equal(Registry.viewOfPane(undefined), "torrents", "normalizeState's default pane is the table");
  assert.equal(Registry.viewOfPane("nonsense"), "torrents");
  assert.deepEqual(Registry.SEARCH_PANES, SEARCH_PANES);
  assert.deepEqual(Registry.SETTINGS_PANES, ALL_SETTINGS_PANES);
  for (const p of SEARCH_PANES) assert.equal(Registry.isSearchPane(p), true, p);
  for (const p of TORRENT_PANES.concat(ALL_SETTINGS_PANES)) assert.equal(Registry.isSearchPane(p), false, p);
  // Every pane any row names is in the map (a new pane needs a view).
  for (const row of commands) for (const p of row.panes) if (p !== "*") assert.ok(Object.prototype.hasOwnProperty.call(Registry.VIEW_OF_PANE, p), row.id + " " + p);
});

// OV2: otherwise t, z, r, q, 1-5 (and every other torrent key) would act on
// the hidden torrents from Settings or Search. Every row in the Library or
// View group and every row whose `needs` touches torrents, except help, the
// palette and the view openers, is checked against every Settings and
// Search pane: it may match one only by naming it (that view's own
// navigation, e.g. settings.down), and a row that touches torrents names
// none at all.
test("views: no torrent row reaches a Settings or Search pane", () => {
  const checked = commands.filter((r) => (r.group === "Library" || r.group === "View" || TORRENT_NEEDS.includes(r.needs)) && !VIEW_EXEMPT.includes(r.id));
  assert.ok(checked.length > 40, "the audit covers the torrent rows");
  for (const row of checked) {
    for (const pane of VIEW_PANES) {
      assert.equal(Registry.paneMatches(row, pane), row.panes.includes(pane), row.id + " reaches " + pane);
      if (TORRENT_NEEDS.includes(row.needs)) assert.equal(Registry.paneMatches(row, pane), false, row.id + " (needs " + row.needs + ") in " + pane);
    }
    const named = row.panes.filter((p) => VIEW_PANES.includes(p));
    if (named.length > 0) {
      // A view's own row names only that view's panes, never "*" or a torrent pane.
      const views = new Set(named.map((p) => Registry.viewOfPane(p)));
      assert.equal(views.size, 1, row.id + " spans views");
      assert.deepEqual(row.panes.filter((p) => !VIEW_PANES.includes(p)), [], row.id + " mixes a view's panes with the torrents'");
    }
  }
  // And through dispatch: every such row's keys, in every view pane, with every flag on.
  for (const pane of VIEW_PANES) {
    for (const row of checked.filter((r) => !r.panes.includes(pane))) {
      for (const label of row.keys) {
        if (label === "g g" || label === "Esc Esc") continue;
        for (const mode of row.modes.filter((m) => m === "NORMAL" || m === "VISUAL")) {
          const r = dispatch(state(Object.assign({ pane: pane, mode: mode, cursorNoMetadata: true, selectionCount: 2,
            inspectorTarget: { kind: "tracker", value: "udp://t.example/a", label: "t.example" }, trackersTab: true, limitCursorKey: "dlLimit", limitToggle: true,
            libraryTarget: { kind: "category", value: "films", label: "films" } }, ALL_ON)), evFor(label));
          assert.notEqual(r.commandId, row.id, row.id + " (" + label + ") ran in " + pane);
        }
      }
      assert.equal(Registry.dispatchCommand(state({ pane: pane }), row.id).commandId === row.id, false, row.id + ": the palette can't run it in " + pane);
    }
  }
});

test("views: help, the palette and the openers are the only exempt rows, and the openers live on the torrent panes only", () => {
  for (const id of ["help.toggle", "palette.open"]) {
    const row = commands.find((r) => r.id === id);
    assert.equal(row.inViews, true, id);
    for (const pane of VIEW_PANES) assert.equal(Registry.paneMatches(row, pane), true, id + " " + pane);
  }
  assert.deepEqual(commands.filter((r) => r.inViews === true).map((r) => r.id).sort(), ["help.toggle", "palette.open"]);
  assert.equal(commands.some((r) => r.inSettings !== undefined), false, "inSettings became inViews");
  for (const id of ["settings.open", "search.open"]) {
    const row = commands.find((r) => r.id === id);
    assert.deepEqual(row.panes, TORRENT_PANES, id);
    for (const pane of VIEW_PANES) assert.equal(Registry.paneMatches(row, pane), false, id + " " + pane);
  }
});

test("F opens Search from every torrent pane in NORMAL; there is no key between Settings and Search", () => {
  for (const pane of TORRENT_PANES) {
    const r = dispatch(state({ pane: pane, inspectorTab: pane === "inspector" ? "info" : "" }), evFor("F"));
    assert.deepEqual([r.commandId, r.state.mode, r.args], ["search.open", "NORMAL", {}], pane);
  }
  assert.equal(dispatch(state({ mode: "VISUAL", selectionCount: 2 }), evFor("F")).commandId, null, "not from VISUAL");
  for (const pane of VIEW_PANES) {
    assert.equal(dispatch(state(Object.assign({ pane: pane }, ALL_ON)), evFor("F")).commandId, null, "F in " + pane);
    assert.equal(dispatch(state(Object.assign({ pane: pane }, ALL_ON)), evFor(",")).commandId, null, ", in " + pane);
  }
  const row = commands.find((r) => r.id === "search.open");
  assert.deepEqual([row.keys, row.title, row.group, row.needs], [["F"], "Search", "App", "none"], "the palette shows it as :Search");
  assert.equal(commands.filter((r) => r.keys.includes("F")).length, 1, "F means nothing else");
  // The palette runs :Search and :Settings only from the torrents (the window leaves a view first).
  for (const pane of TORRENT_PANES) assert.equal(Registry.dispatchCommand(state({ pane: pane }), "search.open").commandId, "search.open", pane);
  for (const pane of VIEW_PANES) {
    assert.equal(Registry.dispatchCommand(state({ pane: pane }), "search.open").commandId, null, pane);
    assert.equal(Registry.dispatchCommand(state({ pane: pane }), "settings.open").commandId, null, pane);
  }
});

test("search: the any-pane torrent keys are dead in every Search pane; : and ? stay; the modal rows stay", () => {
  for (const pane of SEARCH_PANES) {
    for (const row of anyPaneViewRows()) {
      for (const label of row.keys) {
        if (label === "g g" || label === "Esc Esc") continue;
        for (const mode of row.modes.filter((m) => m === "NORMAL" || m === "VISUAL")) {
          const r = dispatch(state({ pane: pane, mode: mode, cursorNoMetadata: true, hasTorrent: true, selectionCount: 2 }), evFor(label));
          if (ANY_PANE_LIVE_IN_SETTINGS.includes(row.id)) assert.equal(r.commandId, row.id, pane + " " + mode + " " + label);
          else assert.ok(r.commandId === null || /^(search|plugin)\./.test(r.commandId), row.id + " " + label + " in " + pane + " resolved to " + r.commandId);
        }
      }
    }
    assert.equal(dispatch(state({ pane: pane, mode: "INSERT" }), evFor("Esc")).commandId, "insert.cancel", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "INSERT" }), evFor("Enter")).commandId, "insert.commit", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "COMMAND" }), evFor("Esc")).commandId, "palette.close", pane);
    const c = Registry.raiseConfirm(state({ pane: pane }), "search.add", "searchAdd", { result: { fileName: "x" } });
    assert.equal(dispatch(c.state, evFor("y")).commandId, "search.add", pane);
    assert.equal(dispatch(c.state, evFor("n")).commandId, "confirm.cancel", pane);
    // A stale prefix from the torrents never completes here.
    assert.equal(dispatch(state({ pane: pane, prefix: "Esc", prefixAt: 0 }), ev("\u001b", KEY.Escape, undefined, 10)).commandId !== "filter.reset", true, pane);
    assert.equal(dispatch(state({ pane: pane, prefix: "g", prefixAt: 0 }), ev("g", keyOf("g"), undefined, 10)).commandId, null, pane);
  }
});

// Every flag a Search row needs, on.
const SEARCH_ON = {
  searchResult: { fileName: "debian-13.0.0-amd64-netinst.iso", fileUrl: "magnet:?xt=urn:btih:" + "ab".repeat(20), descrLink: "https://example.org/t/1", engineName: "example", siteUrl: "https://example.org", fileSize: 1, nbSeeders: 2 },
  searchPlugin: { name: "example", fullName: "Example", version: "1.2", enabled: true, url: "https://example.org" },
  searchPluginCount: 2, searchEnabledPlugins: 1
};
const KEYS_5A = ["j", "k", "Down", "Up", "l", "h", "Enter", "Tab", "Shift-Tab", "Esc", "/", "c", "Space", "x", "y", "d", "s", "S", "P", "i", "U", "u", "a",
  "?", ":", "t", "z", "r", "q", "1", "4", "F", ",", "Ctrl-l", "Ctrl-h", "g", "G", "V"];
const RESULTS_WIDE = { j: "search.down", Down: "search.down", k: "search.up", Up: "search.up", h: "search.focusPlugins", "Shift-Tab": "search.focusPlugins",
  Enter: "search.add", Esc: "search.back", "/": "search.new", c: "search.category", y: "search.copyLink", d: "search.openPage", s: "search.sort", S: "search.sortReverse",
  P: "search.plugins", "?": "help.toggle", ":": "palette.open" };
const PLUGINS_WIDE = { j: "search.down", Down: "search.down", k: "search.up", Up: "search.up", l: "search.focusResults", Enter: "search.focusResults",
  Tab: "search.focusResults", Esc: "search.back", "/": "search.new", c: "search.category", P: "search.plugins", "?": "help.toggle", ":": "palette.open" };
const PLUGIN_LIST = { j: "plugin.down", Down: "plugin.down", k: "plugin.up", Up: "plugin.up", Space: "plugin.toggle", i: "plugin.install",
  x: "plugin.uninstall", U: "plugin.updateAll", Esc: "plugin.close", "?": "help.toggle", ":": "palette.open" };
const KEY_MAP_5A = {
  searchResults: { wide: RESULTS_WIDE, narrow: Object.assign({}, RESULTS_WIDE, { h: "search.pluginsOverlay", Tab: "search.pluginsOverlay", "Shift-Tab": "search.pluginsOverlay" }) },
  searchPlugins: { wide: PLUGINS_WIDE, narrow: Object.assign({}, PLUGINS_WIDE, { Esc: "search.pluginsClose" }) },
  searchPluginList: { wide: PLUGIN_LIST, narrow: PLUGIN_LIST }
};

test("search: every key x Search pane x narrow resolves as pinned, and nothing else resolves", () => {
  for (const pane of SEARCH_PANES) {
    for (const width of ["wide", "narrow"]) {
      const want = KEY_MAP_5A[pane][width];
      for (const label of KEYS_5A) {
        const r = dispatch(state(Object.assign({ pane: pane, narrow: width === "narrow" }, SEARCH_ON)), evFor(label));
        assert.equal(r.commandId, want[label] || null, pane + " " + width + " " + label);
      }
    }
  }
});

test("search: 5a's keys never change a torrent or Settings pane's keys", () => {
  for (const pane of TORRENT_PANES.concat(ALL_SETTINGS_PANES)) {
    for (const label of ["d", "i", "U", "P"]) {
      const r = dispatch(state(Object.assign({ pane: pane, inspectorTab: pane === "inspector" ? "info" : "" }, ALL_ON, SEARCH_ON)), evFor(label));
      assert.equal(r.commandId, null, pane + " " + label);
    }
  }
});

test("search: Enter, y and d need a result and capture it frozen at key time", () => {
  for (const [label, id] of [["Enter", "search.add"], ["y", "search.copyLink"], ["d", "search.openPage"]]) {
    const res = Object.assign({}, SEARCH_ON.searchResult, { extra: { nested: true } });
    const r = dispatch(state({ pane: "searchResults", searchResult: res }), evFor(label));
    assert.equal(r.commandId, id, label);
    assert.equal(r.confirm, undefined, label + ": the window raises any confirm");
    assert.equal(r.state.mode, "NORMAL", label);
    assert.ok(Object.isFrozen(r.args.result), label);
    assert.equal(r.args.result.fileName, res.fileName);
    assert.equal(r.args.result.extra, undefined, "only plain fields are copied");
    res.fileName = "changed";
    assert.equal(r.args.result.fileName, SEARCH_ON.searchResult.fileName, "a later re-sort can't change it");
    const none = dispatch(state({ pane: "searchResults" }), evFor(label));
    assert.deepEqual([none.commandId, none.blocked], [null, "needs a result"], label);
  }
});

test("search: / needs an enabled plugin and says why (OV8); it never sets the mode itself", () => {
  const ok = dispatch(state({ pane: "searchResults", searchPluginCount: 1, searchEnabledPlugins: 1 }), evFor("/"));
  assert.deepEqual([ok.commandId, ok.state.mode], ["search.new", "NORMAL"], "the window opens the searchQuery INSERT");
  const off = dispatch(state({ pane: "searchPlugins", searchPluginCount: 3, searchEnabledPlugins: 0 }), evFor("/"));
  assert.deepEqual([off.commandId, off.blocked], [null, "all plugins are off (P)"]);
  const none = dispatch(state({ pane: "searchResults" }), evFor("/"));
  assert.deepEqual([none.commandId, none.blocked], [null, "no search plugins yet (P)"]);
});

test("search: over the api-down screen a blocked Search key names the down client, not its own need", () => {
  for (const [key, pane] of [["/", "searchResults"], ["c", "searchPlugins"], ["Enter", "searchResults"]]) {
    const down = dispatch(state({ pane, searchPluginCount: 3, searchEnabledPlugins: 0, searchDown: true }), evFor(key));
    assert.deepEqual([down.commandId, down.blocked], [null, "qBittorrent isn't reachable"], key);
  }
  assert.equal(Registry.preconditionMet("pluginsIdle", { searchDown: true }), false, "i and U are out while down, and say why");
  assert.equal(Registry.needsReason("pluginsIdle", { searchDown: true }), "qBittorrent isn't reachable");
  assert.equal(Registry.preconditionMet("pluginsIdle", {}), true);
  const up = dispatch(state({ pane: "searchPlugins", searchPluginCount: 3, searchEnabledPlugins: 0 }), evFor("/"));
  assert.equal(up.blocked, "all plugins are off (P)", "the down reason only while down");
});

test("search: the plugin overlay's Space and x need a plugin, and every write waits for a change still running", () => {
  const plugin = Object.assign({}, SEARCH_ON.searchPlugin);
  for (const [label, id] of [["Space", "plugin.toggle"], ["x", "plugin.uninstall"]]) {
    const r = dispatch(state({ pane: "searchPluginList", searchPlugin: plugin }), evFor(label));
    assert.equal(r.commandId, id, label);
    assert.deepEqual(r.args.plugin, SEARCH_ON.searchPlugin, label);
    assert.ok(Object.isFrozen(r.args.plugin));
    assert.equal(r.confirm, undefined, label + ": x's confirm is the window's");
    const none = dispatch(state({ pane: "searchPluginList" }), evFor(label));
    assert.deepEqual([none.commandId, none.blocked], [null, "needs a plugin"], label);
  }
  for (const [label, id] of [["i", "plugin.install"], ["U", "plugin.updateAll"]]) {
    const r = dispatch(state({ pane: "searchPluginList" }), evFor(label));
    assert.deepEqual([r.commandId, r.args], [id, {}], label + " works with no plugins");
  }
  for (const label of ["Space", "x", "i", "U"]) {
    const busy = dispatch(state({ pane: "searchPluginList", searchPlugin: plugin, searchPluginsBusy: true }), evFor(label));
    assert.deepEqual([busy.commandId, busy.blocked], [null, "wait for the plugin change to finish"], label);
  }
  // j/k and Esc still work while busy.
  assert.equal(dispatch(state({ pane: "searchPluginList", searchPluginsBusy: true }), evFor("j")).commandId, "plugin.down");
  assert.equal(dispatch(state({ pane: "searchPluginList", searchPluginsBusy: true }), evFor("Esc")).commandId, "plugin.close");
});

test("search: the new needs default unmet, with their reasons", () => {
  for (const need of ["searchResult", "searchPluginOn", "searchPlugin"]) assert.equal(Registry.preconditionMet(need, {}), false, need);
  assert.equal(Registry.preconditionMet("pluginsIdle", {}), true, "idle unless told otherwise");
  assert.equal(Registry.preconditionMet("searchPluginOn", { searchEnabledPlugins: "1" }), false, "a number, never a string");
  assert.equal(Registry.preconditionMet("searchResult", { searchResult: "x" }), false, "an object");
  assert.deepEqual(Registry.SEARCH_REASONS, { noResult: "needs a result", allOff: "all plugins are off (P)", noPlugins: "no search plugins yet (P)",
    noPlugin: "needs a plugin", busy: "wait for the plugin change to finish", down: "qBittorrent isn't reachable" });
  assert.equal(Registry.needsReason("searchResult", { searchResult: {} }), "");
});

// The palette shows Search's actions; its navigation rows stay hidden.
const SEARCH_PALETTE_VISIBLE = ["search.open", "search.new", "search.category", "search.add", "search.copyLink", "search.openPage", "search.sort", "search.sortReverse",
  "search.plugins", "plugin.toggle", "plugin.install", "plugin.uninstall", "plugin.updateAll", "plugin.copyListUrl"];

test("search: the palette lists the Search actions; navigation stays hidden; only the opener lives outside Search", () => {
  const rows = commands.filter((r) => /^(search|plugin)\./.test(r.id));
  assert.deepEqual(Array.from(new Set(rows.filter((r) => r.paletteHidden !== true).map((r) => r.id))).sort(), SEARCH_PALETTE_VISIBLE.slice().sort());
  for (const row of rows) {
    for (const p of row.panes) assert.ok(row.id === "search.open" ? TORRENT_PANES.includes(p) : SEARCH_PANES.includes(p), row.id + " " + p);
  }
  const copy = commands.find((r) => r.id === "plugin.copyListUrl");
  assert.deepEqual([copy.keys, copy.paletteOnly], [[], true]);
  assert.equal(Registry.SEARCH_PLUGIN_LIST_URL, "https://github.com/qbittorrent/search-plugins/wiki");
  assert.equal(Registry.dispatchCommand(state({ pane: "searchPluginList" }), "plugin.copyListUrl").commandId, "plugin.copyListUrl");
  assert.equal(Registry.dispatchCommand(state({ pane: "table" }), "plugin.copyListUrl").commandId, null);
});

test("search: ? lists each Search pane's keys, plus : and ?", () => {
  const ids = (pane, st) => Array.from(new Set(helpFor("NORMAL", pane, undefined, st).map((r) => r.id))).sort();
  assert.deepEqual(ids("searchResults", {}), ["help.toggle", "palette.open", "search.add", "search.back", "search.category", "search.copyLink", "search.down", "search.focusPlugins",
    "search.new", "search.openPage", "search.plugins", "search.sort", "search.sortReverse", "search.up"]);
  assert.ok(ids("searchResults", { narrow: true }).includes("search.pluginsOverlay"));
  assert.ok(!ids("searchResults", { narrow: true }).includes("search.focusPlugins"));
  assert.deepEqual(ids("searchPlugins", {}), ["help.toggle", "palette.open", "search.back", "search.category", "search.down", "search.focusResults", "search.new", "search.plugins", "search.up"]);
  assert.deepEqual(ids("searchPlugins", { narrow: true }), ["help.toggle", "palette.open", "search.category", "search.down", "search.focusResults", "search.new", "search.plugins",
    "search.pluginsClose", "search.up"]);
  assert.deepEqual(ids("searchPluginList", {}), ["help.toggle", "palette.open", "plugin.close", "plugin.down", "plugin.install", "plugin.toggle", "plugin.uninstall",
    "plugin.up", "plugin.updateAll"]);
  assert.ok(helpFor("NORMAL", "table").some((r) => r.id === "search.open"), "the torrent view's ? lists F");
  assert.ok(!helpFor("NORMAL", "table").some((r) => /^(search\.(?!open)|plugin\.)/.test(r.id)), "and none of Search's keys");
});

test("search: c opens the category picker (Ruling FB) from the results and the Plugins column, and needs an enabled plugin", () => {
  const row = commands.find((r) => r.id === "search.category");
  assert.deepEqual([row.keys, row.title, row.group, row.panes, row.needs, row.paletteHidden], [["c"], "Category", "App", ["searchResults", "searchPlugins"], "searchPluginOn", undefined]);
  for (const pane of ["searchResults", "searchPlugins"]) {
    const r = dispatch(state({ pane: pane, searchPluginCount: 2, searchEnabledPlugins: 1 }), evFor("c"));
    assert.deepEqual([r.commandId, r.args, r.state.mode], ["search.category", {}, "NORMAL"], pane + ": the Search view opens PICKER itself");
    const off = dispatch(state({ pane: pane, searchPluginCount: 2, searchEnabledPlugins: 0 }), evFor("c"));
    assert.deepEqual([off.commandId, off.blocked], [null, "all plugins are off (P)"], pane);
    const none = dispatch(state({ pane: pane }), evFor("c"));
    assert.deepEqual([none.commandId, none.blocked], [null, "no search plugins yet (P)"], pane);
  }
  assert.equal(dispatch(state({ pane: "searchPluginList", searchEnabledPlugins: 1 }), evFor("c")).commandId, null, "not in the plugins overlay");
  // The picker's own keys are the shared PICKER rows, live in every Search pane.
  for (const pane of SEARCH_PANES) {
    assert.equal(dispatch(state({ pane: pane, mode: "PICKER" }), evFor("Enter")).commandId, "picker.accept", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "PICKER" }), evFor("Esc")).commandId, "picker.cancel", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "PICKER" }), evFor("Down")).commandId, "picker.down", pane);
    assert.equal(dispatch(state({ pane: pane, mode: "PICKER", pickerQueryEmpty: true, pickerMulti: false }), evFor("Space")).commandId, null, pane + ": single choice");
  }
});

// --- Slice 5b0: per-view tables ---------------------------------------------

test("every view but the torrents has VIEW_META with a real opener", () => {
  for (const v of Registry.VIEWS.filter((v) => v !== "torrents")) {
    assert.ok(Registry.VIEW_META[v], v);
    assert.ok(Registry.commands.some((c) => c.id === Registry.VIEW_META[v].opener), v);
    assert.equal(typeof Registry.VIEW_META[v].listedOutside, "boolean", v);
  }
});
