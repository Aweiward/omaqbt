// Command table and a pure key dispatcher for the OmaqBT window.
//
// Loads in node (module.exports, for `node --test`) and in QML
// (`import "CommandRegistry.js" as Registry`), following Model.js's
// export pattern.
//
// `dispatch` is pure: no Date calls, no I/O. Everything it needs (the
// clock, the key event, the current mode/pane/selection) comes in through
// its arguments, and everything it produces comes back out in its return
// value. The caller (the window, in a later task) owns state and re-feeds
// the returned `state` into the next call.

// Qt key codes (Qt::Key, int form as QML's event.key delivers it).
// Verified against /usr/include/qt6/QtCore/qnamespace.h.
var KEY = {
  Escape: 0x01000000,
  Tab: 0x01000001,
  Backtab: 0x01000002,
  Return: 0x01000004,
  Enter: 0x01000005,
  Up: 0x01000013,
  Down: 0x01000015,
  Space: 0x20,
  H: 0x48,
  L: 0x4c,
  N: 0x4e,
  P: 0x50
};

var PREFIX_TIMEOUT_MS = 600;

// A magnet CONFIRM ignores Esc and n for this long after the window raised
// it (pending.at), so a reflexive Esc meant for what came before never
// cancels (deletes) the magnet. Enter and y are never ignored.
var MAGNET_GRACE_MS = 600;

// `panes` uses "*" for "any pane."
var PANE_ANY = "*";

