.import "Model.js" as Model

// Pure view helpers for the OmaqBT window (Client.qml, TorrentTable.qml,
// StatusLine.qml). No I/O, no Date, no Qt objects: everything comes in
// through arguments, so tests/client-view.test.js can run it in node.
//
// The `.import` line above is QML-only. The node test strips it and runs
// this file in a vm context with `Model` supplied (see the test's loader),
// because node can't parse `.import` and QML can't `require`.

// Qt::KeyboardModifier bits, as QML's event.modifiers delivers them.
// Verified against /usr/include/qt6/QtCore/qnamespace.h.
var MOD = {
  Shift: 0x02000000,
  Control: 0x04000000,
  Alt: 0x08000000
};

// keyEvent(key, text, modifiers, now) -> exactly the event shape
// CommandRegistry.dispatch takes: {key, text, modifiers:{ctrl,shift,alt}, now}.
function keyEvent(key, text, modifiers, now) {
  var m = Number(modifiers) || 0;
  return {
    key: Number(key) || 0,
    text: text === undefined || text === null ? "" : String(text),
    modifiers: {
      ctrl: (m & MOD.Control) !== 0,
      shift: (m & MOD.Shift) !== 0,
      alt: (m & MOD.Alt) !== 0
    },
    now: Number(now) || 0
  };
}

// --- Sorting --------------------------------------------------------------

var SORT_CYCLE = ["added", "name", "size", "progress", "dl", "ul", "eta", "ratio"];

// The direction a mode starts in when `s` switches to it. desc is absolute
// (Model.sortTorrents): true means newest, largest, fastest or Z->A first.
var SORT_DEFAULT_DESC = {
  added: true, name: false, size: true, progress: true,
  dl: true, ul: true, eta: false, ratio: true
};

var SORT_NAMES = {
  added: "date added", name: "name", size: "size", progress: "progress",
  dl: "↓ speed", ul: "↑ speed", eta: "ETA", ratio: "ratio"
};

// [descending words, ascending words]. ETA descending puts ∞ first
// (Model's absolute rule), which reads naturally as "longest first".
var SORT_DIRECTION_WORDS = {
  added: ["newest first", "oldest first"],
  name: ["Z→A", "A→Z"],
  size: ["largest first", "smallest first"],
  progress: ["most done first", "least done first"],
  dl: ["fastest first", "slowest first"],
  ul: ["fastest first", "slowest first"],
  eta: ["longest first", "soonest first"],
  ratio: ["highest first", "lowest first"]
};

// The table column that carries the ▾/▴ marker for a sort mode. "added"
// has no column, so the pane title alone says it.
var SORT_COLUMN = {
  added: "", name: "name", size: "size", progress: "progress",
  dl: "dl", ul: "ul", eta: "eta", ratio: "ratio"
};

function validSort(mode) {
  return SORT_CYCLE.indexOf(String(mode)) !== -1 ? String(mode) : "added";
}

// nextSort(mode) -> {sort, desc}: the next mode in the cycle, in its
// default direction.
function nextSort(mode) {
  var i = SORT_CYCLE.indexOf(String(mode));
  var next = SORT_CYCLE[(i + 1) % SORT_CYCLE.length];
  return { sort: next, desc: SORT_DEFAULT_DESC[next] };
}

function sortColumn(mode) {
  return SORT_COLUMN[validSort(mode)];
}

function sortMarker(desc) {
  return desc ? "▾" : "▴";
}

function sortTitle(mode, desc) {
  var m = validSort(mode);
  return "sorted by " + SORT_NAMES[m] + ", " + SORT_DIRECTION_WORDS[m][desc ? 0 : 1];
}

// --- Filters --------------------------------------------------------------

function defaultFilter() {
  return { group: "status", value: "All" };
}

function isDefaultFilter(filter) {
  var f = filter || {};
  return f.group === "status" && f.value === "All";
}

// The label a filter shows as, e.g. in "Nothing matches “q” in Seeding".
// Sentinel values ("") map to the same labels Model.filterGroups uses.
function filterLabel(filter) {
  var f = filter || {};
  var v = String(f.value === undefined || f.value === null ? "" : f.value);
  if (f.group === "status") return v === "" ? "All" : v;
  if (f.group === "category") return v === "" ? "Uncategorized" : v;
  if (f.group === "tag") return v === "" ? "Untagged" : v;
  if (f.group === "tracker") return v === "" ? "Trackerless" : v;
  return "All";
}

// The torrents pane title's right side: "all · “q” · sorted by …".
// Status labels are lowercased like the mockup ("active · sorted by …");
// category/tag/tracker names are shown as they are.
function paneTitle(filter, query, mode, desc) {
  var f = filter || {};
  var label = filterLabel(f);
  if (f.group === "status" || !f.group) label = label.toLowerCase();
  var parts = [label];
  var q = String(query || "").trim();
  if (q !== "") parts.push("“" + q + "”");
  parts.push(sortTitle(mode, desc));
  return parts.join(" · ");
}

// --- Rows -----------------------------------------------------------------

function clamp01(n) {
  var p = Number(n);
  if (!isFinite(p) || p < 0) return 0;
  return p > 1 ? 1 : p;
}

// Sizes the way the table shows them: "1.3 GiB", "754 MiB", "512 B".
function sizeText(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n < 0) n = 0;
  var units = ["B", "KiB", "MiB", "GiB", "TiB"];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n = n / 1024;
    i++;
  }
  if (i === 0) return Math.round(n) + " B";
  return (n < 100 ? n.toFixed(1) : String(Math.round(n))) + " " + units[i];
}

