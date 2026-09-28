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
  // C and T (slice 3a): the category and tag pickers on the cursor row or
  // the VISUAL range (the window captures the targets at key time). Both
  // open PICKER; C's Enter may raise a move CONFIRM (G8).
  { id: "torrent.category", title: "Set category", group: "Torrent", keys: ["C"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "selection" },
  { id: "torrent.tags", title: "Edit tags", group: "Torrent", keys: ["T"], modes: ["NORMAL", "VISUAL"], panes: ["table"], needs: "selection" },
  // The palette's bulk limits (slice 3b, L5): INSERT on the cursor row or
  // the VISUAL range (the window captures the targets at key time, or when
  // ":" opened the palette on a range). paletteOnly: no key reaches them
  // (keys is empty) and `?` leaves them out.
  { id: "limit.setDownload", title: "Set download limit", group: "Torrent", keys: [], paletteOnly: true, modes: ["NORMAL", "VISUAL"], panes: ["table", "inspector"], needs: "selection" },
  { id: "limit.setUpload", title: "Set upload limit", group: "Torrent", keys: [], paletteOnly: true, modes: ["NORMAL", "VISUAL"], panes: ["table", "inspector"], needs: "selection" },
  { id: "limit.setRatio", title: "Set ratio limit", group: "Torrent", keys: [], paletteOnly: true, modes: ["NORMAL", "VISUAL"], panes: ["table", "inspector"], needs: "selection" },

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
  { id: "help.toggle", title: "Help", group: "App", keys: ["?"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none", inSettings: true },
  { id: "window.close", title: "Close window", group: "App", keys: ["q"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "filter.clearText", title: "Clear filter", group: "View", keys: ["Esc"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  { id: "filter.reset", title: "Reset filters", group: "View", keys: ["Esc Esc"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "none" },
  // From VISUAL too (Task 6): the palette then runs a range command on the
  // range (args.range tells the window to keep what it captured).
  { id: "palette.open", title: "Command palette", group: "App", keys: [":"], modes: ["NORMAL", "VISUAL"], panes: [PANE_ANY], needs: "none", inSettings: true },

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

  // NORMAL, filters pane: manage the category or tag under the filters
  // cursor (slice 3a; the 2b trackers-tab verbs). The row is captured at
  // key time (args.target, from s.libraryTarget: {kind: "category"|"tag",
  // value: name, label}); value "" is Uncategorized/Untagged, where only
  // `a` (add to that group) applies. x always confirms.
  { id: "library.add", title: "New category or tag", group: "Library", keys: ["a"], modes: ["NORMAL"], panes: ["filters"], needs: "libraryGroup" },
  { id: "library.rename", title: "Rename category or tag", group: "Library", keys: ["c"], modes: ["NORMAL"], panes: ["filters"], needs: "libraryName" },
  { id: "library.path", title: "Category save path", group: "Library", keys: ["p"], modes: ["NORMAL"], panes: ["filters"], needs: "categoryName" },
  { id: "library.remove", title: "Delete category or tag", group: "Library", keys: ["x"], modes: ["NORMAL"], panes: ["filters"], needs: "libraryName" },

  // NORMAL, inspector pane: the list the current tab shows (trackers,
  // peers or files). Space cycles a file's priority like a widget click
  // (Files only). `tabs` (D7) is what tells file.down/up apart from the
  // Info tab's limit.down/up below: findMatch (see tabMatches) skips a row
  // whose tabs doesn't include the focused inspector tab, so j/k/Space
  // never fall through from one tab's rows to another's.
  { id: "file.down", title: "Next row", group: "View", keys: ["j", "Down"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["files", "trackers", "peers"], needs: "none" },
  { id: "file.up", title: "Previous row", group: "View", keys: ["k", "Up"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["files", "trackers", "peers"], needs: "none" },
  { id: "file.cycle", title: "Cycle file priority", group: "Torrent", keys: ["Space"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["files"], needs: "torrent" },
  // Deviation 3 on Info (Ruling CJ): a no-metadata torrent's Space is
  // Start download -- file.cycle's handler starts a stopped one and never
  // stops a running one -- unless the Limits cursor is on a toggle row,
  // where limit.toggle wins. `when` (see WHEN) makes it a match-level rule,
  // so `?` and the palette see it too. This row comes after the Files row:
  // the palette reads a command's title and tabs from its first row.
  { id: "file.cycle", title: "Start download", group: "Torrent", keys: ["Space"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["info"], needs: "torrent", when: "startDownload" },

  // NORMAL, inspector pane, Info tab only: the Limits group's cursor (D7).
  // limit.edit and limit.toggle need a row/toggle row under the Limits
  // cursor (limitCursorKey/limitToggle, from ClientView.inspectorDispatch),
  // and act on it as it stood at key time (args.limitKey). Space on a
  // value row is blocked with no note (D12: never torrent.toggle, which
  // the inspector pane never binds Space to).
  { id: "limit.down", title: "Next limit", group: "View", keys: ["j", "Down"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["info"], needs: "none" },
  { id: "limit.up", title: "Previous limit", group: "View", keys: ["k", "Up"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["info"], needs: "none" },
  { id: "limit.edit", title: "Edit limit", group: "Torrent", keys: ["Enter"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["info"], needs: "limitRow" },
  { id: "limit.toggle", title: "Toggle limit", group: "Torrent", keys: ["Space"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["info"], needs: "limitToggle", when: "limitSpace" },

  // NORMAL, inspector pane, trackers tab only (Deviation 4: R too). a and
  // R work on an empty list; c and x act on the tracker under the cursor,
  // captured at key time (args.target). x means "remove this tracker" and
  // never removes a torrent (torrent.remove is table-only).
  { id: "tracker.reannounce", title: "Reannounce", group: "Torrent", keys: ["R"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["trackers"], needs: "trackersTab" },
  { id: "tracker.add", title: "Add tracker", group: "Torrent", keys: ["a"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["trackers"], needs: "trackersTab" },
  { id: "tracker.edit", title: "Change tracker URL", group: "Torrent", keys: ["c"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["trackers"], needs: "tracker" },
  { id: "tracker.remove", title: "Remove tracker", group: "Torrent", keys: ["x"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["trackers"], needs: "tracker" },

  // NORMAL, inspector pane, peers tab only: ban the peer under the cursor
  // (captured at key time, CONFIRM). The ban is global: it goes on
  // qBittorrent's IP ban list.
  { id: "peer.ban", title: "Ban peer", group: "Torrent", keys: ["b"], modes: ["NORMAL"], panes: ["inspector"], tabs: ["peers"], needs: "peer" },

  // NORMAL, any pane: swap a stopped no-metadata torrent for its magnet
  // with stopCondition MetadataReceived (qbt fetch-metadata, F4).
  { id: "torrent.fetchMetadata", title: "Fetch metadata only", group: "Torrent", keys: ["f"], modes: ["NORMAL"], panes: [PANE_ANY], needs: "noMetadata" },

  // Settings (slice 4a, eng D6). `,` (or ":Settings" in the palette)
  // swaps the torrent panes for the Settings view; its two columns are the
  // panes settingsSections and settingsKeys. Inside them the any-pane rows
  // above are dead except : and ? (inSettings, see paneMatches). The
  // navigation rows are paletteHidden: the palette lists only "Settings".
  { id: "settings.open", title: "Settings", group: "App", keys: [","], modes: ["NORMAL"], panes: ["filters", "table", "inspector"], needs: "none" },
  { id: "settings.down", title: "Down", group: "View", keys: ["j", "Down"], modes: ["NORMAL"], panes: ["settingsSections", "settingsKeys"], needs: "none", paletteHidden: true },
  { id: "settings.up", title: "Up", group: "View", keys: ["k", "Up"], modes: ["NORMAL"], panes: ["settingsSections", "settingsKeys"], needs: "none", paletteHidden: true },
  // Choosing a section: in a narrow window (slice 4b, D13) the sections
  // column is the overlay, and the window closes it and focuses the settings.
  { id: "settings.enter", title: "Go to the settings", group: "View", keys: ["l", "Enter", "Tab"], modes: ["NORMAL"], panes: ["settingsSections"], needs: "none", paletteHidden: true },
  // Narrow (slice 4b, design D6 and eng D13): below the breakpoint the
  // sections are a chip over the settings, and Tab, h and Shift-Tab open
  // them as an overlay (the window focuses settingsSections while it
  // shows). `when` makes these rows exist only while narrow, so h and
  // Shift-Tab fall through to settings.leave (when: "wide") otherwise.
  { id: "settings.sections", title: "Sections", group: "View", keys: ["Tab", "h", "Shift-Tab"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "narrow", when: "narrow", paletteHidden: true },
  { id: "settings.leave", title: "Back to the sections", group: "View", keys: ["h", "Shift-Tab"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "none", when: "wide", paletteHidden: true },
  { id: "settings.search", title: "Search all settings", group: "View", keys: ["/"], modes: ["NORMAL"], panes: ["settingsSections", "settingsKeys"], needs: "none", paletteHidden: true },
  // Narrow: Esc in the sections overlay closes it first (D13), before
  // settings.back could clear a search or leave Settings.
  { id: "settings.sectionsClose", title: "Close the sections", group: "View", keys: ["Esc"], modes: ["NORMAL"], panes: ["settingsSections"], needs: "narrow", when: "narrow", paletteHidden: true },
  // Esc clears an active search first, then leaves Settings (the window
  // decides which; the registry only names the key). Two rows so the
  // sections' one can step aside for settingsSectionsClose while narrow.
  { id: "settings.back", title: "Clear search, or back to torrents", group: "App", keys: ["Esc"], modes: ["NORMAL"], panes: ["settingsSections"], needs: "none", when: "wide", paletteHidden: true },
  { id: "settings.back", title: "Clear search, or back to torrents", group: "App", keys: ["Esc"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "none", paletteHidden: true },
  // Task 6: the editors, on the setting under the cursor as it stood at
  // key time (args.settingKey). toggleRow/editableRow come from the window
  // (SettingsCommands.flags: SettingsView.editorFor, and no write of that
  // key still saving); a row with no editor is blocked with no note (its
  // help line says why). Their CONFIRM's `y` resolves to settings.write,
  // which has no row at all, so no key and no palette entry can reach it.
  { id: "settings.toggle", title: "Toggle the setting", group: "App", keys: ["Space"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "toggleRow", paletteHidden: true },
  // Slice 4b: Enter on a list row (the schema's listKind: add_trackers,
  // excluded_file_names; banned IPs) opens the list editor, pane
  // settingsList. Before settings.edit, and `when`-gated, so on any other
  // row Enter falls through to settings.edit as in 4a. args.settingKey is
  // the list's key at key time.
  { id: "settings.openList", title: "Open the list", group: "App", keys: ["Enter"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "listRow", when: "listRow", paletteHidden: true },
  { id: "settings.edit", title: "Edit the setting", group: "App", keys: ["Enter"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "editableRow", paletteHidden: true },
  // Slice 4b (design D8): x clears the secret under the cursor when it's
  // one of the schema's secretWritable keys and is set (s.settingsSecretSet,
  // from the window). The window asks first: it raises the CONFIRM with
  // raiseConfirm(state, "settings.clearSecret", ...), whose y comes back
  // here with confirmed: true. A key never carries confirmed.
  { id: "settings.clearSecret", title: "Clear the secret", group: "App", keys: ["x"], modes: ["NORMAL"], panes: ["settingsKeys"], needs: "secretSet" },
  // Slice 4b (design D3): u steps back through this visit's changes, from
  // the settings and from a list. s.settingsUndoCount is how many are left.
  { id: "settings.undo", title: "Undo the last settings change", group: "App", keys: ["u"], modes: ["NORMAL"], panes: ["settingsKeys", "settingsList"], needs: "undoEntry" },

  // Slice 4b: the list editor (pane settingsList) for the list key
  // s.settingsKey. a adds a line; x removes the line under the list cursor
  // (s.listItem, captured at key time as args.listItem), with no confirm:
  // u undoes it; Esc goes back. listEditable is false while a write of
  // that list is saving.
  { id: "list.down", title: "Down", group: "View", keys: ["j", "Down"], modes: ["NORMAL"], panes: ["settingsList"], needs: "none", paletteHidden: true },
  { id: "list.up", title: "Up", group: "View", keys: ["k", "Up"], modes: ["NORMAL"], panes: ["settingsList"], needs: "none", paletteHidden: true },
  { id: "list.add", title: "Add to the list", group: "App", keys: ["a"], modes: ["NORMAL"], panes: ["settingsList"], needs: "listEditable" },
  { id: "list.remove", title: "Remove from the list", group: "App", keys: ["x"], modes: ["NORMAL"], panes: ["settingsList"], needs: "listItem" },
  { id: "list.back", title: "Back to the settings", group: "View", keys: ["Esc"], modes: ["NORMAL"], panes: ["settingsList"], needs: "none", paletteHidden: true },

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
  { id: "confirm.cancel", title: "Cancel", group: "App", keys: ["n", "Esc"], modes: ["CONFIRM"], panes: [PANE_ANY], needs: "none" },

  // PICKER (slice 3a: ListOverlay in picker mode, C's category picker and
  // T's tag picker). The overlay's TextField owns typing; these are the
  // only keys dispatch resolves itself, mirroring COMMAND. Space and Tab
  // both raise "picker.toggle" but only when a toggle means something:
  // Space needs an empty query AND a multi-select picker (else it's a
  // character to type); Tab needs only multi-select (Review Focus 5).
  // Those two conditions can't be expressed as a plain row match, so
  // dispatch() gates them itself, before the row ever matches (see the
  // PICKER branch below); the rows below cover only the unconditional keys.
  { id: "picker.accept", title: "Select", group: "App", keys: ["Enter"], modes: ["PICKER"], panes: [PANE_ANY], needs: "none" },
  { id: "picker.cancel", title: "Cancel", group: "App", keys: ["Esc"], modes: ["PICKER"], panes: [PANE_ANY], needs: "none" },
  { id: "picker.up", title: "Up", group: "App", keys: ["Up", "Ctrl-p"], modes: ["PICKER"], panes: [PANE_ANY], needs: "none" },
  { id: "picker.down", title: "Down", group: "App", keys: ["Down", "Ctrl-n"], modes: ["PICKER"], panes: [PANE_ANY], needs: "none" },
  { id: "picker.toggle", title: "Toggle", group: "App", keys: ["Space", "Tab"], modes: ["PICKER"], panes: [PANE_ANY], needs: "none" }
];

// Commands that switch mode unconditionally when they fire.
var MODE_AFTER = {
  "visual.enter": "VISUAL",
  "visual.exit": "NORMAL",
  "filter.text": "INSERT",
  "settings.search": "INSERT",
  "insert.cancel": "NORMAL",
  "insert.commit": "NORMAL",
  "palette.open": "COMMAND",
  "palette.close": "NORMAL",
  "palette.run": "NORMAL",
  "torrent.category": "PICKER",
  "torrent.tags": "PICKER",
  "picker.accept": "NORMAL",
  "picker.cancel": "NORMAL"
};

// Commands that, when they fire while mode is VISUAL, end the visual
// selection (vim-style: an operator acting on a range leaves the range).
// Movement (cursor.down/up) is not here: it extends the range instead.
var EXITS_VISUAL = {
  "torrent.toggle": true,
  "torrent.remove": true,
  "torrent.delete": true,
  "torrent.recheck": true,
  "limit.setDownload": true,
  "limit.setUpload": true,
  "limit.setRatio": true
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
    cursorPendingMagnet: s.cursorPendingMagnet === true,
    // The inspector's currently shown tab ("info"/"trackers"/"peers"/
    // "files"/"chart", "" when the inspector isn't focused): what `tabs`
    // (D7) matches against. The Info tab's Limits cursor: the row key under
    // it ("dlLimit" ... "firstLast", null for none) and whether it's a
    // toggle row (Sequential, First/last).
    inspectorTab: typeof s.inspectorTab === "string" ? s.inspectorTab : "",
    limitCursorKey: s.limitCursorKey || null,
    limitToggle: s.limitToggle === true,
    // The filters pane's part (ClientView.libraryTarget): the category or
    // tag row under the filters cursor, or null.
    libraryTarget: s.libraryTarget || null,
    // PICKER (slice 3a): the overlay's own query-empty and multi-select
    // flags, read fresh from the caller each dispatch (ListOverlay/the
    // picker never keep their own copy of these -- see the PICKER rows).
    pickerQueryEmpty: s.pickerQueryEmpty === true,
    pickerMulti: s.pickerMulti === true,
    // Settings (Task 6): the key under the settings cursor, and whether it
    // toggles (Space) or edits (Enter) right now. Default off.
    settingsKey: s.settingsKey || null,
    settingsToggle: s.settingsToggle === true,
    settingsEditable: s.settingsEditable === true,
    // Slice 4b, all default off. settingsListRow: the cursor row is a list
    // key (Enter opens it). settingsSecretSet: the cursor row is a
    // secretWritable secret that's set and not saving (x clears it).
    // settingsUndoCount: entries left in this visit's undo history.
    // listEditable: the open list can be written (not saving). listItem:
    // the line under the list cursor, {index, value, tierBreak}, or null.
    // narrow: the window is below the breakpoint (D13).
    settingsListRow: s.settingsListRow === true,
    settingsSecretSet: s.settingsSecretSet === true,
    settingsUndoCount: typeof s.settingsUndoCount === "number" ? s.settingsUndoCount : 0,
    listEditable: s.listEditable === true,
    listItem: s.listItem && typeof s.listItem === "object" ? s.listItem : null,
    narrow: s.narrow === true
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

// The Settings view's two columns (slice 4a) and the list editor (4b).
var SETTINGS_PANES = ["settingsSections", "settingsKeys", "settingsList"];

function isSettingsPane(pane) {
  return SETTINGS_PANES.indexOf(pane) !== -1;
}

// paneMatches(row, pane) -> whether row's panes cover pane. PANE_ANY means
// any torrent pane. Inside Settings it covers only a row marked inSettings
// (: and ?) and the modal rows -- those with no NORMAL or VISUAL mode
// (INSERT, COMMAND, CONFIRM, PICKER), which their mode already gates. So
// t, s, z, r, q, 1-5, Tab, Esc, f and the rest can't act on the hidden
// torrents from Settings (the any-pane audit, pinned by node tests).
function paneMatches(row, pane) {
  if (row.panes.indexOf(pane) !== -1) return true;
  if (row.panes.indexOf(PANE_ANY) === -1) return false;
  if (!isSettingsPane(pane)) return true;
  if (row.inSettings === true) return true;
  return row.modes.indexOf("NORMAL") === -1 && row.modes.indexOf("VISUAL") === -1;
}

// tabMatches(row, tab) -> whether row.tabs (D7) covers the inspector's
// current tab. A row with no `tabs` (everything outside the inspector
// pane, and o/y/m/e/f inside it) is never tab-scoped, so it always matches.
function tabMatches(row, tab) {
  return !row.tabs || row.tabs.indexOf(tab) !== -1;
}

// A row's optional `when` (Ruling CJ): a named condition on the dispatch
// state that must hold for the row to exist at all -- unlike `needs`, a
// failed `when` doesn't block the key, it lets the next row have it.
// findMatch, findMatchIgnoringTabs, dispatchCommand and helpFor all apply
// it, so a key, the palette and `?` agree. startDownload: Info's Space on
// a no-metadata torrent, unless the Limits cursor is on a toggle row;
// limitSpace is its complement, so `?` lists one Space on Info.
// narrow/wide (slice 4b, D13): the Settings rows remapped below the
// breakpoint, and the rows they replace. listRow: Enter opens a list.
var WHEN = {
  startDownload: function(s) { return s.cursorNoMetadata === true && s.limitToggle !== true; },
  limitSpace: function(s) { return !(s.cursorNoMetadata === true && s.limitToggle !== true); },
  narrow: function(s) { return s.narrow === true; },
  wide: function(s) { return s.narrow !== true; },
  listRow: function(s) { return s.settingsListRow === true; }
};

function whenMatches(row, s) {
  return !row.when || (Object.prototype.hasOwnProperty.call(WHEN, row.when) && WHEN[row.when](s) === true);
}

// findMatch(s, ev) -> the row a key resolves to: the first row matching
// mode, pane, key AND (D7) tab (and its `when`, if any). A row that matches everything but the tab
// (e.g. x pressed off the trackers tab) is not returned here -- see
// findMatchIgnoringTabs, which dispatch() consults only to keep reporting
// that row's own `needs` reason, never to run it.
function findMatch(s, ev) {
  var i, j, row, label;
  for (i = 0; i < commands.length; i++) {
    row = commands[i];
    if (row.modes.indexOf(s.mode) === -1) continue;
    if (!paneMatches(row, s.pane)) continue;
    if (!tabMatches(row, s.inspectorTab)) continue;
    if (!whenMatches(row, s)) continue;
    for (j = 0; j < row.keys.length; j++) {
      label = row.keys[j];
      if (label === "g g" || label === "Esc Esc") continue;
      if (matchLabel(label, ev)) return row;
    }
  }
  return null;
}

// findMatchIgnoringTabs(s, ev) -> the same search, but blind to `tabs`:
// exactly what findMatch would have returned before D7 existed. dispatch()
// uses this only when the tab-aware search above found nothing, so a key
// that's genuinely bound elsewhere in this pane (just not on this tab)
// keeps naming why it's blocked (needsReason), instead of going silent.
function findMatchIgnoringTabs(s, ev) {
  var i, j, row, label;
  for (i = 0; i < commands.length; i++) {
    row = commands[i];
    if (row.modes.indexOf(s.mode) === -1) continue;
    if (!paneMatches(row, s.pane)) continue;
    if (!whenMatches(row, s)) continue;
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

// The filters cursor's category/tag row: "group" (any row of the
// Categories or Tags group, Uncategorized/Untagged included), "name" (a
// named category or tag), "category" (a named category), or "".
function libraryKind(s, want) {
  var t = s.libraryTarget;
  if (!t || typeof t !== "object") return false;
  var kind = String(t.kind || "");
  if (kind !== "category" && kind !== "tag") return false;
  if (want === "group") return true;
  if (String(t.value === undefined || t.value === null ? "" : t.value) === "") return false;
  return want === "name" || kind === "category";
}

var LIBRARY_NEEDS = { libraryGroup: "group", libraryName: "name", categoryName: "category" };

// preconditionMet(needs, s): torrent/selection need a cursor torrent (or
// a VISUAL range); tracker/peer need that kind of row under the inspector
// cursor (s.inspectorTarget); trackersTab needs the trackers tab focused
// (even an empty list, so `a` can add the first tracker); noMetadata needs
// a cursor torrent without metadata that isn't a browser magnet still
// pending in the handler flow (that hash is already fetching); limitRow
// needs a row under the Info tab's Limits cursor (s.limitCursorKey);
// limitToggle needs that row to be a toggle (s.limitToggle); both come
// from ClientView.inspectorDispatch and default unmet.
function preconditionMet(needs, s) {
  if (!needs || needs === "none") return true;
  if (needs === "torrent") return s.hasTorrent === true;
  if (needs === "selection") return s.hasTorrent === true || (s.mode === "VISUAL" && s.selectionCount > 0);
  if (needs === "tracker") return targetKind(s) === "tracker";
  if (needs === "peer") return targetKind(s) === "peer";
  if (needs === "trackersTab") return s.trackersTab === true;
  if (needs === "noMetadata") return s.cursorNoMetadata === true && s.cursorPendingMagnet !== true;
  if (needs === "limitRow") return s.limitCursorKey !== null && s.limitCursorKey !== undefined && s.limitCursorKey !== "";
  if (needs === "limitToggle") return s.limitToggle === true;
  if (needs === "toggleRow") return s.settingsToggle === true;
  if (needs === "editableRow") return s.settingsEditable === true;
  if (needs === "listRow") return s.settingsListRow === true;
  if (needs === "secretSet") return s.settingsSecretSet === true;
  if (needs === "undoEntry") return typeof s.settingsUndoCount === "number" && s.settingsUndoCount > 0;
  if (needs === "listEditable") return s.listEditable === true;
  if (needs === "listItem") return s.listEditable === true && !!s.listItem && typeof s.listItem === "object";
  if (needs === "narrow") return s.narrow === true;
  if (Object.prototype.hasOwnProperty.call(LIBRARY_NEEDS, needs)) return libraryKind(s, LIBRARY_NEEDS[needs]);
  return true;
}

// needsReason(needs, s) -> why an unmet `needs` blocks a command: the
// dispatch `blocked` text and the palette's dimmed-row reason. "" when met,
// and also "" for limitRow/limitToggle even when unmet -- Space on a
// Limits value row (or Enter/Space with no Limits row) is blocked with no
// note (D12).
function needsReason(needs, s) {
  if (preconditionMet(needs, s)) return "";
  if (needs === "tracker" || needs === "trackersTab") return "focus the trackers tab";
  if (needs === "peer") return "focus the peers tab";
  if (needs === "categoryName") return "focus a category";
  if (needs === "libraryGroup" || needs === "libraryName") return "focus a category or tag";
  if (needs === "limitRow" || needs === "limitToggle") return "";
  if (needs === "toggleRow" || needs === "editableRow") return "";
  // Slice 4b: the row, list or width already shows why; only undo speaks.
  if (needs === "listRow" || needs === "secretSet" || needs === "listEditable" || needs === "listItem" || needs === "narrow") return "";
  if (needs === "undoEntry") return "nothing to undo";
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
var TARGET_CONFIRM_KINDS = { "tracker.remove": "trackerRemove", "peer.ban": "peerBan", "library.remove": "libraryRemove" };

// confirmRefused(id, target) -> whether a target CONFIRM command can't act
// on its captured target at all, so asking would be pointless: the target
// carries a `refusal` (for trackers, InspectorView.trackerRefusal: a "|"
// in the URL, F13, or a URL qbt would reject; for a category,
// LibraryView.LIBRARY_NOT_READY while its folders aren't known). Such a command comes back
// unconfirmed (args.confirmed unset, no CONFIRM); its handler says why
// and does nothing else. The registry can't load InspectorView (node
// requires this file as is), so the window computes the refusal.
function confirmRefused(id, target) {
  return Object.prototype.hasOwnProperty.call(TARGET_CONFIRM_KINDS, id) && !!target && !!target.refusal;
}

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
  var out = { kind: String(t.kind || ""), value: String(t.value === undefined || t.value === null ? "" : t.value), label: String(t.label === undefined || t.label === null ? "" : t.label) };
  if (t.refusal) out.refusal = String(t.refusal);
  return Object.freeze(out);
}

// copyListItem(item) -> a frozen {index, value, tierBreak} copy of the list
// line under the cursor (slice 4b), so a refresh can't change what x removes.
function copyListItem(item) {
  if (!item || typeof item !== "object") return null;
  return Object.freeze({
    index: Number(item.index),
    value: String(item.value === undefined || item.value === null ? "" : item.value),
    tierBreak: item.tierBreak === true
  });
}

function buildArgs(row, s) {
  var args = {};
  // A tracker/peer command acts on the row under the inspector cursor as
  // it stood when the key was pressed (a copy: a later refresh that moves
  // or drops the row can't change what `y` acts on).
  if (row.needs === "tracker" || row.needs === "peer") {
    args.target = copyTarget(s.inspectorTarget);
  }
  // Likewise the category or tag under the filters cursor.
  if (Object.prototype.hasOwnProperty.call(LIBRARY_NEEDS, row.needs)) {
    args.target = copyTarget(s.libraryTarget);
  }
  // The Info tab's Limits row under the cursor, as it stood at key time.
  if (row.needs === "limitRow" || row.needs === "limitToggle") {
    args.limitKey = s.limitCursorKey;
  }
  // The setting under the Settings cursor (or the open list's key), as it
  // stood at key time.
  if (row.needs === "toggleRow" || row.needs === "editableRow" || row.needs === "listRow" || row.needs === "secretSet" ||
      row.needs === "listEditable" || row.needs === "listItem") {
    args.settingKey = s.settingsKey;
  }
  // The list line under the list cursor, frozen like a target.
  if (row.needs === "listItem") args.listItem = copyListItem(s.listItem);
  // ":" on a VISUAL range: the palette acts on that range (the window keeps it).
  if (row.id === "palette.open" && s.mode === "VISUAL") args.range = true;
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

  // PICKER's Space/Tab: a toggle only under the right condition (see the
  // "picker.toggle" row above), otherwise it's not a match at all -- no
  // "blocked" note, just as an ordinary typed character in COMMAND mode
  // resolves to no command (ListOverlay's field types it instead).
  if (s.mode === "PICKER") {
    if (ev.key === KEY.Space && !(s.pickerQueryEmpty === true && s.pickerMulti === true)) {
      return { state: clearPrefix(s), commandId: null };
    }
    if (matchLabel("Tab", ev) && s.pickerMulti !== true) {
      return { state: clearPrefix(s), commandId: null };
    }
  }

  // Settings has no key sequences: a prefix left over from the torrent
  // view never completes there (Esc Esc would reset the hidden filters).
  if (isSettingsPane(s.pane) && s.prefix !== null) s = clearPrefix(s);

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
    // A row matches this key/mode/pane but not the focused tab (e.g. x off
    // the trackers tab, j/k on Chart): keep naming why, via that row's own
    // `needs`, unless it would have run unconditionally (needs "none" --
    // Chart genuinely has no j/k, so it stays silent, no note at all).
    var offTab = findMatchIgnoringTabs(s, ev);
    if (offTab && offTab.id !== null && offTab.needs !== "none") {
      var reason = needsReason(offTab.needs, s);
      if (reason) return { state: clearPrefix(s), commandId: null, blocked: reason };
    }
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

  if (needsConfirm(row.id, s) && Object.prototype.hasOwnProperty.call(TARGET_CONFIRM_KINDS, row.id) && !confirmRefused(row.id, args.target)) {
    var kind = TARGET_CONFIRM_KINDS[row.id];
    var tpending = { kind: kind, commandId: row.id, args: args, target: args.target };
    return {
      state: assign(clearPrefix(s), { mode: "CONFIRM", pending: tpending }),
      commandId: null,
      confirm: { commandId: row.id, kind: kind, label: args.target.label, target: args.target }
    };
  }

  if (needsConfirm(row.id, s) && !Object.prototype.hasOwnProperty.call(TARGET_CONFIRM_KINDS, row.id)) {
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
  // Leaving VISUAL (via visual.exit, an EXITS_VISUAL action, or C/T's
  // PICKER) drops the range. Without this, a stale selectionCount would
  // leak range semantics into the mode that follows (see confirmCount/
  // buildArgs); the pickers act on the targets the window captured.
  if (s.mode === "VISUAL" && nextState.mode !== "VISUAL") {
    nextState = assign(nextState, { selectionCount: 0 });
  }

  return { state: nextState, commandId: row.id, args: args };
}

// raiseConfirm(state, commandId, kind, args) -> {state, confirm}: a CONFIRM
// the window raises itself, after INSERT rather than on a key (c's merge
// or move, p's move). The pending entry has resolveRow's shape, so `y`
// resolves to commandId with a copy of args plus confirmed: true, and
// n/Esc to confirm.cancel. args.target is the target captured when the
// key was pressed.
function raiseConfirm(state, commandId, kind, args) {
  var s = clearPrefix(normalizeState(state));
  var a = assign(args || {}, {});
  var target = a.target || null;
  var pending = { kind: kind, commandId: commandId, args: a, target: target };
  return {
    state: assign(s, { mode: "CONFIRM", pending: pending }),
    confirm: { commandId: commandId, kind: kind, label: target ? target.label : "", target: target }
  };
}

// dispatchCommand(state, commandId) -> the same result dispatch() gives
// for a key bound to `commandId` in state's mode and pane (the command
// palette runs a command by id, not by key). No row for that id in this
// mode/pane/tab resolves to no command, as an unbound key would. In
// practice the palette never offers a tab-mismatched row (paletteRowFrom
// dims it first), but this stays consistent with findMatch (D7) regardless.
function dispatchCommand(state, commandId) {
  var s = clearPrefix(normalizeState(state));
  for (var i = 0; i < commands.length; i++) {
    var row = commands[i];
    if (row.id === null || row.id !== commandId) continue;
    if (row.modes.indexOf(s.mode) === -1 || !paneMatches(row, s.pane)) continue;
    if (!tabMatches(row, s.inspectorTab)) continue;
    if (!whenMatches(row, s)) continue;
    return resolveRow(s, row, 0);
  }
  return { state: s, commandId: null };
}

// helpFor(mode, pane, tab, state) -> rows from `commands` active for that
// mode/pane, generated from the same table dispatch() reads. Reserved
// (id === null) rows are not commands, so they are left out. `tab` is
// optional (D7): when given, a row whose `tabs` excludes it is left out
// too (the `?` overlay's inspector-pane listing, one tab at a time); when
// omitted, every tab's rows are listed together, as before Task 4.
// `state` (optional, the dispatch state's fields) decides each row's
// `when` (Ruling CJ); without it, the empty state decides.
function helpFor(mode, pane, tab, state) {
  var out = [];
  var i, row;
  var s = normalizeState(state);
  for (i = 0; i < commands.length; i++) {
    row = commands[i];
    if (row.id === null || row.paletteOnly === true) continue;
    if (row.modes.indexOf(mode) === -1) continue;
    if (!paneMatches(row, pane)) continue;
    if (tab !== undefined && !tabMatches(row, tab)) continue;
    if (!whenMatches(row, s)) continue;
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
    raiseConfirm: raiseConfirm,
    helpFor: helpFor,
    preconditionMet: preconditionMet,
    needsReason: needsReason,
    needsConfirm: needsConfirm,
    paneMatches: paneMatches,
    isSettingsPane: isSettingsPane,
    SETTINGS_PANES: SETTINGS_PANES,
    tabMatches: tabMatches,
    whenMatches: whenMatches
  };
}