// The command table. One row per binding in the spec's table. A command id
// can appear on more than one row (e.g. inspector.files is bound to both
// Enter in the table pane and 4 in any pane); helpFor() and dispatch() both
// read this same array, so there is exactly one source of truth.
//
// `keys` doubles as the display strings AND the machine-matchable tokens:
// each entry is either a literal printable character (matched against
// event.text) or one of a fixed vocabulary of special-key labels that
// matchLabel() below recognizes and matches against event.key/ctrl. This
// is a controlled vocabulary, not free-text parsing. The two-key sequences
// ("g g", "Esc Esc") are display-only; dispatch() implements those
// sequences directly rather than through the generic per-key matcher.
var commands = [
  // NORMAL, table (o, y, m and e also work from the inspector, whose Info
  // tab lists them; they act on the cursor torrent)
  { id: "cursor.down", title: "Down", group: "View", keys: ["j", "Down"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "none" },
  { id: "cursor.up", title: "Up", group: "View", keys: ["k", "Up"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "none" },
  { id: "cursor.top", title: "Top", group: "View", keys: ["g g"], modes: ["NORMAL"], panes: ["table"], needs: "none" },
  { id: "cursor.bottom", title: "Bottom", group: "View", keys: ["G"], modes: ["NORMAL"], panes: ["table"], needs: "none" },
  { id: "torrent.toggle", title: "Pause/resume", group: "Torrent", keys: ["Space"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "selection" },
  { id: "inspector.files", title: "Files", group: "View", keys: ["Enter"], modes: ["NORMAL"], panes: ["table"], needs: "none" },
  { id: "torrent.openFolder", title: "Open folder", group: "Torrent", keys: ["o"], modes: ["NORMAL"], panes: ["table", "inspector"], needs: "torrent" },
  { id: "torrent.remove", title: "Remove", group: "Torrent", keys: ["x"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "selection" },
  { id: "torrent.delete", title: "Delete with files", group: "Torrent", keys: ["X"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "selection" },
  { id: "torrent.copyMagnet", title: "Copy magnet", group: "Torrent", keys: ["y"], modes: ["NORMAL"], panes: ["table", "inspector"], needs: "torrent" },
  { id: "torrent.move", title: "Move", group: "Torrent", keys: ["m"], modes: ["NORMAL"], panes: ["table", "inspector"], needs: "torrent" },
  { id: "torrent.recheck", title: "Recheck", group: "Torrent", keys: ["e"], modes: ["NORMAL", "VISUAL"], panes: ["table", "inspector"], needs: "selection" },
  { id: "visual.enter", title: "Visual select", group: "View", keys: ["V"], modes: ["NORMAL"], panes: ["table"], needs: "torrent" },

  // NORMAL, any pane
  { id: "all.toggle", title: "Start/stop all", group: "Library", keys: ["t"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "sort.next", title: "Sort", group: "View", keys: ["s"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "sort.reverse", title: "Reverse sort", group: "View", keys: ["S"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "turtle.toggle", title: "Alt speed", group: "Library", keys: ["z"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "filter.text", title: "Filter", group: "View", keys: ["/"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "refresh", title: "Refresh", group: "Library", keys: ["r"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "inspector.info", title: "Info", group: "View", keys: ["1"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "inspector.files", title: "Files", group: "View", keys: ["4"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "inspector.trackers", title: "Trackers", group: "View", keys: ["2"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "inspector.peers", title: "Peers", group: "View", keys: ["3"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "inspector.chart", title: "Chart", group: "View", keys: ["5"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "pane.next", title: "Next pane", group: "View", keys: ["Tab", "Ctrl-l"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "pane.prev", title: "Prev pane", group: "View", keys: ["Shift-Tab", "Ctrl-h"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "help.toggle", title: "Help", group: "App", keys: ["?"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "window.close", title: "Close window", group: "App", keys: ["q"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "filter.clearText", title: "Clear filter", group: "View", keys: ["Esc"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "filter.reset", title: "Reset filters", group: "View", keys: ["Esc Esc"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "palette.open", title: "Command palette", group: "App", keys: [":"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },

  // COMMAND (the palette's TextField owns typing; these are the only keys
  // dispatch resolves itself).
  { id: "palette.close", title: "Close palette", group: "App", keys: ["Esc"], modes: ["COMMAND"], panes: [PANE_ANY], needs: "none" },
  { id: "palette.run", title: "Run", group: "App", keys: ["Enter"], modes: ["COMMAND"], panes: [PANE_ANY], needs: "none" },
  { id: "palette.up", title: "Up", group: "App", keys: ["Up", "Ctrl-p"], modes: ["COMMAND"], panes: [PANE_ANY], needs: "none" },
  { id: "palette.down", title: "Down", group: "App", keys: ["Down", "Ctrl-n"], modes: ["COMMAND"], panes: [PANE_ANY], needs: "none" },
  { id: "palette.complete", title: "Complete", group: "App", keys: ["Tab"], modes: ["COMMAND"], panes: [PANE_ANY], needs: "none" },

  // NORMAL, filters pane
  { id: "filter.down", title: "Down", group: "View", keys: ["j"], modes: ["NORMAL"], panes: ["filters"], needs: "none" },
  { id: "filter.up", title: "Up", group: "View", keys: ["k"], modes: ["NORMAL"], panes: ["filters"], needs: "none" },
  { id: "filter.apply", title: "Apply filter", group: "View", keys: ["Enter"], modes: ["NORMAL"], panes: ["filters"], needs: "none" },

  // NORMAL, inspector pane: the list the current tab shows (trackers,
  // peers or files; the window ignores these on Info). Space cycles a
  // file's priority like a widget click (Files only).
  { id: "file.down", title: "Next row", group: "View", keys: ["j", "Down"], modes: ["NORMAL"], panes: ["inspector"], needs: "none" },
  { id: "file.up", title: "Previous row", group: "View", keys: ["k", "Up"], modes: ["NORMAL"], panes: ["inspector"], needs: "none" },
  { id: "file.cycle", title: "Cycle file priority", group: "Torrent", keys: ["Space"], modes: ["NORMAL"], panes: ["inspector"], needs: "torrent" },

  // VISUAL (j/k/Space/x/X/e reuse the NORMAL,table rows above; this is the exit)
  { id: "visual.exit", title: "Exit visual", group: "View", keys: ["Esc", "V"], modes: ["VISUAL"], panes: ["table"], needs: "none" },

  // INSERT
  { id: "insert.cancel", title: "Cancel", group: "App", keys: ["Esc"], modes: ["INSERT"], panes: [PANE_ANY], needs: "none" },
  { id: "insert.commit", title: "Commit", group: "App", keys: ["Enter"], modes: ["INSERT"], panes: [PANE_ANY], needs: "none" },

  // CONFIRM (pending.kind "delete" or "remove"; a "magnet" CONFIRM resolves
  // its own keys, see dispatchMagnetConfirm). "confirm.accept" is
  // display-only: dispatch() resolves `y` to the pending command's own id,
  // never to this literal id.
  { id: "confirm.accept", title: "Confirm", group: "App", keys: ["y"], modes: ["CONFIRM"], panes: [PANE_ANY], needs: "none" },
  { id: "confirm.cancel", title: "Cancel", group: "App", keys: ["n", "Esc"], modes: ["CONFIRM"], panes: [PANE_ANY], needs: "none" }
];

// Commands that switch mode unconditionally when they fire.
var MODE_AFTER = {
  "visual.enter": "VISUAL",
  "visual.exit": "NORMAL",
  "filter.text": "INSERT",
  "insert.cancel": "NORMAL",
  "insert.commit": "NORMAL",
  "palette.open": "COMMAND",
  "palette.close": "NORMAL",
  "palette.run": "NORMAL"
};

// Commands that, when they fire while mode is VISUAL, end the visual
// selection (vim-style: an operator acting on a range leaves the range).
// Movement (cursor.down/up) is not here: it extends the range instead.
var EXITS_VISUAL = {
  "torrent.toggle": true,
  "torrent.remove": true,
  "torrent.delete": true,
  "torrent.recheck": true
};

var EXTEND_IDS = { "cursor.down": true, "cursor.up": true };

function assign(base, patch) {
  var out = {};
  var k;
  for (k in base) {
    if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
  }
  for (k in patch) {
    if (Object.prototype.hasOwnProperty.call(patch, k)) out[k] = patch[k];
  }
  return out;
}

function normalizeState(state) {
  var s = state || {};
  return {
    mode: s.mode || "NORMAL",
    pane: s.pane || "table",
    prefix: s.prefix || null,
    prefixAt: s.prefixAt || 0,
    hasTorrent: s.hasTorrent === true,
    selectionCount: typeof s.selectionCount === "number" ? s.selectionCount : 0,
    pending: s.pending || null,
    // The inspector's part (ClientView.inspectorDispatch): the tracker or
    // peer row under the inspector cursor ({kind, value, label} or null),
    // whether the trackers tab is focused, and the cursor torrent's
    // metadata / stopped / pending-browser-magnet flags.
    inspectorTarget: s.inspectorTarget || null,
    trackersTab: s.trackersTab === true,
    cursorNoMetadata: s.cursorNoMetadata === true,
    cursorStopped: s.cursorStopped === true,
    cursorPendingMagnet: s.cursorPendingMagnet === true
  };
}

function clearPrefix(s) {
  return assign(s, { prefix: null, prefixAt: 0 });
}

function withinPrefix(now, prefixAt) {
  return (now - prefixAt) <= PREFIX_TIMEOUT_MS;
}

// Matches one canonical key label against an event. Printable labels match
// on event.text (case carries g vs G, ? vs /, etc., for free); special
// labels match on event.key/modifiers.ctrl and ignore text entirely, even
// though Qt gives Escape/Return/Tab/Space/Ctrl-combos non-empty text too
// (e.g. "\u001b", "\r", "\t", " ", "\f").
function matchLabel(label, ev) {
  var text = ev.text || "";
  var mods = ev.modifiers || {};
  var ctrl = mods.ctrl === true;
  var key = ev.key;

  switch (label) {
    case "Tab": return key === KEY.Tab;
    case "Shift-Tab": return key === KEY.Backtab;
    case "Ctrl-l": return ctrl && key === KEY.L;
    case "Ctrl-h": return ctrl && key === KEY.H;
    case "Ctrl-p": return ctrl && key === KEY.P;
    case "Ctrl-n": return ctrl && key === KEY.N;
    case "Enter": return key === KEY.Return || key === KEY.Enter;
    case "Esc": return key === KEY.Escape;
    case "Up": return key === KEY.Up;
    case "Down": return key === KEY.Down;
    case "Space": return key === KEY.Space;
    default:
      return !ctrl && text !== "" && text === label;
  }
}

function paneMatches(row, pane) {
  return row.panes.indexOf(PANE_ANY) !== -1 || row.panes.indexOf(pane) !== -1;
}

function findMatch(s, ev) {
  var i, j, row, label;
  for (i = 0; i < commands.length; i++) {
    row = commands[i];
    if (row.modes.indexOf(s.mode) === -1) continue;
    if (!paneMatches(row, s.pane)) continue;
    for (j = 0; j < row.keys.length; j++) {
      label = row.keys[j];
      if (label === "g g" || label === "Esc Esc") continue;
      if (matchLabel(label, ev)) return row;
    }
  }
  return null;
}

function targetKind(s) {
  var t = s.inspectorTarget;
  return t && typeof t === "object" ? String(t.kind || "") : "";
}

// preconditionMet(needs, s): torrent/selection need a cursor torrent (or
// a VISUAL range); tracker/peer need that kind of row under the inspector
// cursor (s.inspectorTarget); trackersTab needs the trackers tab focused
// (even an empty list, so `a` can add the first tracker); noMetadata needs
// a cursor torrent without metadata that isn't a browser magnet still
// pending in the handler flow (that hash is already fetching).
function preconditionMet(needs, s) {
  if (!needs || needs === "none") return true;
  if (needs === "torrent") return s.hasTorrent === true;
  if (needs === "selection") return s.hasTorrent === true || (s.mode === "VISUAL" && s.selectionCount > 0);
  if (needs === "tracker") return targetKind(s) === "tracker";
  if (needs === "peer") return targetKind(s) === "peer";
  if (needs === "trackersTab") return s.trackersTab === true;
  if (needs === "noMetadata") return s.cursorNoMetadata === true && s.cursorPendingMagnet !== true;
  return true;
}

// needsReason(needs, s) -> why an unmet `needs` blocks a command: the
// dispatch `blocked` text and the palette's dimmed-row reason. "" when met.
function needsReason(needs, s) {
  if (preconditionMet(needs, s)) return "";
  if (needs === "tracker" || needs === "trackersTab") return "focus the trackers tab";
  if (needs === "peer") return "focus the peers tab";
  if (needs === "noMetadata") {
    if (s.cursorPendingMagnet === true) return "already fetching metadata";
    if (s.hasTorrent === true) return "already has metadata";
  }
  return "needs a selected torrent";
}

// How many torrents a "selection"/"torrent" command targets: the VISUAL
// range if there is one, otherwise the single cursor row. selectionCount
// only means anything while mode is VISUAL -- a range that outlived its
// visual session (state.selectionCount left stale after leaving VISUAL)
// must never be read as a range here.
function confirmCount(s) {
  if (s.mode === "VISUAL" && s.selectionCount > 0) return s.selectionCount;
  return s.hasTorrent ? 1 : 0;
}

// Inspector commands that confirm, by id -> their pending/confirm kind.
// Each acts on the row captured into args.target at key time.
var TARGET_CONFIRM_KINDS = { "tracker.remove": "trackerRemove", "peer.ban": "peerBan" };

function needsConfirm(id, s) {
  if (id === "torrent.delete") return true;
  if (id === "torrent.remove") return true;
  if (Object.prototype.hasOwnProperty.call(TARGET_CONFIRM_KINDS, id)) return true;
  return false;
}

function copyTarget(t) {
  if (!t || typeof t !== "object") return null;
  // Frozen: pending.target, pending.args.target and confirm.target share
  // it, and none of their consumers may change what `y` acts on.
  return Object.freeze({ kind: String(t.kind || ""), value: String(t.value === undefined || t.value === null ? "" : t.value), label: String(t.label === undefined || t.label === null ? "" : t.label) });
}

function buildArgs(row, s) {
  var args = {};
  // A tracker/peer command acts on the row under the inspector cursor as
  // it stood when the key was pressed (a copy: a later refresh that moves
  // or drops the row can't change what `y` acts on).
  if (row.needs === "tracker" || row.needs === "peer") {
    args.target = copyTarget(s.inspectorTarget);
  }
  if (EXTEND_IDS[row.id] === true && s.mode === "VISUAL") {
    args.extend = true;
  }
  if (row.needs === "torrent" || row.needs === "selection") {
    args.count = confirmCount(s);
    if (s.mode === "VISUAL" && s.selectionCount > 0) args.range = true;
  }
  return args;
}

// A browser-magnet confirm (pending.kind "magnet", raised by the window,
// not by a key): Enter or y asks to start it, Esc or n to cancel it, and
// every other key does nothing. The state stays CONFIRM either way: the
// window leaves it once the magnet is handled, and can refuse the start
// while the name is still being fetched. Within MAGNET_GRACE_MS of
// pending.at (when the window raised it; 0 or absent for no grace), Esc
// and n do nothing too.
function dispatchMagnetConfirm(s, ev) {
  var ctrl = (ev.modifiers || {}).ctrl === true;
  var text = ev.text || "";
  if ((!ctrl && text === "y") || matchLabel("Enter", ev)) {
    return { state: s, commandId: "magnet.start", args: {} };
  }
  if ((!ctrl && text === "n") || ev.key === KEY.Escape) {
    var at = Number((s.pending || {}).at) || 0;
    if (at > 0 && (Number(ev.now) || 0) - at < MAGNET_GRACE_MS) return { state: s, commandId: null };
    return { state: s, commandId: "magnet.cancel", args: {} };
  }
  return { state: s, commandId: null };
}

function dispatchConfirm(s, ev) {
  var mods = ev.modifiers || {};
  var ctrl = mods.ctrl === true;
  var text = ev.text || "";
  var pending = s.pending || null;
  if (pending && pending.kind === "magnet") return dispatchMagnetConfirm(s, ev);
  // Resolving CONFIRM always lands in NORMAL. If the command that led here
  // was raised from VISUAL, its range must not survive into NORMAL (see
  // confirmCount/buildArgs) -- so this clears selectionCount unconditionally,
  // which is a no-op when it was already 0 (a NORMAL-mode confirm, e.g.
  // torrent.delete on a single cursor row).
  var resetState = assign(s, { mode: "NORMAL", pending: null, prefix: null, prefixAt: 0, selectionCount: 0 });

  if (!ctrl && text === "y") {
    if (!pending) {
      return { state: resetState, commandId: null };
    }
    return {
      state: resetState,
      commandId: pending.commandId,
      args: assign(pending.args || {}, { confirmed: true })
    };
  }

  if ((!ctrl && text === "n") || ev.key === KEY.Escape) {
    return { state: resetState, commandId: "confirm.cancel", args: {} };
  }

  return { state: s, commandId: null };
}

// dispatch(state, event) -> {state, commandId, args?, blocked?, confirm?}
//
// Pure: reads only `state` and `event`, does no I/O, calls no Date/Math.random.
// `event.now` (ms) drives the g-prefix and Esc-Esc timeouts; dispatch never
// reads the clock itself.
function dispatch(state, event) {
  var s = normalizeState(state);
  var ev = event || {};

  if (s.mode === "CONFIRM") {
    return dispatchConfirm(s, ev);
  }

  var mods = ev.modifiers || {};
  var ctrl = mods.ctrl === true;
  var text = ev.text || "";
  var now = ev.now || 0;

  // Continue an active "g" prefix (cursor.top).
  if (s.prefix === "g") {
    if (withinPrefix(now, s.prefixAt) && !ctrl && text === "g") {
      return { state: clearPrefix(s), commandId: "cursor.top", args: {} };
    }
    s = clearPrefix(s);
  }

  // Continue an active "Esc" prefix (filter.reset).
  if (s.prefix === "Esc") {
    if (withinPrefix(now, s.prefixAt) && ev.key === KEY.Escape) {
      return { state: clearPrefix(s), commandId: "filter.reset", args: {} };
    }
    s = clearPrefix(s);
  }

  // Start a "g" prefix. Only meaningful in NORMAL/table, where cursor.top
  // lives; elsewhere a lone "g" simply falls through to "no match."
  if (s.mode === "NORMAL" && s.pane === "table" && !ctrl && text === "g") {
    return { state: assign(s, { prefix: "g", prefixAt: now }), commandId: null };
  }

  var row = findMatch(s, ev);
  if (!row || row.id === null) {
    return { state: clearPrefix(s), commandId: null };
  }

  return resolveRow(s, row, now);
}

// resolveRow(s, row, now) -> the dispatch result for a matched command row:
// the precondition check, args, CONFIRM for destructive commands, and the
// mode it leaves behind. Shared by dispatch() (a key) and dispatchCommand()
// (the palette), so the two can never resolve a command differently.
function resolveRow(s, row, now) {
  if (!preconditionMet(row.needs, s)) {
    return { state: clearPrefix(s), commandId: null, blocked: needsReason(row.needs, s) };
  }

  var args = buildArgs(row, s);

  if (needsConfirm(row.id, s) && Object.prototype.hasOwnProperty.call(TARGET_CONFIRM_KINDS, row.id)) {
    var kind = TARGET_CONFIRM_KINDS[row.id];
    var tpending = { kind: kind, commandId: row.id, args: args, target: args.target };
    return {
      state: assign(clearPrefix(s), { mode: "CONFIRM", pending: tpending }),
      commandId: null,
      confirm: { commandId: row.id, kind: kind, label: args.target.label, target: args.target }
    };
  }

  if (needsConfirm(row.id, s)) {
    var count = confirmCount(s);
    var withFiles = row.id === "torrent.delete";
    var pending = { kind: withFiles ? "delete" : "remove", commandId: row.id, args: args, count: count, withFiles: withFiles };
    return {
      state: assign(clearPrefix(s), { mode: "CONFIRM", pending: pending }),
      commandId: null,
      confirm: { commandId: row.id, count: count, withFiles: withFiles }
    };
  }

  var nextState = clearPrefix(s);
  if (row.id === "filter.clearText") {
    nextState = assign(nextState, { prefix: "Esc", prefixAt: now });
  }
  if (Object.prototype.hasOwnProperty.call(MODE_AFTER, row.id)) {
    nextState = assign(nextState, { mode: MODE_AFTER[row.id] });
  }
  if (EXITS_VISUAL[row.id] === true && s.mode === "VISUAL") {
    nextState = assign(nextState, { mode: "NORMAL" });
  }
  // Leaving VISUAL (via visual.exit or an EXITS_VISUAL action) drops the
  // range. Without this, a stale selectionCount would leak range semantics
  // into the NORMAL mode that follows (see confirmCount/buildArgs).
  if (s.mode === "VISUAL" && nextState.mode === "NORMAL") {
    nextState = assign(nextState, { selectionCount: 0 });
  }

  return { state: nextState, commandId: row.id, args: args };
}

// dispatchCommand(state, commandId) -> the same result dispatch() gives
// for a key bound to `commandId` in state's mode and pane (the command
// palette runs a command by id, not by key). No row for that id in this
// mode/pane resolves to no command, as an unbound key would.
function dispatchCommand(state, commandId) {
  var s = clearPrefix(normalizeState(state));
  for (var i = 0; i < commands.length; i++) {
    var row = commands[i];
    if (row.id === null || row.id !== commandId) continue;
    if (row.modes.indexOf(s.mode) === -1 || !paneMatches(row, s.pane)) continue;
    return resolveRow(s, row, 0);
  }
  return { state: s, commandId: null };
}

// helpFor(mode, pane) -> rows from `commands` active for that mode/pane,
// generated from the same table dispatch() reads. Reserved (id === null)
// rows are not commands, so they are left out.
function helpFor(mode, pane) {
  var out = [];
  var i, row;
  for (i = 0; i < commands.length; i++) {
    row = commands[i];
    if (row.id === null) continue;
    if (row.modes.indexOf(mode) === -1) continue;
    if (!paneMatches(row, pane)) continue;
    out.push(row);
  }
  return out;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    KEY: KEY,
    MAGNET_GRACE_MS: MAGNET_GRACE_MS,
    commands: commands,
    dispatch: dispatch,
    dispatchCommand: dispatchCommand,
    helpFor: helpFor,
    preconditionMet: preconditionMet,
    needsReason: needsReason,
    needsConfirm: needsConfirm,
    paneMatches: paneMatches
  };
}
