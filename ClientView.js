.import "Model.js" as Model
.import "CommandRegistry.js" as Registry

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
    sizeText: Model.sizeText(r.size),
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

// --- Responsive layout (D5) -------------------------------------------------

var LAYOUT_WIDE = 1300;
var LAYOUT_MEDIUM = 900;
var LAYOUT_NARROW = 700;
var NARROW_HIDDEN_COLUMNS = ["ul", "eta", "ratio"];

// layoutFor(width) -> {filters, inspector: "docked"|"collapsed",
// hideColumns}. From 1300 px everything docks; from 900 the inspector
// collapses; below 900 the filters too; below 700 the ↑, ETA and Ratio
// columns hide (Name, Size, Progress and ↓ never do). A width of 0 or
// less (a window not laid out yet) counts as wide, so a restored side
// pane isn't treated as just collapsed before the first real size.
function layoutFor(width) {
  var w = Number(width) || 0;
  if (w <= 0) w = LAYOUT_WIDE;
  return {
    filters: w >= LAYOUT_MEDIUM ? "docked" : "collapsed",
    inspector: w >= LAYOUT_WIDE ? "docked" : "collapsed",
    hideColumns: w < LAYOUT_NARROW ? NARROW_HIDDEN_COLUMNS.slice() : []
  };
}

// overlayPane(layout, pane) -> the focused pane when it is collapsed (it
// shows as an overlay over the table's edge), else "".
function overlayPane(layout, pane) {
  var l = layout || {};
  if ((pane === "filters" || pane === "inspector") && l[pane] === "collapsed") return pane;
  return "";
}

// paneStep(pane, delta, layout, ev) -> the pane pane.next/pane.prev goes
// to. Ctrl-h/Ctrl-l on an open overlay close it (back to the table);
// Tab/Shift-Tab keep cycling, opening each collapsed pane in turn.
function paneStep(pane, delta, layout, ev) {
  var e = ev || {};
  var directional = !!(e.modifiers && e.modifiers.ctrl) && (e.key === Registry.KEY.H || e.key === Registry.KEY.L);
  if (directional && overlayPane(layout, pane) !== "") return "table";
  return nextPane(pane, delta);
}

// overlayEscape(ev, mode, layout, pane) -> true when this key is a plain
// Esc in NORMAL with an overlay open: it closes the overlay instead of
// clearing the query or arming Esc Esc.
function overlayEscape(ev, mode, layout, pane) {
  var e = ev || {};
  return mode === "NORMAL" && e.key === Registry.KEY.Escape && overlayPane(layout, pane) !== "";
}