// Compact per-row rates: "0", "820K", "4.1M", "12.4M".
function rateText(bytesPerSec) {
  var n = Number(bytesPerSec);
  if (!isFinite(n) || n <= 0) return "0";
  var v = n / 1024;
  if (v < 1000) return Math.max(1, Math.round(v)) + "K";
  v = v / 1024;
  if (v < 1000) return (v < 100 ? v.toFixed(1) : String(Math.round(v))) + "M";
  v = v / 1024;
  return (v < 100 ? v.toFixed(1) : String(Math.round(v))) + "G";
}

var GLYPHS = {
  downloading: { glyph: "●", tone: "accent" },
  seeding: { glyph: "▲", tone: "fg" },
  checking: { glyph: "↻", tone: "muted" },
  stopped: { glyph: "‖", tone: "muted" },
  errored: { glyph: "!", tone: "urgent" }
};

var BAR_CELLS = 10;

function barCells(progress) {
  var p = clamp01(progress);
  if (p >= 1) return BAR_CELLS;
  return Math.min(BAR_CELLS - 1, Math.round(p * BAR_CELLS));
}

function barText(progress) {
  var filled = barCells(progress);
  var out = "";
  for (var i = 0; i < BAR_CELLS; i++) out += i < filled ? "█" : "▒";
  return out;
}

function progressWord(group, state) {
  var s = String(state || "").toLowerCase();
  if (group === "errored") return s === "missingfiles" ? "missing files" : "error";
  if (group === "checking") return s === "moving" ? "moving" : "checking";
  return "";
}

// The ETA cell: "∞" for an ETA with no end, "—" when not applicable.
function etaText(group, eta) {
  if (group !== "downloading" && group !== "seeding") return "—";
  var e = Number(eta);
  if (!isFinite(e) || e < 0 || e >= 8640000) return "∞";
  return Model.formatEta(e);
}

// The display fields every projected row carries (besides `hash`). Every
// value is a string, so the ListModel's role types never vary by row, and
// this is exactly the field list Model.diffRows compares.
var DISPLAY_FIELDS = [
  "name", "glyph", "glyphTone", "sizeText", "bar", "barTone",
  "progressText", "progressTone", "dlText", "ulText", "etaText", "ratioText"
];

// projectRow(row) -> a flat row of display strings for the ListModel. The
// name is run through Model.plainText as a second guard; the delegate also
// renders it with Text.PlainText. Tags are left out on purpose: an array
// role would nest in a ListModel, and no Task 7 cell shows tags.
function projectRow(row) {
  var r = row || {};
  var group = Model.statusGroup(r);
  var g = GLYPHS[group] || GLYPHS.stopped;
  var word = progressWord(group, r.state);
  var showBar = group !== "errored";
  var ratio = Number(r.ratio);
  if (!isFinite(ratio) || ratio < 0) ratio = 0;
  return {
    hash: String(Model.torrentId(r)),
    name: Model.plainText(r.name),
    glyph: g.glyph,
    glyphTone: g.tone,
    sizeText: sizeText(r.size),
    bar: showBar ? barText(r.progress) : "",
    barTone: g.tone,
    progressText: word !== "" ? word : Model.formatPercent(clamp01(r.progress)),
    progressTone: group === "errored" ? "urgent" : "fg",
    dlText: group === "downloading" ? rateText(r.dlSpeed) : "—",
    ulText: group === "downloading" || group === "seeding" ? rateText(r.upSpeed) : "—",
    etaText: etaText(group, r.eta),
    ratioText: ratio.toFixed(2)
  };
}

// The window's table rows: pending magnets out, then the sidebar filter,
// then the `/` text query, then the sort. Returns {raw, rows}: the raw
// Service rows (for actions) and the projected rows (for the ListModel),
// in the same order.
function viewRows(torrents, pendingHashes, filter, query, mode, desc) {
  var live = Model.excludePending(torrents || [], pendingHashes || []);
  var f = filter || defaultFilter();
  var filtered = [];
  for (var i = 0; i < live.length; i++) {
    if (Model.matchFilter(live[i], f)) filtered.push(live[i]);
  }
  var sorted = Model.sortTorrents(Model.filterByQuery(filtered, query), validSort(mode), desc === true);
  var rows = [];
  for (var j = 0; j < sorted.length; j++) rows.push(projectRow(sorted[j]));
  return { raw: sorted, rows: rows };
}

// --- Cursor ---------------------------------------------------------------

function indexOfHash(rows, hash) {
  var list = rows || [];
  var h = String(hash || "");
  if (h === "") return -1;
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].hash === h) return i;
  }
  return -1;
}

// resolveCursor(rows, hash, prevIndex) -> the hash the cursor should sit on
// after the rows change. The cursor follows its torrent by hash. If that
// torrent is gone, it takes the row now at its old index (clamped), or the
// first row when there is no old index (e.g. a restored hash that no
// longer exists). With no rows at all the hash is kept, so a restored
// cursor survives until the first status arrives.
function resolveCursor(rows, hash, prevIndex) {
  var list = rows || [];
  if (list.length === 0) return String(hash || "");
  if (indexOfHash(list, hash) !== -1) return String(hash);
  var i = Number(prevIndex);
  if (!isFinite(i) || i < 0) i = 0;
  if (i > list.length - 1) i = list.length - 1;
  return list[i].hash;
}

