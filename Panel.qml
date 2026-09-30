import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "PopupKeys.js" as PopupKeys

Panel {
  id: root
  moduleName: "aweiward.omaqbt"
  ipcTarget: "aweiward.omaqbt"
  manageIpc: false

  property string focusSection: "header"
  property int rowIndex: 0
  property int fileIndex: 0
  property bool cursorActive: false
  property string view: "list"
  property string filterMode: "active"
  property string sortMode: "default"
  property string detailHash: ""
  property string magnetField: ""
  property string savePathField: ""
  property bool moveFieldOpen: false
  property string movePathField: ""
  property bool confirmOpen: false
  property string pendingDeleteHash: ""
  // The last key press inside the popup, read by keySpy before the catcher
  // sees it: the catcher's deleteRequested() carries no key, so this tells x from X.
  property string lastKeyText: ""
  property string windowNote: ""
  // Set by the catcher's returnRequested, which fires just before
  // activateRequested for Enter only: activate without it is Space.
  property bool enterPending: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color barIconColor: qbt.transferring ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool fieldFocused: (magnetInput && magnetInput.activeFocus) || (savePathInput && savePathInput.activeFocus) || (movePathInput && movePathInput.activeFocus)
  readonly property bool fieldAddable: Model.isAddableTarget(magnetField)
  readonly property string listFilterQuery: Model.listQuery(magnetField)
  readonly property var visibleTorrents: Model.sortTorrents(Model.filterByQuery(Model.filterTorrents(Model.excludePending(qbt.torrents, qbt.magnetPendingHashes), filterMode), listFilterQuery), sortMode)
  readonly property int activeCount: Model.filterTorrents(qbt.torrents, "active").length
  readonly property var selectedTorrent: {
    if (visibleTorrents.length === 0) return null
    return visibleTorrents[Math.max(0, Math.min(rowIndex, visibleTorrents.length - 1))]
  }
  readonly property var detailTorrent: {
    for (var i = 0; i < qbt.torrents.length; i++)
      if (qbt.torrents[i].hash === detailHash) return qbt.torrents[i]
    return null
  }
  readonly property bool headerHasCursor: cursorActive && focusSection === "header" && qbt.ready && view === "list"
  readonly property bool detailHasFolder: detailTorrent !== null && detailTorrent.savePath !== ""
  readonly property string heroTitle: {
    if (view === "detail" && detailTorrent) return Model.plainText(detailTorrent.name)
    return "OmaqBT"
  }
  readonly property string heroMeta: {
    if (view === "detail" && detailTorrent) {
      return Model.formatPercent(detailTorrent.progress) + " · " + Model.formatRate(detailTorrent.dlSpeed) + " · " + Model.formatEta(detailTorrent.eta)
    }
    if (!qbt.installed) return "qBittorrent-nox is not installed"
    if (qbt.lockHolder === "gui") return "Close qBittorrent first"
    if (!qbt.daemon) return "Daemon is not running"
    if (!qbt.api) return "Web API is not reachable"
    var meta = Model.formatRate(qbt.dlSpeed) + " · " + Model.formatRate(qbt.upSpeed) + " · " + activeCount + " active"
    if (qbt.altSpeed) meta += " · turtle"
    if (sortMode !== "default") meta += " · " + Model.sortLabel(sortMode)
    return meta
  }
  readonly property string emptyListText: {
    if (listFilterQuery !== "") return "No matching torrents."
    if (filterMode === "paused") return "No paused torrents."
    if (filterMode === "completed") return "No completed torrents."
    if (filterMode === "all") return "No torrents."
    return "Nothing downloading or seeding."
  }
  readonly property string toggleHint: qbt.transferring ? "Stop all torrents" : "Start all torrents"
  readonly property bool showClipboard: qbt.ready && view === "list" && Model.isAddableTarget(qbt.clipboardText)
  // Model.magnetConfirmState is the one derivation the window shares. The
  // binding re-runs on every magnet snapshot (250 ms while magnets wait),
  // which is also what re-reads Date.now() for the 15-second fallback.
  readonly property var magnetState: Model.magnetConfirmState(qbt.magnetPending, qbt.magnetInbox, qbt.torrents, Date.now() / 1000)
  readonly property var magnetCurrentPending: magnetState.pending
  readonly property var magnetCurrentInbox: magnetState.inbox
  readonly property var magnetCurrentRow: magnetState.row
  readonly property bool magnetHasQueue: magnetState.active
  readonly property bool magnetIsError: magnetState.isError
  readonly property bool magnetCanStart: magnetState.canStart
  readonly property string magnetTitle: magnetState.title
  readonly property string magnetSizeText: magnetState.sizeText
  readonly property int magnetMore: magnetState.more
  readonly property bool magnetConfirmOpen: magnetHasQueue && view === "list"

  function selectedFile() {
    var files = qbt.filesFor(detailHash)
    if (files.length === 0) return null
    return files[Math.max(0, Math.min(fileIndex, files.length - 1))]
  }

  function ensureCursor() {
    if (!qbt.installed) { focusSection = "install"; return }
    if (qbt.lockHolder === "gui") { focusSection = "lock"; return }
    if (!qbt.daemon) { focusSection = "daemon"; return }
    if (view === "detail") {
      var allowed = {
        openFolder: true, copyMagnet: true, moveTo: true, recheck: true,
        remove: true, deleteFiles: true, files: true
      }
      if (!allowed[focusSection])
        focusSection = detailHasFolder ? "openFolder" : "copyMagnet"
      if (focusSection === "openFolder" && !detailHasFolder) focusSection = "copyMagnet"
      var files = qbt.filesFor(detailHash)
      if (fileIndex >= files.length) fileIndex = Math.max(0, files.length - 1)
      return
    }
    if (focusSection === "install" || focusSection === "daemon" || focusSection === "lock") focusSection = "header"
    if (rowIndex >= visibleTorrents.length) rowIndex = Math.max(0, visibleTorrents.length - 1)
    if (rowIndex < 0) rowIndex = 0
  }

  function syncFocus() {
    if (root.confirmOpen && confirmKeyTrap) {
      confirmKeyTrap.forceActiveFocus()
      return
    }
    if (root.fieldFocused) return
    keySpy.forceActiveFocus()
  }

  function openDetail(row) {
    if (!row) return
    view = "detail"
    detailHash = row.hash
    fileIndex = 0
    focusSection = "remove"
    qbt.loadFiles(row.hash)
    if (panelFlick) panelFlick.contentY = 0
  }

  function closeDetail() {
    view = "list"
    detailHash = ""
    fileIndex = 0
    moveFieldOpen = false
    movePathField = ""
    focusSection = visibleTorrents.length ? "rows" : "header"
  }

  function askDeleteFiles(hash) {
    pendingDeleteHash = hash
    confirmOpen = true
    Qt.callLater(syncFocus)
  }

  function removeKeepFiles(hash) {
    if (!hash) return
    qbt.deleteHash(hash, false)
    closeDetail()
  }

  function openFolder(row) {
    if (row && row.savePath) qbt.openPath(row.savePath)
  }

  function openMoveField() {
    if (!detailTorrent) return
    moveFieldOpen = true
    movePathField = String(detailTorrent.savePath || "")
    focusSection = "moveTo"
    Qt.callLater(function() {
      if (movePathInput) movePathInput.forceActiveFocus()
    })
  }

  function closeMoveField() {
    moveFieldOpen = false
    movePathField = ""
    if (movePathInput) movePathInput.text = ""
    focusSection = "moveTo"
    Qt.callLater(syncFocus)
  }

  function submitMove() {
    if (!detailHash) return
    var path = String(movePathField || "").trim()
    if (path === "") {
      qbt.lastError = "Enter an absolute path to move to."
      return
    }
    qbt.setLocation(detailHash, path)
    closeMoveField()
  }

  function copyDetailMagnet() {
    if (detailTorrent) qbt.copyMagnet(detailTorrent)
  }

  function recheckDetail() {
    if (detailHash) qbt.recheckHash(detailHash)
  }

  function startMagnetConfirm() {
    if (!magnetCanStart || !magnetCurrentPending) return
    qbt.startPending(magnetCurrentPending.hash)
  }

  function cancelMagnetConfirm() {
    if (magnetCurrentPending && magnetCurrentPending.hash) {
      qbt.cancelPending(magnetCurrentPending.hash)
      return
    }
    if (magnetCurrentInbox) qbt.dropInboxCurrent()
  }

  function submitAdd(stopped) {
    if (!fieldAddable) return
    qbt.addTarget(magnetField, stopped, savePathField)
    magnetField = ""
    savePathField = ""
    if (magnetInput) magnetInput.text = ""
    if (savePathInput) savePathInput.text = ""
  }

  function setFilter(mode) {
    filterMode = mode
    rowIndex = 0
    if (view === "list") focusSection = visibleTorrents.length ? "rows" : "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    if (view === "detail") {
      if (moveFieldOpen) return
      var order = []
      if (detailHasFolder) order.push("openFolder")
      order.push("copyMagnet", "moveTo", "recheck", "remove", "deleteFiles")
      if (qbt.filesFor(detailHash).length > 0) order.push("files")
      var idx = order.indexOf(focusSection)
      if (idx < 0) {
        focusSection = order[0]
        return
      }
      if (focusSection === "files") {
        if (dy < 0 && fileIndex === 0) {
          focusSection = "deleteFiles"
          return
        }
        if (dy < 0 || dy > 0) {
          fileIndex = Math.max(0, Math.min(qbt.filesFor(detailHash).length - 1, fileIndex + dy))
        }
        return
      }
      var next = idx + dy
      if (next < 0 || next >= order.length) return
      focusSection = order[next]
      if (focusSection === "files") fileIndex = 0
      return
    }
    if (focusSection === "header") {
      if (dy > 0) focusSection = "window"
      return
    }
    if (focusSection === "window") {
      if (dy < 0) { focusSection = "header"; return }
      if (dy > 0 && showClipboard) { focusSection = "clipboard"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "clipboard") {
      if (dy < 0) { focusSection = "window"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "rows") {
      if (dy < 0 && rowIndex === 0) {
        focusSection = showClipboard ? "clipboard" : "window"
        return
      }
      rowIndex = Math.max(0, Math.min(visibleTorrents.length - 1, rowIndex + dy))
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "install") qbt.installDaemon()
    else if (focusSection === "daemon") qbt.startDaemon()
    else if (focusSection === "magnetConfirm") {
      if (magnetCanStart) startMagnetConfirm()
    }
    else if (focusSection === "header") qbt.toggleAll()
    else if (focusSection === "window") openWindowFromPopup()
    else if (focusSection === "clipboard") qbt.addUrl(qbt.clipboardText)
    else if (focusSection === "rows") openDetail(selectedTorrent)
    else if (focusSection === "files") cycleSelectedFile()
    else if (focusSection === "copyMagnet") copyDetailMagnet()
    else if (focusSection === "moveTo") openMoveField()
    else if (focusSection === "recheck") recheckDetail()
    else if (focusSection === "openFolder") openFolder(detailTorrent)
    else if (focusSection === "remove") removeKeepFiles(detailHash)
    else if (focusSection === "deleteFiles") askDeleteFiles(detailHash)
  }

  // Closes the popup, then summons the window. With no shell summon (an old
  // or replacement bar) the popup stays open and shows how to open it.
  function openWindowFromPopup() {
    var shell = root.bar ? root.bar.shell : null
    var result = PopupKeys.openWindow(shell, function() { root.close() })
    windowNote = result.ok ? "" : result.note
  }

  function keyState() {
    return {
      view: view,
      section: focusSection,
      blocked: keyCatcher.blocked,
      magnetConfirmOpen: magnetConfirmOpen && !fieldFocused,
      cursorActive: cursorActive
    }
  }

  // Every catcher signal goes through PopupKeys.route; this runs the action.
  function routeKey(signal, arg) {
    var r = PopupKeys.route(signal, arg, keyState())
    var a = r.action
    if (a === "openWindow") openWindowFromPopup()
    else if (a === "back") closeDetail()
    else if (a === "remove") {
      if (view === "detail") removeKeepFiles(detailHash)
      else if (selectedTorrent) qbt.deleteHash(selectedTorrent.hash, false)
    }
    else if (a === "deleteFiles") {
      var hash = view === "detail" ? detailHash : (selectedTorrent ? selectedTorrent.hash : "")
      if (hash) askDeleteFiles(hash)
    }
    else if (a === "skipFile") skipSelectedFile()
    else if (a === "toggle") {
      if (!qbt.ready) return
      if (view === "detail") { if (detailHash) qbt.toggleHash(detailHash) }
      else if (selectedTorrent) qbt.toggleHash(selectedTorrent.hash)
    }
    else if (a === "moveCursor") {
      if (!cursorActive) { cursorActive = true; return }
      moveCursor(r.args[0], r.args[1])
    }
    else if (a === "activateCursor") activateCursor()
    else if (a === "text") handleTextKey(r.args[0])
    else if (a === "close") root.close()
    else if (a === "cancelMagnet") cancelMagnetConfirm()
    else if (a === "startMagnet") startMagnetConfirm()
  }

  function cycleSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    var next = Model.cyclePriority(file.priority)
    qbt.setPrio(detailHash, file.index, next)
    var files = qbt.filesFor(detailHash)
    var copy = []
    for (var i = 0; i < files.length; i++) {
      var row = files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: next })
      } else {
        copy.push(row)
      }
    }
    qbt.setFilesFor(detailHash, copy)
  }

  function skipSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    qbt.setPrio(detailHash, file.index, 0)
    var files = qbt.filesFor(detailHash)
    var copy = []
    for (var i = 0; i < files.length; i++) {
      var row = files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: 0 })
      } else {
        copy.push(row)
      }
    }
    qbt.setFilesFor(detailHash, copy)
  }

  function handleTextKey(t) {
    if (confirmOpen) return
    if (magnetConfirmOpen && (t === "t" || t === "T")) {
      if (qbt.ready) qbt.toggleAll()
      return
    }
    if (t === "t" || t === "T") {
      if (qbt.ready) qbt.toggleAll()
    } else if (t === "/") {
      if (qbt.ready && view === "list" && magnetInput) magnetInput.forceActiveFocus()
    } else if (t === "y" || t === "Y") {
      if (view === "detail") copyDetailMagnet()
      else if (showClipboard) qbt.addUrl(qbt.clipboardText)
    } else if (t === "m" || t === "M") {
      if (view === "detail") openMoveField()
    } else if (t === "e" || t === "E") {
      if (view === "detail") recheckDetail()
    } else if (t === "r" || t === "R") {
      qbt.refresh()
      if (view === "detail" && detailHash) qbt.loadFiles(detailHash)
    } else if (t === "a" || t === "A") {
      if (view === "list") setFilter("active")
    } else if (t === "p" || t === "P") {
      if (view === "list") setFilter("paused")
    } else if (t === "c" || t === "C") {
      if (view === "list") setFilter("completed")
    } else if (t === "*") {
      if (view === "list") setFilter("all")
    } else if (t === "H") {
      // The catcher sends h as a move and x/X as delete (PopupKeys.route);
      // only a shifted H arrives here as text.
      if (view === "detail") closeDetail()
    } else if (t === "s" || t === "S") {
      if (view === "list") sortMode = Model.cycleSort(sortMode)
    } else if (t === "z" || t === "Z") {
      if (qbt.ready) qbt.toggleTurtle()
    } else if (t === "o" || t === "O") {
      if (view === "detail") openFolder(detailTorrent)
      else openFolder(selectedTorrent)
    }
  }

  readonly property bool barVertical: bar ? bar.vertical : false
  readonly property string barSpeeds: barVertical ? "" : Model.barSpeedText(qbt.dlSpeed, qbt.upSpeed, qbt.transferring)

  implicitWidth: button.implicitWidth + (speedButton.visible ? speedButton.implicitWidth : 0)
  implicitHeight: button.implicitHeight

  function barPressed(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      if (qbt.ready) qbt.toggleAll()
      else root.toggle()
    } else if (buttonCode === Qt.MiddleButton) {
      qbt.refresh()
    } else {
      root.toggle()
    }
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    view = "list"
    filterMode = "active"
    magnetField = ""
    confirmOpen = false
    windowNote = ""
    lastKeyText = ""
    enterPending = false
    if (panelFlick) panelFlick.contentY = 0
    qbt.refresh()
    qbt.loadMagnetSnapshot()
    qbt.readClipboard()
    ensureCursor()
    Qt.callLater(syncFocus)
  }

  // Third-party widgets get the shell facade as bar.shell (Bar.qml
  // pluginBarApiFor -> PluginShellApi.serviceFor). `bar` is injected after
  // creation, so the local fallback stays off until it lands.
  readonly property var sharedService: (root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function") ? root.bar.shell.serviceFor("aweiward.omaqbt") : null
  readonly property var qbt: sharedService || localService

  Service {
    id: localService
    settings: root.settings
    active: root.bar !== null && root.sharedService === null
    startDelayMs: 1500
  }

  Binding {
    target: root.sharedService
    property: "settings"
    value: root.settings
    when: root.sharedService !== null
  }

  onMagnetHasQueueChanged: if (magnetHasQueue) view = "list"

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    // The browser-magnet raise (`qbt magnet-inbox`). While the window is
    // open it shows the confirm itself, so the popup stays shut.
    function magnet(): void {
      root.qbt.loadMagnetSnapshot()
      if (!root.qbt.windowOpen) root.open()
    }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.qbt.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: root.barVertical ? parent.width : implicitWidth
    bar: root.bar
    iconComponent: Component {
      Item {
        OmaqbtLogo {
          anchors.centerIn: parent
          iconSize: Style.font.icon
          color: root.barIconColor
          tailColor: root.qbt.transferring ? Color.accent : root.barIconColor
          badgeColor: root.urgent
          warning: root.qbt.warning
        }
      }
    }
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  WidgetButton {
    id: speedButton
    anchors.left: button.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: visible ? implicitWidth : 0
    bar: root.bar
    text: root.barSpeeds
    fontSize: Style.font.bodySmall
    horizontalMargin: 3
    tooltipText: Model.formatRate(root.qbt.dlSpeed) + " down · " + Model.formatRate(root.qbt.upSpeed) + " up"
    onPressed: function(buttonCode) { root.barPressed(buttonCode) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keySpy
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.fieldFocused || root.confirmOpen
      // Focus lands on keySpy, never the catcher itself, so the spy sees
      // every key before it bubbles up here.
      onActiveFocusChanged: if (activeFocus) keySpy.forceActiveFocus()
      onMoveRequested: function(dx, dy) { root.routeKey("move", { dx: dx, dy: dy }) }
      onReturnRequested: root.enterPending = true
      onActivateRequested: {
        var key = root.enterPending ? "enter" : "space"
        root.enterPending = false
        root.routeKey("activate", key)
      }
      onCloseRequested: root.routeKey("close", null)
      onDeleteRequested: {
        var key = root.lastKeyText
        root.lastKeyText = ""
        root.routeKey("delete", key)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.routeKey("text", t) }

      // A focused child of the catcher: key presses reach it first, then
      // bubble (unaccepted) to the catcher's handler.
      Item {
        id: keySpy
        Keys.onPressed: function(event) {
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
          var del = PopupKeys.deleteKey(event.text, shift)
          root.lastKeyText = del !== "" ? del : event.text
        }
      }

      DropArea {
        anchors.fill: parent
        onDropped: function(drop) {
          if (!root.qbt.ready) return
          var target = ""
          if (drop.hasUrls && drop.urls.length > 0) {
            for (var i = 0; i < drop.urls.length; i++) {
              if (Model.isAddableTarget(String(drop.urls[i]))) { target = String(drop.urls[i]); break }
            }
          }
          if (target === "" && drop.hasText && Model.isAddableTarget(drop.text)) target = drop.text
          if (target === "") return
          root.qbt.addTarget(target, false, "")
          drop.accept()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            visible: root.view === "detail"
            width: parent.width
            implicitHeight: backLabel.implicitHeight
            Text {
              id: backLabel
              text: "← Torrents"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeDetail()
            }
          }

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "header"
            }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.qbt.transferring ? 1.0 : 0.5
              iconComponent: Component {
                OmaqbtLogo {
                  iconSize: Style.font.display
                  color: root.qbt.transferring ? root.foreground : root.dim
                  tailColor: root.qbt.transferring ? Color.accent : root.dim
                  badgeColor: root.urgent
                  warning: root.qbt.warning
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: root.qbt.ready && root.view === "list"
                  checked: root.qbt.transferring
                  busy: root.qbt.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.qbt.toggleAll()
                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // Always shown in the list view, even with qBittorrent missing or
          // the daemon stopped: Enter, a click or `w` opens the window.
          CursorSurface {
            id: windowRow
            visible: root.view === "list"
            width: parent.width
            implicitHeight: Style.space(36)
            hasCursor: root.cursorActive && root.focusSection === "window"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.cursorActive = true; root.focusSection = "window" }
              onClicked: root.openWindowFromPopup()
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              text: PopupKeys.ROW_LABEL
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              text: PopupKeys.ROW_KEY
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            visible: root.view === "list" && root.windowNote !== ""
            width: parent.width
            text: root.windowNote
            textFormat: Text.PlainText
            color: root.dim
            wrapMode: Text.WrapAnywhere
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: root.qbt.ready && root.view === "detail"
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.detailTorrent !== null
              width: parent.width
              text: {
                var t = root.detailTorrent
                if (!t) return ""
                var line = Model.formatSize(t.size) + " · ratio " + Number(t.ratio).toFixed(2) +
                  " · " + t.numSeeds + " seeds · " + t.numLeechs + " peers · added " + Model.formatDate(t.addedOn)
                if (t.savePath !== "") line += "\n" + Model.plainText(t.savePath)
                return line
              }
              color: root.dim
              wrapMode: Text.WrapAnywhere
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            CursorSurface {
              visible: root.detailHasFolder
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              hasCursor: root.cursorActive && root.focusSection === "openFolder"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.focusSection = "openFolder" }
                onClicked: root.openFolder(root.detailTorrent)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Open folder"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              hasCursor: root.cursorActive && root.focusSection === "copyMagnet"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: root.detailTorrent !== null
                onEntered: { root.cursorActive = true; root.focusSection = "copyMagnet" }
                onClicked: root.copyDetailMagnet()
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Copy magnet"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              visible: !root.moveFieldOpen
              hasCursor: root.cursorActive && root.focusSection === "moveTo"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !root.qbt.busy && root.detailHash !== ""
                onEntered: { root.cursorActive = true; root.focusSection = "moveTo" }
                onClicked: root.openMoveField()
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Move to…"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            TextField {
              id: movePathInput
              visible: root.moveFieldOpen
              width: parent.width
              foreground: root.foreground
              placeholderText: "Move to… (absolute path)"
              text: root.movePathField
              onTextChanged: root.movePathField = text
              onAccepted: root.submitMove()
              Keys.onEscapePressed: root.closeMoveField()
            }

            CursorSurface {
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              hasCursor: root.cursorActive && root.focusSection === "recheck"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !root.qbt.busy && root.detailHash !== ""
                onEntered: { root.cursorActive = true; root.focusSection = "recheck" }
                onClicked: root.recheckDetail()
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Force recheck"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              hasCursor: root.cursorActive && root.focusSection === "remove"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !root.qbt.busy && root.detailHash !== ""
                onEntered: { root.cursorActive = true; root.focusSection = "remove" }
                onClicked: root.removeKeepFiles(root.detailHash)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Remove, keep files"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              width: parent.width
              height: Style.space(36)
              implicitHeight: height
              hasCursor: root.cursorActive && root.focusSection === "deleteFiles"
              foreground: root.urgent
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !root.qbt.busy && root.detailHash !== ""
                onEntered: { root.cursorActive = true; root.focusSection = "deleteFiles" }
                onClicked: root.askDeleteFiles(root.detailHash)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Delete files"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Repeater {
              model: root.detailTorrent === null ? [] : [
                {
                  label: "Download limit: " + Model.limitLabel(root.detailTorrent.dlLimit),
                  action: "dlLimit"
                },
                {
                  label: "Upload limit: " + Model.limitLabel(root.detailTorrent.upLimit),
                  action: "upLimit"
                },
                {
                  label: "Sequential download: " + (root.detailTorrent.seqDl ? "on" : "off"),
                  action: "sequential"
                },
                {
                  label: "Seed ratio limit: " + Model.ratioLimitLabel(root.detailTorrent.ratioLimit),
                  action: "shareRatio"
                }
              ]
              delegate: CursorSurface {
                required property var modelData
                width: parent ? parent.width : 0
                height: Style.space(30)
                implicitHeight: height
                hasCursor: false
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                  enabled: !root.qbt.busy && root.detailTorrent !== null
                  onClicked: {
                    var t = root.detailTorrent
                    if (!t) return
                    if (modelData.action === "dlLimit") root.qbt.setLimit(t.hash, "dl", Model.cycleLimit(t.dlLimit))
                    else if (modelData.action === "upLimit") root.qbt.setLimit(t.hash, "up", Model.cycleLimit(t.upLimit))
                    else if (modelData.action === "sequential") root.qbt.setSequential(t.hash, !t.seqDl, undefined, "")
                    else if (modelData.action === "shareRatio") root.qbt.setShareRatio(t.hash, Model.cycleRatioLimit(t.ratioLimit))
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  text: parent.modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Text {
            visible: root.qbt.actionStatus !== "" || root.qbt.lastError !== ""
            width: parent.width
            text: root.qbt.actionStatus !== "" ? root.qbt.actionStatus : root.qbt.lastError
            color: root.qbt.lastError !== "" && root.qbt.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          CursorSurface {
            visible: !root.qbt.installed
            width: parent.width
            implicitHeight: installCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "install"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !root.qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "install" }
              onClicked: root.qbt.installDaemon()
            }
            Column {
              id: installCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - installCol.leftPadding - installCol.rightPadding
                text: "qBittorrent-nox is not installed. Installs qbittorrent-nox from Arch extra. Leaves the desktop qBittorrent app alone."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: root.qbt.busy ? "Installing…" : "Install qBittorrent-nox"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: root.qbt.installed && root.qbt.lockHolder === "gui"
            width: parent.width
            implicitHeight: lockCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "lock"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: { root.cursorActive = true; root.focusSection = "lock" }
            }
            Column {
              id: lockCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - lockCol.leftPadding - lockCol.rightPadding
                text: "Close qBittorrent before starting the daemon."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: root.qbt.installed && !root.qbt.daemon && root.qbt.lockHolder !== "gui"
            width: parent.width
            implicitHeight: daemonCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "daemon"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !root.qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "daemon" }
              onClicked: root.qbt.startDaemon()
            }
            Column {
              id: daemonCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - daemonCol.leftPadding - daemonCol.rightPadding
                text: "qBittorrent daemon is not running"
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: root.qbt.busy ? "Starting…" : "Start daemon"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: root.qbt.vpnUnbound
            width: parent.width
            implicitHeight: vpnCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: false
            foreground: root.urgent
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !root.qbt.busy
              onClicked: root.qbt.startDaemon()
            }
            Column {
              id: vpnCol
              width: parent.width
              spacing: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              leftPadding: Style.space(10)
              rightPadding: Style.space(10)
              Text {
                width: parent.width - vpnCol.leftPadding - vpnCol.rightPadding
                text: "VPN is up but qBittorrent is not bound to " + root.qbt.vpnIface + ". If the VPN drops, transfers keep going outside it."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                text: root.qbt.busy ? "Restarting…" : "Restart daemon to bind"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            visible: root.qbt.ready && root.view === "list"
            width: parent.width
            spacing: Style.space(8)

            Column {
              visible: root.magnetConfirmOpen
              width: parent.width
              spacing: Style.space(6)

              CursorSurface {
                width: parent.width
                implicitHeight: magnetCol.implicitHeight + Style.spacing.rowPaddingX
                hasCursor: root.cursorActive && root.focusSection === "magnetConfirm"
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: { root.cursorActive = true; root.focusSection = "magnetConfirm" }
                }
                Column {
                  id: magnetCol
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(10)
                  rightPadding: Style.space(10)
                  spacing: Style.space(4)
                  Text {
                    text: "From browser"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: parent.width - magnetCol.leftPadding - magnetCol.rightPadding
                    text: root.magnetTitle
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    visible: root.magnetSizeText !== ""
                    text: root.magnetSizeText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: root.magnetMore > 0
                    text: "and " + root.magnetMore + " more waiting"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              CursorSurface {
                visible: root.magnetCanStart
                width: parent.width
                implicitHeight: Style.space(36)
                hasCursor: false
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startMagnetConfirm()
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  text: "Start  Enter"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              CursorSurface {
                width: parent.width
                implicitHeight: Style.space(36)
                hasCursor: false
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cancelMagnetConfirm()
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  text: "Cancel  Esc"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            TextField {
              id: magnetInput
              width: parent.width
              foreground: root.foreground
              placeholderText: "Paste a magnet, URL, or .torrent path · type to filter"
              text: root.magnetField
              onTextChanged: root.magnetField = text
              onAccepted: root.submitAdd(false)
              Keys.onEscapePressed: {
                if (text !== "") {
                  text = ""
                  root.magnetField = ""
                } else {
                  root.close()
                }
              }
            }

            TextField {
              id: savePathInput
              visible: root.fieldAddable
              width: parent.width
              foreground: root.foreground
              placeholderText: "Save to… (leave empty for the default path)"
              text: root.savePathField
              onTextChanged: root.savePathField = text
              onAccepted: root.submitAdd(false)
              Keys.onEscapePressed: {
                if (text !== "") {
                  text = ""
                  root.savePathField = ""
                } else {
                  root.close()
                }
              }
            }

            CursorSurface {
              visible: root.fieldAddable
              width: parent.width
              implicitHeight: Style.space(36)
              hasCursor: false
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.submitAdd(true)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Add stopped"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              visible: root.showClipboard
              width: parent.width
              implicitHeight: Style.space(36)
              hasCursor: root.cursorActive && root.focusSection === "clipboard"
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.focusSection = "clipboard" }
                onClicked: root.qbt.addTarget(root.qbt.clipboardText, false, "")
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Add from clipboard"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            CursorSurface {
              width: parent.width
              implicitHeight: Style.space(36)
              hasCursor: false
              foreground: root.foreground
              fill: root.hoverFill
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: root.qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !root.qbt.busy
                onClicked: root.qbt.toggleTurtle()
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Turtle mode: " + (root.qbt.altSpeed ? "on" : "off")
                color: root.qbt.altSpeed ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Text {
              visible: root.visibleTorrents.length === 0
              width: parent.width
              text: root.emptyListText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.visibleTorrents
              delegate: CursorSurface {
                required property var modelData
                required property int index
                width: column.width
                implicitHeight: rowCol.implicitHeight + Style.spacing.rowPaddingX
                hasCursor: root.cursorActive && root.focusSection === "rows" && root.rowIndex === index
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "rows"
                    root.rowIndex = index
                  }
                  onClicked: root.openDetail(modelData)
                }
                Column {
                  id: rowCol
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(10)
                  rightPadding: Style.space(10)
                  spacing: Style.space(4)
                  Text {
                    width: parent.width - rowCol.leftPadding - rowCol.rightPadding
                    text: modelData.name
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: Model.formatPercent(modelData.progress) + "  ↓ " + Model.formatRate(modelData.dlSpeed) + "  ↑ " + Model.formatRate(modelData.upSpeed) + "  " + Model.formatEta(modelData.eta)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Rectangle {
                    width: parent.width - rowCol.leftPadding - rowCol.rightPadding
                    height: 2
                    color: Qt.darker(root.foreground, 2.2)
                    Rectangle {
                      height: parent.height
                      width: parent.width * Math.max(0, Math.min(1, Number(modelData.progress) || 0))
                      color: root.foreground
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.qbt.ready && root.view === "detail"
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.qbt.filesFor(root.detailHash).length === 0
              width: parent.width
              text: "No files yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.qbt.filesFor(root.detailHash)
              delegate: CursorSurface {
                required property var modelData
                required property int index
                width: column.width
                implicitHeight: Style.space(32)
                hasCursor: root.cursorActive && root.focusSection === "files" && root.fileIndex === index
                foreground: root.foreground
                fill: root.hoverFill
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "files"
                    root.fileIndex = index
                  }
                  onClicked: {
                    root.fileIndex = index
                    root.cycleSelectedFile()
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: prioLabel.left
                  anchors.rightMargin: Style.space(8)
                  text: modelData.name
                  textFormat: Text.PlainText
                  elide: Text.ElideMiddle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  id: prioLabel
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  text: Model.priorityLabel(modelData.priority)
                  color: Number(modelData.priority) === 0 ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Delete this torrent and its files?"
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: {
          root.confirmOpen = false
          root.pendingDeleteHash = ""
          Qt.callLater(root.syncFocus)
        }
        onConfirmed: {
          root.confirmOpen = false
          if (root.pendingDeleteHash !== "") root.qbt.deleteHash(root.pendingDeleteHash, true)
          root.pendingDeleteHash = ""
          root.closeDetail()
          Qt.callLater(root.syncFocus)
        }
      }

      Item {
        id: confirmKeyTrap
        anchors.fill: parent
        visible: root.confirmOpen
        z: 11
        Keys.onPressed: function(event) {
          if (deleteConfirm.handleKey(event)) event.accepted = true
        }
      }
    }
  }

  Shortcut {
    sequences: ["Space"]
    enabled: root.opened && root.qbt.ready && !root.fieldFocused && !root.confirmOpen && !(root.magnetConfirmOpen && root.focusSection === "magnetConfirm")
    onActivated: {
      if (root.view === "detail" && root.detailHash) root.qbt.toggleHash(root.detailHash)
      else if (root.selectedTorrent) root.qbt.toggleHash(root.selectedTorrent.hash)
    }
  }

  Shortcut {
    sequences: ["Backspace"]
    enabled: root.opened && root.view === "detail" && !root.confirmOpen
    onActivated: root.closeDetail()
  }
}