// filterChip(layout, filter) -> the status-line chip ("▸ Seeding") shown
// while the filters are collapsed and the active filter isn't All.
function filterChip(layout, filter) {
  if (!layout || layout.filters !== "collapsed" || isDefaultFilter(filter)) return "";
  return "▸ " + filterLabel(filter);
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
// restored; with rows (or a no-match filter) the real pane is used. The
// empty library keeps the filters pane too, so its a/c/p/x and j/k work
// with zero torrents (ruling BS); its `y` matches nothing there, and the
// window reads an unmatched y in the empty library as add from clipboard.
function dispatchPane(pane, state) {
  // The Settings view (slice 4a) keeps its own columns whatever the torrent
  // view shows: its Esc must work on its down screen too.
  if (Registry.isSettingsPane(pane)) return String(pane);
  if (state === "rows" || state === "noMatch") return String(pane || "table");
  if (state === "empty" && pane === "filters") return "filters";
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
// turtle|add|daemon|install|copy|copyText|prio|dropMagnet (copyText: `y`
// on the trackers and peers tabs)|reannounce|trackerAdd|trackerEdit|
// trackerRemove|ban|fetchMeta (the inspector's actions).
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
  if (kind === "copyText") return "Copying…";
  if (kind === "prio") return "Setting file priority…";
  if (kind === "dropMagnet") return "Dropping the magnet…";
  if (kind === "reannounce") return "Reannouncing…";
  if (kind === "trackerAdd") return "Adding tracker…";
  if (kind === "trackerEdit") return "Changing tracker…";
  if (kind === "trackerRemove") return "Removing tracker…";
  if (kind === "ban") return "Banning peer…";
  if (kind === "fetchMeta") return "Fetching metadata…";
  return "Working…";
}

// The `y` hint of each library confirm; a rename that merges passes its
// own ("merge").
// limitSet (slice 3b) is the D8 share-limit confirm, whose line
// LimitsView.shareConfirm writes.
var LIBRARY_ACCEPT = { libraryRemove: "delete", libraryRename: "rename", libraryPath: "change", categorySet: "set", limitSet: "set" };

// confirmLine(confirm) -> the CONFIRM status line, from
// CommandRegistry.dispatch's `confirm` result {commandId, count, withFiles}.
// {lead, strong, tail, accept}: "Delete 2 torrents" + "and their files" +
// "from disk?", accept "delete". An inspector confirm {kind, label, target}
// names its captured row by label (a tracker's redacted host:port, never
// its URL; a peer's IP, without the port: the ban is IP-wide).
function confirmLine(confirm) {
  var c = confirm || {};
  // A filters-pane confirm (slice 3a): the window built the whole line at
  // key time (LibraryView's delete/rename/path copy) and put it on `line`.
  if (Object.prototype.hasOwnProperty.call(LIBRARY_ACCEPT, c.kind)) {
    return { lead: String(c.line || ""), strong: "", tail: "", accept: c.accept ? String(c.accept) : LIBRARY_ACCEPT[c.kind] };
  }
  if (c.kind === "trackerRemove" || c.kind === "peerBan") {
    var label = String(c.label !== undefined && c.label !== null ? c.label : ((c.target || {}).label || ""));
    if (c.kind === "trackerRemove") {
      return { lead: "Remove tracker " + label + " from this torrent?", strong: "", tail: "", accept: "remove" };
    }
    return { lead: "Ban " + label + " from all torrents? ", strong: "", tail: "It goes on qBittorrent's IP ban list.", accept: "ban" };
  }
  // A setting's confirm (slice 4a): settingQuestion's line, then the
  // schema's consequence (SettingsView.confirmFor).
  if (c.kind === "settingConfirm") {
    return { lead: String(c.line || "") + " ", strong: "", tail: String(c.detail || ""), accept: c.accept ? String(c.accept) : "set" };
  }
  var n = Number(c.count) || 0;
  var t = plural(n, "torrent", "torrents");
  if (c.withFiles === true) {
    return { lead: "Delete " + t + " ", strong: "and their files", tail: " from disk?", accept: "delete" };
  }
  return { lead: "Remove " + t + "? ", strong: "", tail: "Files stay on disk.", accept: "remove" };
}

// --- Browser-magnet confirm (D3) -------------------------------------------
//
// The window shows Model.magnetConfirmState's current item as a pinned row
// and a MAGNET CONFIRM. It raises that CONFIRM itself, only from NORMAL
// with no overlay or help up, so a reflexive Esc meant for the palette, a
// filter, VISUAL or an overlay never cancels (deletes) a magnet.

var MAGNET_FETCHING_NOTE = "Still fetching the name…";

// magnetItemKey(item) -> one queue item's identity: its magnet URL, which
// an inbox line keeps when the drain turns it into a pending entry, else
// its hash.
function magnetItemKey(item) {
  var i = item || {};
  return String(i.url || i.hash || "");
}

// magnetKeys(pending, inbox) -> every queued item's key, pending first.
function magnetKeys(pending, inbox) {
  var out = [];
  var lists = [pending || [], inbox || []];
  for (var l = 0; l < lists.length; l++) {
    for (var i = 0; i < lists[l].length; i++) out.push(magnetItemKey(lists[l][i]));
  }
  return out;
}

// magnetShown(ms, handledKey) -> whether the window offers ms's current
// item: something is waiting and it isn't the item the window already
// started or cancelled (which stays queued until the next snapshot).
function magnetShown(ms, handledKey) {
  if (!ms || !ms.active) return false;
  var key = magnetItemKey(ms.pending || ms.inbox);
  return key === "" || key !== String(handledKey || "");
}

function isMagnetConfirm(regState) {
  var r = regState || {};
  return r.mode === "CONFIRM" && !!r.pending && r.pending.kind === "magnet";
}

// A waiting magnet takes the CONFIRM only once the window has had no key
// for this long (so the Esc after the one that closed the palette, a
// filter, VISUAL, help, an overlay or a delete CONFIRM does its own job).
var MAGNET_SETTLE_MS = 800;
var MAGNET_WAIT_NOTE = "Magnet waiting \u2014 finish, then confirm";

// magnetSync(mem, regState, ms, keys, ctx) -> {mem, regState, focus,
// focusField, wait}, run whenever the queue, the mode, the pane or the help
// overlay changes, and again after `wait` ms.
//   mem: {seen, handled, focusDue} from the last call (null at first).
//   keys: magnetKeys of the whole queue; ctx: {blocked, opened, now,
//   lastKeyAt, active}, where blocked is true while help or a pane overlay
//   is up, now/lastKeyAt are ms (lastKeyAt 0: no key yet) and active is
//   false when the window is known not to be the active one.
// regState is the next registry state, or null for no change: into a
// magnet CONFIRM (pending.at = now) from NORMAL when an item is shown,
// nothing blocks and no key came in the last MAGNET_SETTLE_MS; back to
// NORMAL once no item is shown. wait is the ms left until that settle
// (0: nothing to wait for). focus asks for the window's attention
// (requestWmFocus) when a new key appears while the window is open. While
// INSERT or COMMAND owns a text field, focusField says the request must
// give the keys back to that field; if the window is already active it
// waits instead (focusDue) and asks once the field is closed.
function magnetSync(mem, regState, ms, keys, ctx) {
  var m = mem || { seen: [], handled: "", focusDue: false };
  var c = ctx || {};
  var list = keys || [];
  var seen = m.seen || [];
  var arrived = false;
  for (var i = 0; i < list.length; i++) {
    if (seen.indexOf(list[i]) === -1) arrived = true;
  }
  var handled = list.indexOf(m.handled) !== -1 ? m.handled : "";
  var shown = magnetShown(ms, handled);
  var r = regState || {};
  var next = null;
  var wait = 0;
  var hasNow = typeof c.now === "number";
  var lastKey = Number(c.lastKeyAt) || 0;
  if (shown && r.mode === "NORMAL" && c.blocked !== true) {
    if (hasNow && lastKey > 0 && c.now - lastKey < MAGNET_SETTLE_MS) {
      wait = MAGNET_SETTLE_MS - (c.now - lastKey);
    } else {
      var pending = { kind: "magnet", commandId: "magnet.start" };
      if (hasNow) pending.at = c.now;
      next = copyState(r, { mode: "CONFIRM", pending: pending, prefix: null, prefixAt: 0, selectionCount: 0 });
    }
  } else if (!shown && isMagnetConfirm(r)) {
    next = copyState(r, { mode: "NORMAL", pending: null });
  }
  var due = list.length > 0 && (m.focusDue === true || (arrived && c.opened === true));
  var typing = r.mode === "INSERT" || r.mode === "COMMAND" || r.mode === "PICKER";
  var hold = typing && c.active !== false;
  return {
    mem: { seen: list.slice(), handled: handled, focusDue: due && hold },
    regState: next,
    focus: due && !hold,
    focusField: due && typing && !hold,
    wait: wait
  };
}

// magnetDeferred(shown, regState) -> whether a shown magnet is waiting for
// its CONFIRM (a mode, help, an overlay or the settle holds it).
function magnetDeferred(shown, regState) {
  return shown === true && !isMagnetConfirm(regState);
}

// withMagnetWait(line, deferred) -> the status line's {text, tone}: the
// message line as it is, or, when it is empty and a magnet waits, the
// muted MAGNET_WAIT_NOTE. It never replaces an error or a note.
function withMagnetWait(line, deferred) {
  var l = line || { text: "", tone: "muted" };
  if (String(l.text || "") !== "" || deferred !== true) return l;
  return { text: MAGNET_WAIT_NOTE, tone: "muted" };
}

function copyState(base, patch) {
  var out = {};
  var k;
  for (k in base) {
    if (Object.prototype.hasOwnProperty.call(base, k)) out[k] = base[k];
  }
  for (k in patch) out[k] = patch[k];
  return out;
}

// magnetAction(ms, commandId) -> what magnet.start / magnet.cancel do to
// ms's current item: {call, kind, note}. call is "start" (startPending),
// "cancel" (cancelPending: deletes the torrent and its files), "drop"
// (dropInboxCurrent: an inbox line with no hash yet, or an error line) or
// "" for nothing; kind is the msgTrack kind; note is shown instead.
function magnetAction(ms, commandId) {
  var s = ms || {};
  if (!s.active) return { call: "", kind: "", note: "" };
  if (commandId === "magnet.start") {
    if (s.isError || s.hash === "") return { call: "", kind: "", note: s.isError ? "" : MAGNET_FETCHING_NOTE };
    if (!s.canStart) return { call: "", kind: "", note: MAGNET_FETCHING_NOTE };
    return { call: "start", kind: "start", note: "" };
  }
  if (commandId === "magnet.cancel") {
    if (s.hash !== "") return { call: "cancel", kind: "delete", note: "" };
    if (s.inbox) return { call: "drop", kind: "dropMagnet", note: "" };
  }
  return { call: "", kind: "", note: "" };
}

// magnetLine(ms) -> the status line's MAGNET CONFIRM:
// {lead, title, tail, more, error, hints}. `Start "<title>"?` and `+N
// more`; an error line shows its error and only Esc (dismiss).
function magnetLine(ms) {
  var s = ms || {};
  var more = Number(s.more) > 0 ? "+" + Number(s.more) + " more" : "";
  if (s.isError) {
    return { lead: "", title: "", tail: "", more: more, error: String(s.error || ""), hints: [{ key: "Esc", label: "dismiss" }] };
  }
  return {
    lead: "Start \"",
    title: String(s.title || ""),
    tail: "\"?",
    more: more,
    error: "",
    hints: [{ key: "Enter", label: "start" }, { key: "Esc", label: "cancel" }]
  };
}

// inputPrompt(purpose, shown) -> {prompt, placeholder} for the INSERT
// line. `shown` is the tracker being changed, already redacted
// (InspectorView.redactUrl): the full old URL never reaches the screen.
var TRACKER_URL_PLACEHOLDER = "udp://, http://, https:// or wss://";
// "limit:" + a LimitsView row key -> [label, placeholder].
var LIMIT_PROMPTS = {
  "limit:dlLimit": ["↓ limit", "500K, 1.5M, 0 or u"],
  "limit:upLimit": ["↑ limit", "500K, 1.5M, 0 or u"],
  "limit:ratioLimit": ["Ratio limit", "1.5, g or n"],
  "limit:seedingTimeLimit": ["Seed time", "90m, 2h, 3d, g or n"],
  // The palette's bulk limits (Task 6); `shown` is "3 torrents" or the name.
  "limit:bulk:dlLimit": ["Download limit", "500K, 1.5M, 0 or u"],
  "limit:bulk:upLimit": ["Upload limit", "500K, 1.5M, 0 or u"],
  "limit:bulk:ratioLimit": ["Ratio limit", "1.5, g or n"]
};
function inputPrompt(purpose, shown) {
  if (purpose === "move") return { prompt: "move to", placeholder: "/absolute/path" };
  if (purpose === "trackerAdd") return { prompt: "Add tracker URL", placeholder: TRACKER_URL_PLACEHOLDER };
  if (purpose === "trackerEdit") return { prompt: "Change " + String(shown || "") + " to:", placeholder: TRACKER_URL_PLACEHOLDER };
  // The filters pane's categories and tags (slice 3a); `shown` is the name
  // being renamed or re-pathed, as the status spells it.
  if (purpose === "categoryAdd") return { prompt: "New category", placeholder: "" };
  if (purpose === "tagAdd") return { prompt: "New tag", placeholder: "" };
  if (purpose === "categoryRename" || purpose === "tagRename") return { prompt: "Rename " + String(shown || "") + " to", placeholder: "" };
  if (purpose === "categoryPath") return { prompt: "Save path for " + String(shown || ""), placeholder: "empty = default" };
  // The Info tab's Limits rows (slice 3b); `shown` is the torrent's name.
  if (Object.prototype.hasOwnProperty.call(LIMIT_PROMPTS, purpose)) {
    return { prompt: LIMIT_PROMPTS[purpose][0] + " for " + String(shown || ""), placeholder: LIMIT_PROMPTS[purpose][1] };
  }
  if (purpose === "settingsSearch") return { prompt: "Search settings", placeholder: "label, help or key" };
  // A setting's input editor (Task 6); `shown` is its label.
  if (purpose === "settingEdit") return { prompt: String(shown || ""), placeholder: "" };
  return { prompt: "/", placeholder: "filter by name, or paste a magnet" };
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
    if (c.purpose === "trackerAdd") return [{ key: "Enter", label: "add" }, { key: "Esc", label: "cancel" }];
    if (c.purpose === "trackerEdit") return [{ key: "Enter", label: "change" }, { key: "Esc", label: "cancel" }];
    if (c.purpose === "categoryAdd" || c.purpose === "tagAdd") return [{ key: "Enter", label: "create" }, { key: "Esc", label: "cancel" }];
    if (c.purpose === "categoryRename" || c.purpose === "tagRename") return [{ key: "Enter", label: "rename" }, { key: "Esc", label: "cancel" }];
    if (c.purpose === "settingsSearch") return [{ key: "Enter", label: "keep results" }, { key: "Esc", label: "clear" }];
    if (c.purpose === "settingEdit" || c.purpose === "categoryPath" || Object.prototype.hasOwnProperty.call(LIMIT_PROMPTS, c.purpose)) return [{ key: "Enter", label: "set" }, { key: "Esc", label: "cancel" }];
    return [{ key: "Enter", label: "keep filter" }, { key: "Esc", label: "cancel" }];
  }
  // The palette and the C/T pickers show their own key hints in a footer.
  if (mode === "COMMAND" || mode === "PICKER") return [];
  if (mode === "VISUAL") {
    return [
      { key: "Space", label: "start/stop" },
      { key: "x", label: "remove" },
      { key: "X", label: "delete files" },
      { key: "Esc", label: "cancel" }
    ];
  }
  if (Registry.isSettingsPane(c.pane)) return settingsFooterKeys(c.pane, c.searching === true, c.editor).concat([{ key: "?", label: "keys" }]);
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

// --- Settings (slice 4a) ----------------------------------------------------

// settingsFooterKeys(column, searching) -> [{key, label}] for the focused
// Settings column's footer (the mockup's): the sections move and open a
// section; the settings list moves and goes back. While a search shows,
// Esc clears it first. editor (Task 6) is SettingsView.editorFor's kind for
// the cursor row: a toggle adds "Space toggle", an input "Enter edit", a
// picker "Enter choose"; none (or no row) adds nothing.
var SETTINGS_EDITOR_KEYS = { toggle: { key: "Space", label: "toggle" }, input: { key: "Enter", label: "edit" }, picker: { key: "Enter", label: "choose" } };
function settingsFooterKeys(column, searching, editor) {
  if (column === "settingsSections") {
    return [{ key: "j/k", label: "section" }, { key: "l", label: "keys" }, { key: "/", label: "search all" }, { key: "Esc", label: "back" }];
  }
  var out = [{ key: "j/k", label: "move" }];
  if (Object.prototype.hasOwnProperty.call(SETTINGS_EDITOR_KEYS, editor)) out.push(SETTINGS_EDITOR_KEYS[editor]);
  return out.concat([{ key: "h", label: "sections" }, { key: "/", label: "search" },
    { key: "Esc", label: searching === true ? "clear search" : "back" }]);
}

// settingQuestion(label, isBool, value, shown) -> {line, accept}: what a
// setting's CONFIRM asks before its consequence, naming the setting and
// the value `y` writes ("Turn DHT off?", "Set Encryption to Require?").
// shown is SettingsView.formatValue's text for value.
function settingQuestion(label, isBool, value, shown) {
  if (isBool === true) {
    var on = value === true || value === "true";
    return { line: "Turn " + String(label) + (on ? " on?" : " off?"), accept: on ? "turn on" : "turn off" };
  }
  return { line: "Set " + String(label) + " to " + String(shown) + "?", accept: "set" };
}

// qbt pref-set's own sentences (tests/test_prefs.py pins them): each names
// its setting or its reason already, so it shows as it is.
var PREF_SENTENCES = ["Set by OmaqBT's setup.", "OmaqBT needs this as it is.", "qBittorrent doesn't let this be changed.",
  "OmaqBT doesn't change secrets yet.", "OmaqBT doesn't change this setting.", "OmaqBT doesn't change this setting yet.",
  "Editing multi-line settings arrives in 4b.", "OmaqBT won't change this setting.",
  "OmaqBT can only change on/off, number and text settings."];

// settingFailure(label, error) -> the status line after a failed write:
// qbt's sentence as it is ("qBittorrent ignored DHT", "Couldn't confirm DHT
// (HTTP 409)", a lock's reason), else "Setting <label> failed: <reason>"
// (a bare refusal reads "HTTP 409").
function settingFailure(label, error) {
  var e = String(error || "").trim();
  if (e === "") return "Setting " + String(label) + " failed.";
  if (PREF_SENTENCES.indexOf(e) !== -1 || e.indexOf("qBittorrent ignored ") === 0 || e.indexOf("Couldn't confirm ") === 0
      || e.indexOf("qBittorrent has no setting called ") === 0) return e;
  return "Setting " + String(label) + " failed: " + refusalDetail(e);
}

// settingsReadNote(tableState, failed, error) -> the status line when
// Settings couldn't read preferences but qBittorrent is up (Ruling DO: the
// down screen alone would blame the API), else "".
function settingsReadNote(tableState, failed, error) {
  if (failed !== true || ["gui", "notInstalled", "daemon", "api", "loading"].indexOf(tableState) !== -1) return "";
  var e = String(error || "").trim();
  return e === "" ? "Couldn't read settings." : "Couldn't read settings: " + refusalDetail(e);
}

// settingsSectionStep(sections, index, delta) -> the section cursor moved
// by delta, clamped at the ends, skipping dimmed sections (RSS · slice 5 is
// never a stop). delta 0 re-clamps a stale index. 0 with no stops.
function settingsSectionStep(sections, index, delta) {
  var list = sections || [];
  var stops = [];
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].dimmed !== true) stops.push(i);
  if (stops.length === 0) return 0;
  var at = Number(index) || 0;
  // The stop at or before index (the first stop when index is before them).
  var pos = 0;
  for (var j = 0; j < stops.length; j++) if (stops[j] <= at) pos = j;
  pos = Math.max(0, Math.min(stops.length - 1, pos + (Number(delta) || 0)));
  return stops[pos];
}

