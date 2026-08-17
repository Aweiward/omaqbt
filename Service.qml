import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  property var settings: ({})

  property bool installed: false
  property bool daemon: false
  property string lockHolder: "none"
  property bool api: false
  property real dlSpeed: 0
  property real upSpeed: 0
  property string vpnIface: ""
  property string bindIface: ""
  property var torrents: []
  property var files: []
  property string lastError: ""
  property string actionStatus: ""
  property string clipboardText: ""

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(settings && settings.refreshIntervalSec != null ? settings.refreshIntervalSec : 5), 10)
    if (!isFinite(n)) n = 5
    if (n < 5) n = 5
    if (n > 3600) n = 3600
    return n
  }
  readonly property string helperPath: {
    var s = Qt.resolvedUrl("qbt").toString()
    if (s.indexOf("file://") === 0) return decodeURIComponent(s.substring(7))
    return s
  }
  readonly property bool busy: statusProcess.running || actionProcess.running || filesProcess.running || installProcess.running || daemonProcess.running || clipProcess.running
  readonly property bool ready: installed && daemon && lockHolder !== "gui" && api
  readonly property bool transferring: Model.anyActive(torrents)
  readonly property bool vpnUnbound: Model.vpnUnbound({ daemon: daemon, api: api, vpnIface: vpnIface, bindIface: bindIface })
  readonly property bool warning: !installed || !daemon || lockHolder === "gui" || !api || vpnUnbound

  function clearError() { lastError = "" }

  function applyStatus(raw) {
    var parsed = Model.parseStatusJson(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Failed to read qBittorrent status"
      return
    }
    var finished = Model.newlyCompleted(torrents, parsed.torrents)
    installed = parsed.installed
    daemon = parsed.daemon
    lockHolder = parsed.lockHolder
    api = parsed.api
    dlSpeed = parsed.dlSpeed
    upSpeed = parsed.upSpeed
    vpnIface = parsed.vpnIface
    bindIface = parsed.bindIface
    torrents = parsed.torrents
    lastError = Model.nextStatusError(parsed, lastError)
    if (finished.length > 0) notify(Model.completionText(finished))
  }

  function notify(text) {
    if (!text || notifyProcess.running) return
    notifyProcess.command = ["notify-send", "-a", "OmaqBT", "OmaqBT", text]
    notifyProcess.running = true
  }

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = [helperPath, "status"]
    statusProcess.running = true
  }

  function readClipboard() {
    clipboardText = ""
    clipProcess.command = ["wl-paste", "--no-newline"]
    clipProcess.running = true
  }

  function addTarget(target, stopped, savePath) {
    var t = String(target || "").trim()
    if (!Model.isAddableTarget(t) || actionProcess.running) {
      if (!Model.isAddableTarget(t)) lastError = "Paste a magnet, a .torrent URL, or a .torrent file path."
      return
    }
    clearError()
    actionStatus = stopped ? "Adding torrent (stopped)…" : "Adding torrent…"
    var cmd = [helperPath, "add"]
    if (stopped) cmd.push("--stopped")
    var dir = String(savePath || "").trim()
    if (dir !== "") { cmd.push("--savepath"); cmd.push(dir) }
    cmd.push(t)
    actionProcess.command = cmd
    actionProcess.running = true
  }

  function addUrl(url) { addTarget(url, false, "") }

  function startHash(hash) {
    if (actionProcess.running) return
    clearError()
    actionProcess.command = [helperPath, "start", hash]
    actionProcess.running = true
  }

  function stopHash(hash) {
    if (actionProcess.running) return
    clearError()
    actionProcess.command = [helperPath, "stop", hash]
    actionProcess.running = true
  }

  function toggleHash(hash) {
    var row = null
    for (var i = 0; i < torrents.length; i++) if (torrents[i].hash === hash) row = torrents[i]
    if (!row) return
    var bucket = Model.classifyState(row.state, row.progress)
    if (bucket === "paused" || bucket === "completed") startHash(hash)
    else stopHash(hash)
  }

  function toggleAll() {
    if (Model.anyActive(torrents)) stopHash("all")
    else startHash("all")
  }

  function deleteHash(hash, withFiles) {
    if (actionProcess.running) return
    clearError()
    actionStatus = withFiles ? "Deleting torrent and files…" : "Removing torrent…"
    if (withFiles) actionProcess.command = [helperPath, "delete", hash, "--files"]
    else actionProcess.command = [helperPath, "delete", hash]
    actionProcess.running = true
  }

  function loadFiles(hash) {
    files = []
    if (filesProcess.running) return
    filesProcess.command = [helperPath, "files", hash]
    filesProcess.running = true
  }

  function setPrio(hash, index, prio) {
    if (actionProcess.running) return
    actionProcess.command = [helperPath, "prio", hash, String(index), String(prio)]
    actionProcess.running = true
  }

  function openPath(path) {
    var p = String(path || "")
    if (p === "" || openProcess.running) return
    openProcess.command = ["xdg-open", p]
    openProcess.running = true
  }

  function installDaemon() {
    clearError()
    actionStatus = "Installing qbittorrent-nox…"
    installProcess.command = [helperPath, "install"]
    installProcess.running = true
  }

  function startDaemon() {
    clearError()
    actionStatus = "Starting qBittorrent daemon…"
    daemonProcess.command = [helperPath, "start-daemon"]
    daemonProcess.running = true
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyStatus(statusOut.text)
      else root.lastError = Model.sanitizeError(statusErr.text || "qBittorrent is not reachable")
    }
  }

  Process {
    id: openProcess
    running: false
    command: []
    // Best effort: the file manager owns any failure UI from here.
    onExited: function() {}
  }

  Process {
    id: notifyProcess
    running: false
    command: []
    // Best effort: a missing notify-send must not surface as a plugin error.
    onExited: function() {}
  }

  Process {
    id: clipProcess
    running: false
    command: []
    stdout: StdioCollector { id: clipOut; waitForEnd: true }
    onExited: function() { root.clipboardText = String(clipOut.text || "") }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(actionErr.text || actionOut.text || "qBittorrent command failed")
        return
      }
      root.refresh()
    }
  }

  Process {
    id: filesProcess
    running: false
    command: []
    stdout: StdioCollector { id: filesOut; waitForEnd: true }
    stderr: StdioCollector { id: filesErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(filesErr.text || "Could not read files")
        root.files = []
        return
      }
      try { root.files = JSON.parse(String(filesOut.text || "[]")) }
      catch (e) { root.files = [] }
    }
  }

  Process {
    id: installProcess
    running: false
    command: []
    stdout: StdioCollector { id: installOut; waitForEnd: true }
    stderr: StdioCollector { id: installErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(installErr.text || "Install failed")
        return
      }
      root.startDaemon()
    }
  }

  Process {
    id: daemonProcess
    running: false
    command: []
    stdout: StdioCollector { id: daemonOut; waitForEnd: true }
    stderr: StdioCollector { id: daemonErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0)
        root.lastError = Model.sanitizeError(daemonErr.text || "Could not start qbittorrent-nox")
      root.refresh()
    }
  }
}
