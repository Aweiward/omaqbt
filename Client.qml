pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
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
// Task 7 scope: the filter and inspector panes are titled placeholders;
// `?` and `V` do nothing yet; messages are progress only (Task 8).
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
  // A message this window owns (progress in muted, a validation problem in
  // urgent); cleared by the next key.
  property string noteText: ""
  property string noteTone: "muted"
  // ticket -> progress text, for this window's own actions only.
  property var tickets: ({})
  property string progressText: ""
  // When `y` asked for the clipboard (ms); its answer is used only if it
  // arrives soon after, so a stale request can't add something later.
  property double clipboardAskedAt: 0

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

  // ---- focus diagnostics (see requestWmFocus) -----------------------------
  property int focusAttempts: 0
  property bool focusActivateAsked: false

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

  // Keyboard focus on open. See the Task 7 report for the investigation.
  // In order, until the backing QQuickWindow reports `active`:
  //  1. forceActiveFocus() on the key item (Qt-side focus inside the window);
  //  2. QWindow.requestActivate() on the backing window, which Qt Wayland
  //     turns into an xdg-activation token + activate request; Omarchy sets
  //     misc.focus_on_activate = true, so Hyprland honors it;
  //  3. wlr-foreign-toplevel `activate` on our own toplevel (Hyprland treats
  //     that as a forced activation, the path window switchers use);
  //  4. a Hyprland focus dispatch by address.
  // After ~1.5 s it stops and logs which side refused, for the live check.
  function requestWmFocus() {
    keyRoot.forceActiveFocus()
    focusAttempts = 0
    focusActivateAsked = false
    focusRetry.restart()
  }

  function ownHyprlandToplevel() {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || t.title !== window.title) continue
      var w = t.wayland
      if (w && w.appId && w.appId !== "org.quickshell") continue
      return t
    }
    return null
  }

  function ownWaylandToplevel() {
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (t && t.title === window.title && t.appId === "org.quickshell") return t
    }
    return null
  }

  function focusStep() {
    if (!window.visible) {
      focusRetry.stop()
      return
    }
    // _backingWindow is Quickshell's QQuickWindow behind the proxy; qmllint
    // can't see it on FloatingWindow's declared type, hence the index form.
    var backing = window["_backingWindow"]
    if (backing && backing.active) {
      focusRetry.stop()
      keyRoot.forceActiveFocus()
      console.info("OmaqBT window: keyboard focus after " + focusAttempts + " attempt(s)")
      return
    }
    focusAttempts = focusAttempts + 1
    try {
      // The backing window can connect a moment after the item exists, so
      // the xdg-activation request goes out on the first step that has one.
      if (!focusActivateAsked && backing) {
        focusActivateAsked = true
        backing.requestActivate()
      }
      if (focusAttempts === 1) {
        Hyprland.refreshToplevels()
      } else if (focusAttempts === 3) {
        var wl = ownWaylandToplevel()
        if (wl) wl.activate()
      } else if (focusAttempts === 6) {
        var hy = ownHyprlandToplevel()
        if (hy && hy.address) {
          var addr = String(hy.address)
          if (addr.indexOf("0x") !== 0) addr = "0x" + addr
          if (Hyprland.usingLua) Hyprland.dispatch("hl.dsp.focus({ window = \"address:" + addr + "\" })")
          else Hyprland.dispatch("focuswindow address:" + addr)
        }
      } else if (focusAttempts >= 15) {
        focusRetry.stop()
        var own = ownHyprlandToplevel()
        var active = Hyprland.activeToplevel
        console.warn("OmaqBT window: no keyboard focus after open."
          + " qt.active=" + (backing ? backing.active : "no-backing-window")
          + " hypr.activated=" + (own ? own.activated : "no-toplevel")
          + " hypr.address=" + (own ? own.address : "")
          + " hypr.activeTitle=" + (active ? active.title : "")
          + " foreignToplevel=" + (ownWaylandToplevel() !== null))
      }
    } catch (e) {
      console.warn("OmaqBT window: focus attempt " + focusAttempts + " threw: " + e)
    }
  }

  // ---- view state ----------------------------------------------------------

  function applyViewState(vs) {
    var v = Model.parseViewState(vs)
    filter = v.filter
    sortMode = View.validSort(v.sort)
    sortDesc = v.desc
    cursorHash = v.cursorHash
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

  // reveal: also scroll the cursor into view even if its index is the same
  // (restore, re-sort). Otherwise it is revealed only when its index moved.
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
    // An automatic cursor move (its torrent went away, or a restored hash
    // no longer exists) isn't saved; only user moves are.
    cursorHash = View.resolveCursor(v.rows, cursorHash, prevIndex)
    var nextIndex = View.indexOfHash(v.rows, cursorHash)
    if (nextIndex >= 0 && (reveal === true || nextIndex !== prevIndex)) revealCursor()
  }

  function setCursor(hash) {
    if (hash === cursorHash) return
    cursorHash = hash
    table.positionAt(View.indexOfHash(tableRows, hash))
    saveView()
  }

  function setPane(next) {
    if (next === pane) return
    pane = next
    saveView()
  }

  function rawFor(hashes) {
    var out = []
    for (var i = 0; i < rawRows.length; i++) {
      if (hashes.indexOf(Model.torrentId(rawRows[i])) !== -1) out.push(rawRows[i])
    }
    return out
  }

  // The torrents a command acts on. Task 8 widens this to the VISUAL range.
  function targetHashes() {
    return cursorIndex >= 0 ? [cursorHash] : []
  }

  function opts(hashes) {
    return { origin: "window", hashes: hashes }
  }

  // ---- messages --------------------------------------------------------------

  function track(ticket, text) {
    if (!ticket || ticket <= 0) return
    var next = ({})
    for (var k in tickets) next[k] = tickets[k]
    next[ticket] = text
    tickets = next
    progressText = text
  }

  function finishTicket(ticket) {
    if (!Object.prototype.hasOwnProperty.call(tickets, ticket)) return
    var next = ({})
    var last = ""
    for (var k in tickets) {
      if (String(k) === String(ticket)) continue
      next[k] = tickets[k]
      last = tickets[k]
    }
    tickets = next
    progressText = last
  }

  function note(text, tone) {
    noteText = text
    noteTone = tone || "muted"
  }

  // ---- keys --------------------------------------------------------------------

  function isEnterKey(ev) {
    return ev.key === Registry.KEY.Return || ev.key === Registry.KEY.Enter
  }

  function handleKey(event) {
    var ev = View.keyEvent(event.key, event.text, event.modifiers, Date.now())
    noteText = ""
    var st = ({})
    for (var k in regState) st[k] = regState[k]
    st.pane = View.dispatchPane(pane, tableState)
    st.hasTorrent = tableState === "rows" && cursorIndex >= 0
    st.selectionCount = 0
    var res = Registry.dispatch(st, ev)

    // Task 8 owns VISUAL and the help overlay: V and ? do nothing yet, and
    // the mode switch dispatch() made for V is dropped with them.
    if (res.commandId === "visual.enter" || res.commandId === "help.toggle") {
      st.prefix = null
      st.prefixAt = 0
      regState = st
      return
    }

    regState = res.state
    if (res.confirm) {
      confirm = res.confirm
      confirmHashes = targetHashes()
      return
    }
    if (res.state.mode !== "CONFIRM") confirm = null
    if (res.blocked) {
      handleBlocked(ev)
      return
    }
    if (res.commandId) run(res.commandId, res.args || ({}), ev)
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
      track(service.setLocation(moveHashes.join("|"), text, opts(moveHashes)), View.progressText("move", moveHashes.length))
      moveHashes = []
    } else if (Model.isAddableTarget(text)) {
      track(service.addTarget(text, false, "", opts([])), View.progressText("add", 1))
      textQuery = ""
      rebuildRows()
    } else {
      textQuery = Model.listQuery(text)
      rebuildRows()
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
      rebuildRows()
    }
    moveHashes = []
    endInput()
  }

  // Maps a command id from CommandRegistry to Service calls and view
  // changes. Service calls always carry {origin: "window", hashes}.
  function run(commandId, args, ev) {
    if (!service) return
    var hashes, rows, starts

    switch (commandId) {
    case "cursor.down":
    case "cursor.up":
    case "cursor.top":
    case "cursor.bottom":
      setCursor(View.moveCursor(tableRows, cursorHash, commandId))
      return

    case "torrent.toggle":
      hashes = targetHashes()
      if (hashes.length === 0) return
      starts = View.toggleStarts(rawFor(hashes))
      if (starts) track(service.startHash(hashes.join("|"), opts(hashes)), View.progressText("start", hashes.length))
      else track(service.stopHash(hashes.join("|"), opts(hashes)), View.progressText("stop", hashes.length))
      return

    case "torrent.remove":
    case "torrent.delete":
      hashes = args.confirmed === true ? confirmHashes : targetHashes()
      confirmHashes = []
      if (hashes.length === 0) return
      var withFiles = commandId === "torrent.delete"
      track(service.deleteHash(hashes.join("|"), withFiles, opts(hashes)),
        View.progressText(withFiles ? "delete" : "remove", hashes.length))
      return

    case "torrent.recheck":
      hashes = targetHashes()
      if (hashes.length === 0) return
      track(service.recheckHash(hashes.join("|"), opts(hashes)), View.progressText("recheck", hashes.length))
      return

    case "torrent.openFolder":
      rows = rawFor(targetHashes())
      if (rows.length > 0 && rows[0].savePath) service.openPath(rows[0].savePath)
      return

    case "torrent.copyMagnet":
      rows = rawFor(targetHashes())
      if (rows.length === 0) return
      service.copyMagnet(rows[0])
      note("Copied magnet.", "muted")
      return

    case "torrent.move":
      hashes = targetHashes()
      rows = rawFor(hashes)
      if (rows.length === 0) return
      moveHashes = hashes
      startInput("move", String(rows[0].savePath || ""))
      return

    case "inspector.files":
      // Enter doubles as the primary action of a blocking state.
      if (isEnterKey(ev) && tableState === "daemon") {
        service.startDaemon()
        note(View.progressText("daemon", 0), "muted")
        return
      }
      if (isEnterKey(ev) && tableState === "notInstalled") {
        service.installDaemon()
        note(View.progressText("install", 0), "muted")
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
      track(service.toggleAll(opts(hashes)), View.progressText(starts ? "startAll" : "stopAll", hashes.length))
      return

    case "turtle.toggle":
      track(service.toggleTurtle(opts([])), View.progressText("turtle", 0))
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
      rebuildRows()
      return

    case "filter.reset":
      textQuery = ""
      filter = View.defaultFilter()
      rebuildRows()
      saveView()
      return

    case "insert.commit":
      commitInput()
      return

    case "insert.cancel":
      cancelInput()
      return

    case "refresh":
      service.refresh()
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
      // filter.down/up/apply: Task 8 (FilterPane).
      return
    }
  }

  // ---- wiring ----------------------------------------------------------------

  onServiceChanged: adoptService()

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
      // Strictly this window's own tickets: a pending-magnet drop can emit
      // extra window-origin signals that carry our hashes.
      root.finishTicket(ticket)
    }
    function onClipboardTextChanged() {
      if (root.clipboardAskedAt <= 0) return
      if (Date.now() - root.clipboardAskedAt > 3000) {
        root.clipboardAskedAt = 0
        return
      }
      var text = String(root.service.clipboardText || "").trim()
      if (text === "") return
      root.clipboardAskedAt = 0
      if (Model.isAddableTarget(text)) root.track(root.service.addTarget(text, false, "", root.opts([])), View.progressText("add", 1))
      else root.note("The clipboard has no magnet, .torrent URL or .torrent path.", "urgent")
    }
  }

  Timer {
    id: focusRetry
    interval: 100
    repeat: true
    onTriggered: root.focusStep()
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

  // A titled, bordered pane. A focused pane gets a 1 px accent outline and
  // an accent title; the others a normalBorderAlpha line and a muted title.
  component Pane: Item {
    id: paneItem
    property string title: ""
    property string titleRight: ""
    property bool focusedPane: false
    property bool rightLine: true
    default property alias content: paneBody.data
    readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

    Item {
      id: titleBar
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(30)

      Text {
        id: titleText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: paneItem.title
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.capitalization: Font.AllUppercase
        font.letterSpacing: Style.font.bodySmall * 0.1
        color: paneItem.focusedPane ? Color.accent : Color.muted
      }

      Text {
        anchors.left: titleText.right
        anchors.leftMargin: Style.space(12)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideLeft
        text: paneItem.titleRight
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: paneItem.focusedPane ? Color.accent : Color.muted
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: paneItem.lineColor
      }
    }

    Item {
      id: paneBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: titleBar.bottom
      anchors.bottom: parent.bottom
    }

    Rectangle {
      visible: paneItem.rightLine
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      color: paneItem.lineColor
    }

    Rectangle {
      visible: paneItem.focusedPane
      anchors.fill: parent
      color: "transparent"
      border.width: 1
      border.color: Color.accent
    }
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

        Pane {
          width: Style.space(210)
          height: panes.height
          title: "Filters"
          focusedPane: root.pane === "filters"
        }

        Pane {
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
            onRowClicked: function(hash) {
              root.leaveInsert()
              root.setPane("table")
              root.setCursor(hash)
              keyRoot.forceActiveFocus()
            }
          }
        }

        Pane {
          width: Style.space(380)
          height: panes.height
          title: "Inspector"
          focusedPane: root.pane === "inspector"
          rightLine: false
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
        speedText: root.service ? "↓ " + Model.formatRate(root.service.dlSpeed) + " ↑ " + Model.formatRate(root.service.upSpeed) : ""
        turtle: !!root.service && root.service.altSpeed
        vpn: root.service ? View.vpnPart(root.service.vpnIface, root.service.bindIface, root.service.vpnUnbound) : null
        sidecarDown: !!root.service && root.service.sidecarState === "down"
        loading: root.loading
        message: root.noteText !== "" ? root.noteText : root.progressText
        messageTone: root.noteText !== "" ? root.noteTone : "muted"
        inputPurpose: root.inputPurpose
        hints: View.modeHints(root.mode, {
          accept: root.confirm ? View.confirmLine(root.confirm).accept : "",
          purpose: root.inputPurpose
        })

        onInputEdited: function(text) {
          if (root.mode !== "INSERT" || root.inputPurpose !== "filter") return
          // "Matches update as you type"; a pasted magnet/URL/path is an
          // add target, not a query, so it doesn't filter the table empty.
          root.textQuery = Model.listQuery(text)
          root.rebuildRows()
        }
      }
    }
  }
}