// settingsDownCopy(tableState) -> the down screen Settings shows when
// preferences can't be read: the torrent view's own blocking copy when it
// shows one (daemon down, Qt open, not installed, API down), else the
// api-down copy -- never a new screen. Its keys are the one that works in
// Settings: Esc, back to the torrents (whose screen has the fix).
function settingsDownCopy(tableState) {
  var blocking = ["gui", "notInstalled", "daemon", "api"];
  var c = stateCopy(blocking.indexOf(tableState) !== -1 ? tableState : "api");
  return { title: c.title, tone: c.tone, body: c.body, keys: [{ key: "Esc", label: "Back to torrents" }] };
}

// settingsTitle(section, count, query) -> {title, right} for the settings
// list's pane title: the section and "12 settings", or while a search
// shows, "Search" and "“port” · 7 matches".
function settingsTitle(section, count, query) {
  var n = Number(count) || 0;
  var q = String(query || "").trim();
  if (q !== "") return { title: "Search", right: "“" + q + "” · " + plural(n, "match", "matches") };
  return { title: String(section || ""), right: plural(n, "setting", "settings") };
}

// settingsEntries(rows, searching) -> [{kind: "header", label} |
// {kind: "row", row, index}] for the settings list: a muted group header
// before the first row of each group (SettingsView.rows are in group
// order), none in search results, where each row names its section
// instead. index is the row's position in rows (the cursor's).
function settingsEntries(rows, searching) {
  var list = rows || [];
  var out = [];
  var group = null;
  for (var i = 0; i < list.length; i++) {
    var r = list[i];
    if (searching !== true && r.group !== group) {
      group = r.group;
      out.push({ kind: "header", label: String(group || ""), row: null, index: -1 });
    }
    out.push({ kind: "row", label: "", row: r, index: i });
  }
  return out;
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

// dispatchState(regState, pane, state, hasCursorRow, targets, inspector)
// -> the state handed to CommandRegistry.dispatch. selectionCount means
// something only while mode is VISUAL (the registry contract), so it is 0
// otherwise. `inspector` is inspectorDispatch's result; its fields are
// always written (null/false without one), so a target a previous dispatch
// left in regState never carries over. `picker` is the open C/T picker's
// {queryEmpty, multi} (PICKER's Space/Tab rule), or null; its flags are
// always written too. `settings` is SettingsCommands.flags() while the
// Settings view is open ({key, toggle, editable}: the setting under its
// cursor and whether Space/Enter edit it), or null; written every time.
function dispatchState(regState, pane, state, hasCursorRow, targets, inspector, picker, settings) {
  var st = {};
  var r = regState || {};
  for (var k in r) {
    if (Object.prototype.hasOwnProperty.call(r, k)) st[k] = r[k];
  }
  st.pane = dispatchPane(pane, state);
  st.hasTorrent = state === "rows" && hasCursorRow === true;
  st.selectionCount = st.mode === "VISUAL" ? (targets || []).length : 0;
  var i = inspector || {};
  st.inspectorTarget = i.inspectorTarget || null;
  st.trackersTab = i.trackersTab === true;
  st.filesTab = i.filesTab === true;
  st.inspectorTab = typeof i.inspectorTab === "string" ? i.inspectorTab : "";
  st.limitCursorKey = i.limitCursorKey || null;
  st.limitToggle = i.limitToggle === true;
  st.cursorNoMetadata = i.cursorNoMetadata === true;
  st.cursorStopped = i.cursorStopped === true;
  st.cursorPendingMagnet = i.cursorPendingMagnet === true;
  st.libraryTarget = i.libraryTarget || null;
  var p = picker || {};
  st.pickerQueryEmpty = p.queryEmpty === true;
  st.pickerMulti = p.multi === true;
  var sv = settings || {};
  st.settingsKey = sv.key ? String(sv.key) : null;
  st.settingsToggle = sv.toggle === true;
  st.settingsEditable = sv.editable === true;
  return st;
}

// sameInspectorState(a, b) -> whether two inspectorDispatch results hold
// the same values (the window keeps its palette copy stable across status
// ticks, which rebuild cursorRow and the tab rows every time).
function sameInspectorState(a, b) {
  if (!a || !b) return false;
  var ta = a.inspectorTarget, tb = b.inspectorTarget;
  var sameTarget = ta === tb || (!!ta && !!tb && ta.kind === tb.kind && ta.value === tb.value && ta.label === tb.label);
  var la = a.libraryTarget, lb = b.libraryTarget;
  var sameLibrary = la === lb || (!!la && !!lb && la.kind === lb.kind && la.value === lb.value && la.refusal === lb.refusal);
  return sameTarget && sameLibrary && a.trackersTab === b.trackersTab && a.filesTab === b.filesTab && a.inspectorTab === b.inspectorTab &&
    a.limitCursorKey === b.limitCursorKey && a.limitToggle === b.limitToggle && a.cursorNoMetadata === b.cursorNoMetadata &&
    a.cursorStopped === b.cursorStopped && a.cursorPendingMagnet === b.cursorPendingMagnet;
}

// peerIp(ipPort) -> the peer's IP alone, for the ban confirm (a ban is
// IP-wide, so the port would mislead): "203.0.113.42:6881" ->
// "203.0.113.42", "[2001:db8::1]:51413" -> "2001:db8::1". Anything without
// a recognisable ":port" comes back unchanged.
function peerIp(ipPort) {
  var s = String(ipPort === undefined || ipPort === null ? "" : ipPort);
  var m = /^\[([^\]]*)\]:[0-9]+$/.exec(s);
  if (m) return m[1];
  m = /^([^:\[\]]+):[0-9]+$/.exec(s);
  return m ? m[1] : s;
}

