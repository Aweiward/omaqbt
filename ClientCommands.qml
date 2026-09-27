pragma ComponentBehavior: Bound

import QtQuick
import "Model.js" as Model
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The window's command -> action mapping: run() turns a command id from
// CommandRegistry into Service calls and view changes on the Client it is
// given. Service calls always carry {origin: "window", hashes}. Client.run
// delegates here, so callers keep calling Client.run and Client.handleKey.
QtObject {
  // The Client item whose state and helpers the commands act on.
  required property var client
  // The InspectorPane, for scrolling the Files cursor into view.
  required property var inspectorPane
  // The StatusLine whose input INSERT edits, and the item that takes the
  // keys again when INSERT ends.
  required property var inputLine
  required property Item keyItem
  // The CommandPalette the palette.* commands drive.
  required property var palette
  // The MagnetConfirm that runs magnet.start / magnet.cancel.
  required property var magnet

  // ---- trackers and peers (inspector tabs 2, 3) ---------------------------

  // The tracker url / peer ip:port under each tab's cursor, so a refresh
  // that reorders the list (peers re-sort by speed every tick) keeps the
  // cursor on the same row (stickRow).
  property string trackerKey: ""
  property string peerKey: ""
  // hash|tab|error of the inspect error last put on the status line, so
  // each new error is noted once; "" after a success or a watch change.
  property string notedInspectError: ""

  // Moves inspectNow past tabState's 300 ms "blank" so a tab still
  // waiting for its first reply says "Loading…". A coarse timer can fire
  // up to ~5% early, which would still read "blank" and never re-check,
  // so the clock is advanced to at least since + TAB_BLANK_MS.
  property Timer inspectClock: Timer {
    interval: InspectorView.TAB_BLANK_MS
    onTriggered: client.inspectNow = Math.max(Date.now(), client.inspectSince + InspectorView.TAB_BLANK_MS)
  }

  // The window's watch changed (hashChanged: the cursor torrent, else the
  // tab): restart the stale-reply clock and tell Service. A new torrent
  // starts both lists at the top.
  function syncInspect(hashChanged) {
    var c = client
    if (hashChanged) {
      c.trackerIndex = 0
      c.peerIndex = 0
      trackerKey = ""
      peerKey = ""
    }
    notedInspectError = ""
    c.inspectSince = Date.now()
    c.inspectNow = c.inspectSince
    inspectClock.restart()
    if (c.service && typeof c.service.watch === "function") c.service.watch(c.watchHash, c.inspectorTab)
  }

  // The watched tab's reply changed: a fresh error goes to the status line
  // as an urgent note, once per hash|tab|error (Ruling L); a fresh success
  // re-arms it. A stale entry (older than inspectSince) is ignored.
  function checkInspectError() {
    var c = client
    var e = c.inspectEntry
    if (!e || !(Number(e.at) >= c.inspectSince)) return
    if (!e.error) { notedInspectError = ""; return }
    var k = c.watchHash + "|" + c.inspectorTab + "|" + e.error
    if (k === notedInspectError) return
    notedInspectError = k
    c.note("Couldn't read " + c.inspectorTab + ": " + e.error, "urgent")
  }

  // A refresh of tab's rows: the index of the row with the same key, or
  // the first row when that key is gone (Ruling M); an empty list leaves
  // the index alone.
  function stickRow(tab, rows, index) {
    if (rows.length === 0) return index
    var next = InspectorView.keyedIndex(rows, tab === "trackers" ? trackerKey : peerKey, 0)
    if (tab === "trackers") trackerKey = rows[next].key
    else peerKey = rows[next].key
    return next
  }

  function listRows(tab) {
    return tab === "trackers" ? client.trackersView.rows : client.peersView.rows
  }

  // Puts tab's cursor on row index (a key or a click).
  function setRow(tab, index) {
    var rows = listRows(tab)
    if (index < 0 || index >= rows.length) return
    if (tab === "trackers") { client.trackerIndex = index; trackerKey = rows[index].key }
    else { client.peerIndex = index; peerKey = rows[index].key }
  }

  // `y` in the inspector on trackers or peers (deviation 3: inside
  // torrent.copyMagnet): the tracker's full URL, or the peer's ip:port.
  function copyRow(tab, targets) {
    var c = client
    var row = listRows(tab)[tab === "trackers" ? c.trackerIndex : c.peerIndex]
    if (!row) {
      c.note(tab === "trackers" ? "No tracker to copy." : "No peer to copy.", "muted")
      return
    }
    c.track(c.service.copyText(tab === "trackers" ? row.url : row.ipPort, c.opts(targets)), "copyText", targets)
  }

  function isEnterKey(ev) {
    return ev.key === Registry.KEY.Return || ev.key === Registry.KEY.Enter
  }

  // A key whose command needs a torrent, pressed with none under the
  // cursor. In the empty library, `y` means "add from clipboard" (the
  // empty state's copy), since there is no torrent to copy a magnet from.
  function handleBlocked(ev) {
    var c = client
    if (!c.service) return
    if (c.tableState === "empty" && ev.text === "y" && !ev.modifiers.ctrl) {
      c.clipboardAskedAt = ev.now
      c.service.readClipboard()
    }
  }

  // Sets the mode without a dispatch (a click, or a palette row that stays
  // open), keeping the rest of the registry state.
  function setMode(mode) {
    var c = client
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = mode
    c.regState = st
  }

  // The text field that owns the keys in INSERT or COMMAND, else null.
  function typingField() {
    var m = client.mode
    return m === "INSERT" ? inputLine.inputField : (m === "COMMAND" ? palette.inputField : null)
  }

  // ---- INSERT ------------------------------------------------------------------

  function startInput(purpose, initial) {
    var c = client
    c.inputPurpose = purpose
    c.queryBeforeEdit = c.textQuery
    inputLine.setInput(initial)
    setMode("INSERT")
    inputLine.focusInput()
  }

  function endInput() {
    client.inputPurpose = ""
    keyItem.forceActiveFocus()
  }

  function stayInInsert() {
    setMode("INSERT")
    inputLine.focusInput()
  }

  function commitInput() {
    var c = client
    var text = inputLine.inputValue().trim()
    if (c.inputPurpose === "move") {
      if (!View.isAbsolutePath(text)) {
        c.note("Enter an absolute path to move to.", "urgent")
        stayInInsert()
        return
      }
      c.track(c.service.setLocation(c.moveHashes.join("|"), text, c.opts(c.moveHashes)), "move", c.moveHashes)
      c.moveHashes = []
    } else if (Model.isAddableTarget(text)) {
      c.track(c.service.addTarget(text, false, "", c.opts([])), "add", [])
      c.textQuery = ""
      c.rebuildRows(true)
    } else {
      c.textQuery = Model.listQuery(text)
      c.rebuildRows(true)
    }
    endInput()
  }

  // Client.leaveInsert (a click during INSERT) ends INSERT through here too.
  function cancelInput() {
    var c = client
    if (c.inputPurpose === "filter") {
      c.textQuery = c.queryBeforeEdit
      c.rebuildRows(true)
    }
    c.moveHashes = []
    endInput()
  }

  // ---- COMMAND (the palette) ----------------------------------------------------

  function closePalette() {
    setMode("NORMAL")
    keyItem.forceActiveFocus()
  }

  // Runs a palette row (Enter, or a click). A disabled row (or none) keeps
  // the palette open and says why. An enabled one closes it, goes to the
  // top of the MRU, and runs through the registry like its key would:
  // the same targets, the same CONFIRM, the same mode change afterwards.
  function runPaletteRow(row) {
    var c = client
    if (!row || row.kind !== "command" || !row.enabled) {
      if (row && row.kind === "command") c.note(View.paletteReasonNote(row), "urgent")
      setMode("COMMAND")
      palette.focusField()
      return
    }
    closePalette()
    c.paletteMru = View.mruPush(c.paletteMru, row.id)
    c.setPane(View.palettePane(Registry.commands, row.id, c.pane))
    c.saveView()
    // A neutral event: the Enter that ran the palette must not also count
    // as Enter for the command (Files would start the daemon).
    var ev = View.keyEvent(0, "", 0, Date.now())
    c.dispatchWith(function(st) { return Registry.dispatchCommand(st, row.id) }, ev)
  }

  // ---- commands ------------------------------------------------------------------

  // targets: View.targetHashes as it stood before dispatch (the VISUAL
  // range, or the cursor row).
  function run(commandId, args, ev, targets) {
    var c = client
    if (!c.service) return
    var hashes, rows, starts, ticket
    targets = targets || []

    switch (commandId) {
    case "cursor.down":
    case "cursor.up":
    case "cursor.top":
    case "cursor.bottom":
      c.setCursor(View.moveCursor(c.tableRows, c.cursorHash, commandId))
      return

    case "visual.enter":
    case "visual.exit":
      // The mode and the anchor were set in handleKey.
      return

    case "help.toggle":
      c.helpPane = View.dispatchPane(c.pane, c.tableState)
      c.helpOpen = true
      return

    case "torrent.toggle":
      hashes = targets
      if (hashes.length === 0) return
      starts = View.toggleStarts(c.rawFor(hashes))
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return starts ? c.service.startHash(joined, c.opts(chunk)) : c.service.stopHash(joined, c.opts(chunk))
      }), starts ? "start" : "stop", hashes)
      return

    case "torrent.remove":
    case "torrent.delete":
      hashes = args.confirmed === true ? c.confirmHashes : targets
      c.confirmHashes = []
      if (hashes.length === 0) return
      var withFiles = commandId === "torrent.delete"
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return c.service.deleteHash(joined, withFiles, c.opts(chunk))
      }), withFiles ? "delete" : "remove", hashes)
      return

    case "torrent.recheck":
      hashes = targets
      if (hashes.length === 0) return
      c.track(c.perChunk(hashes, function(joined, chunk) {
        return c.service.recheckHash(joined, c.opts(chunk))
      }), "recheck", hashes)
      return

    case "torrent.openFolder":
      rows = c.rawFor(targets)
      if (rows.length > 0 && rows[0].savePath) c.service.openPath(rows[0].savePath, c.opts(targets))
      return

    case "torrent.copyMagnet":
      if (c.pane === "inspector" && (c.inspectorTab === "trackers" || c.inspectorTab === "peers")) {
        copyRow(c.inspectorTab, targets)
        return
      }
      rows = c.rawFor(targets)
      if (rows.length === 0) return
      // The window validates its own input: Service returns 0 silently.
      if (!Model.magnetUriFor(rows[0])) {
        c.note("No magnet for this torrent.", "urgent")
        return
      }
      c.track(c.service.copyMagnet(rows[0], c.opts(targets)), "copy", targets)
      return

    case "torrent.move":
      hashes = targets
      rows = c.rawFor(hashes)
      if (rows.length === 0) return
      c.moveHashes = hashes
      startInput("move", String(rows[0].savePath || ""))
      return

    case "inspector.files":
      // Enter doubles as the primary action of a blocking state.
      if (isEnterKey(ev) && c.tableState === "daemon") {
        ticket = c.service.startDaemon(c.opts([]))
        if (ticket > 0) c.track(ticket, "daemon", [])
        else c.note(View.progressText("daemon", 0), "muted")
        return
      }
      if (isEnterKey(ev) && c.tableState === "notInstalled") {
        ticket = c.service.installDaemon(c.opts([]))
        if (ticket > 0) c.track(ticket, "install", [])
        else c.note(View.progressText("install", 0), "muted")
        return
      }
      c.inspectorTab = "files"
      return

    case "inspector.info":
      c.inspectorTab = "info"
      return

    case "inspector.trackers":
      c.inspectorTab = "trackers"
      return

    case "inspector.peers":
      c.inspectorTab = "peers"
      return

    case "all.toggle":
      var live = Model.excludePending(c.service.torrents || [], c.service.magnetPendingHashes || [])
      hashes = []
      for (var i = 0; i < live.length; i++) hashes.push(Model.torrentId(live[i]))
      if (hashes.length === 0) return
      starts = !Model.anyActive(live)
      c.track(c.service.toggleAll(c.opts(hashes)), starts ? "startAll" : "stopAll", hashes)
      return

    case "turtle.toggle":
      c.track(c.service.toggleTurtle(c.opts([])), "turtle", [])
      return

    case "sort.next":
      var n = View.nextSort(c.sortMode)
      c.sortMode = n.sort
      c.sortDesc = n.desc
      c.rebuildRows(true)
      c.saveView()
      return

    case "sort.reverse":
      c.sortDesc = !c.sortDesc
      c.rebuildRows(true)
      c.saveView()
      return

    case "filter.text":
      startInput("filter", c.textQuery)
      return

    case "filter.clearText":
      if (c.textQuery === "") return
      c.textQuery = ""
      c.rebuildRows(true)
      return

    case "filter.reset":
      c.textQuery = ""
      c.filter = View.defaultFilter()
      c.filterCursor = View.defaultFilter()
      c.rebuildRows(true)
      c.saveView()
      return

    case "filter.down":
    case "filter.up":
      c.setFilterCursor(View.moveFilterCursor(c.filterEntries, c.filterCursor, commandId === "filter.down" ? 1 : -1))
      return

    case "filter.apply":
      if (View.filterIndex(c.filterEntries, c.filterCursor) < 0) return
      c.applyFilter(c.filterCursor)
      return

    case "file.down":
    case "file.up":
      // Moves the cursor of whichever list the current tab shows.
      if (c.inspectorTab === "trackers" || c.inspectorTab === "peers") {
        var tabRows = listRows(c.inspectorTab)
        if (tabRows.length === 0) return
        var at = c.inspectorTab === "trackers" ? c.trackerIndex : c.peerIndex
        setRow(c.inspectorTab, View.moveIndex(tabRows.length, at, commandId === "file.down" ? 1 : -1))
        inspectorPane.positionRow(c.inspectorTab, c.inspectorTab === "trackers" ? c.trackerIndex : c.peerIndex)
        return
      }
      if (c.inspectorTab !== "files" || c.filesState.state !== "rows") return
      c.fileIndex = View.moveIndex(c.filesState.rows.length, c.fileIndex, commandId === "file.down" ? 1 : -1)
      inspectorPane.positionFile(c.fileIndex)
      return

    case "file.cycle":
      if (c.inspectorTab !== "files" || c.filesState.state !== "rows") return
      c.cycleFile(c.fileIndex)
      return

    case "insert.commit":
      commitInput()
      return

    case "insert.cancel":
      cancelInput()
      return

    case "refresh":
      c.service.refresh()
      c.syncFiles(true)
      return

    case "pane.next":
    case "pane.prev":
      // Tab/Shift-Tab cycle through collapsed panes (opening each as an
      // overlay); Ctrl-h/Ctrl-l on an open overlay close it.
      c.setPane(View.paneStep(c.pane, commandId === "pane.next" ? 1 : -1, c.layout, ev))
      return

    case "window.close":
      c.close()
      return

    case "palette.open":
      palette.open()
      return

    case "palette.close":
      closePalette()
      return

    case "palette.up":
    case "palette.down":
      palette.move(commandId === "palette.down" ? 1 : -1)
      return

    case "palette.complete":
      palette.complete()
      return

    case "palette.run":
      runPaletteRow(palette.currentRow())
      return

    case "magnet.start":
    case "magnet.cancel":
      magnet.act(commandId)
      return

    case "confirm.cancel":
      c.confirm = null
      c.confirmHashes = []
      return

    default:
      return
    }
  }
}