// moveCursor(rows, hash, commandId) -> the new cursor hash for
// cursor.down/up/top/bottom. Movement clamps at the ends.
function moveCursor(rows, hash, commandId) {
  var list = rows || [];
  if (list.length === 0) return String(hash || "");
  var i = indexOfHash(list, hash);
  var next = i;
  if (commandId === "cursor.top") next = 0;
  else if (commandId === "cursor.bottom") next = list.length - 1;
  else if (commandId === "cursor.down") next = i === -1 ? 0 : Math.min(list.length - 1, i + 1);
  else if (commandId === "cursor.up") next = i === -1 ? 0 : Math.max(0, i - 1);
  else if (i === -1) next = 0;
  return list[next].hash;
}

// --- Panes ----------------------------------------------------------------

var PANES = ["filters", "table", "inspector"];

function nextPane(pane, delta) {
  var i = PANES.indexOf(String(pane));
  if (i === -1) i = 1;
  var n = PANES.length;
  return PANES[(((i + delta) % n) + n) % n];
}

// --- States ---------------------------------------------------------------

// tableState(s) -> what the center pane shows:
// "loading" | "gui" | "notInstalled" | "daemon" | "api" | "empty" |
// "noMatch" | "rows". s = {loading, installed, daemon, lockHolder, api,
// liveCount, visibleCount}. The Qt GUI holding the profile wins over
// "daemon down", because starting the daemon can't work until it quits.
function tableState(s) {
  var st = s || {};
  if (st.loading === true) return "loading";
  if (st.lockHolder === "gui") return "gui";
  if (st.installed !== true) return "notInstalled";
  if (st.daemon !== true) return "daemon";
  if (st.api !== true) return "api";
  if (!(st.liveCount > 0)) return "empty";
  if (!(st.visibleCount > 0)) return "noMatch";
  return "rows";
}

