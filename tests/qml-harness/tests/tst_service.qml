import QtQuick
import QtTest
import "../../.."
import "../../../LibraryView.js" as Library

// Service.qml against stub Quickshell.Io processes: nothing is spawned and
// no file is read or written.
TestCase {
  id: tc
  name: "Service"

  Component { id: serviceComp; Service {} }

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function filesProc(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.nextHash !== undefined && o.hash !== undefined) return o
    }
    return null
  }
  // Service Task 3: the readPrefs one-shot Process (unique property: cb).
  function prefsProc(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.cb !== undefined) return o
    }
    return null
  }
  function finish(p, code, out, err) {
    p.stdout.text = out || ""
    p.stderr.text = err || ""
    p.running = false
    p.exited(code, 0)
  }

  function hx(i) { var s = i.toString(16); while (s.length < 40) s = "0" + s; return s }
  // actionProcess: the Process whose current command's verb is `verb`.
  function actionProc(svc, verb) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.running === true && o.command && o.command.length > 1 && o.command[1] === verb) return o
    }
    return null
  }
  // A Service whose start-up magnet-install-handler action has finished,
  // so actionProcess is idle. Returns {svc, p}.
  function idleService() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = actionProc(svc, "magnet-install-handler")
    verify(p !== null, "start() queues the handler install")
    finish(p, 0, "", "")
    compare(p.running, false)
    compare(svc.currentAction, null)
    return { svc: svc, p: p }
  }

  Component { id: spyComp; SignalSpy { signalName: "actionFinished" } }
  function spyOn(svc) { var sp = createTemporaryObject(spyComp, tc); sp.target = svc; return sp }

  // --- runAction by origin -------------------------------------------------

  function test_widget_action_writes_status_and_error() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    svc.lastError = "stale"
    var t = svc.recheckHash(hh("a"))
    verify(t > 0)
    compare(p.command[1], "recheck")
    compare(svc.actionStatus, "Rechecking…", "the widget sees its status on start")
    compare(svc.lastError, "", "and a cleared error")
    finish(p, 0, "{\"ok\":true}", "")
    compare(svc.actionStatus, "")
    compare(svc.lastError, "")
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], true)
    compare(spy.signalArguments[0][3], "widget")
    svc.deleteHash(hh("b"), true)
    compare(svc.actionStatus, "Deleting torrent and files…")
    finish(p, 1, "", "HTTP 409 conflict")
    compare(svc.actionStatus, "")
    compare(svc.lastError, "HTTP 409 conflict", "a widget failure lands in lastError")
    compare(spy.signalArguments[1][1], false)
    compare(spy.signalArguments[1][2], "HTTP 409 conflict")
  }

  function test_window_action_leaves_status_and_error_alone() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    svc.actionStatus = "widget status"
    svc.lastError = "widget error"
    var t1 = svc.recheckHash(hh("a"), { origin: "window", hashes: [hh("a")] })
    compare(p.command[1], "recheck")
    compare(svc.actionStatus, "widget status", "no status write on start")
    compare(svc.lastError, "widget error", "no clearError on start")
    finish(p, 0, "", "")
    compare(svc.actionStatus, "widget status")
    compare(svc.lastError, "widget error")
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t1)
    compare(spy.signalArguments[0][1], true)
    compare(spy.signalArguments[0][2], "")
    compare(spy.signalArguments[0][3], "window")
    compare(spy.signalArguments[0][4], [hh("a")])
    var t2 = svc.deleteHash(hh("b") + "|" + hh("c"), false, { origin: "window", hashes: [hh("b"), hh("c")] })
    finish(p, 1, "", "HTTP 403 forbidden")
    compare(svc.actionStatus, "widget status")
    compare(svc.lastError, "widget error", "a window failure stays out of lastError")
    compare(spy.count, 2)
    compare(spy.signalArguments[1][0], t2)
    compare(spy.signalArguments[1][1], false)
    compare(spy.signalArguments[1][2], "HTTP 403 forbidden")
    compare(spy.signalArguments[1][3], "window")
    compare(spy.signalArguments[1][4], [hh("b"), hh("c")])
  }

  // --- a command that never starts ----------------------------------------

  function test_failed_start_finishes_a_widget_action_and_pumps() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var t = svc.recheckHash(hh("a"))
    compare(svc.actionStatus, "Rechecking…")
    p.running = false                      // no exited: the program never ran
    // Lands between running going false and the check. Window origin, since
    // a widget action clears lastError when it starts (as it always has).
    var t2 = svc.stopHash(hh("b"), { origin: "window", hashes: [hh("b")] })
    compare(svc.actionQueue.length, 1, "a failed start's ticket isn't clobbered")
    tryCompare(spy, "count", 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], false)
    compare(spy.signalArguments[0][2], "Could not run the qbt helper")
    compare(spy.signalArguments[0][3], "widget")
    compare(svc.lastError, "Could not run the qbt helper", "the widget gets an error message")
    compare(svc.actionStatus, "")
    compare(p.running, true, "the queue moved on")
    compare(p.command[1], "stop")
    compare(svc.currentAction.ticket, t2)
    finish(p, 0, "", "")
    wait(0)
    compare(spy.count, 2)
    compare(spy.signalArguments[1][1], true, "a normal exit is never taken for a failed start")
  }

  function test_failed_start_finishes_a_window_action_quietly() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    svc.lastError = ""
    var t = svc.startHash(hh("a"), { origin: "window", hashes: [hh("a")] })
    p.running = false
    tryCompare(spy, "count", 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], false)
    compare(spy.signalArguments[0][2], "Could not run the qbt helper")
    compare(spy.signalArguments[0][3], "window")
    compare(spy.signalArguments[0][4], [hh("a")])
    compare(svc.lastError, "")
    compare(svc.currentAction, null)
    compare(svc.busy, false)
  }

  function test_normal_exit_with_a_queue_raises_no_failure() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    svc.recheckHash(hh("a"), { origin: "window", hashes: [] })
    svc.recheckHash(hh("b"), { origin: "window", hashes: [] })
    finish(p, 0, "", "")
    wait(0)
    compare(spy.count, 1)
    compare(spy.signalArguments[0][1], true)
    compare(p.running, true, "the second one runs")
    compare(p.command[2], hh("b"))
    finish(p, 0, "", "")
    wait(0)
    compare(spy.count, 2)
    compare(spy.signalArguments[1][1], true)
  }

  // --- toggleAll ------------------------------------------------------------

  function test_toggle_all_sends_all_when_nothing_pending_is_live() {
    var o = idleService(), svc = o.svc, p = o.p
    var rows = []
    for (var i = 0; i < 5000; i++) rows.push({ hash: hx(i), state: "stoppedDL", progress: 0.5 })
    svc.torrents = rows
    var tickets = svc.toggleAll()
    compare(tickets.length, 1)
    compare(p.command[1], "start")
    compare(p.command[2], "all")
    compare(svc.actionQueue.length, 0)
  }

  function test_toggle_all_sends_chunks_when_pending_magnet_not_yet_in_torrents() {
    // A magnet added after the last status tick: its hash is pending but
    // no row for it exists yet. "all" must not touch it before it's
    // confirmed, so every live row goes out as explicit chunks instead.
    var o = idleService(), svc = o.svc, p = o.p
    var rows = []
    for (var i = 0; i < 5000; i++) rows.push({ hash: hx(i), state: "stoppedDL", progress: 0.5 })
    svc.torrents = rows
    svc.magnetPending = [{ hash: hx(99999) }]
    var tickets = svc.toggleAll()
    compare(tickets.length, 5)
    compare(svc.actionQueue.length, 4)
    var seen = {}
    for (var n = 0; n < 5; n++) {
      compare(p.command[1], "start")
      verify(p.command[2] !== "all")
      var parts = p.command[2].split("|")
      for (var k = 0; k < parts.length; k++) seen[parts[k]] = true
      finish(p, 0, "", "")
    }
    compare(Object.keys(seen).length, 5000)
  }

  function test_toggle_all_sends_chunks_when_inbox_has_an_item_waiting() {
    // A magnet still sitting in the drain inbox isn't in torrents or
    // magnetPending at all, so it can only be caught through magnetInbox.
    var o = idleService(), svc = o.svc, p = o.p
    var rows = []
    for (var i = 0; i < 5000; i++) rows.push({ hash: hx(i), state: "stoppedDL", progress: 0.5 })
    svc.torrents = rows
    svc.magnetInbox = [{ notified: true }]
    var tickets = svc.toggleAll()
    compare(tickets.length, 5)
    compare(svc.actionQueue.length, 4)
    var seen = {}
    for (var n = 0; n < 5; n++) {
      compare(p.command[1], "start")
      verify(p.command[2] !== "all")
      var parts = p.command[2].split("|")
      for (var k = 0; k < parts.length; k++) seen[parts[k]] = true
      finish(p, 0, "", "")
    }
    compare(Object.keys(seen).length, 5000)
  }

  function test_toggle_all_chunks_5000_live_hashes_into_5_calls() {
    var o = idleService(), svc = o.svc, p = o.p
    var rows = []
    for (var i = 0; i < 5001; i++) rows.push({ hash: hx(i), state: "downloading", progress: 0.5 })
    svc.torrents = rows
    svc.magnetPending = [{ hash: hx(5000) }]
    var tickets = svc.toggleAll({ origin: "window", hashes: [] })
    compare(tickets.length, 5)
    compare(svc.actionQueue.length, 4)
    var seen = {}
    for (var n = 0; n < 5; n++) {
      compare(p.command[1], "stop")
      var parts = p.command[2].split("|")
      compare(parts.length, 1000)
      for (var k = 0; k < parts.length; k++) seen[parts[k]] = true
      finish(p, 0, "", "")
    }
    compare(Object.keys(seen).length, 5000)
    verify(seen[hx(5000)] !== true, "the pending magnet is left alone")
  }

  function test_queued_window_files_load_keeps_its_origin() {
    var svc = createTemporaryObject(serviceComp, tc)
    verify(svc.started)
    compare(svc.sidecarState, "starting", "files go through bash")
    var p = filesProc(svc)
    verify(p !== null)
    svc.lastError = ""
    svc.loadFiles(hh("a"))                              // widget load runs
    compare(p.running, true)
    compare(p.hash, hh("a"))
    svc.loadFiles(hh("b"), { origin: "window" })        // window load queues
    compare(p.nextHash, hh("b"))
    finish(p, 0, "[]", "")                              // a ends, b replays
    compare(p.running, true)
    compare(p.hash, hh("b"))
    compare(svc.filesQuietHashes[hh("b")], true, "the replay keeps the window origin")
    finish(p, 1, "", "HTTP 403")                        // b fails
    compare(svc.lastError, "", "a window load's failure stays out of the widget's lastError")
    compare(svc.filesStatusByHash[hh("b")].state, "error")
    compare(svc.filesStatusByHash[hh("b")].error, "HTTP 403")
    // control: a widget load's failure still reaches lastError
    svc.loadFiles(hh("c"))
    finish(p, 1, "", "HTTP 500")
    compare(svc.lastError, "HTTP 500")
  }

  function test_window_copy_while_busy_returns_zero() {
    var svc = createTemporaryObject(serviceComp, tc)
    var row = { hash: hh("a") }
    var t = svc.copyMagnet(row, { origin: "window", hashes: [hh("a")] })
    verify(t > 0)
    compare(svc.copyMagnet(row, { origin: "window", hashes: [hh("a")] }), 0, "busy: refused")
    compare(svc.actionStatus, "")
  }

  // --- inspect store ---------------------------------------------------

  // The Sidecar Scope among svc's children (unique property: attemptOpen).
  function sidecarObj(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.attemptOpen !== undefined) return o
    }
    return null
  }
  // The stub Process wrapped by the Sidecar (unique property: stdinEnabled).
  function sidecarWire(svc) {
    var sc = sidecarObj(svc)
    if (!sc) return null
    for (var i = 0; i < sc.data.length; i++) {
      var o = sc.data[i]
      if (o && o.stdinEnabled !== undefined) return o
    }
    return null
  }
  // Every {cmd:"watch",...} object written to the wire, in order.
  function watchWrites(wire) {
    var out = []
    var w = (wire && wire.writes) || []
    for (var i = 0; i < w.length; i++) {
      try {
        var obj = JSON.parse(w[i])
        if (obj && obj.cmd === "watch") out.push(obj)
      } catch (e) {}
    }
    return out
  }
  // Every object written to the wire whose cmd matches `name`, in order
  // (watchWrites above is the "watch"-only special case of this).
  function wireCmds(wire, name) {
    var out = []
    var w = (wire && wire.writes) || []
    for (var i = 0; i < w.length; i++) {
      try {
        var obj = JSON.parse(w[i])
        if (obj && obj.cmd === name) out.push(obj)
      } catch (e) {}
    }
    return out
  }
  function statusLine(hashes) {
    var rows = []
    for (var i = 0; i < hashes.length; i++) rows.push({ hash: hashes[i] })
    return JSON.stringify({ type: "status", torrents: rows })
  }

  function test_inspect_info_stores_props_and_pieces_null_keeps_pieces() {
    var svc = createTemporaryObject(serviceComp, tc)
    var h = hh("a")
    var key = h + "|info"
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "info", props: { name: "x" }, pieces: [0, 1] }))
    verify(svc.inspectByKey[key] !== undefined)
    compare(svc.inspectByKey[key].props.name, "x")
    compare(svc.inspectByKey[key].pieces, [0, 1])
    verify(svc.inspectByKey[key].at > 0)
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "info", props: { name: "y" }, pieces: null }))
    compare(svc.inspectByKey[key].props.name, "y", "props still update")
    compare(svc.inspectByKey[key].pieces, [0, 1], "pieces:null keeps the previous pieces")
  }

  function test_inspect_trackers_and_peers_store_under_their_own_keys() {
    var svc = createTemporaryObject(serviceComp, tc)
    var h = hh("a")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "trackers", trackers: [{ url: "u" }] }))
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "peers", peers: { "1.2.3.4:1": {} } }))
    compare(svc.inspectByKey[h + "|trackers"].trackers.length, 1)
    compare(Object.keys(svc.inspectByKey[h + "|peers"].peers).length, 1)
    verify(svc.inspectByKey[h + "|trackers"].peers === undefined, "keys don't leak across tabs")
  }

  function test_inspect_error_line_stores_sanitized_error() {
    var svc = createTemporaryObject(serviceComp, tc)
    var h = hh("a")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "peers", error: "HTTP 500 SID=deadbeef" }))
    var entry = svc.inspectByKey[h + "|peers"]
    verify(entry.error.indexOf("SID=") === -1, "sanitized like the files path")
    compare(entry.error.indexOf("HTTP 500"), 0)
  }

  function test_inspect_error_line_with_no_message_still_sets_a_truthy_error() {
    // A transport failure (e.g. connection reset) can sanitize to "": a
    // falsy entry.error would make a tab render kept-prior data as fresh.
    var svc = createTemporaryObject(serviceComp, tc)
    var h = hh("a")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "trackers", error: "" }))
    var entry = svc.inspectByKey[h + "|trackers"]
    verify(!!entry.error, "error stays truthy even with an empty message")
  }

  function test_inspect_error_keeps_prior_data_for_a_transient_failure() {
    var svc = createTemporaryObject(serviceComp, tc)
    var h = hh("a")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "info", props: { name: "x" }, pieces: null }))
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "info", error: "boom" }))
    var entry = svc.inspectByKey[h + "|info"]
    compare(entry.error, "boom")
    compare(entry.props.name, "x", "a transient failure doesn't blank the tab")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: h, tab: "info", props: { name: "z" }, pieces: null }))
    verify(svc.inspectByKey[h + "|info"].error === undefined, "a success line drops the stale error")
  }

  function test_prunes_inspect_entries_for_hashes_no_longer_in_torrents() {
    var svc = createTemporaryObject(serviceComp, tc)
    var a = hh("a"), b = hh("b")
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: a, tab: "info", props: {}, pieces: null }))
    svc.handleSidecarLine(JSON.stringify({ type: "inspect", hash: b, tab: "info", props: {}, pieces: null }))
    svc.applyStatus(JSON.stringify({ torrents: [{ hash: a }] }))
    verify(svc.inspectByKey[a + "|info"] !== undefined, "a is still in torrents")
    verify(svc.inspectByKey[b + "|info"] === undefined, "b left torrents and is dropped")
  }

  // Slice 3b Task 5: the share-limit chain the D8 confirm resolves through
  // (LimitsView.shareConfirm reads them off Service, as its `status`).
  function test_status_carries_category_limits_and_share_defaults() {
    var svc = createTemporaryObject(serviceComp, tc)
    compare(svc.categoryLimits, {})
    compare(svc.shareDefaults, { ratio: -1, seedingTime: -1, action: "Stop" })
    svc.applyStatus(JSON.stringify({ torrents: [],
      categoryLimits: { anime: { ratioLimit: 2, seedingTimeLimit: -2, shareLimitAction: "RemoveWithContent" } },
      shareDefaults: { ratio: 1.5, seedingTime: 120, action: "Remove" } }))
    compare(svc.categoryLimits.anime.shareLimitAction, "RemoveWithContent")
    compare(svc.categoryLimits.anime.ratioLimit, 2)
    compare(svc.shareDefaults, { ratio: 1.5, seedingTime: 120, action: "Remove" })
    svc.applyStatus(JSON.stringify({ torrents: [] }))
    compare(svc.categoryLimits, {})
    compare(svc.shareDefaults, { ratio: -1, seedingTime: -1, action: "Stop" })
  }

  // --- watch ------------------------------------------------------------

  function test_watch_sends_only_when_up_and_is_resent_on_up() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    verify(wire !== null)
    var h = hh("a")
    svc.watch(h, "trackers")
    compare(svc.watchedHash, h)
    compare(svc.watchedTab, "trackers")
    compare(watchWrites(wire).length, 0, "nothing sent while the sidecar is still starting")
    svc.handleSidecarLine(statusLine([h]))
    compare(svc.sidecarState, "up")
    var sent = watchWrites(wire)
    compare(sent.length, 1, "the watch is resent once the sidecar comes up (F11)")
    compare(sent[0].hash, h)
    compare(sent[0].tab, "trackers")
  }

  function test_watch_files_tab_sends_hash_null_with_tab_info() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    svc.watch(h, "files")
    var sent = watchWrites(wire)
    compare(sent.length, 1)
    compare(sent[0].hash, null)
    compare(sent[0].tab, "info")
  }

  function test_watch_skips_an_identical_resend() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    svc.watch(h, "info")
    compare(watchWrites(wire).length, 1)
    svc.watch(h, "info")
    compare(watchWrites(wire).length, 1, "an identical watch is not re-sent")
  }

  // A real sidecar restart (handleSidecarExit, not just flipping
  // sidecarState by hand): the exited sidecar's watch is gone with it, so
  // the same {hash, tab} must be resent once the replacement's first
  // status line arrives (F11), across every sidecar tab.
  function test_watch_is_resent_after_a_real_sidecar_restart() {
    var tabs = ["info", "trackers", "peers"]
    for (var i = 0; i < tabs.length; i++) {
      var svc = createTemporaryObject(serviceComp, tc)
      var wire = sidecarWire(svc)
      var h = hh("a")
      svc.handleSidecarLine(statusLine([h]))     // sidecar up
      svc.watch(h, tabs[i])
      compare(watchWrites(wire).length, 1, "one watch while up, tab " + tabs[i])
      // The real exit path: both active and started are true in the
      // harness (Component.onCompleted already called start()), so the
      // guard at the top of handleSidecarExit lets it run for real.
      svc.handleSidecarExit(1)
      compare(svc.sidecarState, "starting", "a first failure keeps retrying rather than giving up, tab " + tabs[i])
      svc.handleSidecarLine(statusLine([h]))     // the restarted sidecar's first status line
      var sent = watchWrites(wire)
      compare(sent.length, 2, "the watch is resent once the restarted sidecar comes back up, tab " + tabs[i])
      compare(sent[1].hash, h, "tab " + tabs[i])
      compare(sent[1].tab, tabs[i], "tab " + tabs[i])
    }
  }

  // The minor fix: the resend gate looks at the *effective* watch (whose
  // hash is null for a Files-tab watch), not the raw watchedHash, so a
  // restart while the Files tab is showing doesn't re-clear a watch that
  // was already clear.
  function test_watch_files_tab_is_not_resent_after_a_restart() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    svc.watch(h, "files")
    compare(watchWrites(wire).length, 1, "the initial files-tab watch still clears once")
    svc.handleSidecarExit(1)
    svc.handleSidecarLine(statusLine([h]))
    compare(watchWrites(wire).length, 1, "no pointless resend for a Files-tab watch after a restart")
  }

  function test_window_open_false_clears_the_watch_with_no_client() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    svc.watch(h, "peers")
    wire.writes = []                    // drain to a known point
    svc.windowOpen = true
    svc.windowOpen = false
    var sent = watchWrites(wire)
    compare(sent.length, 1, "closing the window sends exactly one clearing watch")
    var last = sent[0]
    compare(last.hash, null, "closing the window clears the watch itself")
    verify(last.tab === "info" || last.tab === "trackers" || last.tab === "peers" || last.tab === "chart", "the clearing watch still carries a valid tab")
  }

  // --- copyText -----------------------------------------------------------

  function test_copy_text_from_window_returns_a_ticket_and_runs_wl_copy() {
    var svc = createTemporaryObject(serviceComp, tc)
    var spy = spyOn(svc)
    var t = svc.copyText("https://tracker.example/announce?passkey=abc123", { origin: "window", hashes: [] })
    verify(t > 0)
    var p = null
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.command && o.command[0] === "wl-copy") p = o
    }
    verify(p !== null)
    compare(p.command, ["wl-copy", "--", "https://tracker.example/announce?passkey=abc123"])
    // copyProcess has no stdout collector (only stderr), unlike finish()'s
    // assumption -- end it directly.
    p.running = false
    p.exited(0, 0)
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], true)
    compare(spy.signalArguments[0][3], "window")
  }

  // --- inspector write helpers (slice 2b, Task 3) ----------------------------

  function test_inspector_helpers_run_their_qbt_argv_as_window_tickets() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var h = hh("a")
    var url = "https://tracker.example/announce?passkey=abc123&x=1"
    var cases = [
      { call: function(opts) { return svc.reannounce(h, opts) }, argv: ["reannounce", h] },
      { call: function(opts) { return svc.addTracker(h, url, opts) }, argv: ["tracker-add", h, url] },
      { call: function(opts) { return svc.editTracker(h, url, "udp://t2.example:1337/announce", opts) }, argv: ["tracker-edit", h, url, "udp://t2.example:1337/announce"] },
      { call: function(opts) { return svc.removeTracker(h, url, opts) }, argv: ["tracker-remove", h, url] },
      { call: function(opts) { return svc.banPeer("203.0.113.42:6881", opts) }, argv: ["ban-peer", "203.0.113.42:6881"] },
      { call: function(opts) { return svc.fetchMetadata(h, opts) }, argv: ["fetch-metadata", h] }
    ]
    svc.actionStatus = "widget status"
    for (var i = 0; i < cases.length; i++) {
      var t = cases[i].call({ origin: "window", hashes: [h] })
      verify(t > 0, cases[i].argv[0] + " returns a ticket")
      compare(p.command, [svc.helperPath].concat(cases[i].argv))
      compare(svc.actionStatus, "widget status", "a window action leaves the widget's status alone")
      finish(p, 0, "{\"ok\":true}", "")
      compare(spy.count, i + 1)
      compare(spy.signalArguments[i][0], t)
      compare(spy.signalArguments[i][1], true)
      compare(spy.signalArguments[i][3], "window")
      compare(spy.signalArguments[i][4], [h])
    }
    // qbt's refusal comes back as the ticket's (sanitized) error.
    var tf = svc.removeTracker(h, "udp://a.example/x|y", { origin: "window", hashes: [h] })
    finish(p, 1, "", "This tracker's URL can't be edited through the WebUI API")
    compare(spy.signalArguments[cases.length][0], tf)
    compare(spy.signalArguments[cases.length][1], false)
    compare(spy.signalArguments[cases.length][2], "This tracker's URL can't be edited through the WebUI API")
  }

  function test_inspector_helpers_refuse_missing_arguments_without_running() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    var w = { origin: "window", hashes: [] }
    compare(svc.reannounce("", w), 0)
    compare(svc.addTracker(h, "", w), 0)
    compare(svc.addTracker("", "udp://a.example:1/", w), 0)
    compare(svc.editTracker(h, "", "udp://a.example:1/", w), 0)
    compare(svc.editTracker(h, "udp://a.example:1/", "", w), 0)
    compare(svc.removeTracker(h, "", w), 0)
    compare(svc.banPeer("", w), 0)
    compare(svc.fetchMetadata("", w), 0)
    compare(p.running, false, "nothing ran")
    compare(svc.currentAction, null)
  }

  function test_inspector_helper_queues_behind_a_running_action() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    svc.recheckHash(h, { origin: "window", hashes: [h] })
    var t = svc.reannounce(h, { origin: "window", hashes: [h] })
    verify(t > 0, "a queued helper still returns its ticket")
    compare(p.command[1], "recheck")
    finish(p, 0, "", "")
    compare(p.command, [svc.helperPath, "reannounce", h], "it runs once the first one ends")
  }

  // --- library helpers (slice 3a, Task 3) -------------------------------------

  function test_library_helpers_run_their_qbt_argv_as_window_tickets() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var h = hh("a"), h2 = hh("b")
    var list = h + "|" + h2
    var cases = [
      { call: function(w) { return svc.addCategory("anime", "", w) }, argv: ["category-add", "anime"] },
      { call: function(w) { return svc.addCategory("anime", "~/Videos/anime", w) }, argv: ["category-add", "anime", "~/Videos/anime"] },
      { call: function(w) { return svc.setCategoryPath("anime", "/srv/anime", w) }, argv: ["category-path", "anime", "/srv/anime"] },
      { call: function(w) { return svc.setCategoryPath("anime", "", w) }, argv: ["category-path", "anime", ""] },
      { call: function(w) { return svc.removeCategory("anime/2026", w) }, argv: ["category-remove", "anime/2026"] },
      { call: function(w) { return svc.renameCategory("anime", "animation", false, w) }, argv: ["category-rename", "anime", "animation"] },
      { call: function(w) { return svc.renameCategory("anime", "animation", true, w) }, argv: ["category-rename", "anime", "animation", "--merge"] },
      { call: function(w) { return svc.setCategory(list, "anime", w) }, argv: ["set-category", list, "anime"] },
      { call: function(w) { return svc.setCategory([h, h2], "", w) }, argv: ["set-category", list, ""] },
      { call: function(w) { return svc.setCategory("|" + h + "||" + h2 + "|", "anime", w) }, argv: ["set-category", list, "anime"] },
      { call: function(w) { return svc.addTag("anime 2026", w) }, argv: ["tag-add", "anime 2026"] },
      { call: function(w) { return svc.removeTag("seedbox", w) }, argv: ["tag-remove", "seedbox"] },
      { call: function(w) { return svc.renameTag("seedbox", "sb", false, w) }, argv: ["tag-rename", "seedbox", "sb"] },
      { call: function(w) { return svc.renameTag("seedbox", "sb", true, w) }, argv: ["tag-rename", "seedbox", "sb", "--merge"] },
      { call: function(w) { return svc.editTags(list, { add: ["keep", "new one"], remove: ["seedbox"] }, w) },
        argv: ["tags", list, "--add", "keep", "--add", "new one", "--remove", "seedbox"] },
      { call: function(w) { return svc.editTags(h, { add: [], remove: ["seedbox"] }, w) }, argv: ["tags", h, "--remove", "seedbox"] },
      { call: function(w) { return svc.editTags(h, { add: ["keep"] }, w) }, argv: ["tags", h, "--add", "keep"] }
    ]
    svc.actionStatus = "widget status"
    for (var i = 0; i < cases.length; i++) {
      var t = cases[i].call({ origin: "window", hashes: [h] })
      verify(t > 0, cases[i].argv[0] + " returns a ticket")
      compare(p.command, [svc.helperPath].concat(cases[i].argv))
      compare(svc.actionStatus, "widget status", "a window action leaves the widget's status alone")
      finish(p, 0, "{\"ok\":true}", "")
      compare(spy.count, i + 1)
      compare(spy.signalArguments[i][0], t)
      compare(spy.signalArguments[i][1], true)
      compare(spy.signalArguments[i][3], "window")
      compare(spy.signalArguments[i][4], [h])
    }
    // Deviation 1: an incomplete rename's own text comes back as the error.
    var tf = svc.renameCategory("anime", "animation", false, { origin: "window", hashes: [] })
    finish(p, 1, "", "Rename incomplete (12 of 21 moved); press c on anime again to finish.")
    compare(spy.signalArguments[cases.length][0], tf)
    compare(spy.signalArguments[cases.length][1], false)
    compare(spy.signalArguments[cases.length][2], "Rename incomplete (12 of 21 moved); press c on anime again to finish.")
  }

  function test_library_helpers_refuse_missing_arguments_without_running() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    var w = { origin: "window", hashes: [] }
    compare(svc.addCategory("", "", w), 0)
    compare(svc.setCategoryPath("", "/srv", w), 0)
    compare(svc.removeCategory("", w), 0)
    compare(svc.renameCategory("", "b", false, w), 0)
    compare(svc.renameCategory("a", "", false, w), 0)
    compare(svc.setCategory("", "anime", w), 0)
    compare(svc.setCategory([], "anime", w), 0)
    compare(svc.setCategory("||", "anime", w), 0)
    compare(svc.addTag("", w), 0)
    compare(svc.removeTag("", w), 0)
    compare(svc.renameTag("", "b", false, w), 0)
    compare(svc.renameTag("a", "", false, w), 0)
    compare(svc.editTags("", { add: ["keep"], remove: [] }, w), 0)
    compare(svc.editTags(h, { add: [], remove: [] }, w), 0, "no change runs nothing")
    compare(svc.editTags(h, null, w), 0)
    compare(p.running, false, "nothing ran")
    compare(svc.currentAction, null)
  }

  function test_library_widget_origin_sets_its_status_text() {
    var o = idleService(), svc = o.svc, p = o.p
    svc.renameCategory("anime", "animation", false)
    compare(svc.actionStatus, "Renaming anime → animation…")
    finish(p, 0, "{\"ok\":true}", "")
    svc.removeTag("seedbox")
    compare(svc.actionStatus, "Deleting tag…")
    finish(p, 0, "{\"ok\":true}", "")
  }

  // --- per-torrent limit helpers (slice 3b, Task 2) ------------------------

  function test_limit_helpers_run_their_qbt_argv_as_window_tickets() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var h = hh("a"), h2 = hh("b")
    var list = h + "|" + h2
    var cases = [
      { call: function(w) { return svc.setShareLimits(list, { ratio: "1.5" }, false, w) }, argv: ["share-limits", list, "--ratio", "1.5"] },
      { call: function(w) { return svc.setShareLimits(list, { seedingTime: "60" }, false, w) }, argv: ["share-limits", list, "--seed-time", "60"] },
      { call: function(w) { return svc.setShareLimits(list, { ratio: "-2", seedingTime: "-1" }, false, w) }, argv: ["share-limits", list, "--ratio", "-2", "--seed-time", "-1"] },
      { call: function(w) { return svc.setShareLimits(list, { ratio: "2" }, true, w) }, argv: ["share-limits", list, "--ratio", "2", "--force"] },
      { call: function(w) { return svc.setShareLimits("|" + h + "||" + h2 + "|", { ratio: "1" }, false, w) }, argv: ["share-limits", list, "--ratio", "1"] },
      { call: function(w) { return svc.setSequential(list, true, w) }, argv: ["sequential", list, "on"] },
      { call: function(w) { return svc.setSequential(h, false, w) }, argv: ["sequential", h, "off"] },
      { call: function(w) { return svc.setFirstLast(list, true, w) }, argv: ["first-last", list, "on"] },
      { call: function(w) { return svc.setFirstLast(h, false, w) }, argv: ["first-last", h, "off"] },
      { call: function(w) { return svc.setSpeedLimit(list, "dl", 1048576, w) }, argv: ["limit", list, "dl", "1048576"] },
      { call: function(w) { return svc.setSpeedLimit(h, "up", 0, w) }, argv: ["limit", h, "up", "0"] }
    ]
    svc.actionStatus = "widget status"
    for (var i = 0; i < cases.length; i++) {
      var t = cases[i].call({ origin: "window", hashes: [h] })
      verify(t > 0, cases[i].argv[0] + " returns a ticket")
      compare(p.command, [svc.helperPath].concat(cases[i].argv))
      compare(svc.actionStatus, "widget status", "a window action leaves the widget's status alone")
      finish(p, 0, "{\"ok\":true}", "")
      compare(spy.count, i + 1)
      compare(spy.signalArguments[i][0], t)
      compare(spy.signalArguments[i][1], true)
      compare(spy.signalArguments[i][3], "window")
      compare(spy.signalArguments[i][4], [h])
    }
    // qbt's D8 guard refusal comes back as the ticket's (sanitized) error.
    var tf = svc.setShareLimits(h, { ratio: "5" }, false, { origin: "window", hashes: [h] })
    finish(p, 1, "", "1 torrent already meets that limit, and qBittorrent would remove it.")
    compare(spy.signalArguments[cases.length][0], tf)
    compare(spy.signalArguments[cases.length][1], false)
    compare(spy.signalArguments[cases.length][2], "1 torrent already meets that limit, and qBittorrent would remove it.")
  }

  function test_limit_helpers_refuse_missing_arguments_without_running() {
    var o = idleService(), svc = o.svc, p = o.p
    var w = { origin: "window", hashes: [] }
    var h = hh("a")
    compare(svc.setShareLimits("", { ratio: "1" }, false, w), 0)
    compare(svc.setShareLimits([], { ratio: "1" }, false, w), 0)
    compare(svc.setShareLimits("||", { ratio: "1" }, false, w), 0)
    compare(svc.setShareLimits(h, {}, false, w), 0, "no ratio and no seed time runs nothing")
    compare(svc.setShareLimits(h, null, false, w), 0)
    compare(svc.setSequential("", true, w), 0)
    compare(svc.setFirstLast("", true, w), 0)
    compare(svc.setSpeedLimit("", "dl", 1048576, w), 0)
    compare(p.running, false, "nothing ran")
    compare(svc.currentAction, null)
  }

  function test_limit_helper_widget_origin_sets_its_status_text() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    svc.setShareLimits(h, { ratio: "1" }, false)
    verify(svc.actionStatus.length > 0)
    finish(p, 0, "{\"ok\":true}", "")
    svc.setSequential(h, true)
    verify(svc.actionStatus.length > 0)
    finish(p, 0, "{\"ok\":true}", "")
  }

  // LibraryView.js is node-tested; this proves QML's engine loads it and
  // runs its code-point handling the same way.
  function test_library_view_loads_under_qml() {
    compare(Library.nameError("tag", "\u00a0anime", []), "No spaces at the start or end.")
    compare(Library.nameError("category", "anime", ["anime"]), "\"anime\" already exists.")
    var emoji = ""
    for (var i = 0; i < 65; i++) emoji += "\ud83d\ude00"
    compare(Library.nameError("tag", emoji, []), "Keep it to 64 characters.")
    compare(Library.nameError("tag", "a\u0085", []), "No control characters in a name.")
    compare(Library.movePlan({ kind: "remove", name: "anime" },
      [{ hash: hh("a"), category: "anime", autoTmm: true, savePath: "/dl/anime" }],
      { defaultSavePath: "/dl", categoryPaths: {}, relocation: { torrentChanged: true, categoryPathChanged: false } }),
      [{ hash: hh("a"), from: "/dl/anime", to: "/dl" }])
  }

  // ---- slice 3b, Task 6: the widget ------------------------------------------------

  // The widget's ratio row runs `sharelimit`; when qbt's D8 guard refuses,
  // its sentence is the widget's lastError (Panel shows lastError).
  function test_widget_ratio_row_shows_qbts_guard_refusal() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    svc.setShareRatio(h, 1)
    compare(p.command, [svc.helperPath, "sharelimit", h, "1"])
    finish(p, 1, "", "1 torrent already meets that limit, and qBittorrent would remove it with its files.\n")
    compare(svc.lastError, "1 torrent already meets that limit, and qBittorrent would remove it with its files.")
    compare(svc.actionStatus, "")
  }

  // Ruling CF: setSequential takes an optional status text; the widget
  // passes "" and gets no new status line, the window keeps today's text.
  function test_setSequential_takes_an_optional_status_text() {
    var o = idleService(), svc = o.svc, p = o.p
    var h = hh("a")
    svc.actionStatus = ""
    svc.setSequential(h, true, undefined, "")
    compare(p.command, [svc.helperPath, "sequential", h, "on"])
    compare(svc.actionStatus, "", "the widget's click shows no new status text")
    finish(p, 0, "{\"ok\":true}", "")
    svc.setSequential(h, false)
    compare(p.command, [svc.helperPath, "sequential", h, "off"])
    compare(svc.actionStatus, "Setting sequential download…", "without the argument, today's text")
    finish(p, 0, "{\"ok\":true}", "")
  }

  // ---- slice 4a, Task 3: Service reads and writes preferences -----------

  function test_readPrefs_success_calls_back_with_the_parsed_object() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    verify(p !== null)
    var got = null
    svc.readPrefs(function(result) { got = result })
    compare(p.running, true)
    compare(p.command, [svc.helperPath, "prefs"])
    finish(p, 0, "{\"save_path\":\"/x\",\"web_ui_api_key\":{\"set\":true}}", "")
    verify(got !== null)
    compare(got.ok, true)
    compare(got.prefs.save_path, "/x")
    compare(got.prefs.web_ui_api_key, { set: true })
  }

  function test_readPrefs_nonzero_exit_uses_the_stderr_last_line() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var got = null
    svc.readPrefs(function(result) { got = result })
    finish(p, 1, "", "some warning on the way out\nqBittorrent is not reachable\n")
    compare(got.ok, false)
    compare(got.error, "qBittorrent is not reachable")
  }

  function test_readPrefs_malformed_stdout_is_a_read_error() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var got = null
    svc.readPrefs(function(result) { got = result })
    finish(p, 0, "not json", "")
    compare(got.ok, false)
    verify(got.error.length > 0)
  }

  function test_readPrefs_empty_stdout_is_a_read_error() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var got = null
    svc.readPrefs(function(result) { got = result })
    finish(p, 0, "", "")
    compare(got.ok, false)
    verify(got.error.length > 0)
  }

  // Overlapping calls: readPrefs queues rather than coalesces, so a second
  // caller who asks while the first is still in flight still gets its own
  // answer once its own run finishes (nobody's callback is ever dropped).
  function test_readPrefs_overlapping_calls_are_each_answered_in_turn() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var first = null, second = null
    var firstCalls = 0, secondCalls = 0
    svc.readPrefs(function(result) { first = result; firstCalls++ })
    svc.readPrefs(function(result) { second = result; secondCalls++ })
    compare(p.running, true, "only one run is in flight")
    finish(p, 0, "{\"save_path\":\"/one\"}", "")
    verify(first !== null, "the first caller is answered once its run ends")
    compare(first.prefs.save_path, "/one")
    verify(second === null, "the second caller's run hasn't happened yet")
    compare(p.running, true, "the queued call started its own run")
    compare(p.command, [svc.helperPath, "prefs"])
    finish(p, 0, "{\"save_path\":\"/two\"}", "")
    verify(second !== null)
    compare(second.prefs.save_path, "/two")
    // finish() flips running false (arming the failed-start guard's
    // Qt.callLater) immediately before exited fires; drain the event loop
    // and confirm that guard never fires a second, stale answer for
    // either caller once the real exit has already handled it.
    wait(0)
    compare(firstCalls, 1, "a normal exit's failed-start guard never double-fires")
    compare(secondCalls, 1, "a normal exit's failed-start guard never double-fires")
  }

  // The helper itself can't start at all (missing, not executable): no
  // exited, only running going false. Mirrors
  // test_failed_start_finishes_a_widget_action_and_pumps for actionProcess.
  function test_readPrefs_failed_start_answers_could_not_run_and_starts_the_next_queued_call() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var first = null, second = null
    svc.readPrefs(function(result) { first = result })
    svc.readPrefs(function(result) { second = result })  // queued behind the first
    p.running = false                      // no exited: the helper never ran
    tryCompare(p, "running", true, 5000)   // the queued call starts once the guard finishes the first
    verify(first !== null)
    compare(first.ok, false)
    compare(first.error, "Could not run the qbt helper")
    verify(second === null, "the queued call hasn't finished yet")
    compare(p.command, [svc.helperPath, "prefs"])
    finish(p, 0, "{\"save_path\":\"/two\"}", "")
    verify(second !== null)
    compare(second.prefs.save_path, "/two")
  }

  // Fix round 1, the critical race: readPrefs's overlap guard checked only
  // prefsProcess.running, which is already false during the failed-start
  // window (running false, cb still set, no exited yet -- the same window
  // test_readPrefs_failed_start_answers_could_not_run_and_starts_the_next_queued_call
  // exercises from the other end). A second call landing in that exact
  // window used to see running === false and start directly, silently
  // overwriting prefsProcess.cb and losing the first caller's answer for
  // good. The fix also guards on prefsProcess.cb !== null.
  function test_readPrefs_second_call_in_the_failed_start_window_does_not_drop_the_first() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var first = null, second = null
    var firstCalls = 0, secondCalls = 0
    svc.readPrefs(function(result) { first = result; firstCalls++ })
    p.running = false                       // no exited: the helper never ran
    // Before the fix this call would see p.running already false and call
    // startPrefsRead(cb2) directly, clobbering prefsProcess.cb (still the
    // first caller's callback, pending its own deferred guard) and running
    // its own command over it -- the first caller's callback then never
    // fires at all.
    svc.readPrefs(function(result) { second = result; secondCalls++ })
    compare(p.command, [svc.helperPath, "prefs"], "not yet overwritten by the second call")
    wait(0)
    compare(firstCalls, 1, "the first caller is still answered exactly once")
    compare(first.ok, false)
    compare(first.error, "Could not run the qbt helper")
    compare(secondCalls, 0, "the second caller's own run has only just started")
    compare(p.running, true, "the queued second call started its own run once the first was answered")
    finish(p, 0, "{\"save_path\":\"/two\"}", "")
    compare(secondCalls, 1, "the second caller is answered exactly once, from its own run")
    compare(second.ok, true)
    compare(second.prefs.save_path, "/two")
  }

  // ---- Fix round 1, Ruling DK: readPrefs across the Service lifecycle ---

  // An inactive Service (the local-fallback case, Service.qml's own header
  // comment) starts no Process at all, for readPrefs same as every other
  // one-shot read here -- but unlike a fire-and-forget bash refresh, a
  // callback-based read must still always answer, just with this error
  // instead, asynchronously so a caller never sees it called reentrantly.
  function test_readPrefs_on_an_inactive_service_answers_without_starting_a_process() {
    var svc = createTemporaryObject(serviceComp, tc, { active: false })
    compare(svc.started, false)
    var p = prefsProc(svc)
    var got = null, calls = 0
    svc.readPrefs(function(result) { got = result; calls++ })
    compare(p.running, false, "an inactive Service starts no Process at all")
    compare(calls, 0, "the callback is deferred, never called synchronously")
    wait(0)
    compare(calls, 1)
    compare(got.ok, false)
    compare(got.error, "qBittorrent isn't running.")
    compare(p.running, false, "still no Process, even once answered")
  }

  // stop() drains prefsQueue: a call already queued behind an in-flight
  // run when the Service stops must not be left waiting on a pump that
  // may never come (or, worse, resolve stale once memory later starts a
  // fresh service and calls pump). The run already in flight on
  // prefsProcess itself is untouched by stop() and still answers for real
  // once it exits, same as any other in-flight bash Process here.
  function test_stop_drains_the_prefs_queue_with_the_not_running_error() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    var first = null, second = null
    svc.readPrefs(function(result) { first = result })    // starts a run
    svc.readPrefs(function(result) { second = result })   // queued behind it
    compare(p.running, true)
    svc.stop()
    compare(svc.prefsQueue.length, 0, "the queue is drained synchronously by stop()")
    verify(second === null, "answered asynchronously, not yet")
    wait(0)
    verify(second !== null)
    compare(second.ok, false)
    compare(second.error, "qBittorrent isn't running.")
    verify(first === null, "the run already in flight when stop() was called is untouched")
    finish(p, 0, "{\"save_path\":\"/x\"}", "")
    verify(first !== null, "and still answers for real once it exits")
    compare(first.ok, true)
    compare(first.prefs.save_path, "/x")
  }

  // Defensive belt for the same invariant, exercised directly: whatever
  // reaches pumpPrefsQueue while stopped (stop() itself already drains the
  // queue, so this only matters if something else ever leaves it
  // non-empty) starts no new Process, and still answers rather than drops
  // the callback.
  function test_pumpPrefsQueue_starts_no_new_run_once_stopped() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = prefsProc(svc)
    svc.stop()
    var got = null
    svc.prefsQueue = [function(result) { got = result }]
    svc.pumpPrefsQueue()
    compare(p.running, false, "no new run starts once stopped")
    wait(0)
    verify(got !== null, "the callback is still answered, never dropped")
    compare(got.ok, false)
    compare(got.error, "qBittorrent isn't running.")
  }

  function test_setPref_runs_a_ticketed_pref_set_with_dash_dash() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var t = svc.setPref("listen_port", "6881", { origin: "window", hashes: [] })
    verify(t > 0)
    compare(p.command, [svc.helperPath, "pref-set", "listen_port", "--", "6881"])
    finish(p, 0, "{\"ok\":true}", "")
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], true)
    compare(spy.signalArguments[0][3], "window")
  }

  function test_setPref_shows_saving_status_for_the_widget() {
    var o = idleService(), svc = o.svc, p = o.p
    svc.setPref("scan_dirs", "{}")
    compare(p.command, [svc.helperPath, "pref-set", "scan_dirs", "--", "{}"])
    compare(svc.actionStatus, "Saving setting…")
    finish(p, 0, "{\"ok\":true}", "")
  }

  function test_setPref_passes_a_composite_HHMM_value_through_as_a_string() {
    var o = idleService(), svc = o.svc, p = o.p
    svc.setPref("schedule_from", "23:30")
    compare(p.command, [svc.helperPath, "pref-set", "schedule_from", "--", "23:30"])
    finish(p, 0, "{\"ok\":true}", "")
  }

  function test_setPref_reports_qbts_refusal_as_the_tickets_error() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var t = svc.setPref("web_ui_port", "9090", { origin: "window", hashes: [] })
    finish(p, 1, "", "qBittorrent ignored Listening port")
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], false)
    compare(spy.signalArguments[0][2], "qBittorrent ignored Listening port")
  }

  function test_setPref_refuses_an_empty_key_without_running() {
    var o = idleService(), svc = o.svc, p = o.p
    compare(svc.setPref("", "1"), 0)
    compare(p.running, false)
    compare(svc.currentAction, null)
  }

  // After every successful setPref, Service asks for a fresh preferences
  // read: refresh-slow to the sidecar when it's up, the existing bash
  // status refresh when it's down.
  function test_setPref_success_sends_refresh_slow_when_the_sidecar_is_up() {
    var o = idleService(), svc = o.svc, p = o.p
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    compare(svc.sidecarState, "up")
    var before = wireCmds(wire, "refresh-slow").length
    svc.setPref("listen_port", "6881")
    finish(p, 0, "{\"ok\":true}", "")
    var sent = wireCmds(wire, "refresh-slow")
    compare(sent.length, before + 1, "a refresh-slow is sent once the write succeeds")
    compare(wireCmds(wire, "refresh").length, 0, "not the plain refresh a sidecar-up write would otherwise get")
  }

  function test_setPref_success_runs_bash_status_when_the_sidecar_is_down() {
    var o = idleService(), svc = o.svc, p = o.p
    // "down" is a plain property here; driving it there for real (5 failed
    // handleSidecarExit calls) is exercised by the sidecar-lifecycle tests
    // above and would only add an unrelated "gave up" warning to this one.
    svc.sidecarState = "down"
    svc.setPref("listen_port", "6881", { origin: "window", hashes: [] })
    compare(p.command, [svc.helperPath, "pref-set", "listen_port", "--", "6881"])
    finish(p, 0, "{\"ok\":true}", "")
    var sp = actionProc(svc, "status")
    verify(sp !== null, "the bash status refresh ran")
    compare(sp.running, true)
  }

  function test_setPref_failure_sends_no_refresh_slow() {
    var o = idleService(), svc = o.svc, p = o.p
    var wire = sidecarWire(svc)
    var h = hh("a")
    svc.handleSidecarLine(statusLine([h]))
    svc.setPref("listen_port", "6881")
    finish(p, 1, "", "qBittorrent ignored Listening port")
    compare(wireCmds(wire, "refresh-slow").length, 0, "a failed write asks for nothing fresh")
  }

  // ---- slice 4b: secrets, the ban list and list writes (Task 3) ------------------

  // The secret Process (unique property: secretKey).
  function secretProc(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.secretKey !== undefined) return o
    }
    return null
  }
  Component { id: secretSpyComp; SignalSpy { signalName: "secretFinished" } }
  function secretSpy(svc) { var sp = createTemporaryObject(secretSpyComp, tc); sp.target = svc; return sp }
  readonly property string secretValue: " hunter2 \\ \u{1F98A} "
  // Every Process under the Service: none may carry the value in argv.
  function argvHolds(svc, value) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (!o || o.command === undefined) continue
      var cmd = o.command || []
      for (var j = 0; j < cmd.length; j++) if (String(cmd[j]).indexOf(value) !== -1) return true
    }
    return false
  }

  function test_setSecret_runs_its_own_process_and_writes_stdin_only_once_started() {
    var o = idleService(), svc = o.svc, p = o.p
    var q = secretProc(svc)
    verify(q !== null, "a Process of its own")
    var spy = secretSpy(svc)
    var actions = spyOn(svc)
    var t = svc.setSecret("proxy_password", secretValue, { origin: "window", hashes: [] })
    verify(t > 0)
    compare(q.command, [svc.helperPath, "pref-set", "proxy_password", "--stdin"])
    compare(q.running, true)
    compare(q.stdinEnabled, true)
    compare(q.writes, [], "nothing is written before the process starts")
    compare(svc.actionQueue.length, 0, "never the action queue")
    compare(svc.currentAction, null)
    compare(p.running, false, "the action Process stays idle")
    verify(!argvHolds(svc, secretValue), "never in argv")
    q.started()
    compare(q.writes, [secretValue], "the value, exactly, with no newline")
    compare(q.stdinEnabled, false, "stdin is closed once written")
    q.started()
    compare(q.writes.length, 1, "written once")
    q.stdout.text = "{\"ok\":true}"
    q.running = false
    q.exited(0, 0)
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], true)
    compare(spy.signalArguments[0][2], "")
    compare(actions.count, 0, "not an actionFinished: the window's ticket arrives on secretFinished")
    compare(svc.lastError, "")
    compare(svc.actionStatus, "")
  }

  function test_setSecret_failure_reports_qbts_line_and_never_touches_lastError() {
    var o = idleService(), svc = o.svc
    var q = secretProc(svc)
    var spy = secretSpy(svc)
    var t = svc.setSecret("dyndns_password", secretValue, { origin: "window" })
    q.started()
    q.stderr.text = "Keep it to one line.\n"
    q.running = false
    q.exited(1, 0)
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], false)
    compare(spy.signalArguments[0][2], "Keep it to one line.")
    compare(svc.lastError, "")
  }

  function test_setSecret_that_never_starts_answers_could_not_run_and_drops_the_value() {
    var o = idleService(), svc = o.svc
    var q = secretProc(svc)
    var spy = secretSpy(svc)
    var t = svc.setSecret("proxy_password", secretValue, { origin: "window" })
    q.running = false
    wait(0)
    compare(spy.count, 1)
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], false)
    compare(spy.signalArguments[0][2], "Could not run the qbt helper")
    q.started()
    compare(q.writes, [], "a late started writes nothing: the value is gone")
    verify(svc.setSecret("proxy_password", "next", { origin: "window" }) > 0, "free for the next one")
  }

  function test_setSecret_refuses_while_one_runs_other_keys_and_a_stopped_service() {
    var o = idleService(), svc = o.svc
    var q = secretProc(svc)
    verify(svc.setSecret("proxy_password", "a", { origin: "window" }) > 0)
    compare(svc.setSecret("proxy_password", "b", { origin: "window" }), 0, "one at a time: busy")
    q.started()
    q.running = false
    q.exited(0, 0)
    for (var k of ["web_ui_password", "web_ui_api_key", "listen_port", ""]) {
      compare(svc.setSecret(k, "x", { origin: "window" }), 0, k)
    }
    compare(q.command[2], "proxy_password")
    var idle = createTemporaryObject(serviceComp, tc, { active: false })
    compare(idle.setSecret("proxy_password", "x", { origin: "window" }), 0, "an inactive Service starts nothing")
    compare(secretProc(idle).running, false)
  }

  function test_setSecret_success_asks_the_sidecar_for_fresh_preferences() {
    var o = idleService(), svc = o.svc
    var wire = sidecarWire(svc)
    svc.handleSidecarLine(statusLine([hh("a")]))
    var before = wireCmds(wire, "refresh-slow").length
    var q = secretProc(svc)
    svc.setSecret("proxy_password", "x", { origin: "window" })
    q.started()
    q.running = false
    q.exited(0, 0)
    compare(wireCmds(wire, "refresh-slow").length, before + 1)
    for (var i = 0; i < wire.writes.length; i++) verify(String(wire.writes[i]).indexOf("\"x\"") === -1)
  }

  function test_clearSecret_is_a_ticketed_pref_set_clear_for_the_three_secrets_only() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var t = svc.clearSecret("mail_notification_password", { origin: "window" })
    verify(t > 0)
    compare(p.command, [svc.helperPath, "pref-set", "mail_notification_password", "--clear"])
    finish(p, 0, "{\"ok\":true}", "")
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[0][1], true)
    compare(svc.clearSecret("web_ui_password", { origin: "window" }), 0)
    compare(svc.clearSecret("web_ui_api_key", { origin: "window" }), 0)
  }

  function test_banList_is_a_ticketed_ban_list_add_or_remove() {
    var o = idleService(), svc = o.svc, p = o.p
    var spy = spyOn(svc)
    var t = svc.banList("add", "2001:db8::1", { origin: "window" })
    compare(p.command, [svc.helperPath, "ban-list", "add", "2001:db8::1"])
    finish(p, 0, "{\"ok\":true}", "")
    var u = svc.banList("remove", "10.0.0.1", { origin: "window" })
    compare(p.command, [svc.helperPath, "ban-list", "remove", "10.0.0.1"])
    finish(p, 1, "", "10.0.0.1 isn't banned.")
    compare(spy.signalArguments[0][0], t)
    compare(spy.signalArguments[1][0], u)
    compare(spy.signalArguments[1][1], false)
    compare(spy.signalArguments[1][2], "10.0.0.1 isn't banned.")
    compare(svc.banList("drop", "10.0.0.1", { origin: "window" }), 0)
    compare(svc.banList("add", "", { origin: "window" }), 0)
  }

  // The value never lands in a Service property (or a property of one of
  // its Processes), on success or failure. The stub Process's `writes` is
  // its record of stdin, the one place it may be; it's checked apart.
  function holds(v, s, depth) {
    var d = depth === undefined ? 6 : depth
    if (v === null || v === undefined || d < 0) return false
    if (typeof v === "string") return v.indexOf(s) !== -1
    if (typeof v !== "object" || v.objectName !== undefined) return false
    for (var k in v) {
      var x
      try { x = v[k] } catch (e) { continue }
      if (holds(x, s, d - 1)) return true
    }
    return false
  }
  function sweepService(svc, s) {
    var hits = []
    var objs = [svc]
    for (var i = 0; i < svc.data.length; i++) objs.push(svc.data[i])
    for (var j = 0; j < objs.length; j++) {
      var o = objs[j]
      if (!o) continue
      for (var k in o) {
        if (k === "writes" || k === "data" || k === "parent") continue
        var v
        try { v = o[k] } catch (e) { continue }
        if (typeof v === "function") continue
        if (v && typeof v === "object" && v.objectName !== undefined) {
          // A collector (stdout/stderr): its text.
          if (typeof v.text === "string" && v.text.indexOf(s) !== -1) hits.push(j + "." + k + ".text")
          continue
        }
        if (holds(v, s)) hits.push(j + "." + k)
      }
    }
    return hits
  }

  function test_setSecret_leaves_the_value_in_no_service_property() {
    var o = idleService(), svc = o.svc
    compare(sweepService(svc, secretValue), [])
    svc.lastError = "x" + secretValue
    verify(sweepService(svc, secretValue).length > 0, "a planted value is caught")
    svc.lastError = ""
    var q = secretProc(svc)
    svc.setSecret("proxy_password", secretValue, { origin: "window" })
    compare(sweepService(svc, secretValue), [], "while it runs")
    q.started()
    compare(sweepService(svc, secretValue), [], "once written")
    compare(q.writes, [secretValue])
    q.stderr.text = "Keep it to one line."
    q.running = false
    q.exited(1, 0)
    compare(sweepService(svc, secretValue), [], "after a failure")
    svc.setSecret("proxy_password", secretValue, { origin: "window" })
    q.running = false
    wait(0)
    compare(sweepService(svc, secretValue), [], "after a run that never started")
  }
}
