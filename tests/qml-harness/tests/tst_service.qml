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