// dispatchPane(pane, state) -> the pane handed to CommandRegistry.dispatch.
// A blocking state (daemon down, not installed, Qt open, API down, empty
// library, loading) replaces the whole center with its own keys (Enter,
// y, r), and those keys are table-pane rows in the registry. So while one
// shows, keys dispatch as if the table were focused, whatever pane was
// restored; with rows (or a no-match filter) the real pane is used.
function dispatchPane(pane, state) {
  if (state === "rows" || state === "noMatch") return String(pane || "table");
  return "table";
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

function countText(n) {
  return plural(Number(n) || 0, "torrent", "torrents");
}

// Copy for each non-row state (final copy from the design spec's states
// table and the approved mockup). keys: [{key, label}].
function stateCopy(state, ctx) {
  var c = ctx || {};
  if (state === "loading") {
    return { title: "Connecting to qbittorrent-nox…", tone: "muted", body: "", keys: [] };
  }
  if (state === "gui") {
    return {
      title: "qBittorrent (Qt) is open",
      tone: "urgent",
      body: "The Qt app and the daemon share one profile and can't run together. Quit the Qt app (tray icon too), then start the daemon.",
      keys: [{ key: "r", label: "Check again" }]
    };
  }
  if (state === "notInstalled") {
    return {
      title: "qbittorrent-nox isn't installed",
      tone: "fg",
      body: "OmaqBT drives the headless qBittorrent daemon. Install it to get started.",
      keys: [{ key: "Enter", label: "Install qbittorrent-nox" }, { key: "r", label: "Check again" }]
    };
  }
  if (state === "daemon") {
    return {
      title: "qbittorrent-nox isn't running",
      tone: "fg",
      body: "Your library and settings are untouched. Start the daemon to see them.",
      // No ":" "Commands" key yet: the command palette arrives in slice 1b.
      keys: [{ key: "Enter", label: "Start daemon" }]
    };
  }
  if (state === "api") {
    return {
      title: "qbittorrent-nox isn't answering",
      tone: "fg",
      body: "The daemon is running but its Web API isn't reachable on localhost yet.",
      keys: [{ key: "r", label: "Check again" }]
    };
  }
  if (state === "empty") {
    return {
      title: "No torrents yet",
      tone: "fg",
      body: "Click a magnet link in your browser, or add one here.",
      keys: [{ key: "/", label: "Add magnet, URL, or .torrent" }, { key: "y", label: "Add from clipboard" }]
    };
  }
  if (state === "noMatch") {
    var q = String(c.query || "").trim();
    var label = filterLabel(c.filter);
    var inAll = Number(c.matchesInAll) || 0;
    var keys = [];
    if (q !== "") keys.push({ key: "Esc", label: "Clear the text filter" });
    keys.push({ key: "Esc Esc", label: "Clear filter, show All" });
    if (q !== "") {
      return {
        title: "Nothing matches “" + q + "” in " + label,
        tone: "fg",
        body: plural(inAll, "match", "matches") + " in All.",
        keys: keys
      };
    }
    return {
      title: "Nothing in " + label,
      tone: "fg",
      body: countText(inAll) + " in All.",
      keys: keys
    };
  }
  return { title: "", tone: "fg", body: "", keys: [] };
}

// --- Actions --------------------------------------------------------------

// toggleStarts(rawRows) -> true when Space should start the targets: every
// target is stopped (paused or completed). Otherwise Space stops them.
// Matches Service.toggleHash for a single row.
function toggleStarts(rawRows) {
  var list = rawRows || [];
  if (list.length === 0) return false;
  for (var i = 0; i < list.length; i++) {
    var bucket = Model.classifyState(list[i].state, list[i].progress);
    if (bucket !== "paused" && bucket !== "completed") return false;
  }
  return true;
}

// Progress copy for the status line (muted) while this window's action
// runs. kind: start|stop|remove|delete|recheck|move|startAll|stopAll|
// turtle|add|daemon|install.
function progressText(kind, count) {
  var n = Number(count) || 0;
  var t = plural(n, "torrent", "torrents");
  if (kind === "start") return "Starting " + t + "…";
  if (kind === "stop") return "Stopping " + t + "…";
  if (kind === "remove") return "Removing " + t + "…";
  if (kind === "delete") return "Deleting " + t + " and their files…";
  if (kind === "recheck") return "Rechecking " + t + "…";
  if (kind === "move") return "Moving " + t + "…";
  if (kind === "startAll") return "Starting all torrents…";
  if (kind === "stopAll") return "Stopping all torrents…";
  if (kind === "turtle") return "Switching alt speed…";
  if (kind === "add") return "Adding torrent…";
  if (kind === "daemon") return "Starting qbittorrent-nox…";
  if (kind === "install") return "Installing qbittorrent-nox…";
  if (kind === "copy") return "Copying magnet…";
  if (kind === "prio") return "Setting file priority…";
  return "Working…";
}

// confirmLine(confirm) -> the CONFIRM status line, from
// CommandRegistry.dispatch's `confirm` result {commandId, count, withFiles}.
// {lead, strong, tail, accept}: "Delete 2 torrents" + "and their files" +
// "from disk?", accept "delete".
function confirmLine(confirm) {
  var c = confirm || {};
  var n = Number(c.count) || 0;
  var t = plural(n, "torrent", "torrents");
  if (c.withFiles === true) {
    return { lead: "Delete " + t + " ", strong: "and their files", tail: " from disk?", accept: "delete" };
  }
  return { lead: "Remove " + t + "? ", strong: "", tail: "Files stay on disk.", accept: "remove" };
}

// Key hints for the status line's right side, per mode (and, in NORMAL,
// per focused pane). ctx: {accept, purpose, pane, filesTab}.
function modeHints(mode, ctx) {
  var c = ctx || {};
  if (mode === "CONFIRM") {
    return [{ key: "y", label: c.accept || "confirm" }, { key: "n/Esc", label: "keep" }];
  }
  if (mode === "INSERT") {
    if (c.purpose === "move") return [{ key: "Enter", label: "move" }, { key: "Esc", label: "cancel" }];
    return [{ key: "Enter", label: "keep filter" }, { key: "Esc", label: "cancel" }];
  }
  if (mode === "VISUAL") {
    return [
      { key: "Space", label: "start/stop" },
      { key: "x", label: "remove" },
      { key: "X", label: "delete files" },
      { key: "Esc", label: "cancel" }
    ];
  }
  if (c.pane === "filters") {
    return [
      { key: "j/k", label: "move" },
      { key: "Enter", label: "apply" },
      { key: "Tab", label: "pane" },
      { key: "?", label: "keys" }
    ];
  }
  if (c.pane === "inspector") {
    if (c.filesTab === true) {
      return [
        { key: "j/k", label: "move" },
        { key: "Space", label: "priority" },
        { key: "1", label: "info" },
        { key: "Tab", label: "pane" },
        { key: "?", label: "keys" }
      ];
    }
    return [
      { key: "1", label: "info" },
      { key: "4", label: "files" },
      { key: "Tab", label: "pane" },
      { key: "?", label: "keys" }
    ];
  }
  return [
    { key: "j/k", label: "move" },
    { key: "Space", label: "start/stop" },
    { key: "V", label: "visual" },
    { key: "/", label: "filter" },
    { key: "s", label: "sort" },
    { key: "?", label: "keys" },
    { key: "q", label: "close" }
  ];
}

// --- Tones ----------------------------------------------------------------

// toneColor(tone, palette) -> the palette color for a tone name. palette
// is qs.Commons' Color singleton in QML ({foreground, accent, muted,
// urgent}); passing it in keeps this file free of Qt objects. The one
// helper TorrentTable, StatusLine and the side panes share.
function toneColor(tone, palette) {
  var p = palette || {};
  if (tone === "accent") return p.accent;
  if (tone === "muted") return p.muted;
  if (tone === "urgent") return p.urgent;
  return p.foreground;
}

// --- Targets and VISUAL ---------------------------------------------------

// visualRange(rows, anchorHash, cursorHash) -> the hashes from the anchor
// row to the cursor row, inclusive, in the table's current order. When
// the anchor row is gone (filtered out, or removed by a tick) the range
// collapses to the cursor row; with no cursor row it is empty.
function visualRange(rows, anchorHash, cursorHash) {
  var list = rows || [];
  var c = indexOfHash(list, cursorHash);
  if (c === -1) return [];
  var a = indexOfHash(list, anchorHash);
  if (a === -1) a = c;
  var lo = Math.min(a, c);
  var hi = Math.max(a, c);
  var out = [];
  for (var i = lo; i <= hi; i++) out.push(list[i].hash);
  return out;
}

// targetHashes(mode, rows, cursorHash, anchorHash) -> the torrents a
// command acts on: the VISUAL range while mode is VISUAL, otherwise the
// cursor row. The window computes this BEFORE dispatch: an action that
// leaves VISUAL (Space, x, X, e) comes back with mode NORMAL or CONFIRM,
// and must still act on the range as it stood when the key was pressed.
function targetHashes(mode, rows, cursorHash, anchorHash) {
  if (mode === "VISUAL") return visualRange(rows, anchorHash, cursorHash);
  return indexOfHash(rows, cursorHash) !== -1 ? [String(cursorHash)] : [];
}

// dispatchState(regState, pane, state, hasCursorRow, targets) -> the state
// handed to CommandRegistry.dispatch. selectionCount means something only
// while mode is VISUAL (the registry contract), so it is 0 otherwise.
function dispatchState(regState, pane, state, hasCursorRow, targets) {
  var st = {};
  var r = regState || {};
  for (var k in r) {
    if (Object.prototype.hasOwnProperty.call(r, k)) st[k] = r[k];
  }
  st.pane = dispatchPane(pane, state);
  st.hasTorrent = state === "rows" && hasCursorRow === true;
  st.selectionCount = st.mode === "VISUAL" ? (targets || []).length : 0;
  return st;
}

// nextAnchor(nextMode, commandId, anchorHash, cursorHash) -> the VISUAL
// anchor after a dispatch: set to the cursor by visual.enter, kept while
// the mode stays VISUAL, cleared as soon as VISUAL is left (a CONFIRM
// raised from VISUAL keeps its own copy of the range in confirmHashes).
function nextAnchor(nextMode, commandId, anchorHash, cursorHash) {
  if (nextMode !== "VISUAL") return "";
  if (commandId === "visual.enter") return String(cursorHash || "");
  return String(anchorHash || "");
}

// leaveVisualState(regState) -> regState back in NORMAL with no range
// (selectionCount 0, no prefix), for a VISUAL session ended outside
// dispatch, e.g. by a click that moves focus to another pane.
function leaveVisualState(regState) {
  var st = {};
  var r = regState || {};
  for (var k in r) {
    if (Object.prototype.hasOwnProperty.call(r, k)) st[k] = r[k];
  }
  if (st.mode === "VISUAL") st.mode = "NORMAL";
  st.selectionCount = 0;
  st.prefix = null;
  st.prefixAt = 0;
  return st;
}

// hashSet(list) -> {hash: true}, for per-row lookups in delegates.
function hashSet(list) {
  var out = {};
  var l = list || [];
  for (var i = 0; i < l.length; i++) out[String(l[i])] = true;
  return out;
}

// --- Messages -------------------------------------------------------------
//
// The window's status-line message state. Immutable: every function
// returns a new object. Priority when shown: error (urgent, kept until
// the next key) > note > progress (muted, while this window's own tickets
// run) > nothing (the stats show).

// tickets: ticket -> {kind, count, hashes, text, group}. groups: group id
// -> {left, failed, error}: the tickets of one user action (a bulk action
// split into several qbt calls) share a group and report as one.
function emptyMessages() {
  return { tickets: {}, groups: {}, progress: "", error: "", errorHashes: [], note: "", noteTone: "muted" };
}

function copyMessages(m) {
  var s = m || emptyMessages();
  var tickets = {};
  for (var k in s.tickets || {}) tickets[k] = s.tickets[k];
  var groups = {};
  for (var g in s.groups || {}) {
    var src = s.groups[g];
    groups[g] = { left: src.left, failed: src.failed, error: src.error };
  }
  return {
    tickets: tickets,
    groups: groups,
    progress: String(s.progress || ""),
    error: String(s.error || ""),
    errorHashes: (s.errorHashes || []).slice(),
    note: String(s.note || ""),
    noteTone: s.noteTone || "muted"
  };
}

// failureText(kind, count) -> the lead of an action's error line.
function failureText(kind, count) {
  var n = Number(count) || 0;
  var t = plural(n, "torrent", "torrents");
  if (kind === "start") return "Couldn't start " + t;
  if (kind === "stop") return "Couldn't stop " + t;
  if (kind === "remove") return "Couldn't remove " + t;
  if (kind === "delete") return "Couldn't delete " + t;
  if (kind === "recheck") return "Couldn't recheck " + t;
  if (kind === "move") return "Couldn't move " + t;
  if (kind === "startAll") return "Couldn't start all torrents";
  if (kind === "stopAll") return "Couldn't stop all torrents";
  if (kind === "turtle") return "Couldn't switch alt speed";
  if (kind === "add") return "Couldn't add the torrent";
  if (kind === "daemon") return "Couldn't start qbittorrent-nox";
  if (kind === "install") return "Couldn't install qbittorrent-nox";
  if (kind === "copy") return "Couldn't copy the magnet";
  if (kind === "prio") return "Couldn't set the file priority";
  if (kind === "files") return "Couldn't read files";
  return "The action failed";
}

var BUSY_NOTE = "Busy, try again.";

// msgTrack(m, ticket, kind, count, hashes) -> m with this window's ticket
// recorded and its progress text showing. ticket may be an array: the
// tickets of one user action split into several qbt calls, which then
// show progress until every one has finished and report one message
// (see msgFinish). A ticket <= 0 (Service refused the call because it is
// busy), or an array with no ticket > 0, records nothing and notes
// BUSY_NOTE.
function msgTrack(m, ticket, kind, count, hashes) {
  var list = Array.isArray(ticket) ? ticket : [ticket];
  var ids = [];
  for (var i = 0; i < list.length; i++) {
    var t = Number(list[i]) || 0;
    if (t > 0) ids.push(String(t));
  }
  // Service refuses a window call with 0 only when the process that would
  // run it is already busy (the window validates its own input first).
  if (ids.length === 0) return msgNote(m, BUSY_NOTE, "muted");
  var next = copyMessages(m);
  var text = progressText(kind, count);
  var group = ids[0];
  var own = (hashes || []).slice();
  for (var j = 0; j < ids.length; j++) {
    next.tickets[ids[j]] = { kind: kind, count: Number(count) || 0, hashes: own, text: text, group: group };
  }
  next.groups[group] = { left: ids.length, failed: false, error: "" };
  next.progress = text;
  return next;
}

// A success note for actions whose effect isn't visible in the table.
var DONE_NOTES = { copy: "Copied magnet." };

function ownsTicket(m, ticket) {
  return !!m && !!m.tickets && Object.prototype.hasOwnProperty.call(m.tickets, String(ticket));
}

// msgFinish(m, ticket, ok, error) -> m after one of this window's tickets
// ended. A ticket the window doesn't own returns m unchanged (the same
// object), so foreign completions -- another view's, or the extra ones a
// pending-magnet drop emits with our hashes -- never touch the window. On
// failure the error line and the affected hashes (for the row `!`) are
// set; bulk actions report one error for all their torrents, since qbt
// can't say which one failed. A ticket of a group (see msgTrack) only
// counts down while others of its group still run -- the progress stays --
// and the group's last ticket reports once: the first failure's error if
// any ticket failed, else success.
function msgFinish(m, ticket, ok, error) {
  if (!ownsTicket(m, ticket)) return m;
  var next = copyMessages(m);
  var entry = next.tickets[String(ticket)];
  delete next.tickets[String(ticket)];
  var last = "";
  for (var k in next.tickets) last = next.tickets[k].text;
  next.progress = last;
  var gid = entry.group !== undefined ? String(entry.group) : String(ticket);
  var group = next.groups[gid] || { left: 1, failed: false, error: "" };
  group.left = group.left - 1;
  if (ok !== true && !group.failed) {
    group.failed = true;
    group.error = String(error || "").trim();
  }
  if (group.left > 0) {
    next.groups[gid] = group;
    return next;
  }
  delete next.groups[gid];
  if (!group.failed && DONE_NOTES[entry.kind]) {
    next.note = DONE_NOTES[entry.kind];
    next.noteTone = "muted";
  }
  if (group.failed) {
    var err = group.error;
    next.error = failureText(entry.kind, entry.count) + (err !== "" ? ": " + err : ".");
    next.errorHashes = entry.hashes.slice();
  }
  return next;
}

// msgError(m, text, hashes) -> m showing an urgent error until the next key.
function msgError(m, text, hashes) {
  var next = copyMessages(m);
  next.error = String(text || "");
  next.errorHashes = (hashes || []).slice();
  return next;
}

// msgNote(m, text, tone) -> m with a one-key note (e.g. "Copied magnet.").
function msgNote(m, text, tone) {
  var next = copyMessages(m);
  next.note = String(text || "");
  next.noteTone = tone || "muted";
  return next;
}

// msgKey(m) -> m after a keypress: the error, its row marks and any note
// clear; progress for tickets still running stays.
function msgKey(m) {
  var next = copyMessages(m);
  next.error = "";
  next.errorHashes = [];
  next.note = "";
  next.noteTone = "muted";
  return next;
}

// messageLine(m) -> {text, tone} for the status line ("" = show stats).
function messageLine(m) {
  var s = m || emptyMessages();
  if (s.error) return { text: s.error, tone: "urgent" };
  if (s.note) return { text: s.note, tone: s.noteTone || "muted" };
  if (s.progress) return { text: s.progress, tone: "muted" };
  return { text: "", tone: "muted" };
}

// --- Clipboard ------------------------------------------------------------

// clipboardOutcome(text, askedAt, now) -> what a clipboard answer means
// for the window's `y` (add from clipboard): "none" when the window
// didn't ask, "stale" when it answered more than 3 s later, "empty",
// "add" for an addable target, "invalid" otherwise. Every outcome but
// "none" disarms the request.
function clipboardOutcome(text, askedAt, now) {
  var asked = Number(askedAt) || 0;
  if (asked <= 0) return "none";
  if ((Number(now) || 0) - asked > 3000) return "stale";
  var t = String(text || "").trim();
  if (t === "") return "empty";
  return Model.isAddableTarget(t) ? "add" : "invalid";
}

// --- Filter pane ----------------------------------------------------------

var FILTER_GROUP_TITLES = { status: "Status", category: "Categories", tag: "Tags", tracker: "Trackers" };

function sameFilter(a, b) {
  var x = a || {};
  var y = b || {};
  return String(x.group) === String(y.group) && String(x.value) === String(y.value);
}

// filterEntries(groups) -> Model.filterGroups flattened for the pane:
// a header entry per group, then its items. Every value is a string, a
// number or a bool so the pane can compare lists cheaply.
function filterEntries(groups) {
  var out = [];
  var g = groups || [];
  for (var i = 0; i < g.length; i++) {
    out.push({ kind: "header", group: g[i].group, value: "", label: FILTER_GROUP_TITLES[g[i].group] || String(g[i].group), count: 0, zero: false });
    var items = g[i].items || [];
    for (var j = 0; j < items.length; j++) {
      var it = items[j];
      out.push({
        kind: "item",
        group: it.group,
        value: String(it.value),
        label: Model.plainText(it.label),
        count: Number(it.count) || 0,
        zero: it.zero === true
      });
    }
  }
  return out;
}

// filterIndex(entries, filter) -> the index of the item entry for filter,
// or -1 (e.g. a restored category that no longer exists).
function filterIndex(entries, filter) {
  var e = entries || [];
  for (var i = 0; i < e.length; i++) {
    if (e[i].kind === "item" && sameFilter(e[i], filter)) return i;
  }
  return -1;
}

// moveFilterCursor(entries, cursor, delta) -> the {group, value} the
// filter pane's cursor lands on after j (+1) or k (-1). Headers are
// skipped; movement clamps at the ends. A cursor that isn't in the list
// starts from the first item.
function moveFilterCursor(entries, cursor, delta) {
  var e = entries || [];
  var items = [];
  for (var i = 0; i < e.length; i++) if (e[i].kind === "item") items.push(e[i]);
  if (items.length === 0) return cursor || defaultFilter();
  var at = -1;
  for (var j = 0; j < items.length; j++) if (sameFilter(items[j], cursor)) at = j;
  var next = at === -1 ? 0 : Math.max(0, Math.min(items.length - 1, at + (delta > 0 ? 1 : -1)));
  return { group: items[next].group, value: items[next].value };
}

// sameEntries(a, b) -> true when two filterEntries lists render the same,
// so a status tick that changes no count leaves the pane's delegates alone.
function sameEntries(a, b) {
  var x = a || [];
  var y = b || [];
  if (x.length !== y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i].kind !== y[i].kind || x[i].group !== y[i].group || x[i].value !== y[i].value
      || x[i].label !== y[i].label || x[i].count !== y[i].count || x[i].zero !== y[i].zero) return false;
  }
  return true;
}

