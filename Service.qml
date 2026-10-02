import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "LibraryView.js" as Library

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
  // Off for the bar widget's fallback: under a replacement bar the
  // service-kind instance still runs and sends every desktop notification.
  property bool notifications: true
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
  // The probe's view of qBittorrent.conf: "ok" once the localhost bypass is
  // off and an API key is set, else "bypass" or "nokey" (secure-daemon fixes
  // both). authRefused: qBittorrent answered an API call with 403.
  property string auth: "ok"
  property bool authRefused: false
  // Date.now() of the last automatic secure-daemon run (0: none yet).
  property real secureDaemonAt: 0
  property var torrents: []
  // Status's top-level category and tag names (zero-count ones included),
  // for the window's filter pane.
  property var categories: []
  // Per-category {savePath, downloadPath}, keyed by name, for predicting
  // whether a category/save-path change would move a torrent's files.
  property var categoryPaths: ({})
  property var tags: []
  // qBittorrent's default save path, and whether it relocates files on a
  // torrent's category change / a category's save-path change -- both from
  // /app/preferences, read on the slow timer.
  property string defaultSavePath: ""
  property var relocation: ({ torrentChanged: false, categoryPathChanged: false })
  // The share-limit chain behind a torrent's -2 values (slice 3b): each
  // category's {ratioLimit, seedingTimeLimit, shareLimitAction}, and the
  // global {ratio, seedingTime, action} (Model.parseStatusJson's shapes).
  // LimitsView.shareConfirm reads them off this object as its `status`.
  property var categoryLimits: ({})
  property var shareDefaults: ({ ratio: -1, seedingTime: -1, action: "Stop" })
  // The home directory, so the window predicts where `p ~/x` puts files
  // (qbt expands ~/ with the same $HOME; LibraryView.movePlan's home).
  readonly property string homeDir: Quickshell.env("HOME") || ""
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
  // Callbacks waiting for their own readPrefs run: overlapping calls are
  // queued (never coalesced), so a caller mid-flight when another call
  // comes in still gets its own answer -- see readPrefs.
  property var prefsQueue: []
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
  // sidecarDown is the one the inspector tabs read: they show "Needs
  // qbt-serve" only once the sidecar has actually given up, not while it
  // is still starting or backing off.
  readonly property bool sidecarUp: sidecarState === "up"
  readonly property bool sidecarDown: sidecarState === "down"
  property int sidecarFailures: 0
  property double sidecarLastBeat: 0
  property double sidecarUpSince: 0
  property int filesRequestSeq: 0
  property var filesRequests: ({})

  // hash+"|"+tab -> {props, pieces, trackers, peers, points, error, at}
  // (only the fields that tab uses; at is Date.now() at the last update of
  // any kind, success or error). Ruling G: an error entry keeps whatever
  // data fields it already had rather than wiping them, so a transient
  // sidecar failure never blanks a tab that already had something to
  // show; a consumer decides purely from `.error` (truthy means show the
  // error state, regardless of what data is still sitting alongside it) --
  // InspectorView.tabState returns "error" whenever entry.error is set,
  // never by inspecting the data fields themselves. Pruned of any hash
  // that has left torrents on every applyStatus, so a cursor that visited
  // a torrent that later disappeared doesn't leak forever.
  property var inspectByKey: ({})
  // The inspector's current cursor: the hash and tab the sidecar should be
  // reading. "files" is not a sidecar tab -- watch(hash, "files") is a
  // clearing watch. Resent on every sidecar-up (F11); Service clears it
  // itself when windowOpen goes false, since the window (and its Client)
  // may already be destroyed by then.
  property string watchedHash: ""
  property string watchedTab: "info"
  // The {hash, tab} last actually written to the wire, so an unchanged
  // watch is never re-sent; null once the running sidecar has forgotten
  // it (a fresh process, or none running at all).
  property var lastSentWatch: null
  // Slice 5a (Search): the two qbt search lanes' waiting runs, the job the
  // sidecar watches for the window (0: none), and Recent (the last 8
  // queries, newest first; kept here so it outlives a rebuilt window, and
  // never written to disk).
  property var searchJobQueue: []
  property var searchPluginQueue: []
  property var searchJobItem: null
  property var searchPluginItem: null
  property int searchWatchId: 0
  property var searchRecent: []
  // The plugin change running or waiting on the plugins lane: "install",
  // "uninstall", "toggle" (on/off), "update" or "". Kept here, not in the
  // window, so a reopened window still shows it and waits for it (Space,
  // x, i and U; OV4's hold during an update). Set by syncPluginChange once
  // the lane has settled (not a binding: a handler that asks for another
  // run would re-enter it).
  property string searchPluginChange: ""
  // Slice 5b1 (RSS): the one `qbt rss` lane's running item and queue
  // (rssRun), and the last `qbt rss items` answer (its raw stdout and what
  // it parsed to), so a read that didn't change is flagged `same`.
  property var rssQueue: []
  property var rssItem: null
  property string rssLastItemsText: ""
  property var rssLastItems: null

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
  readonly property bool warning: !installed || !daemon || lockHolder === "gui" || !api || vpnUnbound || authRefused

  // Emitted after every queued action ends, once the queue has moved on.
  // error is sanitized and empty on success.
  signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
  // Emitted every time a readClipboard() answer arrives, even when it is
  // empty (an empty answer leaves clipboardText unchanged, so its change
  // signal can't tell a view that the read finished).
  signal clipboardRead(string text)
  // Slice 4b: the end of a setSecret run (its own Process, not the action
  // queue): the ticket setSecret returned, and qbt's one-line reason on a
  // failure. Never the value.
  signal secretFinished(int ticket, bool ok, string error)
  // Slice 5a (Search): the end of a `qbt search …` / `qbt search-plugin …`
  // run (searchRun's ticket): ok, qbt's one-line reason on a failure, and
  // its stdout JSON on success (null when there was none or it didn't
  // parse). Never actionFinished: these don't go through actionQueue.
  signal searchFinished(int ticket, bool ok, string error, var data)
  // A sidecar search reply ({"type":"search", ...}), as the sidecar sent it.
  signal searchReply(var reply)
  // A (re)started sidecar came up with no search watch while the window
  // still watches a job: the window re-sends it at the rows it holds (OV7).
  signal searchWatchLost()
  // Slice 5b1 (RSS): the end of a `qbt rss` write (rssRun's ticket): ok,
  // qbt's one-line sentence on a failure, and its stdout JSON on success
  // (null when there was none or it didn't parse). The reads (items,
  // article, error) answer their callback instead.
  signal rssFinished(int ticket, bool ok, string error, var data)

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
    auth = parsed.auth
    authRefused = parsed.authRefused
    torrents = parsed.torrents
    categories = Array.isArray(parsed.categories) ? parsed.categories : []
    categoryPaths = (parsed.categoryPaths && typeof parsed.categoryPaths === "object") ? parsed.categoryPaths : ({})
    tags = Array.isArray(parsed.tags) ? parsed.tags : []
    defaultSavePath = parsed.defaultSavePath || ""
    relocation = parsed.relocation || { torrentChanged: false, categoryPathChanged: false }
    categoryLimits = parsed.categoryLimits || ({})
    shareDefaults = parsed.shareDefaults || { ratio: -1, seedingTime: -1, action: "Stop" }
    lastError = Model.nextStatusError(parsed, lastError)
    if (finished.length > 0) notify(Model.completionText(finished))
    pruneInspectByKey(torrents)
    maybeSecureDaemon()
  }

  // A daemon set up before the API-key fix still lets every local account
  // in. secure-daemon turns the bypass off and sets a key (one restart), at
  // most once a minute. The bar widget's fallback Service may try too; qbt's
  // lock makes the second run a no-op.
  function maybeSecureDaemon() {
    if (!installed || !daemon || lockHolder === "gui" || auth === "ok") return
    if (secureDaemonAt > 0 && Date.now() - secureDaemonAt < 60000) return
    secureDaemonAt = Date.now()
    runAction([helperPath, "secure-daemon"], "Securing qBittorrent…")
  }

  // Drops any inspectByKey entry whose hash has left torrents (bounded
  // memory for a library the cursor has wandered through). Only assigns a
  // new object when something actually dropped, so the common case (the
  // window closed, nothing watched) never fires inspectByKeyChanged on
  // every tick.
  function pruneInspectByKey(liveTorrents) {
    var live = ({})
    var rows = liveTorrents || []
    for (var i = 0; i < rows.length; i++) {
      var h = rows[i] && rows[i].hash
      if (h) live[h] = true
    }
    var next = null
    for (var k in inspectByKey) {
      var idx = k.indexOf("|")
      var hash = idx >= 0 ? k.substring(0, idx) : k
      if (live[hash]) continue
      if (next === null) {
        next = ({})
        for (var kk in inspectByKey) next[kk] = inspectByKey[kk]
      }
      delete next[k]
    }
    if (next !== null) inspectByKey = next
  }

  // Stores one inspect line under hash+"|"+tab. An info reply with
  // pieces:null keeps the previous pieces (the sidecar's own throttling,
  // F9); an error line keeps whatever data the tab already had, so a
  // transient failure (one bad read, still within back-off) doesn't blank
  // a tab that was already showing something -- a following success line
  // drops the stale error. Always a fresh object, for QML's change
  // notification.
  function handleInspectLine(data) {
    if (!data || typeof data.hash !== "string" || typeof data.tab !== "string") return
    var key = data.hash + "|" + data.tab
    var prev = inspectByKey[key] || {}
    var entry = { at: Date.now() }
    if (data.error !== undefined && data.error !== null) {
      entry.error = Model.sanitizeError(data.error || ("Could not read " + data.tab))
      if (prev.props !== undefined) entry.props = prev.props
      if (prev.pieces !== undefined) entry.pieces = prev.pieces
      if (prev.trackers !== undefined) entry.trackers = prev.trackers
      if (prev.peers !== undefined) entry.peers = prev.peers
      if (prev.points !== undefined) entry.points = prev.points
    } else if (data.tab === "info") {
      entry.props = data.props
      entry.pieces = (data.pieces === null || data.pieces === undefined) ? prev.pieces : data.pieces
    } else if (data.tab === "trackers") {
      entry.trackers = data.trackers
    } else if (data.tab === "peers") {
      entry.peers = data.peers
    } else if (data.tab === "chart") {
      entry.points = data.points
    } else {
      return
    }
    var next = ({})
    for (var k in inspectByKey) next[k] = inspectByKey[k]
    next[key] = entry
    inspectByKey = next
  }

  // The {hash, tab} qbt-serve should actually be told, given a watch()
  // call: "files" isn't a sidecar tab, so it always maps to a clearing
  // watch (hash:null) -- but WATCH_TABS still requires a valid tab on that
  // clearing watch, so it comes back as "info", never "files" itself.
  function effectiveWatch(hash, tab) {
    var t = String(tab || "info")
    if (t !== "info" && t !== "trackers" && t !== "peers" && t !== "chart") return { hash: null, tab: "info" }
    var h = String(hash || "")
    return { hash: h !== "" ? h : null, tab: t }
  }

  // hash: falsy clears the watch. tab: the pane's tab name, including
  // "files" (translated to a clearing watch since the sidecar never reads
  // it). Stores watchedHash/watchedTab verbatim either way, so a later
  // watch(hash, "info") after a watch(hash, "files") still counts as a
  // real change.
  function watch(hash, tab) {
    watchedHash = String(hash || "")
    watchedTab = String(tab || "info")
    sendWatchIfChanged()
  }

  // Sends the current watch only when it actually differs from what the
  // running sidecar was last told (an identical re-send is harmless on
  // the wire but pointless, F11); no-ops while the sidecar isn't up.
  function sendWatchIfChanged() {
    if (sidecarState !== "up") return
    var eff = effectiveWatch(watchedHash, watchedTab)
    if (lastSentWatch && lastSentWatch.hash === eff.hash && lastSentWatch.tab === eff.tab) return
    lastSentWatch = eff
    sidecar.send({ cmd: "watch", hash: eff.hash, tab: eff.tab })
  }

  // Called when windowOpen goes false: the window (and its Client, which
  // owns the cursor) may already be destroyed, so Service clears the
  // watch on its own rather than relying on the window to ask -- without
  // this the sidecar would keep reading properties/peers for a torrent
  // nobody is looking at anymore.
  function clearWatch() {
    watchedHash = ""
    sendWatchIfChanged()
  }

  function notify(text) {
    if (!text || !notifications) return
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
  // its own message from actionFinished. stdin (optional): a secret-bearing
  // value (a tracker URL, a magnet) written to the child's stdin once it has
  // started, never put on argv, where /proc/<pid>/cmdline shows it to every
  // local account.
  function runAction(cmd, statusText, opts, stdin) {
    var ticket = actionTicketSeq + 1
    actionTicketSeq = ticket
    var item = Model.makeActionItem(ticket, cmd, statusText, opts, stdin)
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
    actionProcess.stdinEnabled = item.stdin !== null
    actionProcess.running = true
  }

  // The child runs: an action's stdin value goes once, then stdin closes
  // (EOF). Like rssStarted.
  function actionStarted() {
    var item = currentAction
    if (!item || item.stdin === null || item.written === true) return
    item.written = true
    actionProcess.write(item.stdin)
    item.stdin = null
    actionProcess.stdinEnabled = false
  }

  // Ends the current action: the one path for a command that exited and
  // for one that never started. ok false reports err (already sanitized)
  // to the widget's lastError unless the action came from the window.
  function finishAction(ok, err) {
    var done = currentAction
    currentAction = null
    // Exited or never started: either way stdin closes before the next
    // action (startQueuedAction reopens it for one that has its own).
    actionProcess.stdinEnabled = false
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
    // A successful setPref gets its preferences re-read (refreshSlow),
    // never the plain refresh() every other action gets -- a torrent-list
    // refresh wouldn't pick up a preferences change at all.
    if (kind === "pref-set") refreshSlow()
    else refresh()
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

  // Called after every successful setPref (Task 3): a plain refresh only
  // re-ticks the torrent list, which never picks up a preferences change,
  // so a write asks for a preferences reread instead -- refresh-slow to
  // the sidecar when it's up, or refresh()'s existing bash statusProcess
  // fallback when it's down (or still starting, where refresh() is
  // already a no-op, same as it is for every other action).
  function refreshSlow() {
    if (!started) return
    if (sidecarState === "up") {
      sidecar.send({ cmd: "refresh-slow" })
      return
    }
    refresh()
  }

  function readClipboard() {
    clipboardText = ""
    clipProcess.command = ["wl-paste", "--no-newline"]
    clipProcess.running = true
  }

  // The last non-blank line of a (possibly multi-line) stderr blob. `qbt
  // prefs`'s own failure contract is a single line, but this is defensive
  // against any trailing blank line (or noise ahead of it) the same way a
  // human reading a terminal would just look at the last thing printed.
  function lastStderrLine(text) {
    var lines = String(text || "").split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = lines[i].trim()
      if (line !== "") return line
    }
    return ""
  }

  // Answers cb, asynchronously (Qt.callLater), with the same "not running"
  // error readPrefs, pumpPrefsQueue and stop() all use for a Service that
  // isn't started: never called synchronously out of readPrefs itself, so
  // a caller can always assume its callback fires on a later tick, never
  // reentrantly within the call that asked for it.
  function answerPrefsNotRunning(cb) {
    Qt.callLater(function() { cb({ ok: false, error: "qBittorrent isn't running." }) })
  }

  // Settings (Task 3): reads `qbt prefs` in its own Process, never the
  // ticketed action queue (it's a read, not a write). cb is called with
  // {ok:true, prefs} or {ok:false, error}; a qBittorrent-down failure is
  // just another {ok:false, error} -- the Settings view is the one that
  // decides to show the api-down screen for it. Overlapping calls are
  // queued rather than coalesced: a caller who asks while another read is
  // still in flight gets its own fresh run and its own answer once its
  // turn comes, so nobody's callback is ever silently dropped. An
  // inactive/stopped Service starts no Process at all (Ruling DK, same
  // invariant the file header documents for every other Process here);
  // its callback still always fires, just with that error instead.
  function readPrefs(cb) {
    if (!started) {
      answerPrefsNotRunning(cb)
      return
    }
    // prefsProcess.cb !== null also counts: in the failed-start window
    // (running already false, no exited yet -- see prefsProcess's
    // onRunningChanged below) a call landing here must still queue behind
    // the pending callback rather than overwrite it, the same reasoning
    // runAction's currentAction !== null check applies to actionProcess.
    if (prefsProcess.running || prefsProcess.cb !== null) {
      prefsQueue = Model.enqueueAction(prefsQueue, cb)
      return
    }
    startPrefsRead(cb)
  }

  function startPrefsRead(cb) {
    prefsProcess.cb = cb
    prefsProcess.command = [helperPath, "prefs"]
    prefsProcess.running = true
  }

  // Started from prefsProcess.onExited (a real run just finished) and,
  // defensively, from anywhere else that might find prefsQueue non-empty
  // after the Service has stopped: stop() itself already drains the queue
  // synchronously, so in practice this only ever sees !started if a run
  // that was already in flight when stop() was called exits afterward.
  // Either way, no new Process starts once stopped, and the callback is
  // still answered rather than dropped.
  function pumpPrefsQueue() {
    var next = Model.shiftAction(prefsQueue)
    prefsQueue = next.rest
    if (!next.item) return
    if (!started) {
      answerPrefsNotRunning(next.item)
      return
    }
    startPrefsRead(next.item)
  }

  // Settings (Task 3): a normal ticketed write, `qbt pref-set <key>
  // --value-stdin` with the value on stdin: a value such as add_trackers can
  // hold a private tracker's passkey, so it never rides on argv. A
  // composite's key is the composite's own key and its value is "HH:MM" --
  // passed through as a plain string like everything else here, since qbt
  // is the one that knows how to split it. finishAction reads its every
  // success as a preferences change (refreshSlow above).
  function setPref(key, value, opts) {
    if (!key) return 0
    return runAction([helperPath, "pref-set", String(key), "--value-stdin"], "Saving setting…", opts, String(value))
  }

  // ---- slice 4b: secrets and the ban list (Task 3) ------------------------------

  // The three secrets `qbt pref-set --stdin` may write (eng 4b D2/D7).
  readonly property var secretKeys: ["proxy_password", "dyndns_password", "mail_notification_password"]

  // `qbt pref-set <key> --stdin` in its own Process (secretProcess), never
  // the ticketed action queue: the value goes to the child's stdin once it
  // has started, then stdin closes. It is held only by the local closure
  // below until then -- never a property, never argv, never logged -- and a
  // run that never starts drops it. One at a time; 0 while one runs, for a
  // key outside secretKeys, or on a Service that isn't started. Returns a
  // ticket that secretFinished carries back.
  function setSecret(key, value, opts) {
    var k = String(key || "")
    if (!started || secretKeys.indexOf(k) === -1 || secretProcess.running || secretProcess.ticket !== 0) return 0
    var p = secretProcess
    var armed = true
    var feed = function() {
      if (!armed) return
      armed = false
      p.started.disconnect(feed)
      p.write(String(value))
      p.stdinEnabled = false
    }
    // A run that ends (or never starts) with the value unwritten drops it.
    var drop = function() {
      if (p.running) return
      p.runningChanged.disconnect(drop)
      if (!armed) return
      armed = false
      p.started.disconnect(feed)
    }
    p.ticket = mintTicket()
    p.secretKey = k
    p.command = [helperPath, "pref-set", k, "--stdin"]
    p.stdinEnabled = true
    p.started.connect(feed)
    p.runningChanged.connect(drop)
    p.running = true
    return p.ticket
  }

  function finishSecret(ok, err) {
    var ticket = secretProcess.ticket
    secretProcess.ticket = 0
    secretProcess.secretKey = ""
    if (ticket === 0) return
    if (ok) refreshSlow()
    secretFinished(ticket, ok, err)
  }

  // `qbt pref-set <key> --clear`: a normal ticketed write (no value).
  function clearSecret(key, opts) {
    var k = String(key || "")
    if (secretKeys.indexOf(k) === -1) return 0
    return runAction([helperPath, "pref-set", k, "--clear"], "Clearing secret…", opts)
  }

  // `qbt ban-list add|remove <ip>` (eng 4b D3/D11): qbt re-reads the list
  // just before writing and reports a mismatch as an error.
  function banList(op, ip, opts) {
    if ((op !== "add" && op !== "remove") || !ip) return 0
    return runAction([helperPath, "ban-list", op, String(ip)], op === "add" ? "Banning address…" : "Unbanning address…", opts)
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
    // The target (a magnet or URL can carry a passkey) goes on stdin.
    cmd.push("--stdin")
    return runAction(cmd, stopped ? "Adding torrent (stopped)…" : "Adding torrent…", opts, t)
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
  // live). One call with "all" when nothing is pending and the inbox is
  // empty; otherwise the live hashes in chunks of Model.HASH_CHUNK, since
  // one argv string can't hold every hash of a large library. A pending or
  // inboxed magnet always forces the explicit-hash path, even when every
  // current row is live, so "all" never touches a magnet before the user
  // confirms it.
  function toggleAll(opts) {
    var live = Model.excludePending(torrents, magnetPendingHashes)
    if (live.length === 0) return []
    var verb = Model.anyActive(live) ? "stop" : "start"
    var targets = Model.toggleAllTargets(torrents, magnetPendingHashes, undefined, (magnetInbox || []).length)
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

  // Per-torrent limits (slice 3b, Task 2). hashes is a "|" list, an array
  // or a QML sequence of at most Model.HASH_CHUNK (the window chunks),
  // read by LibraryView.hashList, same as the library helpers above.
  // limits: {ratio?, seedingTime?} -- each sent only when given, so a
  // caller can change just one without touching the other (qbt's
  // share-limits keeps whatever it isn't told to change). force appends
  // --force, for the D8 guard's confirm.
  function setShareLimits(hashes, limits, force, opts) {
    var list = Library.hashList(hashes).join("|")
    if (list === "") return 0
    var l = limits || {}
    var hasRatio = l.ratio !== undefined && l.ratio !== null
    var hasSeedingTime = l.seedingTime !== undefined && l.seedingTime !== null
    if (!hasRatio && !hasSeedingTime) return 0
    var cmd = [helperPath, "share-limits", list]
    if (hasRatio) cmd.push("--ratio", String(l.ratio))
    if (hasSeedingTime) cmd.push("--seed-time", String(l.seedingTime))
    if (force) cmd.push("--force")
    return runAction(cmd, "Setting share limits…", opts)
  }

  // statusText (optional, Ruling CF): the widget's status while it runs;
  // the widget's Sequential click passes "" (it never showed one).
  function setSequential(hashes, on, opts, statusText) {
    var list = Library.hashList(hashes).join("|")
    if (list === "") return 0
    return runAction([helperPath, "sequential", list, on ? "on" : "off"], statusText === undefined ? "Setting sequential download…" : String(statusText), opts)
  }

  function setFirstLast(hashes, on, opts) {
    var list = Library.hashList(hashes).join("|")
    if (list === "") return 0
    return runAction([helperPath, "first-last", list, on ? "on" : "off"], "Setting first/last piece priority…", opts)
  }

  function setSpeedLimit(hashes, kind, bytes, opts) {
    var list = Library.hashList(hashes).join("|")
    if (list === "") return 0
    return runAction([helperPath, "limit", list, kind, String(bytes)], "Setting speed limit…", opts)
  }

  // Shared by copyMagnet and copyText: opts: {origin: "window", hashes}
  // returns a ticket and reports through actionFinished, leaving
  // actionStatus and lastError alone; without opts (the widget) it sets
  // statusText and gets today's behavior (returns 0 while busy).
  function startCopy(text, opts, statusText) {
    if (copyProcess.running) return 0
    var fromWindow = isWindowOrigin(opts)
    var done = null
    if (fromWindow) {
      done = windowDone(opts)
    } else {
      clearError()
      actionStatus = statusText
    }
    copyProcess.done = done
    // The text (a magnet, a tracker URL) goes on stdin: wl-copy stays
    // resident serving the clipboard, and its argv would show a passkey in
    // /proc/<pid>/cmdline the whole time.
    copyProcess.pendingText = String(text)
    copyProcess.command = ["wl-copy", "--type", "text/plain;charset=utf-8"]
    copyProcess.stdinEnabled = true
    copyProcess.running = true
    return done ? done.ticket : 0
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
    return startCopy(uri, opts, "Copied magnet.")
  }

  // Used by y on the trackers and peers tabs (always window origin: those
  // panes only exist in the inspector). Same contract as copyMagnet.
  function copyText(text, opts) {
    return startCopy(text, opts, "Copied.")
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

  // The inspector's writes (slice 2b). qbt validates every argument (F5)
  // and dies with a message the ticket's error carries; these only refuse
  // an empty one (0, nothing runs). finishAction refreshes on success.
  function reannounce(hash, opts) {
    if (!hash) return 0
    return runAction([helperPath, "reannounce", hash], "Reannouncing…", opts)
  }

  // A tracker URL can carry a passkey: it goes on stdin (`--stdin`), the
  // hash stays on argv. tracker-edit reads old NUL new, no trailing NUL.
  function addTracker(hash, url, opts) {
    if (!hash || !url) return 0
    return runAction([helperPath, "tracker-add", hash, "--stdin"], "Adding tracker…", opts, String(url))
  }

  function editTracker(hash, oldUrl, newUrl, opts) {
    if (!hash || !oldUrl || !newUrl) return 0
    return runAction([helperPath, "tracker-edit", hash, "--stdin"], "Changing tracker…", opts, String(oldUrl) + "\u0000" + String(newUrl))
  }

  function removeTracker(hash, url, opts) {
    if (!hash || !url) return 0
    return runAction([helperPath, "tracker-remove", hash, "--stdin"], "Removing tracker…", opts, String(url))
  }

  function banPeer(peer, opts) {
    if (!peer) return 0
    return runAction([helperPath, "ban-peer", peer], "Banning peer…", opts)
  }

  function fetchMetadata(hash, opts) {
    if (!hash) return 0
    return runAction([helperPath, "fetch-metadata", hash], "Fetching metadata…", opts)
  }

  // Categories and tags (slice 3a). qbt checks every name (G4/OV5), path
  // and hash and dies with the message the ticket's error carries; these
  // only refuse a missing argument (0, nothing runs). "" is a real value
  // for setCategory's name (none) and setCategoryPath's path (the
  // default). hashes is a "|" list, an array or a QML sequence of at most
  // Model.HASH_CHUNK (the window chunks, like setLocation's callers), read
  // by LibraryView.hashList, the same helper movePlan uses.
  function addCategory(name, path, opts) {
    if (!name) return 0
    var cmd = [helperPath, "category-add", name]
    if (path) cmd.push(path)
    return runAction(cmd, "Adding category…", opts)
  }

  function setCategoryPath(name, path, opts) {
    if (!name) return 0
    return runAction([helperPath, "category-path", name, String(path || "")], "Changing save path…", opts)
  }

  function removeCategory(name, opts) {
    if (!name) return 0
    return runAction([helperPath, "category-remove", name], "Deleting category…", opts)
  }

  function renameCategory(oldName, newName, merge, opts) {
    return runRename("category-rename", oldName, newName, merge, opts)
  }

  function setCategory(hashes, name, opts) {
    var list = Library.hashList(hashes).join("|")
    if (list === "") return 0
    return runAction([helperPath, "set-category", list, String(name || "")], "Setting category…", opts)
  }

  function addTag(name, opts) {
    if (!name) return 0
    return runAction([helperPath, "tag-add", name], "Adding tag…", opts)
  }

  function removeTag(name, opts) {
    if (!name) return 0
    return runAction([helperPath, "tag-remove", name], "Deleting tag…", opts)
  }

  function renameTag(oldName, newName, merge, opts) {
    return runRename("tag-rename", oldName, newName, merge, opts)
  }

  function runRename(verb, oldName, newName, merge, opts) {
    if (!oldName || !newName) return 0
    var cmd = [helperPath, verb, oldName, newName]
    if (merge) cmd.push("--merge")
    return runAction(cmd, "Renaming " + oldName + " → " + newName + "…", opts)
  }

  // changes: {add: [...], remove: [...]} (LibraryView.tagChanges); 0 when
  // there is nothing to change.
  function editTags(hashes, changes, opts) {
    var list = Library.hashList(hashes).join("|")
    var add = (changes && changes.add) || []
    var remove = (changes && changes.remove) || []
    if (list === "" || add.length + remove.length === 0) return 0
    var cmd = [helperPath, "tags", list]
    for (var i = 0; i < add.length; i++) cmd.push("--add", add[i])
    for (var j = 0; j < remove.length; j++) cmd.push("--remove", remove[j])
    return runAction(cmd, "Changing tags…", opts)
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
  // OV10: launched detached (setsid -f forks and returns at once), so a
  // slow file manager or browser can never wedge openProcess.
  function openPath(path, opts) {
    var p = String(path || "")
    if (p === "" || openProcess.running) return
    openProcess.command = ["setsid", "-f", "xdg-open", p]
    openProcess.running = true
  }

  // ---- slice 5a: Search (Task 3) ------------------------------------------------

  // `d` (design D3): a result's page, after the window's confirm. Only an
  // http(s) link (the window already applied the pageLink rule); detached
  // like openPath (OV10). Returns whether it launched.
  function openUrl(url) {
    var u = String(url || "")
    if (!/^https?:\/\//i.test(u) || openProcess.running) return false
    openProcess.command = ["setsid", "-f", "xdg-open", u]
    openProcess.running = true
    return true
  }

  // Two lanes of `qbt search*` runs, each one at a time in order: "jobs"
  // (start, stop, delete, add) and "plugins" (list, install, uninstall,
  // enable, update: an install reads back for up to 20 s, which must not
  // hold up a stop). Every argv is an array, never a shell string. Returns
  // the ticket searchFinished carries back, or 0 on a Service that isn't
  // started. stdin (optional): a value written to the child once it starts,
  // then closed, kept off argv.
  function searchRun(lane, cmd, stdin) {
    if (!started) return 0
    var item = { ticket: mintTicket(), cmd: cmd, stdin: typeof stdin === "string" ? stdin : null }
    var plugins = lane === "plugins"
    var p = plugins ? searchPluginProcess : searchJobProcess
    if (p.running || (plugins ? searchPluginItem : searchJobItem) !== null) {
      if (plugins) searchPluginQueue = searchPluginQueue.concat([item])
      else searchJobQueue = searchJobQueue.concat([item])
    } else {
      startSearchItem(plugins, item)
    }
    if (plugins) syncPluginChange()
    return item.ticket
  }

  function syncPluginChange() {
    var items = [searchPluginItem].concat(searchPluginQueue)
    for (var i = 0; i < items.length; i++) {
      var c = items[i] ? items[i].cmd : null
      if (!c || c.length < 3 || c[1] !== "search-plugin") continue
      if (c[2] === "enable") { searchPluginChange = "toggle"; return }
      if (c[2] === "install" || c[2] === "uninstall" || c[2] === "update") { searchPluginChange = c[2]; return }
    }
    searchPluginChange = ""
  }

  function startSearchItem(plugins, item) {
    var p = plugins ? searchPluginProcess : searchJobProcess
    if (plugins) searchPluginItem = item
    else searchJobItem = item
    p.command = item.cmd
    p.stdinEnabled = item.stdin !== null && item.stdin !== undefined
    p.running = true
  }

  // A lane's child runs: its stdin value goes out once, then stdin closes.
  function searchStarted(plugins) {
    var p = plugins ? searchPluginProcess : searchJobProcess
    var item = plugins ? searchPluginItem : searchJobItem
    if (!item || item.stdin === null || item.stdin === undefined || item.written === true) return
    item.written = true
    p.write(item.stdin)
    item.stdin = null
    p.stdinEnabled = false
  }

  // The end of a lane's run (exited, or never started): the next queued
  // run starts first, then the signal goes out.
  // The lane's item goes straight from this run to the next one (never
  // null in between), so a handler of searchPluginChange that asks for
  // another run is queued behind it, never started over it.
  function finishSearchItem(plugins, ok, err, data) {
    var item = plugins ? searchPluginItem : searchJobItem
    var queue = plugins ? searchPluginQueue : searchJobQueue
    var proc = plugins ? searchPluginProcess : searchJobProcess
    proc.stdinEnabled = false
    if (queue.length > 0 && started) {
      if (plugins) searchPluginQueue = queue.slice(1)
      else searchJobQueue = queue.slice(1)
      startSearchItem(plugins, queue[0])
    } else {
      if (plugins) searchPluginItem = null
      else searchJobItem = null
      if (queue.length > 0) {
        if (plugins) searchPluginQueue = queue.slice(1)
        else searchJobQueue = queue.slice(1)
        Qt.callLater(function() { root.searchFinished(queue[0].ticket, false, "qBittorrent isn't running.", null) })
      }
    }
    if (plugins) syncPluginChange()
    if (!item) return
    if (ok && item.cmd.length > 2 && item.cmd[1] === "search" && item.cmd[2] === "add") refresh()
    // A start the window gave up on (it closed while the start ran or
    // waited): nobody will watch or delete its job, so it goes here.
    if (item.abandoned === true && ok) {
      var id = data && typeof data === "object" ? data.id : undefined
      if (typeof id === "number" && /^[1-9][0-9]{0,9}$/.test(String(id)) && id <= 2147483647) searchDelete(id)
    }
    searchFinished(item.ticket, ok, err, data)
  }

  function isSearchStart(item) {
    return !!item && item.cmd.length > 2 && item.cmd[1] === "search" && item.cmd[2] === "start"
  }

  // The window closed: the start running and every start still queued are
  // abandoned (the window, rebuilt on every toggle, can't delete them).
  function abandonSearchStarts() {
    if (isSearchStart(searchJobItem)) searchJobItem.abandoned = true
    for (var i = 0; i < searchJobQueue.length; i++) if (isSearchStart(searchJobQueue[i])) searchJobQueue[i].abandoned = true
  }

  function searchExited(plugins, exitCode, out, err) {
    if ((plugins ? searchPluginItem : searchJobItem) === null) return
    if (exitCode !== 0) {
      finishSearchItem(plugins, false, Model.sanitizeError(lastStderrLine(err) || "Could not run the qbt helper"), null)
      return
    }
    var text = String(out || "").trim()
    var data = null
    if (text !== "") {
      try { data = JSON.parse(text) } catch (e) { data = null }
    }
    finishSearchItem(plugins, true, "", data)
  }

  // A lane whose program never started (running went false, no exited).
  function searchLost(plugins, pending) {
    var p = plugins ? searchPluginProcess : searchJobProcess
    if (p.running || (plugins ? searchPluginItem : searchJobItem) !== pending) return
    finishSearchItem(plugins, false, "Could not run the qbt helper", null)
  }

  function searchStart(pattern, category) {
    return searchRun("jobs", [helperPath, "search", "start", "--pattern", String(pattern), "--category", String(category)])
  }
  function searchStop(id) { return searchRun("jobs", [helperPath, "search", "stop", String(id)]) }
  function searchDelete(id) { return searchRun("jobs", [helperPath, "search", "delete", String(id)]) }
  // plugin: the result's engineName, passed only when non-empty.
  // A private plugin's link can carry a passkey: it goes on stdin.
  function searchAdd(link, plugin) {
    var cmd = [helperPath, "search", "add", "--stdin"]
    if (plugin) cmd.push(String(plugin))
    return searchRun("jobs", cmd, String(link))
  }
  function searchPluginList() { return searchRun("plugins", [helperPath, "search-plugin", "list"]) }
  function searchPluginInstall(url) { return searchRun("plugins", [helperPath, "search-plugin", "install", String(url)]) }
  function searchPluginUninstall(name) { return searchRun("plugins", [helperPath, "search-plugin", "uninstall", String(name)]) }
  function searchPluginEnable(name, on) { return searchRun("plugins", [helperPath, "search-plugin", "enable", String(name), on ? "on" : "off"]) }
  function searchPluginUpdate() { return searchRun("plugins", [helperPath, "search-plugin", "update"]) }

  // The sidecar's search watch (OV7): the window owns the offset (the rows
  // it holds) and sends it with every command. searchWatchId remembers the
  // job so a restarted sidecar's first status line asks the window to
  // re-send (searchWatchLost). Returns whether the sidecar got it.
  function searchWatch(id, offset) {
    var n = Number(id) || 0
    if (n <= 0) return false
    searchWatchId = n
    return sidecar.send({ cmd: "search", id: n, offset: Math.max(0, Number(offset) || 0) })
  }

  function searchUnwatch() {
    if (searchWatchId === 0) return
    searchWatchId = 0
    sidecar.send({ cmd: "search", id: null })
  }

  function handleSearchLine(data) {
    if (!data || typeof data !== "object" || data.type !== "search") return
    // A reply for a job nobody watches any more (a late one) goes nowhere.
    if (Number(data.id) !== searchWatchId) return
    // The final reply and "gone" end the sidecar's watch (Ruling FB).
    if (data.error === "gone") searchWatchId = 0
    searchReply(data)
  }

  // ---- slice 5b1: RSS (Task 3) ------------------------------------------------------

  // One serial lane of `qbt rss <sub>` runs, one at a time in order
  // (tests/fixtures/rss-contract.md). argv holds only the subcommand; every
  // value goes on stdin, NUL-joined with no trailing NUL (fields null: no
  // stdin at all, `items`). A read passes cb, answered as cb(ok, error,
  // data, same); a write passes none and ends in rssFinished. Returns the
  // ticket, or 0 on a Service that isn't started (nothing runs, and no
  // callback or signal follows).
  function rssRun(sub, fields, cb) {
    if (!started) return 0
    var item = { ticket: mintTicket(), sub: sub, cmd: [helperPath, "rss", sub], stdin: fields === null ? null : fields.join("\u0000"), cb: cb || null }
    if (rssProcess.running || rssItem !== null) rssQueue = rssQueue.concat([item])
    else startRssItem(item)
    return item.ticket
  }

  function startRssItem(item) {
    rssItem = item
    rssProcess.command = item.cmd
    rssProcess.stdinEnabled = item.stdin !== null
    rssProcess.running = true
  }

  // The child runs: its values go to stdin once, then stdin closes (EOF).
  function rssStarted() {
    var item = rssItem
    if (!item || item.stdin === null || item.written === true) return
    item.written = true
    rssProcess.write(item.stdin)
    rssProcess.stdinEnabled = false
  }

  // The end of a run (exited, or never started): the next queued run
  // starts first, then the answer goes out.
  function finishRssItem(ok, err, text) {
    var item = rssItem
    rssProcess.stdinEnabled = false
    if (rssQueue.length > 0 && started) {
      var next = rssQueue[0]
      rssQueue = rssQueue.slice(1)
      startRssItem(next)
    } else {
      rssItem = null
      if (rssQueue.length > 0) {
        var dropped = rssQueue
        rssQueue = []
        Qt.callLater(function() { for (var i = 0; i < dropped.length; i++) root.answerRss(dropped[i], false, "qBittorrent isn't running.", null, false) })
      }
    }
    if (!item) return
    var data = null
    var same = false
    if (ok) {
      var t = String(text || "").trim()
      if (item.sub === "items" && t !== "" && t === rssLastItemsText && rssLastItems !== null) {
        same = true
        data = rssLastItems
      } else if (t !== "") {
        try { data = JSON.parse(t) } catch (e) { data = null }
      }
      if (item.sub === "items") {
        rssLastItemsText = data !== null ? t : ""
        rssLastItems = data
      }
      if (item.sub === "add") refresh()
    } else if (item.sub === "items") {
      rssLastItemsText = ""
      rssLastItems = null
    }
    answerRss(item, ok, err, data, same)
  }

  function answerRss(item, ok, err, data, same) {
    if (item.cb) {
      var cb = item.cb
      item.cb = null
      cb(ok, err, data, same)
    } else if (item.read !== true) {
      rssFinished(item.ticket, ok, err, data)
    }
  }

  function rssExited(exitCode, out, err) {
    if (rssItem === null) return
    if (exitCode !== 0) finishRssItem(false, Model.sanitizeError(lastStderrLine(err) || "Could not run the qbt helper"), "")
    else finishRssItem(true, "", out)
  }

  function rssLost(pending) {
    if (rssProcess.running || rssItem !== pending) return
    finishRssItem(false, "Could not run the qbt helper", "")
  }

  // The window closed: its reads answer nobody (it is rebuilt, never
  // reopened; a callback would reach a destroyed view).
  function dropRssCallbacks() {
    var items = [rssItem].concat(rssQueue)
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].cb) { items[i].cb = null; items[i].read = true }
  }

  // A read always has a callback (a missing one answers nobody).
  function rssRead(sub, fields, cb) {
    return rssRun(sub, fields, typeof cb === "function" ? cb : function() {})
  }

  function rssItems(cb) { return rssRead("items", null, cb) }
  function rssArticle(path, guid, cb) { return rssRead("article", [String(path), String(guid)], cb) }
  function rssError(url, cb) { return rssRead("error", [String(url)], cb) }
  function rssAddFeed(url, path) { return rssRun("add-feed", [String(url), String(path)], null) }
  function rssAddFolder(path) { return rssRun("add-folder", [String(path)], null) }
  function rssRename(from, to) { return rssRun("rename", [String(from), String(to)], null) }
  function rssRemove(path) { return rssRun("remove", [String(path)], null) }
  // Slice 5b2 (Task 3): the auto-download rules, on the same lane
  // (tests/fixtures/rss-rules-contract.md). The reads answer cb(ok, error,
  // data); the writes end in rssFinished. rule-set's changes and snapshot
  // go as JSON ({} for a pure on or off), enable as keep, off or on.
  function rssRules(cb) { return rssRead("rules", null, cb) }
  function rssRuleCheck(key, value, useRegex, cb) { return rssRead("rule-check", [String(key), String(value), useRegex === true ? "true" : "false"], cb) }
  function rssRulePreview(name, cb) { return rssRead("rule-preview", [String(name)], cb) }
  function rssRuleCreate(name, feedUrl) { return rssRun("rule-create", [String(name), String(feedUrl || "")], null) }
  function rssRuleSet(name, changes, snapshot, enable) {
    return rssRun("rule-set", [String(name), JSON.stringify(changes || ({})), JSON.stringify(snapshot || ({})), String(enable)], null)
  }
  function rssRuleRename(from, to) { return rssRun("rule-rename", [String(from), String(to)], null) }
  function rssRuleRemove(name) { return rssRun("rule-remove", [String(name)], null) }
  // path "" refreshes everything (one empty field).
  function rssRefresh(path) { return rssRun("refresh", [String(path)], null) }
  // guid "" marks a whole feed or folder (path "" everything); expect is
  // the count the window's confirm named (0 with a guid).
  function rssMarkRead(path, guid, expect) { return rssRun("mark-read", [String(path), String(guid), String(Number(expect) || 0)], null) }
  function rssAdd(torrentURL, link) { return rssRun("add", [String(torrentURL), String(link)], null) }
  // 5b2 T2: Settings' auto-download count (D8), `qbt rss rules-preview-enabled`
  // (no stdin): cb(ok, err, {rules, will, noTorrent}).
  function rssAutoPreview(cb) { return rssRead("rules-preview-enabled", null, cb) }

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
    // watchedHash/watchedTab are kept -- they're resent on the next
    // sidecar-up -- but the sidecar that knew about lastSentWatch is gone,
    // and inspectByKey stays exactly as it was.
    lastSentWatch = null
    sidecar.stop()
    // Ruling DK: every readPrefs call still queued behind an in-flight (or
    // already-finished) run is answered now, rather than left to time out
    // whenever (if ever) pumpPrefsQueue next runs -- a run already in
    // flight on prefsProcess itself is left alone and still answers its
    // own caller for real once it exits.
    var queued = prefsQueue
    prefsQueue = []
    for (var i = 0; i < queued.length; i++) answerPrefsNotRunning(queued[i])
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
        // A fresh (or restarted) sidecar knows nothing of any watch; resend
        // it (F11) unless the effective watch has no hash (nothing is
        // actually being watched, or the current tab is "files"), so a
        // bar-only session -- or a Files-tab watch -- never sends a
        // pointless clearing watch on every start.
        lastSentWatch = null
        if (effectiveWatch(watchedHash, watchedTab).hash !== null) sendWatchIfChanged()
        // Slice 5a: a fresh sidecar has no search watch either (OV7).
        if (searchWatchId > 0) searchWatchLost()
      }
    } else if (msg.type === "heartbeat") {
      sidecarLastBeat = Date.now()
    } else if (msg.type === "inspect") {
      handleInspectLine(msg.data)
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
    // The exited sidecar's own watch state is gone with it; watchedHash/
    // watchedTab are kept and resent once a replacement comes up.
    lastSentWatch = null
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

  // The window is rebuilt on every toggle, so its Client may already be
  // destroyed by the time windowOpen flips false and could never send a
  // clearing watch itself; Service does it here instead (see clearWatch),
  // and deletes the jobs of the starts it gave up on (abandonSearchStarts).
  onWindowOpenChanged: if (!windowOpen) { clearWatch(); searchUnwatch(); abandonSearchStarts(); dropRssCallbacks() }

  onSidecarCadenceMsChanged: if (sidecarState === "up") sendCadence()

  Component.onCompleted: if (active) activate()

  Sidecar {
    id: sidecar
    path: root.sidecarPath
    onLine: function(text) { root.handleSidecarLine(text) }
    onSearchLine: function(data) { root.handleSearchLine(data) }
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
    // The text to copy, held only until it is written to stdin.
    property string pendingText: ""
    running: false
    command: []
    stdinEnabled: false
    stderr: StdioCollector { id: copyErr; waitForEnd: true }
    onStarted: {
      if (!copyProcess.stdinEnabled) return
      copyProcess.write(copyProcess.pendingText)
      copyProcess.pendingText = ""
      copyProcess.stdinEnabled = false
    }
    // Ended, or never started: nothing is left held or open.
    onRunningChanged: {
      if (running) return
      copyProcess.pendingText = ""
      copyProcess.stdinEnabled = false
    }
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
    stdinEnabled: false
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onStarted: root.actionStarted()
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

  // Settings (Task 3): `qbt prefs`, its own one-shot Process rather than
  // the ticketed actionQueue -- a read, run and answered independently of
  // whatever write may already be in flight.
  Process {
    id: prefsProcess
    property var cb: null
    running: false
    command: []
    stdout: StdioCollector { id: prefsOut; waitForEnd: true }
    stderr: StdioCollector { id: prefsErr; waitForEnd: true }
    // A helper that can't even start (missing, not executable) emits no
    // exited at all, only running going false -- the same case
    // actionProcess guards against below. Deferred a turn so a normal
    // exit (which already cleared cb, and may already have started the
    // next queued run) is never double-reported.
    onRunningChanged: {
      if (running || prefsProcess.cb === null) return
      var pending = prefsProcess.cb
      Qt.callLater(function() {
        if (prefsProcess.running || prefsProcess.cb !== pending) return
        prefsProcess.cb = null
        pending({ ok: false, error: "Could not run the qbt helper" })
        root.pumpPrefsQueue()
      })
    }
    onExited: function(exitCode) {
      var cb = prefsProcess.cb
      prefsProcess.cb = null
      var result
      if (exitCode !== 0) {
        result = { ok: false, error: Model.sanitizeError(root.lastStderrLine(prefsErr.text) || "Could not read preferences") }
      } else {
        var text = String(prefsOut.text || "").trim()
        var prefs = null
        if (text !== "") {
          try { prefs = JSON.parse(text) } catch (e) { prefs = null }
        }
        if (!prefs || typeof prefs !== "object" || Array.isArray(prefs)) {
          result = { ok: false, error: "Could not read preferences" }
        } else {
          result = { ok: true, prefs: prefs }
        }
      }
      if (cb) cb(result)
      root.pumpPrefsQueue()
    }
  }

  // Slice 4b: `qbt pref-set <key> --stdin` (setSecret). stdinEnabled is
  // set per run and closed right after the value is written; ticket is 0
  // while idle. A run that never starts emits no exited, only running
  // going false: deferred a turn, like prefsProcess.
  Process {
    id: secretProcess
    property int ticket: 0
    property string secretKey: ""
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: secretOut; waitForEnd: true }
    stderr: StdioCollector { id: secretErr; waitForEnd: true }
    onRunningChanged: {
      if (running || secretProcess.ticket === 0) return
      var pending = secretProcess.ticket
      Qt.callLater(function() {
        if (secretProcess.running || secretProcess.ticket !== pending) return
        root.finishSecret(false, "Could not run the qbt helper")
      })
    }
    onExited: function(exitCode) {
      secretProcess.stdinEnabled = false
      if (exitCode !== 0) root.finishSecret(false, Model.sanitizeError(root.lastStderrLine(secretErr.text) || "Could not set the secret"))
      else root.finishSecret(true, "")
    }
  }

  // Slice 5a: the two `qbt search*` lanes (searchRun). searchLane is also
  // what a test finds each by. A run that never starts emits no exited,
  // only running going false: deferred a turn, like prefsProcess.
  Process {
    id: searchJobProcess
    readonly property string searchLane: "jobs"
    running: false
    command: []
    stdinEnabled: false
    onStarted: root.searchStarted(false)
    stdout: StdioCollector { id: searchJobOut; waitForEnd: true }
    stderr: StdioCollector { id: searchJobErr; waitForEnd: true }
    onRunningChanged: {
      if (running || root.searchJobItem === null) return
      var pending = root.searchJobItem
      Qt.callLater(function() { root.searchLost(false, pending) })
    }
    onExited: function(exitCode) { root.searchExited(false, exitCode, searchJobOut.text, searchJobErr.text) }
  }

  Process {
    id: searchPluginProcess
    readonly property string searchLane: "plugins"
    running: false
    command: []
    stdinEnabled: false
    onStarted: root.searchStarted(true)
    stdout: StdioCollector { id: searchPluginOut; waitForEnd: true }
    stderr: StdioCollector { id: searchPluginErr; waitForEnd: true }
    onRunningChanged: {
      if (running || root.searchPluginItem === null) return
      var pending = root.searchPluginItem
      Qt.callLater(function() { root.searchLost(true, pending) })
    }
    onExited: function(exitCode) { root.searchExited(true, exitCode, searchPluginOut.text, searchPluginErr.text) }
  }

  // Slice 5b1: the `qbt rss` lane (rssRun). rssLane is what a test finds it
  // by. stdin is opened per run and closed after its one write. A run that
  // never starts emits no exited, only running going false: deferred a
  // turn, like prefsProcess.
  Process {
    id: rssProcess
    readonly property string rssLane: "rss"
    running: false
    command: []
    stdinEnabled: false
    stdout: StdioCollector { id: rssOut; waitForEnd: true }
    stderr: StdioCollector { id: rssErr; waitForEnd: true }
    onStarted: root.rssStarted()
    onRunningChanged: {
      if (running || root.rssItem === null) return
      var pending = root.rssItem
      Qt.callLater(function() { root.rssLost(pending) })
    }
    onExited: function(exitCode) { root.rssExited(exitCode, rssOut.text, rssErr.text) }
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
