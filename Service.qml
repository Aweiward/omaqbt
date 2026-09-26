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
  // Status's top-level category and tag names (zero-count ones included),
  // for the window's filter pane.
  property var categories: []
  property var tags: []
  property var filesByHash: ({})
  // hash -> {state: "loading"|"ok"|"error", error}: lets a view tell a
  // files load in flight, an empty list and a failed read apart.
  property var filesStatusByHash: ({})
  // hash -> true while that hash's latest files load came from the window
  // (origin "window"): its failure then stays out of the widget's lastError.
  property var filesQuietHashes: ({})
  property string lastError: ""
  property string actionStatus: ""
  property string clipboardText: ""
  property var actionQueue: []
  // Tickets are 1-based so a method can return 0 for "nothing queued".
  property int actionTicketSeq: 0
  property var currentAction: null
  property var notifyQueue: []
  property var magnetInbox: []
  property var magnetPending: []
  property bool magnetHandlerInstalled: false
  property double magnetBackoffUntil: 0
  property bool magnetDrainQueued: false
  property bool magnetNotReadyNotified: false

  // The window's persisted view: {filter:{group,value}, sort, desc,
  // cursorHash, pane} (see Model.parseViewState). Loaded once from
  // view.json on the FileView below; windowOpen is set by the window
  // itself and feeds the sidecar cadence rule below.
  property var viewState: Model.defaultViewState()
  property bool windowOpen: false
  // The state most recently asked to be saved but not yet written, because
  // a write already landed within the last second; null once flushed.
  property var pendingViewState: null
  // The exact text of the most recent write attempt, kept so a failed write
  // (missing directory) can be retried once mkdir -p finishes.
  property string lastViewStateWriteText: ""
  property bool viewStateMkdirRetried: false
  readonly property string viewStateDir: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base || base.length === 0) base = Quickshell.env("HOME") + "/.local/state"
    return base + "/omaqbt"
  }
  readonly property string viewStatePath: viewStateDir + "/view.json"

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
  // While the window is open and the sidecar is up, poll at least once a
  // second so the table doesn't lag the window's own cadence; the bash
  // fallback timer below never reads windowOpen, so it keeps polling at
  // refreshIntervalSec regardless.
  readonly property int sidecarCadenceMs: {
    var base = Model.cadenceMs(magnetWatching, refreshIntervalSec)
    if (windowOpen && sidecarState === "up") return Math.min(1000, base)
    return base
  }
  readonly property bool busy: statusProcess.running || actionProcess.running || filesProcess.running || installProcess.running || daemonProcess.running || clipProcess.running || actionQueue.length > 0
  readonly property bool ready: installed && daemon && lockHolder !== "gui" && api
  readonly property bool transferring: Model.anyActive(torrents, magnetPendingHashes)
  readonly property bool vpnUnbound: Model.vpnUnbound({ daemon: daemon, api: api, vpnIface: vpnIface, bindIface: bindIface })
  readonly property bool warning: !installed || !daemon || lockHolder === "gui" || !api || vpnUnbound

  // Emitted after every queued action ends, once the queue has moved on.
  // error is sanitized and empty on success.
  signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
  // Emitted every time a readClipboard() answer arrives, even when it is
  // empty (an empty answer leaves clipboardText unchanged, so its change
  // signal can't tell a view that the read finished).
  signal clipboardRead(string text)

  function clearError() { lastError = "" }

  // A ticket for a window-origin call that doesn't go through runAction
  // (copy, install, start daemon); its end is reported the same way,
  // through actionFinished.
  function mintTicket() {
    var ticket = actionTicketSeq + 1
    actionTicketSeq = ticket
    return ticket
  }

  function windowDone(opts) {
    return { ticket: mintTicket(), origin: "window", hashes: (opts && opts.hashes) ? opts.hashes : [] }
  }

  // Debounced to at most one write per second: a call while a write from
  // the last second is still cooling down only updates viewState (so
  // readers see it immediately) and queues the write for when the cooldown
  // timer fires; a call once the cooldown has elapsed writes right away and
  // starts a fresh cooldown.
  function saveViewState(state) {
    var normalized = Model.parseViewState(state)
    viewState = normalized
    pendingViewState = normalized
    if (viewStateCooldown.running) return
    flushViewState()
  }

  function flushViewState() {
    var state = pendingViewState
    pendingViewState = null
    viewStateCooldown.restart()
    var text = Model.serializeViewState(state)
    lastViewStateWriteText = text
    viewStateMkdirRetried = false
    viewStateFile.setText(text)
  }

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
    categories = Array.isArray(parsed.categories) ? parsed.categories : []
    tags = Array.isArray(parsed.tags) ? parsed.tags : []
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

  // opts: {origin: "widget"|"window", hashes: [...]}. Returns the ticket.
  // Window actions leave actionStatus and lastError alone; the window builds
  // its own message from actionFinished.
  function runAction(cmd, statusText, opts) {
    var ticket = actionTicketSeq + 1
    actionTicketSeq = ticket
    var item = Model.makeActionItem(ticket, cmd, statusText, opts)
    // currentAction also counts: after a failed start the process is no
    // longer running, but its action stays current until the deferred
    // start check below finishes it, and starting another here would
    // orphan that ticket.
    if (actionProcess.running || currentAction !== null) {
      actionQueue = Model.enqueueAction(actionQueue, item)
      return ticket
    }
    startQueuedAction(item)
    return ticket
  }

  function isWindowOrigin(opts) {
    return !!opts && opts.origin === "window"
  }

  function startQueuedAction(item) {
    if (!item || !item.cmd) return
    currentAction = item
    if (item.origin !== "window") {
      clearError()
      actionStatus = item.status || ""
    }
    actionProcess.command = item.cmd
    actionProcess.running = true
  }

  // Ends the current action: the one path for a command that exited and
  // for one that never started. ok false reports err (already sanitized)
  // to the widget's lastError unless the action came from the window.
  function finishAction(ok, err) {
    var done = currentAction
    currentAction = null
    var fromWindow = !!done && done.origin === "window"
    var cmd = (done && done.cmd) || []
    var kind = cmd.length > 1 ? String(cmd[1]) : ""
    if (kind === "magnet-drain") magnetDrainQueued = false
    if (!fromWindow) actionStatus = ""
    if (!ok) {
      if (!fromWindow) lastError = err
      if (kind === "magnet-drain") magnetBackoffUntil = Date.now() + 2000
      pumpActionQueue()
      // Emitted last so a handler that queues another action sees a
      // consistent actionProcess.
      if (done) actionFinished(done.ticket, false, err, done.origin, done.hashes)
      return
    }
    refresh()
    loadMagnetSnapshot()
    pumpActionQueue()
    if (done) actionFinished(done.ticket, true, "", done.origin, done.hashes)
  }

  // Deferred from actionProcess's running going false: by then a command
  // that ran has had its exited handled (Quickshell emits exited before
  // runningChanged) and moved currentAction on. The same ticket still
  // current with nothing running means the program never started.
  function checkActionStarted(ticket) {
    var cur = currentAction
    if (!cur || cur.ticket !== ticket || actionProcess.running) return
    finishAction(false, Model.sanitizeError("Could not run the qbt helper"))
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

  function addTarget(target, stopped, savePath, opts) {
    var t = String(target || "").trim()
    if (!Model.isAddableTarget(t)) {
      if (!isWindowOrigin(opts)) lastError = "Paste a magnet, a .torrent URL, or a .torrent file path."
      return 0
    }
    var cmd = [helperPath, "add"]
    if (stopped) cmd.push("--stopped")
    var dir = String(savePath || "").trim()
    if (dir !== "") { cmd.push("--savepath"); cmd.push(dir) }
    cmd.push(t)
    return runAction(cmd, stopped ? "Adding torrent (stopped)…" : "Adding torrent…", opts)
  }

  function addUrl(url, opts) { return addTarget(url, false, "", opts) }

  function startHash(hash, opts) {
    return runAction([helperPath, "start", hash], "", opts)
  }

  function stopHash(hash, opts) {
    return runAction([helperPath, "stop", hash], "", opts)
  }

  function toggleHash(hash, opts) {
    var row = null
    for (var i = 0; i < torrents.length; i++) if (torrents[i].hash === hash) row = torrents[i]
    if (!row) return 0
    var bucket = Model.classifyState(row.state, row.progress)
    if (bucket === "paused" || bucket === "completed") return startHash(hash, opts)
    return stopHash(hash, opts)
  }

  // Returns the tickets of the qbt calls it queued ([] when nothing is
  // live). One call with "all" when no pending magnet is in torrents;
  // otherwise the live hashes in chunks of Model.HASH_CHUNK, since one argv
  // string can't hold every hash of a large library.
  function toggleAll(opts) {
    var live = Model.excludePending(torrents, magnetPendingHashes)
    if (live.length === 0) return []
    var verb = Model.anyActive(live) ? "stop" : "start"
    var targets = Model.toggleAllTargets(torrents, magnetPendingHashes)
    var tickets = []
    for (var i = 0; i < targets.length; i++) tickets.push(runAction([helperPath, verb, targets[i]], "", opts))
    return tickets
  }

  function deleteHash(hash, withFiles, opts) {
    var cmd = [helperPath, "delete", hash]
    if (withFiles) cmd.push("--files")
    return runAction(cmd, withFiles ? "Deleting torrent and files…" : "Removing torrent…", opts)
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

  function setFilesStatus(hash, state, error) {
    var key = String(hash || "")
    if (key === "") return
    var next = ({})
    for (var k in filesStatusByHash) next[k] = filesStatusByHash[k]
    next[key] = { state: state, error: String(error || "") }
    filesStatusByHash = next
  }

  // A failed files read: the widget's lastError unless the window asked.
  function filesFailed(hash, error) {
    var key = String(hash || "")
    if (Model.filesFailureWritesLastError(filesQuietHashes, key)) lastError = error
    setFilesFor(key, [])
    setFilesStatus(key, "error", error)
  }

  // opts: {origin: "window"} keeps a failure out of lastError (the window
  // reads filesStatusByHash instead). The widget calls it without opts.
  function loadFiles(hash, opts) {
    if (!started || !hash) return
    filesQuietHashes = Model.filesQuietAfterLoad(filesQuietHashes, hash, isWindowOrigin(opts))
    setFilesFor(hash, [])
    setFilesStatus(hash, "loading", "")
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

  function setPrio(hash, index, prio, opts) {
    return runAction([helperPath, "prio", hash, String(index), String(prio)], "", opts)
  }

  function toggleTurtle(opts) {
    return runAction([helperPath, "turtle"], "", opts)
  }

  function setLimit(hash, kind, bytes, opts) {
    return runAction([helperPath, "limit", hash, kind, String(bytes)], "", opts)
  }

  function toggleSequential(hash, opts) {
    return runAction([helperPath, "sequential", hash], "", opts)
  }

  function setShareRatio(hash, ratio, opts) {
    return runAction([helperPath, "sharelimit", hash, String(ratio)], "", opts)
  }

  // opts: {origin: "window", hashes} returns a ticket and reports the copy
  // through actionFinished, leaving actionStatus and lastError alone. The
  // widget calls it without opts and gets today's behavior (returns 0).
  function copyMagnet(row, opts) {
    var fromWindow = isWindowOrigin(opts)
    var uri = Model.magnetUriFor(row)
    if (!uri) {
      if (!fromWindow) lastError = "No magnet for this torrent."
      return 0
    }
    if (copyProcess.running) return 0
    var done = null
    if (fromWindow) {
      done = windowDone(opts)
    } else {
      clearError()
      actionStatus = "Copied magnet."
    }
    copyProcess.done = done
    copyProcess.command = ["wl-copy", "--", uri]
    copyProcess.running = true
    return done ? done.ticket : 0
  }

  function recheckHash(hash, opts) {
    if (!hash) return 0
    return runAction([helperPath, "recheck", hash], "Rechecking…", opts)
  }

  function setLocation(hash, dir, opts) {
    var path = String(dir || "").trim()
    if (!hash || path === "") {
      if (!isWindowOrigin(opts)) lastError = "Enter an absolute path to move to."
      return 0
    }
    return runAction([helperPath, "set-location", hash, path], "Moving…", opts)
  }

  function installMagnetHandler(opts) {
    if (!started || magnetHandlerInstalled) return 0
    magnetHandlerInstalled = true
    return runAction([helperPath, "magnet-install-handler"], "", opts)
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

  function dropPending(hash, opts) {
    return runAction([helperPath, "magnet-pending-drop", hash], "", opts)
  }

  function dropInboxCurrent(opts) {
    return runAction([helperPath, "magnet-inbox-drop"], "", opts)
  }

  // Two actions each; both carry opts and the primary action's ticket is
  // returned (start / delete), not the pending-drop bookkeeping.
  function startPending(hash, opts) {
    var ticket = startHash(hash, opts)
    dropPending(hash, opts)
    return ticket
  }

  function cancelPending(hash, opts) {
    var ticket = deleteHash(hash, true, opts)
    dropPending(hash, opts)
    return ticket
  }

  // opts is accepted for the same call shape as the other actions; opening
  // a folder writes no shared state for any origin (the file manager owns
  // its own failure UI).
  function openPath(path, opts) {
    var p = String(path || "")
    if (p === "" || openProcess.running) return
    openProcess.command = ["xdg-open", p]
    openProcess.running = true
  }

  // opts: {origin: "window"} returns a ticket that covers the install and
  // the daemon start that follows it, reported through actionFinished; the
  // widget's actionStatus and lastError are left alone. Without opts (the
  // widget) the behavior is unchanged and 0 is returned.
  function installDaemon(opts) {
    var fromWindow = isWindowOrigin(opts)
    if (fromWindow && installProcess.running) return 0
    var done = null
    if (fromWindow) {
      done = windowDone(opts)
    } else {
      clearError()
      actionStatus = "Installing qbittorrent-nox…"
    }
    if (!installProcess.running) installProcess.done = done
    installProcess.command = [helperPath, "install"]
    installProcess.running = true
    return done ? done.ticket : 0
  }

  function startDaemon(opts) {
    var fromWindow = isWindowOrigin(opts)
    if (fromWindow && daemonProcess.running) return 0
    var done = fromWindow ? windowDone(opts) : null
    runDaemonStart(done)
    return done ? done.ticket : 0
  }

  // done: the window's ticket record, or null for the widget.
  function runDaemonStart(done) {
    if (!done) {
      clearError()
      actionStatus = "Starting qBittorrent daemon…"
    }
    // A start already in flight keeps its window ticket record: a widget
    // call meanwhile must not orphan it.
    if (!daemonProcess.running) daemonProcess.done = done
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
        filesFailed(hash, Model.sanitizeError(msg.data.error || "Could not read files"))
        return
      }
      setFilesFor(hash, Array.isArray(msg.data.files) ? msg.data.files : [])
      setFilesStatus(hash, "ok", "")
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
    // A files request the sidecar never answered retries through bash,
    // keeping the origin of the load it replaces.
    var lastHash = ""
    for (var k in orphans) lastHash = orphans[k]
    if (lastHash !== "") loadFiles(lastHash, Model.filesReplayOpts(filesQuietHashes, lastHash))
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

  // Read once at start, asynchronously (no blockLoading) so the plugin's
  // first frame never waits on disk. A missing file is a first run and says
  // nothing, so printErrors stays off and viewState just keeps its default.
  FileView {
    id: viewStateFile
    path: root.viewStatePath
    printErrors: false
    atomicWrites: true
    onLoaded: root.viewState = Model.parseViewState(text())
    onLoadFailed: function(error) {
      // FileNotFound is a first run and leaves viewState at its default;
      // anything else (e.g. permission denied) is worth a log line, since
      // it silently keeps the window on defaults too.
      if (error === FileViewError.FileNotFound) return
      console.warn("OmaqBT view.json load failed: " + FileViewError.toString(error))
    }
    onSaveFailed: function(error) {
      if (root.viewStateMkdirRetried) return
      root.viewStateMkdirRetried = true
      viewStateMkdirProcess.command = ["mkdir", "-p", "-m", "700", root.viewStateDir]
      viewStateMkdirProcess.running = true
    }
  }

  Timer {
    id: viewStateCooldown
    interval: 1000
    repeat: false
    onTriggered: if (root.pendingViewState !== null) root.flushViewState()
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

  // One-shot: view.json's directory doesn't exist yet (first run). Retried
  // exactly once per write attempt -- viewStateMkdirRetried guards against a
  // loop if the directory still can't be created (e.g. permission denied).
  // onRunningChanged rather than onExited: a Process whose program can't
  // even start (e.g. "mkdir" missing from PATH) emits no exited at all,
  // only running going false, and this must still retry the write once to
  // find that out. It also sidesteps this file's one qmllint warning (the
  // QProcess::ExitStatus parameter type on onExited isn't resolvable here)
  // without adding another instance of it.
  Process {
    id: viewStateMkdirProcess
    running: false
    command: []
    onRunningChanged: if (!running) viewStateFile.setText(root.lastViewStateWriteText)
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
    onExited: function() {
      root.clipboardText = String(clipOut.text || "")
      root.clipboardRead(root.clipboardText)
    }
  }

  Process {
    id: copyProcess
    // The window's ticket record for this copy, or null (the widget).
    property var done: null
    running: false
    command: []
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onExited: function(exitCode) {
      var done = copyProcess.done
      copyProcess.done = null
      if (done) {
        var err = exitCode !== 0 ? Model.sanitizeError(copyErr.text || "Could not copy magnet") : ""
        root.actionFinished(done.ticket, exitCode === 0, err, done.origin, done.hashes)
        return
      }
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
    // A program that can't start (qbt missing, not executable) emits no
    // exited, only running going false -- the viewStateMkdirProcess case.
    // The check is deferred because a harness (or any emitter) may flip
    // running before exited; checkActionStarted only fails a ticket that is
    // still current once the event loop has run.
    onRunningChanged: {
      if (running || root.currentAction === null) return
      var ticket = root.currentAction.ticket
      Qt.callLater(function() { root.checkActionStarted(ticket) })
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.finishAction(false, Model.sanitizeError(actionErr.text || actionOut.text || "qBittorrent command failed"))
      else root.finishAction(true, "")
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
        root.filesFailed(done, Model.sanitizeError(filesErr.text || "Could not read files"))
      } else {
        var rows = []
        try { rows = JSON.parse(String(filesOut.text || "[]")) }
        catch (e) { rows = [] }
        root.setFilesFor(done, rows)
        root.setFilesStatus(done, "ok", "")
      }
      // A queued load keeps its origin: replaying it bare would make a
      // window load's failure land in the widget's lastError.
      if (next !== "" && next !== done) root.loadFiles(next, Model.filesReplayOpts(root.filesQuietHashes, next))
    }
  }

  Process {
    id: installProcess
    // The window's ticket record for this install, or null (the widget).
    property var done: null
    running: false
    command: []
    stdout: StdioCollector { id: installOut; waitForEnd: true }
    stderr: StdioCollector { id: installErr; waitForEnd: true }
    onExited: function(exitCode) {
      var done = installProcess.done
      installProcess.done = null
      if (done) {
        // The window's ticket covers the daemon start that follows, so a
        // success hands it on instead of reporting it here.
        if (exitCode !== 0) root.actionFinished(done.ticket, false, Model.sanitizeError(installErr.text || "Install failed"), done.origin, done.hashes)
        else if (daemonProcess.running) root.actionFinished(done.ticket, true, "", done.origin, done.hashes)
        else root.runDaemonStart(done)
        return
      }
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
    // The window's ticket record for this start, or null (the widget).
    property var done: null
    running: false
    command: []
    stdout: StdioCollector { id: daemonOut; waitForEnd: true }
    stderr: StdioCollector { id: daemonErr; waitForEnd: true }
    onExited: function(exitCode) {
      var done = daemonProcess.done
      daemonProcess.done = null
      if (done) {
        var err = exitCode !== 0 ? Model.sanitizeError(daemonErr.text || "Could not start qbittorrent-nox") : ""
        root.refresh()
        root.actionFinished(done.ticket, exitCode === 0, err, done.origin, done.hashes)
        return
      }
      root.actionStatus = ""
      if (exitCode !== 0)
        root.lastError = Model.sanitizeError(daemonErr.text || "Could not start qbittorrent-nox")
      root.refresh()
    }
  }
}