// Ruling BM (LibraryView.LIBRARY_NOT_READY; ClientView can't import
// LibraryView, so the text is repeated here and pinned by a node test).
var LIBRARY_NOT_READY = "Still reading qBittorrent's folders; try again in a moment.";

// libraryTarget(ctx) -> the filters pane's part of the dispatch state: the
// Categories or Tags row under the filters cursor, {kind: "category"|
// "tag", value: name, label: name} (value "" for Uncategorized/Untagged),
// or null on a Status or Trackers row, a cursor not in the list, or when
// the filters pane isn't the one keys go to. A category carries
// `refusal` (LIBRARY_NOT_READY) until ctx.libraryReady: every category
// write waits for qBittorrent's default save path (ruling BM). The name
// is the status's own spelling (a legacy name included); the pane shows
// it as plain text.
function libraryTarget(ctx) {
  var c = ctx || {};
  if (dispatchPane(c.pane, c.state) !== "filters") return null;
  var cursor = c.filterCursor;
  if (!cursor || (cursor.group !== "category" && cursor.group !== "tag")) return null;
  if (filterIndex(c.filterEntries, cursor) < 0) return null;
  var value = String(cursor.value === undefined || cursor.value === null ? "" : cursor.value);
  var t = { kind: String(cursor.group), value: value, label: value };
  if (t.kind === "category" && c.libraryReady !== true) t.refusal = LIBRARY_NOT_READY;
  return t;
}

