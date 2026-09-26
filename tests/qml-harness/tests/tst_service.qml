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