// --- Inspector ------------------------------------------------------------

// inspectorInfo(row, dateText) -> the Info tab for the cursor row, or null
// when there is no cursor row ("Select a torrent"). dateText(epochSec)
// formats the added time (QML passes Qt.formatDateTime; keeping it an
// argument keeps this file free of Date). Missing values show "—".
function inspectorInfo(row, dateText) {
  if (!row) return null;
  var r = row;
  var group = Model.statusGroup(r);
  var g = GLYPHS[group] || GLYPHS.stopped;
  var word = progressWord(group, r.state) || group;
  var size = Number(r.size);
  var hasSize = isFinite(size) && size > 0;
  var ratio = Number(r.ratio);
  var hasRatio = r.ratio !== undefined && r.ratio !== null && isFinite(ratio);
  var added = Number(r.addedOn);
  var fmt = typeof dateText === "function" ? dateText : function(s) { return Model.formatDate(s); };
  function num(v) {
    var n = Number(v);
    return v === undefined || v === null || !isFinite(n) ? null : n;
  }
  var seeds = num(r.numSeeds);
  var leechs = num(r.numLeechs);
  var dl = num(r.dlSpeed);
  var ul = num(r.upSpeed);
  function text(v) {
    var s = Model.plainText(v);
    return s === "" ? "—" : s;
  }
  return {
    name: text(r.name),
    fields: [
      { label: "State", value: g.glyph + " " + word + " · " + Model.formatPercent(clamp01(r.progress)), tone: g.tone },
      { label: "Size", value: hasSize ? sizeText(size) + " (" + sizeText(size * clamp01(r.progress)) + " done)" : "—", tone: "fg" },
      { label: "Speed", value: dl === null && ul === null ? "—" : "↓ " + sizeText(dl || 0) + "/s · ↑ " + sizeText(ul || 0) + "/s", tone: "fg" },
      { label: "Peers", value: seeds === null && leechs === null ? "—" : plural(seeds || 0, "seed", "seeds") + " · " + plural(leechs || 0, "leecher", "leechers"), tone: "fg" },
      { label: "Ratio", value: hasRatio ? Math.max(0, ratio).toFixed(2) + " · limit " + Model.ratioLimitLabel(r.ratioLimit === undefined ? -2 : r.ratioLimit) : "—", tone: "fg" },
      { label: "Category", value: text(r.category), tone: "fg" },
      { label: "Added", value: isFinite(added) && added > 0 ? String(fmt(added)) : "—", tone: "fg" },
      { label: "Save path", value: text(r.savePath), tone: "fg" }
    ],
    keys: [
      { key: "o", label: "open folder" },
      { key: "y", label: "copy magnet" },
      { key: "m", label: "move" },
      { key: "e", label: "recheck" }
    ]
  };
}

