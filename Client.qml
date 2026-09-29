pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import "Model.js" as Model
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The OmaqBT window (the manifest's `panel` entry point). The shell's panel
// Loader creates this item when `shell toggle/summon aweiward.omaqbt` opens
// it and destroys it on hide (no keepLoaded), injecting `service`, `shell`
// and `manifest` right after creation.
//
// Lifecycle follows ~/.local/share/omarchy/shell/plugins/dev-gallery/
// GalleryPanel.qml: a FloatingWindow child, `open()` from the host, and a
// WM close routed back through `shell.hide` so the host's open map and
// `toggle` stay right. `opened` is what the host's isPluginOpen() reads.
//
// Keys: one raw Keys.onPressed on `keyRoot` builds the CommandRegistry
// event, calls Registry.dispatch, and hands the result to run(). No
// PanelKeyCatcher (it eats h/j/k/l, Esc, Tab, Enter and Space).
//
// Decisions (targets, the VISUAL range, messages, filter/file cursors,
// inspector fields, help rows) live in ClientView.js as pure, node-tested
// functions; this file wires them to Service and the panes.
Item {
  id: root

  // ---- host injections ----------------------------------------------------
  property var service: null
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "aweiward.omaqbt"

  // ---- lifecycle ----------------------------------------------------------
  // True from creation: a shell.json reload re-creates this item for a
  // panel that is still open without calling open(), and the window maps
  // on its own (FloatingWindow is visible by default).
  property bool opened: true
  property bool closing: false

  // ---- view state (persisted through service.saveViewState) ---------------
  property var filter: View.defaultFilter()
  property string sortMode: "added"
  property bool sortDesc: true
  property string cursorHash: ""
  property string pane: "table"
  // Set by the first user-driven view change. Until then the window keeps
  // following service.viewState, whose FileView load is asynchronous and
  // can land after this item was built.
  property bool viewTouched: false
  // The palette's recently used command ids, newest first (View.mruPush).
  property var paletteMru: []
  // The inspector's shown tab (setInspectorTab; applyViewState restores it
  // directly, like pane, so a restore isn't a user change).
  property string inspectorTab: "info"

  // ---- per-view, not persisted --------------------------------------------
  // The view standing in the window (slice 5a, eng C1): "torrents" (the
  // three panes), "settings" (`,`) or "search" (`F`). Only showView() and
  // leaveView() change it: they open and close Settings and Search, Esc
  // leaves through them (each view's leaveRequested), and they decide what
  // a browser magnet's CONFIRM or a torrent row from the palette closes.
  // Never saved: a reopened window lands on the torrents.
  // Slice 5b0: every view but the torrents is a host (the view host
  // contract, docs/plans/slice-5b0.md: SettingsHost, SearchPane), looked up
  // by name (viewHost); the Client and ClientCommands loop over the hosts
  // instead of branching on a view's name. A new view is a Registry.VIEWS
  // entry plus its host in viewHostList.
  property string activeView: "torrents"
  property string textQuery: ""
  property var regState: ({ mode: "NORMAL", pane: "table", prefix: null, prefixAt: 0, hasTorrent: false, selectionCount: 0, pending: null })
  property var confirm: null
  // The torrents a pending CONFIRM will act on, fixed when it was asked:
  // a status tick while the question is up may move the cursor, and `y`
  // must never delete a different torrent than the one named.
  property var confirmHashes: []
  property string inputPurpose: ""
  property string queryBeforeEdit: ""
  property var moveHashes: []
  // The status-line message state (View.emptyMessages): this window's
  // tickets and their progress, an error kept until the next key (with its
  // rows marked `!`), and one-key notes.
  property var messages: View.emptyMessages()
  readonly property var messageLine: View.messageLine(messages)
  // When `y` asked for the clipboard (ms); its answer is used only if it
  // arrives soon after, so a stale request can't add something later.
  property double clipboardAskedAt: 0

  // ---- VISUAL ----------------------------------------------------------------
  // The row V was pressed on; the range is anchor..cursor in the current
  // order (View.visualRange). Empty outside VISUAL.
  property string anchorHash: ""
  readonly property var visualHashes: mode === "VISUAL" ? View.visualRange(tableRows, anchorHash, cursorHash) : []
  // The rows painted with Style.selectionFill: the live range in VISUAL,
  // and the fixed range a CONFIRM, a C/T picker or the palette will act on.
  readonly property var rangeHashes: View.hashSet(mode === "VISUAL" ? visualHashes
    : (mode === "CONFIRM" && confirmHashes.length > 1 ? confirmHashes : (mode === "PICKER" ? commands.pickerTargets : commands.heldRange)))
  readonly property var errorHashes: View.hashSet(messages.errorHashes)

  // ---- filter pane -------------------------------------------------------------
  property var filterEntries: []
  // The j/k cursor in the filter pane; Enter applies it (becomes `filter`).
  property var filterCursor: View.defaultFilter()

  // ---- inspector -----------------------------------------------------------------
  readonly property var cursorRow: tableState === "rows" ? rawRow(cursorHash) : null
  readonly property var inspectorInfo: View.inspectorInfo(cursorRow, function(sec) {
    return Qt.formatDateTime(new Date(sec * 1000), "yyyy-MM-dd hh:mm")
  }, infoTab.noMeta)
  // Bound to a bool, not to cursorRow: cursorRow is a fresh object every
  // status tick, and re-running filesView would hand the Files ListView a
  // new model and reset its scroll on every tick.
  readonly property bool hasCursorRow: tableState === "rows" && cursorIndex >= 0
  readonly property var filesState: View.filesView(
    service && hasCursorRow ? (service.filesByHash || {})[cursorHash] : [],
    service && hasCursorRow ? (service.filesStatusByHash || {})[cursorHash] : undefined)
  property int fileIndex: 0
  // The file `index` (InspectorView.keyedIndex's key, not a position)
  // under the cursor, so a refresh that reorders or drops rows can carry
  // fileIndex to the same file (or clamp) instead of a stale position.
  property int fileCursorKey: -1
  onFileIndexChanged: fileCursorKey = filesState.rows[fileIndex] ? filesState.rows[fileIndex].key : -1
  // The hash whose files this window last asked for, and whether a failed
  // answer for it still has to be reported on the status line.
  property string filesLoadedHash: ""
  property bool filesErrorPending: false
  // A files refresh (same hash): keep the cursor on the same file by key;
  // an empty refresh (a reload's brief `[]`) leaves it alone rather than
  // clamping to a list that is only transiently empty.
  onFilesStateChanged: {
    var rows = filesState.rows
    if (rows.length === 0) return
    var next = InspectorView.keyedIndex(rows, fileCursorKey, fileIndex)
    fileIndex = next
    fileCursorKey = rows[next] ? rows[next].key : -1
  }

  // ---- trackers and peers (inspector tabs 2, 3) -----------------------------------
  // The torrent the sidecar reads ("" with no row, or closing). Replies are
  // read under the current hash+tab only, so a late one for another torrent
  // never paints; one older than inspectSince (ms, when this key became
  // current) counts as none (A->B->A). inspectNow: tabState's clock.
  readonly property string watchHash: opened && hasCursorRow ? cursorHash : ""
  onWatchHashChanged: commands.syncInspect(true)
  property double inspectSince: 0
  property double inspectNow: 0
  readonly property var inspectEntry: service && watchHash !== "" ? (service.inspectByKey || {})[watchHash + "|" + inspectorTab] : undefined
  onInspectEntryChanged: commands.checkInspectError()
  readonly property bool sidecarUp: !!service && !service.sidecarDown
  readonly property var trackersView: InspectorView.listTab("trackers", inspectorTab === "trackers" ? inspectEntry : undefined, inspectSince, inspectNow, sidecarUp, cursorRow)
  readonly property var peersView: InspectorView.listTab("peers", inspectorTab === "peers" ? inspectEntry : undefined, inspectSince, inspectNow, sidecarUp, cursorRow)
  // InspectorView.chartTab(...): {state, series, error}.
  readonly property var chartView: InspectorView.chartTab(inspectorTab === "chart" ? inspectEntry : undefined, inspectSince, inspectNow, sidecarUp)
  // The Info tab's pieces bar and Transfer/Torrent groups. Read from the
  // "|info" key regardless of which tab is shown, unlike inspectEntry
  // above: a switch to Files needs this torrent's no-metadata state too,
  // and InspectorView.infoView's own staleness/sidecar gate already blanks
  // it once inspectSince moves past a switch away from Info (Task 3's
  // pattern, same as tabState).
  readonly property var infoEntry: service && watchHash !== "" ? (service.inspectByKey || {})[watchHash + "|info"] : undefined
  readonly property var infoTab: InspectorView.infoView(infoEntry, inspectSince, sidecarUp, cursorRow, function(sec) {
    return Qt.formatDateTime(new Date(sec * 1000), "yyyy-MM-dd hh:mm")
  })
  // Each list's cursor, kept on its url / ip:port (ClientCommands.stickRow).
  property int trackerIndex: 0
  property int peerIndex: 0
  onTrackersViewChanged: trackerIndex = commands.stickRow("trackers", trackersView.rows, trackerIndex)
  onPeersViewChanged: peerIndex = commands.stickRow("peers", peersView.rows, peerIndex)
  // What x/c/b/f act on (View.inspectorDispatch, with the filters pane's
  // a/c/p/x row), fed to every dispatch.
  // inspectorState is its copy that only changes with its values, so a
  // status tick doesn't rebuild an open palette's rows.
  readonly property var inspectorNow: View.inspectorDispatch({ pane: pane, state: tableState, tab: inspectorTab,
    trackers: trackersView.rows, trackerIndex: trackerIndex, peers: peersView.rows, peerIndex: peerIndex, row: cursorRow,
    cursorHash: cursorHash, noMeta: infoTab.noMeta, pending: service ? service.magnetPendingHashes : [],
    filterCursor: filterCursor, filterEntries: filterEntries, libraryReady: commands.libraryReady, limitRow: commands.limitCursorRow })
  property var inspectorState: View.inspectorDispatch({})
  onInspectorNowChanged: if (!View.sameInspectorState(inspectorState, inspectorNow)) inspectorState = inspectorNow

  // ---- responsive layout (D5) ------------------------------------------------------
  // A collapsed pane with focus shows as an overlay; a resize that
  // collapses the focused pane gives focus back to the table.
  readonly property var layout: View.layoutFor(keyRoot.width)
  readonly property bool filtersDocked: layout.filters === "docked"
  readonly property bool inspectorDocked: layout.inspector === "docked"
  onFiltersDockedChanged: if (!filtersDocked && pane === "filters") setPane("table")
  onInspectorDockedChanged: if (!inspectorDocked && pane === "inspector") setPane("table")

  // ---- browser-magnet confirm (D3, MagnetConfirm.qml) -------------------------------
  readonly property var magnetState: Model.magnetConfirmState(service ? service.magnetPending : [],
    service ? service.magnetInbox : [], service ? service.torrents : [], Date.now() / 1000)
  onMagnetStateChanged: magnetRow.sync()
  // Deferred, so the key that changed the mode (palette.close, insert.cancel)
  // finishes before a waiting magnet takes the CONFIRM.
  // Its question is on the torrent view: whichever view stands in leaves.
  onModeChanged: { Qt.callLater(magnetRow.sync); if (View.isMagnetConfirm(regState)) leaveView() }
  onPaneChanged: Qt.callLater(magnetRow.sync)
  onHelpOpenChanged: Qt.callLater(magnetRow.sync)
  // When handleKey last ran (ms): a waiting magnet settles after it.
  property double lastKeyAt: 0
  readonly property var statusMessage: View.withMagnetWait(messageLine, magnetRow.deferred)

  // ---- help ------------------------------------------------------------------------
  property bool helpOpen: false
  property string helpPane: "table"

  // ---- rows ---------------------------------------------------------------
  property var rawRows: []
  property var tableRows: []
  property int liveCount: 0
  property int matchesInAll: 0
  readonly property int cursorIndex: View.indexOfHash(tableRows, cursorHash)

  // ---- loading ------------------------------------------------------------
  // Service has no "first status arrived" flag. Any status field moving off
  // its initial value means one arrived; if none moves within the grace
  // (e.g. nothing installed), the real state shows anyway.
  property bool loadGraceOver: false
  property bool loadingTextDue: false
  readonly property bool statusSeen: !!service && (service.installed || service.daemon || service.api
    || service.lockHolder !== "none" || (service.torrents || []).length > 0 || String(service.lastError || "") !== "")
  readonly property bool loading: !statusSeen && !loadGraceOver

  readonly property string tableState: View.tableState({
    loading: loading,
    installed: !!service && service.installed,
    daemon: !!service && service.daemon,
    lockHolder: service ? service.lockHolder : "none",
    api: !!service && service.api,
    liveCount: liveCount,
    visibleCount: tableRows.length
  })
  readonly property var stateCopy: View.stateCopy(tableState, { query: textQuery, filter: filter, matchesInAll: matchesInAll })
  readonly property string mode: regState.mode
  // The registry pane keys go to: the active view's pane (a Settings column,
  // a Search pane) while one stands in, else the torrent pane (also for a
  // view name with no host, so a key never reaches a pane nobody shows).
  readonly property string keyPane: activeView === "torrents" || !viewHost(activeView) ? View.dispatchPane(pane, tableState)
    : viewHost(activeView).column
  // Search's dispatch flags while it shows (null otherwise), as
  // SettingsCommands.flags() is Settings'. The footer reads it.
  readonly property var searchFlags: viewHost("search") ? viewHost("search").flagsNow() : null

  // ---- view hosts (slice 5b0) -----------------------------------------------

  // Every view's host; viewHost finds one by its `name`.
  readonly property var viewHostList: [settingsHost, searchView]
  // Every Registry.VIEWS entry but the torrents, in registry order.
  readonly property var hostNames: Registry.VIEWS.filter(function (v) { return v !== "torrents" })

  // viewHost(name) -> that view's host, or null (the torrents, or a name
  // no host has).
  function viewHost(name) {
    if (name === "torrents") return null
    var list = viewHostList
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === name) return list[i]
    return null
  }

  // {name: flagsNow()} for every host: View.dispatchState's `views` map.
  function viewFlags() {
    var out = ({})
    var names = hostNames
    for (var i = 0; i < names.length; i++) {
      var h = viewHost(names[i])
      if (h) out[names[i]] = h.flagsNow()
    }
    return out
  }

  // ---- lifecycle functions ------------------------------------------------

  function open(payloadJson) {
    closing = false
    opened = true
    window.visible = true
    if (service) service.windowOpen = true
    Qt.callLater(root.requestWmFocus)
  }

  // Closes the window and tells the host. The shell's hide() calls close()
  // on this item before it drops the panel from its open map, so the guard
  // turns that nested call into a no-op instead of a loop.
  function close() {
    if (closing) return
    closing = true
    // An open palette/picker would lose its field focus; reopening lands on the torrents.
    if (mode === "COMMAND") commands.closePalette(); else if (mode === "PICKER") commands.closePicker()
    if (mode === "INSERT" && View.VIEW_INPUT_PURPOSES.indexOf(inputPurpose) !== -1) leaveInsert()
    // Every view drops what it holds (Settings its CONFIRM; D7/OV14:
    // leaving Search keeps its job, closing the window doesn't), in
    // Registry.VIEWS order.
    for (var i = 0; i < hostNames.length; i++) {
      var h = viewHost(hostNames[i])
      if (h) h.windowClosed()
    }
    leaveView()
    helpOpen = false
    opened = false
    window.visible = false
    if (service) service.windowOpen = false
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    closing = false
  }

  // Keyboard focus on open: WmFocus retries until the WM activates the
  // window. Kept here for open(), the window handlers and the harness.
  // target: a text field to give the keys back to (default keyRoot).
  function requestWmFocus(target) {
    wmFocus.requestWmFocus(target)
  }

  function windowActive() { return wmFocus.windowActive() }

  // ---- views (slice 5a, eng C1) ----------------------------------------------

  // Makes `name` the active view: the one standing in leaves first
  // (closeView), then the new one opens (openView) with activeView already
  // set, so its `open` is true while it starts. "torrents" just leaves.
  function showView(name) {
    var next = Registry.VIEWS.indexOf(name) !== -1 ? name : "torrents"
    if (next === activeView) return
    var from = viewHost(activeView)
    activeView = next
    if (from) from.closeView()
    var to = viewHost(next)
    if (to) to.openView()
  }

  // Back to the torrents, with their pane, cursor and filter as they were.
  function leaveView() { showView("torrents") }
  function typingField() { return commands.typingField() }

  // ---- view state ----------------------------------------------------------

  function applyViewState(vs) {
    var v = Model.parseViewState(vs)
    filter = v.filter
    sortMode = View.validSort(v.sort)
    sortDesc = v.desc
    cursorHash = v.cursorHash
    paletteMru = v.paletteMru
    // Not setPane/setInspectorTab: those save, and a restore must not
    // count as a user change. VISUAL is table-only, so it ends here too.
    leaveVisual()
    pane = v.pane
    inspectorTab = v.inspectorTab
    rebuildRows(true)
  }

  function saveView() {
    viewTouched = true
    if (!service || typeof service.saveViewState !== "function") return
    service.saveViewState({ filter: filter, sort: sortMode, desc: sortDesc, cursorHash: cursorHash, pane: pane, paletteMru: paletteMru, inspectorTab: inspectorTab })
  }

  // Switches the inspector's tab (a click, or a digit key's inspector.*
  // command) and persists it, exactly as setPane persists a pane change.
  function setInspectorTab(tab) {
    if (tab === inspectorTab) return
    inspectorTab = tab
    saveView()
  }

  function adoptService() {
    if (!service) return
    applyViewState(service.viewState)
    if (window.visible) service.windowOpen = true
  }

  // ---- rows ------------------------------------------------------------------

  // Scrolls the cursor row into view once the ListView has laid out the
  // latest rows (ListView.Contain: no scroll when it is already visible).
  function revealCursor() {
    Qt.callLater(function() { table.positionAt(root.cursorIndex) })
  }

  // reveal: scroll the cursor row into view afterwards. Only changes the
  // user started pass it (restore, s/S, a filter or query change; cursor
  // keys reveal through setCursor). Background status ticks never do, even
  // when a dynamic sort moves the cursor's index, so a tick can't snap the
  // view back while the user scrolls.
  function rebuildRows(reveal) {
    if (!service) return
    var torrents = service.torrents || []
    var pending = service.magnetPendingHashes || []
    var v = View.viewRows(torrents, pending, filter, textQuery, sortMode, sortDesc)
    var prevIndex = View.indexOfHash(tableRows, cursorHash)
    var live = Model.excludePending(torrents, pending)
    table.setRows(v.rows)
    rawRows = v.raw
    tableRows = v.rows
    liveCount = live.length
    matchesInAll = Model.filterByQuery(live, textQuery).length
    var entries = View.filterEntries(Model.filterGroups(live, service.categories || [], service.tags || []))
    if (!View.sameEntries(filterEntries, entries)) filterEntries = entries
    // An automatic cursor move (its torrent went away, or a restored hash
    // no longer exists) isn't saved; only user moves are.
    // A fetch-metadata swap keeps it on its hash while that drops out, and
    // shows the row once it's back (the re-add can land anywhere).
    var held = commands.holdsCursor(cursorHash)
    if (!held) cursorHash = View.resolveCursor(v.rows, cursorHash, prevIndex)
    commands.checkFetches()
    if ((reveal === true || (held && prevIndex < 0)) && View.indexOfHash(v.rows, cursorHash) >= 0) revealCursor()
  }

  function setCursor(hash) {
    if (hash === cursorHash) return
    cursorHash = hash
    table.positionAt(View.indexOfHash(tableRows, hash))
    saveView()
  }

  function setPane(next) {
    if (next === pane) return
    // Every VISUAL row is table-only, so a pane change (a click on a filter
    // or a file) that stayed in VISUAL would leave no key working, Esc
    // included. Any pane change ends VISUAL first.
    leaveVisual()
    pane = next
    // Entering the filter pane puts its cursor on the active filter.
    if (next === "filters") setFilterCursor(View.filterIndex(filterEntries, filter) >= 0 ? filter : View.moveFilterCursor(filterEntries, null, 1))
    saveView()
  }

  function leaveVisual() {
    if (regState.mode !== "VISUAL") return
    regState = View.leaveVisualState(regState)
    anchorHash = ""
  }

  function setFilterCursor(f) {
    filterCursor = { group: f.group, value: f.value }
    var i = View.filterIndex(filterEntries, filterCursor)
    if (i >= 0) Qt.callLater(function() { filterPane.positionAt(i) })
  }

  function applyFilter(f) {
    filter = { group: f.group, value: f.value }
    rebuildRows(true)
    saveView()
  }

  function rawRow(hash) {
    for (var i = 0; i < rawRows.length; i++) {
      if (Model.torrentId(rawRows[i]) === hash) return rawRows[i]
    }
    return null
  }

  function rawFor(hashes) {
    var out = []
    for (var i = 0; i < rawRows.length; i++) {
      if (hashes.indexOf(Model.torrentId(rawRows[i])) !== -1) out.push(rawRows[i])
    }
    return out
  }

  function opts(hashes) {
    return { origin: "window", hashes: hashes }
  }

  // Runs call(joined, chunk) once per Model.chunkHashes chunk of hashes (one
  // argv string can't carry a large VISUAL range) and returns the tickets,
  // which track() reports as one action.
  function perChunk(hashes, call) {
    var chunks = Model.chunkHashes(hashes)
    var tickets = []
    for (var i = 0; i < chunks.length; i++) tickets.push(call(chunks[i].join("|"), chunks[i]))
    return tickets
  }

  // ---- messages --------------------------------------------------------------

  // Records one of this window's tickets (or the tickets of one chunked
  // action, as an array) and shows its progress.
  function track(ticket, kind, hashes) {
    messages = View.msgTrack(messages, ticket, kind, hashes.length, hashes)
  }

  function note(text, tone) {
    messages = View.msgNote(messages, text, tone)
  }

  // ---- files (inspector tab 4) ----------------------------------------------

  // Asks Service for the cursor row's files when the Files tab shows a row
  // whose files this window hasn't asked for yet (force: `r` reloads).
  function syncFiles(force) {
    if (!service || inspectorTab !== "files" || cursorRow === null) return
    if (!force && filesLoadedHash === cursorHash) return
    if (filesLoadedHash !== cursorHash) { fileIndex = 0; fileCursorKey = -1 }
    filesLoadedHash = cursorHash
    filesErrorPending = true
    service.loadFiles(cursorHash, opts([cursorHash]))
  }

  // A failed read of the files this window asked for goes to the status
  // line once (the Files tab itself shows "Couldn't read files").
  function checkFilesStatus() {
    if (!filesErrorPending || !service) return
    var st = (service.filesStatusByHash || {})[filesLoadedHash]
    if (!st || st.state === "loading") return
    filesErrorPending = false
    if (st.state === "error") {
      messages = View.msgError(messages, View.failureText("files", 1) + (st.error ? ": " + st.error : "."), [])
    }
  }

  function cycleFile(index) {
    var files = service.filesFor(cursorHash)
    if (index < 0 || index >= files.length) return
    var file = files[index]
    var next = Model.cyclePriority(file.priority)
    track(service.setPrio(cursorHash, file.index, next, opts([cursorHash])), "prio", [cursorHash])
    service.setFilesFor(cursorHash, View.withPriority(files, file.index, next))
  }

  // ---- keys --------------------------------------------------------------------

  function handleKey(event) {
    var ev = View.keyEvent(event.key, event.text, event.modifiers, Date.now())
    lastKeyAt = ev.now
    // Any key ends an error (and its row marks) or a note.
    messages = View.msgKey(messages)
    if (helpOpen) {
      // The overlay takes the key that closes it.
      helpOpen = false
      return
    }
    // Esc on an open overlay closes it (no query clear, no Esc Esc). The
    // torrent pane, not keyPane: a down screen dispatches as the table.
    if (View.overlayEscape(ev, regState.mode, layout, activeView !== "torrents" ? keyPane : pane)) { setPane("table"); return }
    dispatchWith(function(st) { return Registry.dispatch(st, ev) }, ev)
  }

  // Resolves a key (Registry.dispatch) or a palette command
  // (Registry.dispatchCommand) against the current state and applies it.
  // fixed: targets captured earlier (a palette opened on a VISUAL range).
  function dispatchWith(resolve, ev, fixed) {
    // Targets are fixed before dispatch: Space/x/X/e from VISUAL come back
    // in NORMAL or CONFIRM, and must still act on the range as it stood.
    var targets = fixed || View.targetHashes(regState.mode, tableRows, cursorHash, anchorHash)
    var res = resolve(registryState(targets))

    regState = res.state
    anchorHash = View.nextAnchor(res.state.mode, res.commandId, anchorHash, cursorHash)
    if (res.confirm) {
      confirm = commands.describeConfirm(res.confirm)
      confirmHashes = targets
      return
    }
    if (res.state.mode !== "CONFIRM") confirm = null
    // An unmatched key goes there too (the empty library's filters pane).
    if (res.blocked || !res.commandId) {
      commands.handleBlocked(ev, res.blocked || "")
      return
    }
    run(res.commandId, res.args || ({}), ev, targets)
  }

  // The state a key or palette command resolves against, as it stands now.
  // Every view's flags go in `views` (viewFlags); the positional settings
  // and search flags are kept for dispatchState's existing callers.
  function registryState(targets) {
    return View.dispatchState(regState, keyPane, tableState, cursorIndex >= 0, targets, inspectorNow, commands.pickerFlags(),
      settingsHost.flagsNow(), searchFlags, viewFlags())
  }

  // Ends INSERT the way Esc does (insert.cancel: the filter query goes
  // back to what it was before `/`, a move is dropped), e.g. on a click.
  function leaveInsert() {
    if (regState.mode !== "INSERT") return
    commands.setMode("NORMAL")
    commands.cancelInput()
  }

  // Maps a command id from CommandRegistry to Service calls and view
  // changes (ClientCommands). Kept here for handleKey and the harness.
  function run(commandId, args, ev, targets) {
    // Slice 4b: the list editor, secrets and narrow rows are SettingsCommands'.
    // Slice 5a: Search's rows (all but its opener) are SearchPane's.
    // Slice 5b0: the first host (Registry.VIEWS order) that owns it runs it.
    for (var i = 0; i < hostNames.length; i++) {
      var h = viewHost(hostNames[i])
      if (h && h.owns(commandId)) { h.run(commandId, args, ev); return }
    }
    commands.run(commandId, args, ev, targets)
  }

  // ---- wiring ----------------------------------------------------------------

  onServiceChanged: adoptService()
  onCursorHashChanged: syncFiles(false)
  onInspectorTabChanged: { syncFiles(false); commands.syncInspect(false) }
  onTableStateChanged: syncFiles(false)

  Component.onCompleted: {
    inspectorState = inspectorNow
    if (service) adoptService()
    if (window.visible) requestWmFocus()
  }

  Component.onDestruction: {
    if (service) service.windowOpen = false
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onTorrentsChanged() { root.rebuildRows() }
    function onMagnetPendingHashesChanged() { root.rebuildRows() }
    function onViewStateChanged() {
      if (!root.viewTouched) root.applyViewState(root.service.viewState)
    }
    function onActionFinished(ticket, ok, error, origin, hashes) {
      settingsCmds.finished(ticket, ok, error)
      commands.libraryFinished(ticket, ok, error)
      // Strictly this window's own tickets (msgFinish ignores the rest): a
      // pending-magnet drop can emit extra window-origin signals that
      // carry our hashes.
      if (!commands.fetchFinished(ticket, ok)) root.messages = View.msgFinish(root.messages, ticket, ok, error)
    }
    function onClipboardRead(text) {
      var outcome = View.clipboardOutcome(text, root.clipboardAskedAt, Date.now())
      if (outcome === "none") return
      root.clipboardAskedAt = 0
      if (outcome === "add") root.track(root.service.addTarget(String(text).trim(), false, "", root.opts([])), "add", [])
      else if (outcome === "empty") root.note("The clipboard is empty.", "urgent")
      else if (outcome === "invalid") root.note("The clipboard has no magnet, .torrent URL or .torrent path.", "urgent")
    }
    function onFilesStatusByHashChanged() { root.checkFilesStatus() }
  }

  ClientCommands {
    id: commands
    client: root
    inspectorPane: inspector
    inputLine: statusLine
    keyItem: keyRoot
    palette: cmdPalette
    settingsView: settingsView
    settingsCommands: settingsCmds
    magnet: magnetRow
    categoryPicker: catPicker
    tagPicker: tagPicker
  }

  SettingsCommands {
    id: settingsCmds
    client: root
    commands: commands
    settingsView: settingsView
  }

  // Slice 5b0: Settings' view host (SearchPane is its own).
  SettingsHost { id: settingsHost; pane: settingsView; cmds: settingsCmds }

  WmFocus {
    id: wmFocus
    targetWindow: window
    keyItem: keyRoot
  }

  Timer {
    interval: 3000
    running: true
    repeat: false
    onTriggered: root.loadGraceOver = true
  }

  Timer {
    interval: 300
    running: true
    repeat: false
    onTriggered: root.loadingTextDue = true
  }

  FloatingWindow {
    id: window
    title: "OmaqBT"
    color: Color.background
    implicitWidth: 1600
    implicitHeight: 900
    minimumSize: Qt.size(640, 400)

    onVisibleChanged: {
      if (visible) {
        root.opened = true
        if (root.service) root.service.windowOpen = true
        root.requestWmFocus()
        return
      }
      // A WM close (or anything but our own close()) goes back through the
      // host, so its open map and `toggle` stay right.
      if (!root.closing) root.close()
    }

    onWindowConnected: if (visible) root.requestWmFocus()

    Item {
      id: keyRoot
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        root.handleKey(event)
        event.accepted = true
      }

      Item {
        id: panes
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: statusLine.top

        ClientPane {
          anchors.left: parent.left
          width: Style.space(210)
          height: panes.height
          title: "Filters"
          swappedOut: root.activeView !== "torrents"
          focusedPane: root.pane === "filters"
          collapsed: !root.filtersDocked

          FilterPane {
            id: filterPane
            anchors.fill: parent
            entries: root.filterEntries
            activeFilter: root.filter
            cursorFilter: root.filterCursor
            focusedPane: root.pane === "filters"
            footerKeys: commands.footerKeys
            onItemClicked: function(group, value) {
              root.leaveInsert()
              root.setPane("filters")
              root.setFilterCursor({ group: group, value: value })
              root.applyFilter({ group: group, value: value })
              keyRoot.forceActiveFocus()
            }
          }
        }

        ClientPane {
          x: root.filtersDocked ? Style.space(210) : 0
          width: Math.max(0, panes.width - x - (root.inspectorDocked ? Style.space(380) : 0))
          height: panes.height
          title: "Torrents"
          swappedOut: root.activeView !== "torrents"
          titleRight: View.paneTitle(root.filter, root.textQuery, root.sortMode, root.sortDesc)
          focusedPane: root.pane === "table"

          MagnetConfirm {
            id: magnetRow
            anchors.left: parent.left
            anchors.right: parent.right
            client: root
          }

          TorrentTable {
            id: table
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: magnetRow.bottom
            anchors.bottom: parent.bottom
            cursorHash: root.cursorHash
            sortMode: root.sortMode
            sortDesc: root.sortDesc
            tableState: root.tableState
            stateCopy: root.stateCopy
            showLoadingText: root.loadingTextDue
            rangeHashes: root.rangeHashes
            errorHashes: root.errorHashes
            hideColumns: root.layout.hideColumns
            onRowClicked: function(hash) {
              root.leaveInsert()
              root.setPane("table")
              root.setCursor(hash)
              keyRoot.forceActiveFocus()
            }
          }
        }

        ClientPane {
          anchors.right: parent.right
          width: Style.space(380)
          height: panes.height
          title: "Inspector"
          swappedOut: root.activeView !== "torrents"
          titleRight: inspector.titleRight
          focusedPane: root.pane === "inspector"
          collapsed: !root.inspectorDocked
          rightLine: false

          InspectorPane {
            id: inspector
            anchors.fill: parent
            tab: root.inspectorTab
            info: root.inspectorInfo
            row: root.cursorRow
            pieces: root.infoTab.cells
            piecesLegend: root.infoTab.legend
            noMeta: root.infoTab.noMeta
            infoErrored: root.infoTab.errored
            groups: commands.infoGroups
            limitKeys: commands.limitFooterKeys
            files: root.filesState
            fileIndex: root.fileIndex
            trackers: root.trackersView
            peers: root.peersView
            chart: root.chartView
            trackerIndex: root.trackerIndex
            peerIndex: root.peerIndex
            focusedPane: root.pane === "inspector"
            onTabClicked: function(tab) {
              root.leaveInsert()
              root.setInspectorTab(tab)
              keyRoot.forceActiveFocus()
            }
            onListRowClicked: function(tab, index) {
              root.leaveInsert()
              root.setPane("inspector")
              commands.setRow(tab, index)
              keyRoot.forceActiveFocus()
            }
            onFileClicked: function(index) {
              root.leaveInsert()
              root.setPane("inspector")
              root.fileIndex = index
              root.cycleFile(index)
              keyRoot.forceActiveFocus()
            }
          }
        }
      }

      SettingsPane {
        id: settingsView
        anchors.fill: panes
        service: root.service
        tableState: root.tableState
        narrow: View.settingsNarrow(keyRoot.width)
        open: root.activeView === settingsHost.name
        onLeaveRequested: root.leaveView()
      }
      // Slice 5a: the Search view's mount point (SearchPane.qml documents
      // what it gets and what it must provide).
      SearchPane {
        id: searchView
        anchors.fill: panes
        service: root.service
        client: root
        commands: commands
        tableState: root.tableState
        narrow: View.settingsNarrow(keyRoot.width)
        open: root.activeView === searchView.name
        onLeaveRequested: root.leaveView()
      }
      StatusLine {
        id: statusLine
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        mode: root.mode
        confirmParts: root.confirm ? View.confirmLine(root.confirm) : null
        magnetParts: magnetRow.lineParts
        countText: View.countText(root.liveCount)
        selectedCount: root.mode === "VISUAL" ? root.visualHashes.length : 0
        speedText: root.service ? "↓ " + Model.formatRate(root.service.dlSpeed) + " ↑ " + Model.formatRate(root.service.upSpeed) : ""
        turtle: !!root.service && root.service.altSpeed
        vpn: root.service ? View.vpnPart(root.service.vpnIface, root.service.bindIface, root.service.vpnUnbound) : null
        sidecarDown: !!root.service && root.service.sidecarState === "down"
        loading: root.loading
        message: root.statusMessage.text
        messageTone: root.statusMessage.tone
        inputPurpose: root.inputPurpose
        inputShown: commands.inputShown
        filterChip: View.filterChip(root.layout, root.filter)
        hints: View.modeHints(root.mode, View.copyState(settingsCmds.flags() || ({}), {
          accept: root.confirm ? View.confirmLine(root.confirm).accept : "",
          purpose: root.inputPurpose,
          pane: root.keyPane,
          search: root.searchFlags,
          searching: settingsView.searching,
          editor: settingsView.editorKind,
          filesTab: root.inspectorTab === "files" && !root.infoTab.noMeta
        }))

        onInputEdited: function(text) {
          // A view's own INSERT goes to the host that owns its purpose.
          var viewInput = root.mode === "INSERT" ? commands.inputHost(root.inputPurpose) : null
          if (viewInput) viewInput.inputEdited(root.inputPurpose, text)
          if (root.mode !== "INSERT" || root.inputPurpose !== "filter") return
          // "Matches update as you type"; a pasted magnet/URL/path is an
          // add target, not a query, so it doesn't filter the table empty.
          root.textQuery = Model.listQuery(text)
          root.rebuildRows(true)
        }
      }

      HelpOverlay {
        anchors.fill: parent
        visible: root.helpOpen
        groups: root.helpOpen ? View.helpRows(Registry.helpFor("NORMAL", root.helpPane, root.inspectorTab, root.registryState([]))) : []
        mode: "NORMAL"
        paneName: View.helpPaneName(root.helpPane)
        onDismissed: {
          root.helpOpen = false
          keyRoot.forceActiveFocus()
        }
      }

      CommandPalette {
        id: cmdPalette
        anchors.fill: parent
        visible: root.mode === "COMMAND"
        mru: root.paletteMru
        evalState: View.paletteState(root.tableState, root.cursorIndex >= 0, root.inspectorState, root.pane, root.activeView,
          settingsHost.flagsNow(), root.keyPane, root.searchFlags, root.viewFlags())
        onKeyForwarded: function(event) { root.handleKey(event) }
        onActivated: function(row) { commands.runPaletteRow(row) }
        onDismissed: commands.closePalette()
      }

      CategoryPicker { id: catPicker; anchors.fill: parent; commands: commands }
      TagPicker { id: tagPicker; anchors.fill: parent; commands: commands }
    }
  }
}
