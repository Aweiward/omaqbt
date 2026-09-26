pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Commons
import "Model.js" as Model
import "CommandRegistry.js" as Registry
import "ClientView.js" as View

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

  // ---- per-view, not persisted --------------------------------------------
  property string textQuery: ""
  property string inspectorTab: "info"
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
  // and the fixed range a CONFIRM raised from VISUAL will act on.
  readonly property var rangeHashes: View.hashSet(mode === "VISUAL" ? visualHashes
    : (mode === "CONFIRM" && confirmHashes.length > 1 ? confirmHashes : []))
  readonly property var errorHashes: View.hashSet(messages.errorHashes)

  // ---- filter pane -------------------------------------------------------------
  property var filterEntries: []
  // The j/k cursor in the filter pane; Enter applies it (becomes `filter`).
  property var filterCursor: View.defaultFilter()

  // ---- inspector -----------------------------------------------------------------
  readonly property var cursorRow: tableState === "rows" ? rawRow(cursorHash) : null
  readonly property var inspectorInfo: View.inspectorInfo(cursorRow, function(sec) {
    return Qt.formatDateTime(new Date(sec * 1000), "yyyy-MM-dd hh:mm")
  })
  // Bound to a bool, not to cursorRow: cursorRow is a fresh object every
  // status tick, and re-running filesView would hand the Files ListView a
  // new model and reset its scroll on every tick.
  readonly property bool hasCursorRow: tableState === "rows" && cursorIndex >= 0
  readonly property var filesState: View.filesView(
    service && hasCursorRow ? (service.filesByHash || {})[cursorHash] : [],
    service && hasCursorRow ? (service.filesStatusByHash || {})[cursorHash] : undefined)
  property int fileIndex: 0
  // The hash whose files this window last asked for, and whether a failed
  // answer for it still has to be reported on the status line.
  property string filesLoadedHash: ""
  property bool filesErrorPending: false

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
    opened = false
    window.visible = false
    if (service) service.windowOpen = false
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    closing = false
  }

  // Keyboard focus on open: WmFocus retries until the WM activates the
  // window. Kept here for open(), the window handlers and the harness.
  function requestWmFocus() {
    wmFocus.requestWmFocus()
  }

  // ---- view state ----------------------------------------------------------

  function applyViewState(vs) {
    var v = Model.parseViewState(vs)
    filter = v.filter
    sortMode = View.validSort(v.sort)
    sortDesc = v.desc
    cursorHash = v.cursorHash
    // Not setPane: that saves, and a restore must not count as a user
    // change (viewTouched). VISUAL is table-only, so it ends here too.
    leaveVisual()
    pane = v.pane
    rebuildRows(true)
  }

  function saveView() {
    viewTouched = true
    if (!service || typeof service.saveViewState !== "function") return
    service.saveViewState({ filter: filter, sort: sortMode, desc: sortDesc, cursorHash: cursorHash, pane: pane })
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
    cursorHash = View.resolveCursor(v.rows, cursorHash, prevIndex)
    if (reveal === true && View.indexOfHash(v.rows, cursorHash) >= 0) revealCursor()
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
    if (filesLoadedHash !== cursorHash) fileIndex = 0
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

  function isEnterKey(ev) {
    return ev.key === Registry.KEY.Return || ev.key === Registry.KEY.Enter
  }

  function handleKey(event) {
    var ev = View.keyEvent(event.key, event.text, event.modifiers, Date.now())
    // Any key ends an error (and its row marks) or a note.
    messages = View.msgKey(messages)
    if (helpOpen) {
      // The overlay takes the key that closes it.
      helpOpen = false
      return
    }
    // Targets are fixed before dispatch: Space/x/X/e from VISUAL come back
    // in NORMAL or CONFIRM, and must still act on the range as it stood.
    var targets = View.targetHashes(regState.mode, tableRows, cursorHash, anchorHash)
    var st = View.dispatchState(regState, pane, tableState, cursorIndex >= 0, targets)
    var res = Registry.dispatch(st, ev)

    regState = res.state
    anchorHash = View.nextAnchor(res.state.mode, res.commandId, anchorHash, cursorHash)
    if (res.confirm) {
      confirm = res.confirm
      confirmHashes = targets
      return
    }
    if (res.state.mode !== "CONFIRM") confirm = null
    if (res.blocked) {
      handleBlocked(ev)
      return
    }
    if (res.commandId) run(res.commandId, res.args || ({}), ev, targets)
  }

  // A key whose command needs a torrent, pressed with none under the
  // cursor. In the empty library, `y` means "add from clipboard" (the
  // empty state's copy), since there is no torrent to copy a magnet from.
  function handleBlocked(ev) {
    if (!service) return
    if (tableState === "empty" && ev.text === "y" && !ev.modifiers.ctrl) {
      clipboardAskedAt = ev.now
      service.readClipboard()
    }
  }

  function startInput(purpose, initial) {
    inputPurpose = purpose
    queryBeforeEdit = textQuery
    statusLine.setInput(initial)
    var st = ({})
    for (var k in regState) st[k] = regState[k]
    st.mode = "INSERT"
    regState = st
    statusLine.focusInput()
  }

  function endInput() {
    inputPurpose = ""
    keyRoot.forceActiveFocus()
  }

  function stayInInsert() {
    var st = ({})
    for (var k in regState) st[k] = regState[k]
    st.mode = "INSERT"
    regState = st
    statusLine.focusInput()
  }

  function commitInput() {
    var text = statusLine.inputValue().trim()
    if (inputPurpose === "move") {
      if (!View.isAbsolutePath(text)) {
        note("Enter an absolute path to move to.", "urgent")
        stayInInsert()
        return
      }
      track(service.setLocation(moveHashes.join("|"), text, opts(moveHashes)), "move", moveHashes)
      moveHashes = []
    } else if (Model.isAddableTarget(text)) {
      track(service.addTarget(text, false, "", opts([])), "add", [])
      textQuery = ""
      rebuildRows(true)
    } else {
      textQuery = Model.listQuery(text)
      rebuildRows(true)
    }
    endInput()
  }

  // Ends INSERT the way Esc does (insert.cancel: the filter query goes
  // back to what it was before `/`, a move is dropped), e.g. on a click.
  function leaveInsert() {
    if (regState.mode !== "INSERT") return
    var st = ({})
    for (var k in regState) st[k] = regState[k]
    st.mode = "NORMAL"
    regState = st
    cancelInput()
  }

  function cancelInput() {
    if (inputPurpose === "filter") {
      textQuery = queryBeforeEdit
      rebuildRows(true)
    }
    moveHashes = []
    endInput()
  }

  // Maps a command id from CommandRegistry to Service calls and view
  // changes. Service calls always carry {origin: "window", hashes}.
  // targets: View.targetHashes as it stood before dispatch (the VISUAL
  // range, or the cursor row).
  function run(commandId, args, ev, targets) {
    if (!service) return
    var hashes, rows, starts, ticket
    targets = targets || []

    switch (commandId) {
    case "cursor.down":
    case "cursor.up":
    case "cursor.top":
    case "cursor.bottom":
      setCursor(View.moveCursor(tableRows, cursorHash, commandId))
      return

    case "visual.enter":
    case "visual.exit":
      // The mode and the anchor were set in handleKey.
      return

    case "help.toggle":
      helpPane = View.dispatchPane(pane, tableState)
      helpOpen = true
      return

    case "torrent.toggle":
      hashes = targets
      if (hashes.length === 0) return
      starts = View.toggleStarts(rawFor(hashes))
      track(perChunk(hashes, function(joined, chunk) {
        return starts ? service.startHash(joined, opts(chunk)) : service.stopHash(joined, opts(chunk))
      }), starts ? "start" : "stop", hashes)
      return

    case "torrent.remove":
    case "torrent.delete":
      hashes = args.confirmed === true ? confirmHashes : targets
      confirmHashes = []
      if (hashes.length === 0) return
      var withFiles = commandId === "torrent.delete"
      track(perChunk(hashes, function(joined, chunk) {
        return service.deleteHash(joined, withFiles, opts(chunk))
      }), withFiles ? "delete" : "remove", hashes)
      return

    case "torrent.recheck":
      hashes = targets
      if (hashes.length === 0) return
      track(perChunk(hashes, function(joined, chunk) {
        return service.recheckHash(joined, opts(chunk))
      }), "recheck", hashes)
      return

    case "torrent.openFolder":
      rows = rawFor(targets)
      if (rows.length > 0 && rows[0].savePath) service.openPath(rows[0].savePath, opts(targets))
      return

    case "torrent.copyMagnet":
      rows = rawFor(targets)
      if (rows.length === 0) return
      // The window validates its own input: Service returns 0 silently.
      if (!Model.magnetUriFor(rows[0])) {
        note("No magnet for this torrent.", "urgent")
        return
      }
      track(service.copyMagnet(rows[0], opts(targets)), "copy", targets)
      return

    case "torrent.move":
      hashes = targets
      rows = rawFor(hashes)
      if (rows.length === 0) return
      moveHashes = hashes
      startInput("move", String(rows[0].savePath || ""))
      return

    case "inspector.files":
      // Enter doubles as the primary action of a blocking state.
      if (isEnterKey(ev) && tableState === "daemon") {
        ticket = service.startDaemon(opts([]))
        if (ticket > 0) track(ticket, "daemon", [])
        else note(View.progressText("daemon", 0), "muted")
        return
      }
      if (isEnterKey(ev) && tableState === "notInstalled") {
        ticket = service.installDaemon(opts([]))
        if (ticket > 0) track(ticket, "install", [])
        else note(View.progressText("install", 0), "muted")
        return
      }
      inspectorTab = "files"
      return

    case "inspector.info":
      inspectorTab = "info"
      return

    case "all.toggle":
      var live = Model.excludePending(service.torrents || [], service.magnetPendingHashes || [])
      hashes = []
      for (var i = 0; i < live.length; i++) hashes.push(Model.torrentId(live[i]))
      if (hashes.length === 0) return
      starts = !Model.anyActive(live)
      track(service.toggleAll(opts(hashes)), starts ? "startAll" : "stopAll", hashes)
      return

    case "turtle.toggle":
      track(service.toggleTurtle(opts([])), "turtle", [])
      return

    case "sort.next":
      var n = View.nextSort(sortMode)
      sortMode = n.sort
      sortDesc = n.desc
      rebuildRows(true)
      saveView()
      return

    case "sort.reverse":
      sortDesc = !sortDesc
      rebuildRows(true)
      saveView()
      return

    case "filter.text":
      startInput("filter", textQuery)
      return

    case "filter.clearText":
      if (textQuery === "") return
      textQuery = ""
      rebuildRows(true)
      return

    case "filter.reset":
      textQuery = ""
      filter = View.defaultFilter()
      filterCursor = View.defaultFilter()
      rebuildRows(true)
      saveView()
      return

    case "filter.down":
    case "filter.up":
      setFilterCursor(View.moveFilterCursor(filterEntries, filterCursor, commandId === "filter.down" ? 1 : -1))
      return

    case "filter.apply":
      if (View.filterIndex(filterEntries, filterCursor) < 0) return
      applyFilter(filterCursor)
      return

    case "file.down":
    case "file.up":
      if (inspectorTab !== "files" || filesState.state !== "rows") return
      fileIndex = View.moveIndex(filesState.rows.length, fileIndex, commandId === "file.down" ? 1 : -1)
      inspector.positionFile(fileIndex)
      return

    case "file.cycle":
      if (inspectorTab !== "files" || filesState.state !== "rows") return
      cycleFile(fileIndex)
      return

    case "insert.commit":
      commitInput()
      return

    case "insert.cancel":
      cancelInput()
      return

    case "refresh":
      service.refresh()
      syncFiles(true)
      return

    case "pane.next":
      setPane(View.nextPane(pane, 1))
      return

    case "pane.prev":
      setPane(View.nextPane(pane, -1))
      return

    case "window.close":
      close()
      return

    case "confirm.cancel":
      confirm = null
      confirmHashes = []
      return

    default:
      return
    }
  }

  // ---- wiring ----------------------------------------------------------------

  onServiceChanged: adoptService()
  onCursorHashChanged: syncFiles(false)
  onInspectorTabChanged: syncFiles(false)
  onTableStateChanged: syncFiles(false)

  Component.onCompleted: {
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
      // Strictly this window's own tickets (msgFinish ignores the rest): a
      // pending-magnet drop can emit extra window-origin signals that
      // carry our hashes.
      root.messages = View.msgFinish(root.messages, ticket, ok, error)
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

      Row {
        id: panes
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: statusLine.top

        ClientPane {
          width: Style.space(210)
          height: panes.height
          title: "Filters"
          focusedPane: root.pane === "filters"

          FilterPane {
            id: filterPane
            anchors.fill: parent
            entries: root.filterEntries
            activeFilter: root.filter
            cursorFilter: root.filterCursor
            focusedPane: root.pane === "filters"
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
          width: Math.max(0, panes.width - Style.space(210) - Style.space(380))
          height: panes.height
          title: "Torrents"
          titleRight: View.paneTitle(root.filter, root.textQuery, root.sortMode, root.sortDesc)
          focusedPane: root.pane === "table"

          TorrentTable {
            id: table
            anchors.fill: parent
            cursorHash: root.cursorHash
            sortMode: root.sortMode
            sortDesc: root.sortDesc
            tableState: root.tableState
            stateCopy: root.stateCopy
            showLoadingText: root.loadingTextDue
            rangeHashes: root.rangeHashes
            errorHashes: root.errorHashes
            onRowClicked: function(hash) {
              root.leaveInsert()
              root.setPane("table")
              root.setCursor(hash)
              keyRoot.forceActiveFocus()
            }
          }
        }

        ClientPane {
          width: Style.space(380)
          height: panes.height
          title: "Inspector"
          focusedPane: root.pane === "inspector"
          rightLine: false

          InspectorPane {
            id: inspector
            anchors.fill: parent
            tab: root.inspectorTab
            info: root.inspectorInfo
            files: root.filesState
            fileIndex: root.fileIndex
            focusedPane: root.pane === "inspector"
            onTabClicked: function(tab) {
              root.leaveInsert()
              root.inspectorTab = tab
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

      StatusLine {
        id: statusLine
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        mode: root.mode
        confirmParts: root.confirm ? View.confirmLine(root.confirm) : null
        countText: View.countText(root.liveCount)
        selectedCount: root.mode === "VISUAL" ? root.visualHashes.length : 0
        speedText: root.service ? "↓ " + Model.formatRate(root.service.dlSpeed) + " ↑ " + Model.formatRate(root.service.upSpeed) : ""
        turtle: !!root.service && root.service.altSpeed
        vpn: root.service ? View.vpnPart(root.service.vpnIface, root.service.bindIface, root.service.vpnUnbound) : null
        sidecarDown: !!root.service && root.service.sidecarState === "down"
        loading: root.loading
        message: root.messageLine.text
        messageTone: root.messageLine.tone
        inputPurpose: root.inputPurpose
        hints: View.modeHints(root.mode, {
          accept: root.confirm ? View.confirmLine(root.confirm).accept : "",
          purpose: root.inputPurpose,
          pane: View.dispatchPane(root.pane, root.tableState),
          filesTab: root.inspectorTab === "files"
        })

        onInputEdited: function(text) {
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
        groups: root.helpOpen ? View.helpRows(Registry.helpFor("NORMAL", root.helpPane)) : []
        mode: "NORMAL"
        paneName: root.helpPane
        onDismissed: {
          root.helpOpen = false
          keyRoot.forceActiveFocus()
        }
      }
    }
  }
}