// filesView(files, status) -> the Files tab: {state, rows}. status is
// Service's per-hash files status ({state: "loading"|"ok"|"error"}) or
// undefined before any load. state: "loading" | "error" | "empty" | "rows".
function filesView(files, status) {
  var st = status && status.state ? status.state : "loading";
  var list = Array.isArray(files) ? files : [];
  if (st === "error") return { state: "error", rows: [] };
  if (list.length === 0) return { state: st === "ok" ? "empty" : "loading", rows: [] };
  var rows = [];
  for (var i = 0; i < list.length; i++) {
    var f = list[i] || {};
    var prio = parseInt(String(f.priority), 10);
    rows.push({
      index: Number(f.index),
      name: Model.plainText(f.name),
      progressText: Model.formatPercent(clamp01(f.progress)),
      priorityText: Model.priorityLabel(f.priority),
      skipped: prio === 0
    });
  }
  return { state: "rows", rows: rows };
}

// withPriority(files, index, prio) -> a copy of files with one file's
// priority changed: the optimistic update the widget also makes after
// setPrio, so the label moves before the next files load.
function withPriority(files, index, prio) {
  var out = [];
  var list = files || [];
  for (var i = 0; i < list.length; i++) {
    var f = list[i];
    if (f && Number(f.index) === Number(index)) {
      out.push({ index: f.index, name: f.name, progress: f.progress, priority: prio });
    } else {
      out.push(f);
    }
  }
  return out;
}

