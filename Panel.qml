import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

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
  property string detailHash: ""
  property string magnetField: ""
  property bool confirmOpen: false
  property string pendingDeleteHash: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color barIconColor: qbt.transferring ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property bool fieldFocused: magnetInput && magnetInput.activeFocus
  readonly property var visibleTorrents: Model.filterTorrents(qbt.torrents, filterMode)
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
    return Model.formatRate(qbt.dlSpeed) + " · " + Model.formatRate(qbt.upSpeed) + " · " + activeCount + " active"
  }
  readonly property string emptyListText: {
    if (filterMode === "paused") return "No paused torrents."
    if (filterMode === "completed") return "No completed torrents."
    if (filterMode === "all") return "No torrents."
    return "Nothing downloading or seeding."
  }
  readonly property string toggleHint: qbt.transferring ? "Stop all torrents" : "Start all torrents"
  readonly property bool showClipboard: qbt.ready && view === "list" && Model.isAddableUrl(qbt.clipboardText)

  function selectedFile() {
    if (!qbt.files || qbt.files.length === 0) return null
    return qbt.files[Math.max(0, Math.min(fileIndex, qbt.files.length - 1))]
  }

  function ensureCursor() {
    if (!qbt.installed) { focusSection = "install"; return }
    if (qbt.lockHolder === "gui") { focusSection = "lock"; return }
    if (!qbt.daemon) { focusSection = "daemon"; return }
    if (view === "detail") {
      if (focusSection !== "remove" && focusSection !== "deleteFiles" && focusSection !== "files")
        focusSection = (qbt.files && qbt.files.length > 0) ? "files" : "remove"
      if (fileIndex >= qbt.files.length) fileIndex = Math.max(0, qbt.files.length - 1)
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
    keyCatcher.forceActiveFocus()
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
      if (focusSection === "remove") {
        if (dy > 0) focusSection = "deleteFiles"
        return
      }
      if (focusSection === "deleteFiles") {
        if (dy < 0) focusSection = "remove"
        else if (dy > 0 && qbt.files.length > 0) {
          focusSection = "files"
          fileIndex = 0
        }
        return
      }
      if (qbt.files.length === 0) return
      if (dy < 0 && fileIndex === 0) {
        focusSection = "deleteFiles"
        return
      }
      fileIndex = Math.max(0, Math.min(qbt.files.length - 1, fileIndex + dy))
      return
    }
    if (focusSection === "header") {
      if (dy > 0 && showClipboard) { focusSection = "clipboard"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "clipboard") {
      if (dy < 0) { focusSection = "header"; return }
      if (dy > 0 && visibleTorrents.length > 0) { focusSection = "rows"; rowIndex = 0 }
      return
    }
    if (focusSection === "rows") {
      if (dy < 0 && rowIndex === 0) {
        focusSection = showClipboard ? "clipboard" : "header"
        return
      }
      rowIndex = Math.max(0, Math.min(visibleTorrents.length - 1, rowIndex + dy))
    }
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "install") qbt.installDaemon()
    else if (focusSection === "daemon") qbt.startDaemon()
    else if (focusSection === "header") qbt.toggleAll()
    else if (focusSection === "clipboard") qbt.addUrl(qbt.clipboardText)
    else if (focusSection === "rows") openDetail(selectedTorrent)
    else if (focusSection === "files") cycleSelectedFile()
    else if (focusSection === "remove") removeKeepFiles(detailHash)
    else if (focusSection === "deleteFiles") askDeleteFiles(detailHash)
  }

  function cycleSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    var next = Model.cyclePriority(file.priority)
    qbt.setPrio(detailHash, file.index, next)
    var copy = []
    for (var i = 0; i < qbt.files.length; i++) {
      var row = qbt.files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: next })
      } else {
        copy.push(row)
      }
    }
    qbt.files = copy
  }

  function skipSelectedFile() {
    var file = selectedFile()
    if (!file || !detailHash) return
    qbt.setPrio(detailHash, file.index, 0)
    var copy = []
    for (var i = 0; i < qbt.files.length; i++) {
      var row = qbt.files[i]
      if (row.index === file.index) {
        copy.push({ index: row.index, name: row.name, progress: row.progress, priority: 0 })
      } else {
        copy.push(row)
      }
    }
    qbt.files = copy
  }

  function handleTextKey(t) {
    if (confirmOpen) return
    if (t === "t" || t === "T") {
      if (qbt.ready) qbt.toggleAll()
    } else if (t === "/") {
      if (qbt.ready && view === "list" && magnetInput) magnetInput.forceActiveFocus()
    } else if (t === "y" || t === "Y") {
      if (showClipboard) qbt.addUrl(qbt.clipboardText)
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
    } else if (t === "x") {
      if (view === "detail") skipSelectedFile()
      else if (selectedTorrent) qbt.deleteHash(selectedTorrent.hash, false)
    } else if (t === "X") {
      var hash = view === "detail" ? detailHash : (selectedTorrent ? selectedTorrent.hash : "")
      if (hash) askDeleteFiles(hash)
    } else if (t === "h" || t === "H") {
      if (view === "detail") closeDetail()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    view = "list"
    filterMode = "active"
    magnetField = ""
    confirmOpen = false
    if (panelFlick) panelFlick.contentY = 0
    qbt.refresh()
    qbt.readClipboard()
    ensureCursor()
    Qt.callLater(syncFocus)
  }

  Service {
    id: qbt
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { qbt.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        QbittorrentIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          warning: qbt.warning
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (qbt.ready) qbt.toggleAll()
        else root.toggle()
      } else if (buttonCode === Qt.MiddleButton) {
        qbt.refresh()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.fieldFocused || root.confirmOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { root.handleTextKey(t) }

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
              iconOpacity: qbt.transferring ? 1.0 : 0.5
              iconComponent: Component {
                QbittorrentIcon {
                  iconSize: Style.font.display
                  color: qbt.transferring ? root.foreground : root.dim
                  badgeColor: root.urgent
                  warning: qbt.warning
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: qbt.ready && root.view === "list"
                  checked: qbt.transferring
                  busy: qbt.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: qbt.toggleAll()
                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Column {
            visible: qbt.ready && root.view === "detail"
            width: parent.width
            spacing: Style.space(6)

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
                cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !qbt.busy && root.detailHash !== ""
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
                cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
                enabled: !qbt.busy && root.detailHash !== ""
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
          }

          Text {
            visible: qbt.actionStatus !== "" || qbt.lastError !== ""
            width: parent.width
            text: qbt.actionStatus !== "" ? qbt.actionStatus : qbt.lastError
            color: qbt.lastError !== "" && qbt.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: !qbt.installed
            width: parent.width
            implicitHeight: installCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "install"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "install" }
              onClicked: qbt.installDaemon()
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
                text: qbt.busy ? "Installing…" : "Install qBittorrent-nox"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          CursorSurface {
            visible: qbt.installed && qbt.lockHolder === "gui"
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
            visible: qbt.installed && !qbt.daemon && qbt.lockHolder !== "gui"
            width: parent.width
            implicitHeight: daemonCol.implicitHeight + Style.spacing.rowPaddingX
            hasCursor: root.cursorActive && root.focusSection === "daemon"
            foreground: root.foreground
            fill: root.hoverFill
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: qbt.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !qbt.busy
              onEntered: { root.cursorActive = true; root.focusSection = "daemon" }
              onClicked: qbt.startDaemon()
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
                text: qbt.busy ? "Starting…" : "Start daemon"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Column {
            visible: qbt.ready && root.view === "list"
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: magnetInput
              width: parent.width
              foreground: root.foreground
              placeholderText: "Paste a magnet or .torrent URL"
              text: root.magnetField
              onTextChanged: root.magnetField = text
              onAccepted: {
                qbt.addUrl(text)
                root.magnetField = ""
                text = ""
              }
              Keys.onEscapePressed: root.close()
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
                onClicked: qbt.addUrl(qbt.clipboardText)
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                text: "Add magnet from clipboard"
                color: root.foreground
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
            visible: qbt.ready && root.view === "detail"
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: !qbt.files || qbt.files.length === 0
              width: parent.width
              text: "No files yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: qbt.files
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
          if (root.pendingDeleteHash !== "") qbt.deleteHash(root.pendingDeleteHash, true)
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
    enabled: root.opened && qbt.ready && !root.fieldFocused && !root.confirmOpen
    onActivated: {
      if (root.view === "detail" && root.detailHash) qbt.toggleHash(root.detailHash)
      else if (root.selectedTorrent) qbt.toggleHash(root.selectedTorrent.hash)
    }
  }

  Shortcut {
    sequences: ["Backspace"]
    enabled: root.opened && root.view === "detail" && !root.confirmOpen
    onActivated: root.closeDetail()
  }
}
