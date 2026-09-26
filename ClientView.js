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
      keys: [{ key: "Enter", label: "Start daemon" }, { key: ":", label: "Commands" }]
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

// Key hints for the status line's right side, per mode.
function modeHints(mode, ctx) {
  var c = ctx || {};
  if (mode === "CONFIRM") {
    return [{ key: "y", label: c.accept || "confirm" }, { key: "n/Esc", label: "keep" }];
  }
  if (mode === "INSERT") {
    if (c.purpose === "move") return [{ key: "Enter", label: "move" }, { key: "Esc", label: "cancel" }];
    return [{ key: "Enter", label: "keep filter" }, { key: "Esc", label: "cancel" }];
  }
  return [
    { key: "j/k", label: "move" },
    { key: "Space", label: "start/stop" },
    { key: "x", label: "remove" },
    { key: "/", label: "filter" },
    { key: "s", label: "sort" },
    { key: "q", label: "close" }
  ];
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
    countText: countText,
    stateCopy: stateCopy,
    toggleStarts: toggleStarts,
    progressText: progressText,
    confirmLine: confirmLine,
    modeHints: modeHints,
    vpnPart: vpnPart,
    isAbsolutePath: isAbsolutePath
  };
}