// moveIndex(count, index, delta) -> a list cursor moved by delta, clamped.
function moveIndex(count, index, delta) {
  var n = Number(count) || 0;
  if (n <= 0) return 0;
  var i = Number(index) || 0;
  return Math.max(0, Math.min(n - 1, i + delta));
}

// --- Help -----------------------------------------------------------------

var HELP_GROUPS = ["Torrent", "View", "Library", "App"];

function helpKeyLabel(label) {
  return label === "g g" ? "gg" : String(label);
}

// helpRows(rows) -> the `?` overlay from CommandRegistry.helpFor rows:
// [{group, items: [{keys, title}]}], groups in Torrent / View / Library /
// App order. A command bound on several rows (inspector.files: Enter and
// 4) is listed once with all its keys; the reserved null-id row is
// skipped (helpFor already leaves it out).
function helpRows(rows) {
  var byGroup = {};
  var seen = {};
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    var r = list[i];
    if (!r || r.id === null || r.id === undefined) continue;
    var keys = (r.keys || []).map(helpKeyLabel);
    if (seen[r.id]) {
      var item = seen[r.id];
      for (var k = 0; k < keys.length; k++) if (item.keyList.indexOf(keys[k]) === -1) item.keyList.push(keys[k]);
      item.keys = item.keyList.join(" / ");
      continue;
    }
    var entry = { keyList: keys.slice(), keys: keys.join(" / "), title: String(r.title) };
    seen[r.id] = entry;
    var g = HELP_GROUPS.indexOf(r.group) !== -1 ? r.group : "App";
    if (!byGroup[g]) byGroup[g] = [];
    byGroup[g].push(entry);
  }
  var out = [];
  for (var j = 0; j < HELP_GROUPS.length; j++) {
    var items = byGroup[HELP_GROUPS[j]];
    if (!items) continue;
    out.push({
      group: HELP_GROUPS[j],
      items: items.map(function(e) { return { keys: e.keys, title: e.title }; })
    });
  }
  return out;
}

