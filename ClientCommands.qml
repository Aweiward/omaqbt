pragma ComponentBehavior: Bound

import QtQuick
import "Model.js" as Model
import "CommandRegistry.js" as Registry
import "ClientView.js" as View

// The window's command -> action mapping: run() turns a command id from
// CommandRegistry into Service calls and view changes on the Client it is
// given. Service calls always carry {origin: "window", hashes}. Client.run
// delegates here, so callers keep calling Client.run and Client.handleKey.
QtObject {
  // The Client item whose state and helpers the commands act on.
  required property var client
  // The InspectorPane, for scrolling the Files cursor into view.
  required property var inspectorPane

  function isEnterKey(ev) {
    return ev.key === Registry.KEY.Return || ev.key === Registry.KEY.Enter
  }

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
      c.startInput("move", String(rows[0].savePath || ""))
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
      c.startInput("filter", c.textQuery)
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
      if (c.inspectorTab !== "files" || c.filesState.state !== "rows") return
      c.fileIndex = View.moveIndex(c.filesState.rows.length, c.fileIndex, commandId === "file.down" ? 1 : -1)
      inspectorPane.positionFile(c.fileIndex)
      return

    case "file.cycle":
      if (c.inspectorTab !== "files" || c.filesState.state !== "rows") return
      c.cycleFile(c.fileIndex)
      return

    case "insert.commit":
      c.commitInput()
      return

    case "insert.cancel":
      c.cancelInput()
      return

    case "refresh":
      c.service.refresh()
      c.syncFiles(true)
      return

    case "pane.next":
      c.setPane(View.nextPane(c.pane, 1))
      return

    case "pane.prev":
      c.setPane(View.nextPane(c.pane, -1))
      return

    case "window.close":
      c.close()
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
