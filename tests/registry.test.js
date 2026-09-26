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

test("x removes the torrent (no confirm for a single target)", () => {
  const r = dispatch(state({ hasTorrent: true }), ev("x", keyOf("x")));
  assert.equal(r.commandId, "torrent.remove");
  assert.equal(r.confirm, undefined);
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

test("2, 3 and 5 are reserved no-ops", () => {
  for (const d of ["2", "3", "5"]) {
    const r = dispatch(state(), ev(d, 0x30 + Number(d)));
    assert.equal(r.commandId, null, d);
    assert.equal(r.blocked, undefined, d);
  }
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

test("digits 2, 3 and 5 are no-ops in every pane", () => {
  for (const pane of ["table", "filters", "inspector"]) {
    for (const d of ["2", "3", "5"]) {
      const r = dispatch(state({ pane }), ev(d, 0x30 + Number(d)));
      assert.equal(r.commandId, null, pane + "/" + d);
    }
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
  // x in the filters pane: no row matches at all, so no `blocked` field.
  const r = dispatch(state({ pane: "filters", hasTorrent: false }), ev("x", keyOf("x")));
  assert.equal(r.commandId, null);
  assert.equal(r.blocked, undefined);
});

test("torrent.remove confirms only above one target", () => {
  const single = dispatch(state({ mode: "VISUAL", selectionCount: 1 }), ev("x", keyOf("x")));
  assert.equal(single.commandId, "torrent.remove");
  assert.equal(single.confirm, undefined);

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
  assert.equal(remove.commandId, "torrent.remove");
  assert.equal(remove.args.count, 1);
  assert.equal(remove.args.range, undefined);
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
  const validNeeds = ["none", "torrent", "selection"];
  for (const row of commands) {
    assert.ok(row.id === null || typeof row.id === "string");
    assert.equal(typeof row.title, "string");
    assert.ok(validGroups.includes(row.group), row.id + " group " + row.group);
    assert.ok(Array.isArray(row.keys) && row.keys.length > 0, row.id);
    assert.ok(Array.isArray(row.modes) && row.modes.length > 0, row.id);
    assert.ok(Array.isArray(row.panes) && row.panes.length > 0, row.id);
    assert.ok(validNeeds.includes(row.needs), row.id + " needs " + row.needs);
  }
});

// --- NORMAL, inspector pane: the Files tab list --------------------------

test("j/k/Down/Up and Space in the inspector pane are the file list's keys", () => {
  const s = state({ pane: "inspector", hasTorrent: true });
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