// The VPN part of the status line. tone "fg" when bound, "urgent" when a
// VPN interface exists but the daemon isn't bound to it; null when there
// is no VPN at all.
function vpnPart(vpnIface, bindIface, unbound) {
  var vpn = String(vpnIface || "");
  if (vpn === "") return null;
  if (unbound === true) return { text: vpn + " not bound", tone: "urgent" };
  return { text: String(bindIface || vpn) + " bound", tone: "fg" };
}

// A move target must be an absolute path; Service returns 0 for anything
// else from the window and says nothing, so the window checks first.
function isAbsolutePath(path) {
  var p = String(path || "").trim();
  return p.length > 1 && p.charAt(0) === "/";
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MOD: MOD,
    keyEvent: keyEvent,
    SORT_CYCLE: SORT_CYCLE,
    nextSort: nextSort,
    validSort: validSort,
    sortColumn: sortColumn,
    sortMarker: sortMarker,
    sortTitle: sortTitle,
    defaultFilter: defaultFilter,
    isDefaultFilter: isDefaultFilter,
    filterLabel: filterLabel,
    paneTitle: paneTitle,
    sizeText: sizeText,
    rateText: rateText,
    barCells: barCells,
    barText: barText,
    etaText: etaText,
    DISPLAY_FIELDS: DISPLAY_FIELDS,
    projectRow: projectRow,
    viewRows: viewRows,
    indexOfHash: indexOfHash,
    resolveCursor: resolveCursor,
    moveCursor: moveCursor,
    PANES: PANES,
    nextPane: nextPane,
    tableState: tableState,
    dispatchPane: dispatchPane,
    countText: countText,
    stateCopy: stateCopy,
    toggleStarts: toggleStarts,
    progressText: progressText,
    confirmLine: confirmLine,
    modeHints: modeHints,
    vpnPart: vpnPart,
    isAbsolutePath: isAbsolutePath,
    toneColor: toneColor,
    visualRange: visualRange,
    targetHashes: targetHashes,
    dispatchState: dispatchState,
    nextAnchor: nextAnchor,
    leaveVisualState: leaveVisualState,
    BUSY_NOTE: BUSY_NOTE,
    hashSet: hashSet,
    emptyMessages: emptyMessages,
    failureText: failureText,
    msgTrack: msgTrack,
    msgFinish: msgFinish,
    msgError: msgError,
    msgNote: msgNote,
    msgKey: msgKey,
    messageLine: messageLine,
    ownsTicket: ownsTicket,
    clipboardOutcome: clipboardOutcome,
    sameFilter: sameFilter,
    filterEntries: filterEntries,
    filterIndex: filterIndex,
    moveFilterCursor: moveFilterCursor,
    sameEntries: sameEntries,
    inspectorInfo: inspectorInfo,
    filesView: filesView,
    withPriority: withPriority,
    moveIndex: moveIndex,
    helpRows: helpRows
  };
}