// inspectorDispatch(ctx) -> the inspector's part of the dispatch state
// (and the filters pane's: libraryTarget, from ctx.filterCursor,
// ctx.filterEntries and ctx.libraryReady):
//   inspectorTarget: {kind: "tracker", value: url, label: host} for the
//     trackers tab's cursor row, {kind: "peer", value: ipPort, label:
//     peerIp(ipPort)} for the peers tab's (qbt bans `value`); null on other tabs, an empty list, a
//     cursor off the list, or when the inspector isn't the focused pane.
//   trackersTab: the focused inspector shows the trackers tab of a cursor
//     torrent (even with no trackers, so `a` can add the first one).
//   filesTab: likewise for the Files tab (the palette's file.cycle reason).
//   cursorNoMetadata / cursorStopped / cursorPendingMagnet: the cursor
//     torrent has no metadata (ctx.noMeta) / is stoppedDL or pausedDL
//     (what qbt fetch-metadata accepts) / is a browser magnet still pending
//     in the handler flow. These follow the cursor from any pane.
// ctx: {pane, state (tableState), tab, trackers, trackerIndex, peers,
// peerIndex, row (the cursor's raw row or null), cursorHash, noMeta,
// pending (Service.magnetPendingHashes), limitRow (the LimitsView.limitRows
// entry under the Info tab's Limits cursor, or null)}.
function inspectorDispatch(ctx) {
  var c = ctx || {};
  var row = c.row || null;
  var focused = dispatchPane(c.pane, c.state) === "inspector" && row !== null;
  var target = null;
  if (focused && (c.tab === "trackers" || c.tab === "peers")) {
    var list = (c.tab === "trackers" ? c.trackers : c.peers) || [];
    var at = Number(c.tab === "trackers" ? c.trackerIndex : c.peerIndex);
    var r = at >= 0 && at < list.length ? list[at] : null;
    if (r && c.tab === "trackers") {
      target = { kind: "tracker", value: String(r.url), label: String(r.host) };
      // InspectorView.trackerRefusal, when c and x can't act on it.
      if (r.refusal) target.refusal = String(r.refusal);
    }
    else if (r) {
      target = { kind: "peer", value: String(r.ipPort), label: peerIp(r.ipPort) };
      // InspectorView.peerRefusal, when b can't ban it.
      if (r.refusal) target.refusal = String(r.refusal);
    }
  }
  var st = row ? String(row.state || "").toLowerCase() : "";
  var hash = String(c.cursorHash || "");
  var limitRow = focused && c.tab === "info" && c.limitRow && c.limitRow.key ? c.limitRow : null;
  return {
    inspectorTarget: target,
    trackersTab: focused && c.tab === "trackers",
    filesTab: focused && c.tab === "files",
    // The tab CommandRegistry's `tabs` (D7) matches against, gated by
    // `focused` exactly like trackersTab/filesTab above. "" when the
    // inspector isn't focused, so a stale tab from a previous dispatch
    // never leaks into an unrelated pane's key.
    inspectorTab: focused ? String(c.tab || "") : "",
    // The Info tab's Limits row under its cursor (limit.edit/limit.toggle's
    // needs), gated like inspectorTab: none unless focused on Info.
    limitCursorKey: limitRow ? String(limitRow.key) : null,
    limitToggle: !!limitRow && limitRow.toggle === true,
    cursorNoMetadata: row !== null && c.noMeta === true,
    cursorStopped: st === "stoppeddl" || st === "pauseddl",
    cursorPendingMagnet: hash !== "" && (c.pending || []).indexOf(hash) !== -1,
    libraryTarget: libraryTarget(c)
  };
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
    groups[g] = { left: src.left, failed: src.failed, error: src.error, done: src.done || 0, total: src.total || 0 };
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
  if (kind === "copyText") return "Couldn't copy";
  if (kind === "prio") return "Couldn't set the file priority";
  if (kind === "files") return "Couldn't read files";
  if (kind === "dropMagnet") return "Couldn't drop the magnet";
  if (kind === "reannounce") return "Couldn't reannounce";
  if (kind === "trackerAdd") return "Couldn't add the tracker";
  if (kind === "trackerEdit") return "Couldn't change the tracker";
  if (kind === "trackerRemove") return "Couldn't remove the tracker";
  if (kind === "ban") return "Couldn't ban the peer";
  if (kind === "fetchMeta") return "Couldn't fetch metadata";
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
// copy (optional, slice 3a): {progress, done, raw, fail} for an action
// whose copy names its target ("Renaming anime → animation…" / "Renamed
// anime → animation"); raw shows the failure as the error text alone (qbt's
// own sentence, e.g. "Rename incomplete (12 of 21 moved); …"); fail names
// the action first ("Deleting category anime failed: HTTP 409"). guard
// (slice 3b, share limits) shows qbt's D8 refusal and its partial write as
// they are (isLimitSentence, Ruling CL 1); every other error gets `fail`.
// tally (slice 3b, a limit write over several chunks): the head of the
// line that says how many torrents changed when a chunk fails after
// another landed ("↓ limit set on 1000 of 1001 torrents; the rest failed
// (HTTP 409)").
function msgTrack(m, ticket, kind, count, hashes, copy) {
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
  var cp = copy || {};
  var text = cp.progress ? String(cp.progress) : progressText(kind, count);
  var group = ids[0];
  var own = (hashes || []).slice();
  // A tally copy: each ticket's chunk size (list[i] ran Model.chunkHashes'
  // chunk i), so msgFinish can count the torrents in chunks that landed.
  var tally = cp.tally ? String(cp.tally) : "";
  var chunks = tally !== "" ? Model.chunkHashes(own) : [];
  var sizes = {};
  for (var c = 0; c < list.length; c++) if ((Number(list[c]) || 0) > 0) sizes[String(Number(list[c]))] = chunks[c] ? chunks[c].length : 0;
  for (var j = 0; j < ids.length; j++) {
    next.tickets[ids[j]] = { kind: kind, count: Number(count) || 0, hashes: own, text: text, group: group, done: cp.done ? String(cp.done) : "", raw: cp.raw === true, fail: cp.fail ? String(cp.fail) : "", guard: cp.guard === true, tally: tally, size: sizes[ids[j]] || 0 };
  }
  next.groups[group] = { left: ids.length, failed: false, error: "", done: 0, total: own.length };
  next.progress = text;
  return next;
}

// A success note for actions whose effect isn't visible in the table.
// fetchMeta has none: its ticket ending isn't the metadata arriving (the
// window shows FETCH_META_DONE_NOTE once the torrent's size is known).
var DONE_NOTES = {
  copy: "Copied magnet.",
  copyText: "Copied",
  reannounce: "Reannounced",
  trackerAdd: "Tracker added",
  trackerEdit: "Tracker changed",
  trackerRemove: "Tracker removed",
  ban: "Peer banned"
};
var FETCH_META_DONE_NOTE = "Metadata received · stopped";

// fetchMetaRefusal(row, fetching) -> "" when `f` can swap the cursor
// torrent (the registry already required no metadata and no pending
// browser magnet), else the note: this window is already fetching it
// (after the swap it runs until qBittorrent stops it at metadata), or it
// isn't stoppedDL/pausedDL, which qbt fetch-metadata refuses too.
function fetchMetaRefusal(row, fetching) {
  if (fetching === true) return "Already fetching metadata.";
  if (!row) return "";
  var st = String(row.state || "").toLowerCase();
  return st === "stoppeddl" || st === "pauseddl" ? "" : "Stop it first.";
}

// fetchHolds(watch, now) -> whether the window keeps its cursor on a
// fetch-metadata swap's hash (ClientCommands' watch {ticket, done, at}):
// while the ticket runs (the hash drops out of the status stream between
// the delete and the re-add), and for FETCH_HOLD_MS after it succeeded,
// in case the status stream lags the re-add. Never after a failure (the
// window drops the watch).
var FETCH_HOLD_MS = 10000;
function fetchHolds(watch, now) {
  if (!watch) return false;
  if (watch.done !== true) return true;
  return (Number(now) || 0) - (Number(watch.at) || 0) <= FETCH_HOLD_MS;
}

// fetchMetaProgress(torrents, hash) -> where a fetch-metadata swap stands
// in Service's torrent list: "absent" (between the delete and the re-add,
// or gone), "received" (size > 0, i.e. the metadata arrived), "stopped"
// (listed, no size, stoppedDL/pausedDL: someone stopped it before the
// metadata came) or "waiting" (listed, running, size still unknown).
function fetchMetaProgress(torrents, hash) {
  var list = torrents || [];
  for (var i = 0; i < list.length; i++) {
    if (Model.torrentId(list[i]) !== hash) continue;
    if (Number(list[i].size) > 0) return "received";
    var st = String(list[i].state || "").toLowerCase();
    return st === "stoppeddl" || st === "pauseddl" ? "stopped" : "waiting";
  }
  return "absent";
}

// fetchWatchOutcome(watch, progress, now) -> what a status tick does with
// one of the window's fetch-metadata watches, given fetchMetaProgress:
// "keep" (the ticket still runs, or it's running without a size yet, or
// it's absent inside the fetchHolds window, or stopped inside
// FETCH_STOPPED_GRACE_MS of the ticket's success, while the status stream
// catches up with the re-add), "received" (report the done note), or
// "quiet" (end it with no note: gone after the hold, or stopped with no
// metadata, so "Fetching metadata…" can't stay forever).
var FETCH_STOPPED_GRACE_MS = 3000;
function fetchWatchOutcome(watch, progress, now) {
  if (!watch) return "quiet";
  if (watch.done !== true) return "keep";
  if (progress === "received") return "received";
  if (progress === "waiting") return "keep";
  if (progress === "absent") return fetchHolds(watch, now) ? "keep" : "quiet";
  return (Number(now) || 0) - (Number(watch.at) || 0) <= FETCH_STOPPED_GRACE_MS ? "keep" : "quiet";
}

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
  var group = next.groups[gid] || { left: 1, failed: false, error: "", done: 0, total: 0 };
  group.left = group.left - 1;
  if (ok === true) group.done = (group.done || 0) + (entry.size || 0);
  if (ok !== true && !group.failed) {
    group.failed = true;
    group.error = String(error || "").trim();
  }
  if (group.left > 0) {
    next.groups[gid] = group;
    return next;
  }
  delete next.groups[gid];
  var done = entry.done || DONE_NOTES[entry.kind];
  if (!group.failed && done) {
    next.note = done;
    next.noteTone = "muted";
  }
  if (group.failed) {
    var err = group.error;
    var detail = refusalDetail(err);
    if (entry.tally && group.done > 0 && group.done < group.total) {
      next.error = entry.tally + " on " + group.done + " of " + group.total + " torrents; the rest failed" + (detail === "" ? "." : " (" + detail.replace(/\.$/, "") + ")");
    } else if (entry.raw === true && err !== "") next.error = err;
    else if (entry.guard === true && isLimitSentence(err)) next.error = err;
    else if (entry.fail) next.error = entry.fail + (err !== "" ? ": " + refusalDetail(err) : ".");
    else next.error = failureText(entry.kind, entry.count) + (err !== "" ? ": " + err : ".");
    next.errorHashes = entry.hashes.slice();
  }
  return next;
}

// Ruling CL 1: the only share-limit failures that name their action
// themselves, and so show as they are: qbt's D8 guard refusal ("N torrents
// already meet that limit, and qBittorrent would remove them.") and its
// partial write ("Share limits set on K of N torrents; …"). Every other
// failure ("2 of those torrents are gone.", a usage line) gets the lead.
function isLimitSentence(err) {
  var e = String(err || "");
  return e.indexOf(" already meet") !== -1 || e.indexOf("Share limits set on ") === 0;
}

