import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Created once by the shell as the plugin's shared service (null parent), and
// once per bar widget as a local fallback that stays inactive while the shared
// one exists. An inactive Service starts no Process at all.
Scope {
  id: root
  property var settings: ({})
  property bool active: true
  // A local fallback waits this long after becoming active before it starts,
  // so a hot reload (service torn down before its widgets) never overlaps.
  property int startDelayMs: 0
  property bool started: false

  property bool installed: false
  property bool daemon: false
  property string lockHolder: "none"
  property bool api: false
  property bool altSpeed: false
  property real dlSpeed: 0
  property real upSpeed: 0
  property string vpnIface: ""
  property string bindIface: ""
  property var torrents: []
  property var filesByHash: ({})
  property string lastError: ""
  property string actionStatus: ""
  property string clipboardText: ""
  property var actionQueue: []
  property var notifyQueue: []
  property var magnetInbox: []
  property var magnetPending: []
  property bool magnetHandlerInstalled: false
  property double magnetBackoffUntil: 0
  property bool magnetDrainQueued: false
  property bool magnetNotReadyNotified: false

  // One of starting|up|down. "down" means the sidecar gave up and this
  // Service stays on bash polling for the rest of its lifetime.
  property string sidecarState: "starting"
  property int sidecarFailures: 0
  property double sidecarLastBeat: 0
  property double sidecarUpSince: 0
  property int filesRequestSeq: 0
  property var filesRequests: ({})

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
  readonly property string sidecarPath: {
    var s = Qt.resolvedUrl("qbt-serve").toString()
    if (s.indexOf("file://") === 0) return decodeURIComponent(s.substring(7))
    return s
  }
  readonly property var magnetPendingHashes: {
    var out = []
    var p = magnetPending || []
    for (var i = 0; i < p.length; i++) {
      if (p[i] && p[i].hash) out.push(p[i].hash)
      var hs = (p[i] && p[i].hashes) || []
      for (var j = 0; j < hs.length; j++) if (hs[j]) out.push(hs[j])
    }
    return out
  }
  readonly property bool magnetWatching: (magnetInbox && magnetInbox.length > 0) || (magnetPending && magnetPending.length > 0)
  readonly property int sidecarCadenceMs: Model.cadenceMs(magnetWatching, refreshIntervalSec)
  readonly property bool busy: statusProcess.running || actionProcess.running || filesProcess.running || installProcess.running || daemonProcess.running || clipProcess.running || actionQueue.length > 0
  readonly property bool ready: installed && daemon && lockHolder !== "gui" && api
  readonly property bool transferring: Model.anyActive(torrents, magnetPendingHashes)
  readonly property bool vpnUnbound: Model.vpnUnbound({ daemon: daemon, api: api, vpnIface: vpnIface, bindIface: bindIface })
  readonly property bool warning: !installed || !daemon || lockHolder === "gui" || !api || vpnUnbound

  function clearError() { lastError = "" }

  function applyStatus(raw) {
    var parsed = Model.parseStatusJson(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Failed to read qBittorrent status"
      return
    }
    var finished = Model.newlyCompleted(
      Model.excludePending(torrents, magnetPendingHashes),
      Model.excludePending(parsed.torrents, magnetPendingHashes)
    )
    installed = parsed.installed
    daemon = parsed.daemon
    lockHolder = parsed.lockHolder
    api = parsed.api
    altSpeed = parsed.altSpeed
    dlSpeed = parsed.dlSpeed
    upSpeed = parsed.upSpeed
    vpnIface = parsed.vpnIface
    bindIface = parsed.bindIface
    torrents = parsed.torrents
    lastError = Model.nextStatusError(parsed, lastError)
    if (finished.length > 0) notify(Model.completionText(finished))
  }

  function notify(text) {
    if (!text) return
    if (notifyProcess.running) {
      notifyQueue = Model.enqueueAction(notifyQueue, { text: String(text) })
      return
    }
    notifyProcess.command = ["notify-send", "-a", "OmaqBT", "OmaqBT", String(text)]
    notifyProcess.running = true
  }

  function pumpNotifyQueue() {
    var next = Model.shiftAction(notifyQueue)
    notifyQueue = next.rest
    if (next.item && next.item.text) notify(next.item.text)
  }

  function runAction(cmd, statusText) {
    var item = { cmd: cmd, status: statusText || "" }
    if (actionProcess.running) {
      actionQueue = Model.enqueueAction(actionQueue, item)
      return
    }
    startQueuedAction(item)
  }

  function startQueuedAction(item) {
    if (!item || !item.cmd) return
    clearError()
    actionStatus = item.status || ""
    actionProcess.command = item.cmd
    actionProcess.running = true
  }

  function pumpActionQueue() {
    var next = Model.shiftAction(actionQueue)
    actionQueue = next.rest
    if (next.item) startQueuedAction(next.item)
  }

  function refresh() {
    if (!started) return
    if (sidecarState === "up") {
      sidecar.send({ cmd: "refresh" })
      return
    }
    // Bash polls status only after the sidecar gave up; while it starts or
    // backs off, status stays stale so two pollers never overlap.
    if (sidecarState !== "down") return
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
    if (!Model.isAddableTarget(t)) {
      lastError = "Paste a magnet, a .torrent URL, or a .torrent file path."
      return
    }
    var cmd = [helperPath, "add"]
    if (stopped) cmd.push("--stopped")
    var dir = String(savePath || "").trim()
    if (dir !== "") { cmd.push("--savepath"); cmd.push(dir) }
    cmd.push(t)
    runAction(cmd, stopped ? "Adding torrent (stopped)…" : "Adding torrent…")
  }

  function addUrl(url) { addTarget(url, false, "") }

  function startHash(hash) {
    runAction([helperPath, "start", hash], "")
  }

  function stopHash(hash) {
    runAction([helperPath, "stop", hash], "")
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
    var live = Model.excludePending(torrents, magnetPendingHashes)
    if (live.length === 0) return
    var start = !Model.anyActive(live)
    for (var i = 0; i < live.length; i++) {
      var h = Model.torrentId(live[i])
      if (!h) continue
      if (start) startHash(h)
      else stopHash(h)
    }
  }

  function deleteHash(hash, withFiles) {
    var cmd = [helperPath, "delete", hash]
    if (withFiles) cmd.push("--files")
    runAction(cmd, withFiles ? "Deleting torrent and files…" : "Removing torrent…")
  }

  function filesFor(hash) {
    var rows = (filesByHash || {})[String(hash || "")]
    return rows || []
  }

  function setFilesFor(hash, rows) {
    var key = String(hash || "")
    if (key === "") return
    var next = ({})
    for (var k in filesByHash) next[k] = filesByHash[k]
    next[key] = Array.isArray(rows) ? rows : []
    filesByHash = next
  }

  function loadFiles(hash) {
    if (!started || !hash) return
    setFilesFor(hash, [])
    if (sidecarState === "up") {
      var id = filesRequestSeq + 1
      filesRequestSeq = id
      var pending = ({})
      for (var k in filesRequests) pending[k] = filesRequests[k]
      pending[id] = String(hash)
      filesRequests = pending
      sidecar.send({ id: id, cmd: "files", hash: String(hash) })
      return
    }
    if (filesProcess.running) {
      filesProcess.nextHash = String(hash)
      return
    }
    filesProcess.hash = String(hash)
    filesProcess.command = [helperPath, "files", hash]
    filesProcess.running = true
  }

  function takeFilesRequest(id) {
    var hash = filesRequests[id]
    if (hash === undefined) return ""
    var rest = ({})
    for (var k in filesRequests) if (String(k) !== String(id)) rest[k] = filesRequests[k]
    filesRequests = rest
    return String(hash)
  }

  function setPrio(hash, index, prio) {
    runAction([helperPath, "prio", hash, String(index), String(prio)], "")
  }

  function toggleTurtle() {
    runAction([helperPath, "turtle"], "")
  }

  function setLimit(hash, kind, bytes) {
    runAction([helperPath, "limit", hash, kind, String(bytes)], "")
  }

  function toggleSequential(hash) {
    runAction([helperPath, "sequential", hash], "")
  }

  function setShareRatio(hash, ratio) {
    runAction([helperPath, "sharelimit", hash, String(ratio)], "")
  }

  function copyMagnet(row) {
    var uri = Model.magnetUriFor(row)
    if (!uri) {
      lastError = "No magnet for this torrent."
      return
    }
    if (copyProcess.running) return
    clearError()
    actionStatus = "Copied magnet."
    copyProcess.command = ["wl-copy", "--", uri]
    copyProcess.running = true
  }

  function recheckHash(hash) {
    if (!hash) return
    runAction([helperPath, "recheck", hash], "Rechecking…")
  }

  function setLocation(hash, dir) {
    var path = String(dir || "").trim()
    if (!hash || path === "") {
      lastError = "Enter an absolute path to move to."
      return
    }
    runAction([helperPath, "set-location", hash, path], "Moving…")
  }

  function installMagnetHandler() {
    if (!started || magnetHandlerInstalled) return
    magnetHandlerInstalled = true
    runAction([helperPath, "magnet-install-handler"], "")
  }

  function loadMagnetSnapshot() {
    if (!started || magnetSnapProcess.running) return
    magnetSnapProcess.command = [helperPath, "magnet-snapshot"]
    magnetSnapProcess.running = true
  }

  function tickMagnet() {
    loadMagnetSnapshot()
    if (!ready) {
      var inbox = magnetInbox || []
      if (inbox.length > 0 && !inbox[0].notified && !magnetNotReadyNotified) {
        magnetNotReadyNotified = true
        notify("OmaqBT is not ready — click the mark when the daemon is up")
      }
      return
    }
    magnetNotReadyNotified = false
    var now = Date.now()
    if ((magnetInbox || []).length > 0 && now >= magnetBackoffUntil && !magnetDrainQueued) {
      magnetDrainQueued = true
      runAction([helperPath, "magnet-drain"], "Adding torrent from browser…")
    }
    stopPendingIfNeeded()
  }

  function stopPendingIfNeeded() {
    var p = magnetPending || []
    for (var i = 0; i < p.length; i++) {
      var hash = p[i] && p[i].hash
      if (!hash) continue
      var row = null
      for (var j = 0; j < torrents.length; j++) {
        if (Model.torrentId(torrents[j]) === hash || torrents[j].hash === hash) {
          row = torrents[j]
          break
        }
      }
      if (row && Model.pendingNeedsStop(row.state)) stopHash(hash)
    }
  }

  function dropPending(hash) {
    runAction([helperPath, "magnet-pending-drop", hash], "")
  }

  function dropInboxCurrent() {
    runAction([helperPath, "magnet-inbox-drop"], "")
  }

  function startPending(hash) {
    startHash(hash)
    dropPending(hash)
  }

  function cancelPending(hash) {
    deleteHash(hash, true)
    dropPending(hash)
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

  function start() {
    if (!active || started) return
    started = true
    installMagnetHandler()
    refresh()
    loadMagnetSnapshot()
    startSidecar()
  }

  function stop() {
    startDelayTimer.stop()
    sidecarRestartTimer.stop()
    started = false
    sidecarUpSince = 0
    if (sidecarState !== "down") {
      sidecarState = "starting"
      sidecarFailures = 0
    }
    filesRequests = ({})
    sidecar.stop()
  }

  function activate() {
    if (startDelayMs > 0) startDelayTimer.restart()
    else start()
  }

  function startSidecar() {
    if (!started || sidecarState === "down") return
    sidecar.start()
  }

  function sendCadence() {
    sidecar.send({ cmd: "cadence", ms: sidecarCadenceMs })
  }

  function handleSidecarLine(text) {
    var msg = Model.parseServeLine(text)
    if (msg.type === "status") {
      var wasUp = sidecarState === "up"
      applyStatus(msg.raw)
      sidecarState = "up"
      sidecarLastBeat = Date.now()
      if (!wasUp) {
        sidecarUpSince = Date.now()
        sendCadence()
      }
    } else if (msg.type === "heartbeat") {
      sidecarLastBeat = Date.now()
    } else if (msg.type === "files") {
      var hash = takeFilesRequest(msg.data.id)
      if (hash === "") return
      if (msg.data.error !== undefined && msg.data.error !== null) {
        lastError = Model.sanitizeError(msg.data.error || "Could not read files")
        setFilesFor(hash, [])
        return
      }
      setFilesFor(hash, Array.isArray(msg.data.files) ? msg.data.files : [])
    } else if (msg.type === "error") {
      console.warn("OmaqBT qbt-serve: " + Model.sanitizeError(msg.data.error || "error"))
    } else if (msg.type === "fatal") {
      // The exit that follows counts the failure; this only records why.
      console.warn("OmaqBT qbt-serve fatal: " + Model.sanitizeError(msg.data.error || "fatal"))
    }
  }

  function handleSidecarExit(code) {
    // A deliberate stop (active went false) is not a failure.
    if (!active || !started) return
    sidecarState = "starting"
    var orphans = filesRequests
    filesRequests = ({})
    // Only a sidecar that stayed up for a minute earns a clean slate, so one
    // that dies right after its first tick still reaches sidecarGaveUp.
    if (sidecarUpSince > 0 && Date.now() - sidecarUpSince >= 60000) sidecarFailures = 0
    sidecarUpSince = 0
    sidecarFailures = sidecarFailures + 1
    if (Model.sidecarGaveUp(sidecarFailures)) {
      sidecarState = "down"
      console.warn("OmaqBT qbt-serve gave up after " + sidecarFailures + " failures; using bash polling")
    } else {
      sidecarRestartTimer.interval = Math.max(1, Model.nextBackoffMs(sidecarFailures))
      sidecarRestartTimer.restart()
    }
    // A files request the sidecar never answered retries through bash.
    var lastHash = ""
    for (var k in orphans) lastHash = orphans[k]
    if (lastHash !== "") loadFiles(lastHash)
  }

  onActiveChanged: {
    if (active) activate()
    else stop()
  }

  onSidecarCadenceMsChanged: if (sidecarState === "up") sendCadence()

  Component.onCompleted: if (active) activate()

  Sidecar {
    id: sidecar
    path: root.sidecarPath
    onLine: function(text) { root.handleSidecarLine(text) }
    onExited: function(code) { root.handleSidecarExit(code) }
  }

  Timer {
    id: startDelayTimer
    interval: Math.max(1, root.startDelayMs)
    repeat: false
    onTriggered: root.start()
  }

  Timer {
    id: sidecarRestartTimer
    repeat: false
    onTriggered: root.startSidecar()
  }

  // The sidecar heartbeats every 5 s from its own thread; a silent child is
  // hung, so kill it and let its exit take the failure path.
  Timer {
    interval: 1000
    repeat: true
    running: root.active && root.sidecarState === "up"
    onTriggered: {
      if (!Model.heartbeatExpired(root.sidecarLastBeat, Date.now(), 5000)) return
      console.warn("OmaqBT qbt-serve missed its heartbeat; restarting")
      root.sidecarState = "starting"
      sidecar.stop()
    }
  }

  // While the sidecar is up it ticks on its own cadence, so these timers only
  // poll through bash once it has given up.
  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: !root.magnetWatching && root.active && root.started
    onTriggered: {
      if (root.sidecarState === "down") root.refresh()
      root.loadMagnetSnapshot()
    }
  }

  Timer {
    interval: 250
    repeat: true
    running: root.magnetWatching && root.active && root.started
    onTriggered: {
      if (root.sidecarState === "down") root.refresh()
      root.tickMagnet()
    }
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
    onExited: function() { root.pumpNotifyQueue() }
  }

  Process {
    id: magnetSnapProcess
    running: false
    command: []
    stdout: StdioCollector { id: magnetSnapOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      try {
        var snap = JSON.parse(String(magnetSnapOut.text || "{}"))
        root.magnetInbox = snap.inbox || []
        root.magnetPending = snap.pending || []
      } catch (e) {
        root.magnetInbox = []
        root.magnetPending = []
      }
    }
  }

  Process {
    id: clipProcess
    running: false
    command: []
    stdout: StdioCollector { id: clipOut; waitForEnd: true }
    onExited: function() { root.clipboardText = String(clipOut.text || "") }
  }

  Process {
    id: copyProcess
    running: false
    command: []
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.actionStatus = ""
        root.lastError = Model.sanitizeError(copyErr.text || "Could not copy magnet")
        return
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var kind = ""
      try { kind = String((command && command.length > 1) ? command[1] : "") } catch (e) { kind = "" }
      if (kind === "magnet-drain") root.magnetDrainQueued = false
      root.actionStatus = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(actionErr.text || actionOut.text || "qBittorrent command failed")
        if (kind === "magnet-drain") root.magnetBackoffUntil = Date.now() + 2000
        root.pumpActionQueue()
        return
      }
      root.refresh()
      root.loadMagnetSnapshot()
      root.pumpActionQueue()
    }
  }

  Process {
    id: filesProcess
    property string hash: ""
    property string nextHash: ""
    running: false
    command: []
    stdout: StdioCollector { id: filesOut; waitForEnd: true }
    stderr: StdioCollector { id: filesErr; waitForEnd: true }
    onExited: function(exitCode) {
      var done = filesProcess.hash
      var next = filesProcess.nextHash
      filesProcess.nextHash = ""
      if (exitCode !== 0) {
        root.lastError = Model.sanitizeError(filesErr.text || "Could not read files")
        root.setFilesFor(done, [])
      } else {
        var rows = []
        try { rows = JSON.parse(String(filesOut.text || "[]")) }
        catch (e) { rows = [] }
        root.setFilesFor(done, rows)
      }
      if (next !== "" && next !== done) root.loadFiles(next)
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
