import QtQuick
import QtTest
import "../../.."

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
}