// qbt's bare "qBittorrent refused it (HTTP 409)" -> "HTTP 409"; any other
// error as it is.
function refusalDetail(err) {
  var m = /^qBittorrent refused it \((.*)\)$/.exec(err);
  return m ? m[1] : err;
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
var FILTER_EMPTY_NOTES = { category: "No categories yet", tag: "No tags yet" };

function sameFilter(a, b) {
  var x = a || {};
  var y = b || {};
  return String(x.group) === String(y.group) && String(x.value) === String(y.value);
}

// filterEntries(groups) -> Model.filterGroups flattened for the pane:
// a header entry per group, then its items (and, for an empty Categories
// or Tags group, a "note" entry). Every value is a string, a
// number or a bool so the pane can compare lists cheaply.
function filterEntries(groups) {
  var out = [];
  var g = groups || [];
  for (var i = 0; i < g.length; i++) {
    out.push({ kind: "header", group: g[i].group, value: "", label: FILTER_GROUP_TITLES[g[i].group] || String(g[i].group), count: 0, zero: false });
    var items = g[i].items || [];
    var named = false;
    for (var n = 0; n < items.length; n++) if (String(items[n].value) !== "") named = true;
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
    // Slice 3a: an empty Categories or Tags group gets a muted line under
    // Uncategorized/Untagged (kind "note": the cursor never stops on it).
    if (!named && FILTER_EMPTY_NOTES[g[i].group]) {
      out.push({ kind: "note", group: g[i].group, value: "", label: FILTER_EMPTY_NOTES[g[i].group], count: 0, zero: false });
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

// inspectorInfo(row, dateText, noMeta) -> the Info tab for the cursor row,
// or null when there is no cursor row ("Select a torrent"). dateText is
// unused here since Added moved to the Transfer group (InspectorView.
// infoGroups, Ruling T: the approved mockup and the spec's top-block
// field list omit it) -- kept as the second argument so noMeta stays the
// third and Client.qml's call site doesn't need to change. Missing values
// show "—". noMeta (InspectorView.noMetadata's result) swaps the State
// field's percentage for "waiting for metadata" -- true for every torrent
// in the user's library today, whose state is stopped, size unknown.
function inspectorInfo(row, dateText, noMeta) {
  if (!row) return null;
  var r = row;
  var group = Model.statusGroup(r);
  var g = GLYPHS[group] || GLYPHS.stopped;
  var word = progressWord(group, r.state) || group;
  var size = Number(r.size);
  var hasSize = isFinite(size) && size > 0;
  var ratio = Number(r.ratio);
  var hasRatio = r.ratio !== undefined && r.ratio !== null && isFinite(ratio);
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
  var stateSuffix = noMeta === true ? "waiting for metadata" : Model.formatPercent(clamp01(r.progress));
  return {
    name: text(r.name),
    fields: [
      { label: "State", value: g.glyph + " " + word + " · " + stateSuffix, tone: g.tone },
      { label: "Size", value: hasSize ? Model.sizeText(size) + " (" + Model.sizeText(size * clamp01(r.progress)) + " done)" : "—", tone: "fg" },
      { label: "Speed", value: dl === null && ul === null ? "—" : "↓ " + Model.sizeText(dl || 0) + "/s · ↑ " + Model.sizeText(ul || 0) + "/s", tone: "fg" },
      { label: "Peers", value: seeds === null && leechs === null ? "—" : plural(seeds || 0, "seed", "seeds") + " · " + plural(leechs || 0, "leecher", "leechers"), tone: "fg" },
      { label: "Ratio", value: hasRatio ? Math.max(0, ratio).toFixed(2) + " · limit " + Model.ratioLimitLabel(r.ratioLimit === undefined ? -2 : r.ratioLimit) : "—", tone: "fg" },
      { label: "Category", value: text(r.category), tone: "fg" },
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
    var idx = Number(f.index);
    rows.push({
      key: idx,
      index: idx,
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

// --- Command palette --------------------------------------------------------

// fuzzyMatch(query, title) -> {score, indices} | null. Case-insensitive
// subsequence match: every character of `query`, in order, must appear
// somewhere in `title` (not necessarily contiguous). The match picked is
// the leftmost-greedy one (each query character takes the earliest
// available occurrence in `title`), which is deterministic and, if any
// subsequence match exists, always finds one.
//
// Scoring rewards, per matched character: a consecutive run (this match
// immediately follows the previous one), the start of a word (preceded by
// a non-alphanumeric character, or the very first character), and the
// start of the title specifically (index 0, on top of the word-start
// bonus). An empty query matches everything with score 0 and no indices.
var FUZZY_CONSECUTIVE_BONUS = 15;
var FUZZY_WORD_START_BONUS = 10;
var FUZZY_TITLE_START_BONUS = 5;

function isWordBoundaryBefore(title, index) {
  if (index <= 0) return true;
  var c = title.charAt(index - 1);
  return !/[a-z0-9]/i.test(c);
}

function fuzzyMatch(query, title) {
  var q = String(query || "");
  var t = String(title || "");
  if (q === "") return { score: 0, indices: [] };
  var lowerQ = q.toLowerCase();
  var lowerT = t.toLowerCase();
  var indices = [];
  var searchFrom = 0;
  for (var i = 0; i < lowerQ.length; i++) {
    var pos = lowerT.indexOf(lowerQ.charAt(i), searchFrom);
    if (pos === -1) return null;
    indices.push(pos);
    searchFrom = pos + 1;
  }
  var score = 0;
  for (var j = 0; j < indices.length; j++) {
    var idx = indices[j];
    score += 1;
    if (j > 0 && idx === indices[j - 1] + 1) score += FUZZY_CONSECUTIVE_BONUS;
    if (isWordBoundaryBefore(t, idx)) score += FUZZY_WORD_START_BONUS;
    if (idx === 0) score += FUZZY_TITLE_START_BONUS;
  }
  return { score: score, indices: indices };
}

// mruPush(mru, id) -> mru with `id` moved (or inserted) at the front,
// deduped, capped at 20. Pure: never mutates `mru`. The cap is
// Model.PALETTE_MRU_CAP, not a second local constant, so the storage cap
// here and the one sanitizeMruList enforces on load (Model.js) can't drift
// apart.
function mruPush(mru, id) {
  var pushed = String(id);
  var out = [pushed];
  var list = mru || [];
  for (var i = 0; i < list.length; i++) {
    if (String(list[i]) !== pushed) out.push(list[i]);
  }
  return out.slice(0, Model.PALETTE_MRU_CAP);
}

// The groups (and their order) a palette row can belong to -- the same
// four HELP_GROUPS the `?` overlay uses.
var PALETTE_GROUPS = HELP_GROUPS;
var PALETTE_MRU_SHOWN = 5;

// paletteRunsFrom(rows, pane): at least one of a command's commands-table
// rows has panes covering `pane` (directly, or via the any-pane wildcard).
// The palette evaluates a command from the table when it runs there, else
// from the pane the window was in when ":" was pressed (state.pane); a
// command covering neither is dimmed with the pane it needs. Checked on
// the rows (rather than through dispatch/findMatch), so the key's own
// match order doesn't matter.
function paletteRunsFrom(rows, pane) {
  for (var i = 0; i < rows.length; i++) {
    if (Registry.paneMatches(rows[i], pane)) return true;
  }
  return false;
}

function paletteRunsFromTable(rows) {
  return paletteRunsFrom(rows, "table");
}

// The "focus the <pane>" reason for a command whose rows never cover the
// table pane, named after whichever specific pane its rows do require
// (e.g. the Files tab's file.* rows name "inspector"; the filters pane's
// filter.* rows name "filters"). Every current such command's rows agree
// on a single pane, so the first one found is used.
var PALETTE_FOCUS_REASON = { filters: "focus the filters", inspector: "focus the inspector" };

function paletteFocusReason(rows) {
  for (var i = 0; i < rows.length; i++) {
    var panes = rows[i].panes || [];
    for (var j = 0; j < panes.length; j++) {
      var reason = PALETTE_FOCUS_REASON[panes[j]];
      if (reason) return reason;
    }
  }
  return "focus the inspector";
}

// Every raw commands-table row for one command id, merged: keys collected
// (in first-seen order, deduped) across every row sharing the id, exactly
// as helpRows merges them for the `?` overlay. `needs` is taken from the
// first row (every duplicate-id row in the table shares the same `needs`).
function paletteCommandEntries(commandsTable) {
  var order = [];
  var byId = {};
  var list = commandsTable || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row || row.id === null || row.id === undefined) continue;
    if (String(row.id).indexOf("palette.") === 0) continue;
    if (!row.modes || row.modes.indexOf("NORMAL") === -1) continue;
    // Settings' own navigation (slice 4a): only "Settings" itself is listed.
    if (row.paletteHidden === true) continue;
    if (!byId[row.id]) {
      byId[row.id] = { id: row.id, title: row.title, group: row.group, needs: row.needs, tabs: row.tabs, rows: [] };
      order.push(row.id);
    }
    byId[row.id].rows.push(row);
  }
  var out = [];
  for (var j = 0; j < order.length; j++) out.push(byId[order[j]]);
  return out;
}

// paletteEntryFor(entry, state) -> the entry as it stands in `state`
// (Ruling CL 3): a command with several rows shows the first one that
// exists here -- its tab matches and its `when` holds, as dispatch decides
// -- so its title, tabs and needs are that row's (a no-metadata Info tab's
// Space row is "Start download"). With no such row, the entry as it is
// (its first row), which paletteRowFrom then dims.
function paletteEntryFor(entry, state) {
  var s = state || {};
  for (var i = 0; i < entry.rows.length; i++) {
    var row = entry.rows[i];
    if (!Registry.tabMatches(row, s.inspectorTab) || !Registry.whenMatches(row, s)) continue;
    if (i === 0) return entry;
    return { id: entry.id, title: row.title, group: row.group, needs: row.needs, tabs: row.tabs, rows: entry.rows };
  }
  return entry;
}

// paletteTabsReason(tabs) -> "focus the X tab" (one tab) or "focus the X, Y
// or Z tab" (several), the palette's dimmed-row text for a command whose
// rows (D7) don't cover the inspector's current tab.
function paletteTabsReason(tabs) {
  var list = tabs || [];
  if (list.length <= 1) return "focus the " + (list[0] || "") + " tab";
  return "focus the " + list.slice(0, -1).join(", ") + " or " + list[list.length - 1] + " tab";
}

function paletteKeysText(rows) {
  var seen = [];
  for (var i = 0; i < rows.length; i++) {
    var keys = rows[i].keys || [];
    for (var k = 0; k < keys.length; k++) {
      var label = helpKeyLabel(keys[k]);
      if (seen.indexOf(label) === -1) seen.push(label);
    }
  }
  return seen.join(" / ");
}

// paletteRowFrom(entry, state, indices) -> one {kind:"command", ...} row.
// enabled/reason follow the table's own precondition function (reused from
// CommandRegistry, never copied): a command whose rows never cover the
// table pane is disabled with "focus the <pane>" it actually needs (e.g.
// "focus the inspector" for the Files tab's file.* rows, "focus the
// filters" for the filters pane's filter.* rows -- see
// paletteFocusReason) unless the palette was opened from a pane they do
// cover (state.pane); next, a tab-scoped command (D7: file.*, tracker.*,
// peer.ban, limit.*) whose rows don't cover the inspector's current tab is
// disabled with paletteTabsReason -- mirroring findMatch's own pane-then-
// tab order, so the palette never offers a key the registry wouldn't
// resolve; otherwise a failed `needs` precondition disables it with
// Registry.needsReason ("needs a selected torrent", "focus the trackers
// tab", "already has metadata", ...). A row that fails an earlier check
// reports that reason: focusing the right pane/tab is the prerequisite for
// the precondition mattering at all.
function paletteRowFrom(entry, state, indices) {
  var enabled = true;
  var reason = "";
  var pane = state && state.pane ? String(state.pane) : "table";
  if (!paletteRunsFromTable(entry.rows) && !paletteRunsFrom(entry.rows, pane)) {
    enabled = false;
    reason = paletteFocusReason(entry.rows);
  } else if (entry.tabs && !Registry.tabMatches({ tabs: entry.tabs }, state && state.inspectorTab)) {
    enabled = false;
    reason = paletteTabsReason(entry.tabs);
  } else if (!Registry.preconditionMet(entry.needs, state)) {
    enabled = false;
    reason = Registry.needsReason(entry.needs, state);
  } else if (entry.id === "file.cycle" && (entry.tabs || []).indexOf("files") !== -1 && state.cursorNoMetadata === true) {
    // A no-metadata torrent has no files: Space there is Start download
    // (Deviation 3), which this row's title doesn't say.
    enabled = false;
    reason = "no files yet";
  }
  return {
    kind: "command",
    id: entry.id,
    title: entry.title,
    group: entry.group,
    keys: paletteKeysText(entry.rows),
    indices: indices || [],
    enabled: enabled,
    reason: reason
  };
}

function paletteDividerRow() {
  return { kind: "divider", id: null, title: "", group: "", keys: "", indices: [], enabled: false, reason: "" };
}

function paletteTitleAsc(a, b) {
  var ta = String(a.title).toLowerCase();
  var tb = String(b.title).toLowerCase();
  if (ta === tb) return 0;
  return ta < tb ? -1 : 1;
}

// paletteRows(query, commands, mru, state) -> the rows the palette shows.
//
// Empty query: up to 5 MRU commands (in MRU order, dropping ids that
// aren't real commands) that still exist, then a divider (omitted when
// there are no MRU rows to divide from -- a fresh install has no recents,
// and a lone divider above an otherwise-full list reads as a rendering
// glitch), then every other eligible command grouped Torrent/View/
// Library/App and sorted by title within each group.
//
// Non-empty query: every command whose title fuzzy-matches `query`,
// ordered by score descending, ties broken by title; no divider.
//
// A command is eligible when its id isn't null or "palette.*" and its
// `modes` include "NORMAL" -- the same table `commands` (as passed in)
// that helpFor/dispatch read.
function paletteRows(query, commands, mru, state) {
  var entries = paletteCommandEntries(commands).map(function(e) { return paletteEntryFor(e, state); });
  var byId = {};
  var i;
  for (i = 0; i < entries.length; i++) byId[entries[i].id] = entries[i];

  var q = String(query || "");

  if (q === "") {
    var mruIds = [];
    var mlist = mru || [];
    for (i = 0; i < mlist.length && mruIds.length < PALETTE_MRU_SHOWN; i++) {
      var id = mlist[i];
      if (byId[id] && mruIds.indexOf(id) === -1) mruIds.push(id);
    }

    var rowsOut = [];
    for (i = 0; i < mruIds.length; i++) rowsOut.push(paletteRowFrom(byId[mruIds[i]], state, []));
    if (mruIds.length > 0) rowsOut.push(paletteDividerRow());

    var shown = {};
    for (i = 0; i < mruIds.length; i++) shown[mruIds[i]] = true;
    var remaining = [];
    for (i = 0; i < entries.length; i++) {
      if (!shown[entries[i].id]) remaining.push(entries[i]);
    }
    remaining.sort(function(a, b) {
      var ga = PALETTE_GROUPS.indexOf(a.group);
      var gb = PALETTE_GROUPS.indexOf(b.group);
      if (ga !== gb) return ga - gb;
      return paletteTitleAsc(a, b);
    });
    for (i = 0; i < remaining.length; i++) rowsOut.push(paletteRowFrom(remaining[i], state, []));
    return rowsOut;
  }

  var scored = [];
  for (i = 0; i < entries.length; i++) {
    var m = fuzzyMatch(q, entries[i].title);
    if (m) scored.push({ entry: entries[i], score: m.score, indices: m.indices });
  }
  scored.sort(function(a, b) {
    if (a.score !== b.score) return b.score - a.score;
    return paletteTitleAsc(a.entry, b.entry);
  });
  var out = [];
  for (i = 0; i < scored.length; i++) out.push(paletteRowFrom(scored[i].entry, state, scored[i].indices));
  return out;
}

// paletteState(tableState, hasCursorRow, inspector, pane) -> the dispatch
// state paletteRows evaluates commands against: NORMAL, whatever the
// window's actual mode. A command runnable from the table is evaluated as
// the table would; one that only runs in `pane` (the pane the palette was
// opened from, "table" when omitted) is evaluated there, with the
// inspector's fields (inspectorDispatch) so its reason can name the tab.
function paletteState(tableState, hasCursorRow, inspector, pane) {
  return dispatchState({ mode: "NORMAL" }, pane || "table", tableState, hasCursorRow, [], inspector);
}

// paletteSegments(title, indices) -> the title split into runs of
// [{text, matched}], matched runs being the fuzzyMatch indices. The
// palette paints each run as its own PlainText Text, so an untrusted
// title is never parsed as markup.
function paletteSegments(title, indices) {
  var t = String(title || "");
  var hit = {};
  var list = indices || [];
  for (var i = 0; i < list.length; i++) hit[list[i]] = true;
  var out = [];
  for (var j = 0; j < t.length; j++) {
    var m = hit[j] === true;
    if (out.length > 0 && out[out.length - 1].matched === m) out[out.length - 1].text += t.charAt(j);
    else out.push({ text: t.charAt(j), matched: m });
  }
  return out;
}

// A row is selectable when it isn't a divider and isn't disabled. Divider
// is the one reserved `kind` (ListOverlay's contract, slice 3a Task 4):
// this reads "not a divider" rather than "kind === 'command'" so a
// picker's rows (whatever kind they use, or none) work with paletteFirst/
// paletteMove/paletteCursorFor/paletteCommandCount without Task 6 having
// to touch them.
function paletteSelectable(row) {
  return !!row && row.kind !== "divider" && row.enabled === true;
}

function paletteRealRow(row) {
  return !!row && row.kind !== "divider";
}

// paletteFirst(rows) -> where the palette cursor starts: the first enabled
// row, else the first real (non-divider) row (so Enter can still report
// why every match is disabled), else -1.
function paletteFirst(rows) {
  var list = rows || [];
  for (var i = 0; i < list.length; i++) if (paletteSelectable(list[i])) return i;
  for (var j = 0; j < list.length; j++) if (paletteRealRow(list[j])) return j;
  return -1;
}

// paletteMove(rows, index, delta) -> the next enabled command row in the
// direction of delta (+1 down, -1 up), skipping dividers and disabled rows.
// No wrap: with nothing further that way, the cursor stays where it is.
function paletteMove(rows, index, delta) {
  var list = rows || [];
  var step = delta < 0 ? -1 : 1;
  for (var i = index + step; i >= 0 && i < list.length; i += step) {
    if (paletteSelectable(list[i])) return i;
  }
  return index;
}

// paletteCursorFor(rows, id) -> the row of command `id` when it is still
// there and enabled (the rows were rebuilt under the cursor, e.g. a status
// tick), else where a fresh list starts (paletteFirst).
function paletteCursorFor(rows, id) {
  var list = rows || [];
  for (var i = 0; i < list.length; i++) {
    if (paletteSelectable(list[i]) && list[i].id === id) return i;
  }
  return paletteFirst(list);
}

// paletteCommandCount(rows) -> how many real rows (not dividers) there
// are, for the palette's (or a picker's) "N of M" count.
function paletteCommandCount(rows) {
  var n = 0;
  var list = rows || [];
  for (var i = 0; i < list.length; i++) if (paletteRealRow(list[i])) n++;
  return n;
}

// palettePane(commands, id, pane) -> the pane a palette command runs in:
// the current pane when one of the command's NORMAL rows works there (Sort
// works anywhere, Open folder from the inspector), otherwise "table" (the
// pane paletteRows evaluated it for; e.g. Pause/resume from the filters).
function palettePane(commandsTable, id, pane) {
  var list = commandsTable || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (!row || row.id !== id || row.modes.indexOf("NORMAL") === -1) continue;
    if (Registry.paneMatches(row, pane)) return String(pane);
  }
  return "table";
}

// paletteRangeCommand(commandsTable, id) -> whether a palette opened on a
// VISUAL range runs `id` on that range: it has a VISUAL row acting on the
// selection (Space/x/X/e, C/T, the bulk limits). Anything else runs as
// from NORMAL.
function paletteRangeCommand(commandsTable, id) {
  var list = commandsTable || [];
  for (var i = 0; i < list.length; i++) {
    var row = list[i];
    if (row && row.id === id && row.needs === "selection" && row.modes.indexOf("VISUAL") !== -1) return true;
  }
  return false;
}

// rangeState(st, count) -> a dispatch state as if in VISUAL over count
// rows (a palette opened on a range, whose own mode is NORMAL by then).
function rangeState(st, count) {
  var out = {};
  for (var k in st || {}) {
    if (Object.prototype.hasOwnProperty.call(st, k)) out[k] = st[k];
  }
  out.mode = "VISUAL";
  out.selectionCount = Number(count) || 0;
  return out;
}

// paletteOwnsKey(ev) -> whether the palette's text field hands this key to
// the window instead of typing it: every key COMMAND mode resolves (Esc,
// Enter, Up/Down, Ctrl-n/Ctrl-p, Tab), plus Shift-Tab, which would
// otherwise move focus out of the field.
function paletteOwnsKey(ev) {
  if (ev && ev.key === Registry.KEY.Backtab) return true;
  return Registry.dispatch({ mode: "COMMAND" }, ev).commandId !== null;
}

// overlayOwnsKey(keyMode, ev, queryEmpty) -> whether ListOverlay's field
// hands this key back to the window (keyForwarded) instead of typing it.
// The shared decision behind both CommandPalette and a slice 3a picker
// (ListOverlay's own Keys.onPressed calls this, keyMode being its own
// `keyMode` property):
//   COMMAND -- exactly paletteOwnsKey (unchanged).
//   PICKER  -- Tab, Backtab, Enter, Esc, Up, Down, Ctrl-p and Ctrl-n
//   always; Space only while the field is empty (queryEmpty, read before
//   this keystroke edits it). Whether an empty-query Space or a Tab
//   actually *does* anything is PICKER's own dispatch rule (pickerMulti);
//   here we only decide forward-vs-type, so a single-choice picker's
//   empty-query Space is still forwarded (and dispatch quietly drops it)
//   rather than typed, and Tab never falls through to a focus change.
function overlayOwnsKey(keyMode, ev, queryEmpty) {
  if (keyMode !== "PICKER") return paletteOwnsKey(ev);
  if (!ev) return false;
  var key = ev.key;
  if (key === Registry.KEY.Backtab || key === Registry.KEY.Tab) return true;
  if (key === Registry.KEY.Return || key === Registry.KEY.Enter) return true;
  if (key === Registry.KEY.Escape || key === Registry.KEY.Up || key === Registry.KEY.Down) return true;
  var mods = ev.modifiers || {};
  if (mods.ctrl === true && (key === Registry.KEY.P || key === Registry.KEY.N)) return true;
  if (key === Registry.KEY.Space) return queryEmpty === true;
  return false;
}

// The status-line note for Enter (or a click) on a disabled palette row;
// "" for a row blocked with no note (reason "", e.g. the Limits rows).
function paletteReasonNote(row) {
  if (!row.reason) return "";
  return String(row.title) + ": " + String(row.reason) + ".";
}

// The palette's empty result, quoted like the table's "Nothing matches".
function paletteEmptyText(query) {
  return "No command matches “" + String(query || "") + "”";
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
    sizeText: Model.sizeText,
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
    layoutFor: layoutFor,
    overlayPane: overlayPane,
    paneStep: paneStep,
    overlayEscape: overlayEscape,
    filterChip: filterChip,
    tableState: tableState,
    dispatchPane: dispatchPane,
    countText: countText,
    stateCopy: stateCopy,
    toggleStarts: toggleStarts,
    progressText: progressText,
    confirmLine: confirmLine,
    modeHints: modeHints,
    settingsFooterKeys: settingsFooterKeys,
    settingQuestion: settingQuestion,
    settingFailure: settingFailure,
    settingsReadNote: settingsReadNote,
    settingsSectionStep: settingsSectionStep,
    settingsDownCopy: settingsDownCopy,
    settingsTitle: settingsTitle,
    settingsEntries: settingsEntries,
    inputPrompt: inputPrompt,
    vpnPart: vpnPart,
    isAbsolutePath: isAbsolutePath,
    toneColor: toneColor,
    visualRange: visualRange,
    targetHashes: targetHashes,
    dispatchState: dispatchState,
    inspectorDispatch: inspectorDispatch,
    libraryTarget: libraryTarget,
    sameInspectorState: sameInspectorState,
    FETCH_META_DONE_NOTE: FETCH_META_DONE_NOTE,
    fetchMetaRefusal: fetchMetaRefusal,
    fetchMetaProgress: fetchMetaProgress,
    fetchHolds: fetchHolds,
    fetchWatchOutcome: fetchWatchOutcome,
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
    helpRows: helpRows,
    fuzzyMatch: fuzzyMatch,
    mruPush: mruPush,
    paletteRows: paletteRows,
    paletteState: paletteState,
    paletteSegments: paletteSegments,
    paletteFirst: paletteFirst,
    paletteMove: paletteMove,
    paletteCursorFor: paletteCursorFor,
    paletteCommandCount: paletteCommandCount,
    palettePane: palettePane,
    paletteOwnsKey: paletteOwnsKey,
    overlayOwnsKey: overlayOwnsKey,
    paletteReasonNote: paletteReasonNote,
    paletteRangeCommand: paletteRangeCommand,
    rangeState: rangeState,
    paletteEmptyText: paletteEmptyText,
    MAGNET_FETCHING_NOTE: MAGNET_FETCHING_NOTE,
    magnetItemKey: magnetItemKey,
    magnetKeys: magnetKeys,
    magnetShown: magnetShown,
    isMagnetConfirm: isMagnetConfirm,
    MAGNET_SETTLE_MS: MAGNET_SETTLE_MS,
    MAGNET_WAIT_NOTE: MAGNET_WAIT_NOTE,
    magnetSync: magnetSync,
    magnetDeferred: magnetDeferred,
    withMagnetWait: withMagnetWait,
    magnetAction: magnetAction,
    magnetLine: magnetLine,
    peerIp: peerIp
  };
}
