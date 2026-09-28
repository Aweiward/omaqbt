import QtQuick
import QtTest
import "../../.."

// Slice 5a (Task 3): Service's Search side against stub Quickshell.Io
// processes (nothing is spawned): the two qbt search* lanes, the sidecar's
// search watch and its routed replies, and the detached opens (OV10).
TestCase {
  id: tc
  name: "ServiceSearch"

  Component { id: serviceComp; Service {} }
  Component { id: finishedSpy; SignalSpy { signalName: "searchFinished" } }
  Component { id: replySpy; SignalSpy { signalName: "searchReply" } }
  Component { id: lostSpy; SignalSpy { signalName: "searchWatchLost" } }
  function spy(comp, svc) { var s = createTemporaryObject(comp, tc); s.target = svc; return s }

  function lane(svc, name) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.searchLane === name) return o
    }
    return null
  }
  function openProc(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.command !== undefined && o.stdout === null && o.stderr === null && o.command.length > 2 && o.command[2] === "xdg-open") return o
    }
    return null
  }
  function finish(p, code, out, err) {
    p.stdout.text = out || ""
    p.stderr.text = err || ""
    p.running = false
    p.exited(code, 0)
  }
  function sidecarObj(svc) {
    for (var i = 0; i < svc.data.length; i++) if (svc.data[i] && svc.data[i].attemptOpen !== undefined) return svc.data[i]
    return null
  }
  function sidecarWire(svc) {
    var sc = sidecarObj(svc)
    for (var i = 0; i < sc.data.length; i++) if (sc.data[i] && sc.data[i].stdinEnabled !== undefined) return sc.data[i]
    return null
  }
  function searchWrites(wire) {
    var out = []
    for (var i = 0; i < wire.writes.length; i++) {
      var obj = JSON.parse(wire.writes[i])
      if (obj.cmd === "search") out.push(obj)
    }
    return out
  }
  function statusLine() { return JSON.stringify({ type: "status", torrents: [] }) }

  function test_each_lane_runs_one_at_a_time_in_order_with_argv_arrays() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(finishedSpy, svc)
    var jobs = lane(svc, "jobs"), plug = lane(svc, "plugins")
    var t1 = svc.searchStart("debian 13; rm -rf /", "all")
    var t2 = svc.searchDelete(7)
    var t3 = svc.searchPluginInstall("https://example.org/jackett.py")
    verify(t1 > 0 && t2 > t1 && t3 > t2)
    compare(jobs.command, [svc.helperPath, "search", "start", "--pattern", "debian 13; rm -rf /", "--category", "all"])
    compare(plug.command, [svc.helperPath, "search-plugin", "install", "https://example.org/jackett.py"], "the plugins lane doesn't wait for the jobs lane")
    finish(jobs, 0, "{\"id\":7}\n", "")
    compare(s.count, 1)
    compare(s.signalArguments[0][0], t1)
    compare(s.signalArguments[0][1], true)
    compare(s.signalArguments[0][3], { id: 7 })
    compare(jobs.command, [svc.helperPath, "search", "delete", "7"], "the queued delete starts next")
    finish(jobs, 1, "", "noise\nqBittorrent refused it (HTTP 500)\n")
    compare(s.signalArguments[1][0], t2)
    compare(s.signalArguments[1][1], false)
    compare(s.signalArguments[1][2], "qBittorrent refused it (HTTP 500)")
    finish(plug, 0, "not json", "")
    compare(s.signalArguments[2][0], t3)
    compare(s.signalArguments[2][1], true)
    compare(s.signalArguments[2][3], null, "unparsable stdout is null data")
  }

  function test_every_verb_has_its_argv() {
    var svc = createTemporaryObject(serviceComp, tc)
    var jobs = lane(svc, "jobs"), plug = lane(svc, "plugins")
    var h = svc.helperPath
    svc.searchStop(7);                       compare(jobs.command, [h, "search", "stop", "7"]); finish(jobs, 0, "{\"ok\":true}")
    svc.searchAdd("magnet:?xt=urn:btih:x", "");  compare(jobs.command, [h, "search", "add", "magnet:?xt=urn:btih:x"], "no empty plugin argument"); finish(jobs, 0, "")
    svc.searchAdd("https://e.org/d/1", "piratebay"); compare(jobs.command, [h, "search", "add", "https://e.org/d/1", "piratebay"]); finish(jobs, 0, "")
    svc.searchPluginList();                  compare(plug.command, [h, "search-plugin", "list"]); finish(plug, 0, "[]")
    svc.searchPluginUninstall("eztv");       compare(plug.command, [h, "search-plugin", "uninstall", "eztv"]); finish(plug, 0, "")
    svc.searchPluginEnable("eztv", true);    compare(plug.command, [h, "search-plugin", "enable", "eztv", "on"]); finish(plug, 0, "")
    svc.searchPluginEnable("eztv", false);   compare(plug.command, [h, "search-plugin", "enable", "eztv", "off"]); finish(plug, 0, "")
    svc.searchPluginUpdate();                compare(plug.command, [h, "search-plugin", "update"]); finish(plug, 0, "")
  }

  function test_a_run_that_never_starts_still_finishes() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(finishedSpy, svc)
    var jobs = lane(svc, "jobs")
    var t = svc.searchStop(3)
    jobs.running = false
    wait(20)
    compare(s.count, 1)
    compare(s.signalArguments[0][0], t)
    compare(s.signalArguments[0][2], "Could not run the qbt helper")
  }

  function test_the_watch_its_replies_and_a_restart() {
    var svc = createTemporaryObject(serviceComp, tc)
    var wire = sidecarWire(svc)
    var replies = spy(replySpy, svc)
    var lost = spy(lostSpy, svc)
    svc.handleSidecarLine(statusLine())
    verify(svc.searchWatch(7, 2))
    compare(searchWrites(wire), [{ cmd: "search", id: 7, offset: 2 }])
    // Routed by the Sidecar: a search reply never reaches handleSidecarLine.
    wire.stdout.read(JSON.stringify({ type: "search", id: 7, status: "Running", total: 3, offset: 2, rows: [{}], capped: false }))
    compare(replies.count, 1)
    compare(replies.signalArguments[0][0].total, 3)
    wire.stdout.read(JSON.stringify({ type: "search", id: 6, status: "Running", total: 3, offset: 0, rows: [], capped: false }))
    compare(replies.count, 1, "another job's reply is dropped")
    wire.stdout.read(JSON.stringify({ type: "status", torrents: [] }))
    compare(svc.sidecarState, "up", "status lines still go through")
    compare(lost.count, 0)
    svc.handleSidecarExit(1)
    svc.handleSidecarLine(statusLine())
    compare(lost.count, 1, "a restarted sidecar asks the window to re-send its watch")
    wire.stdout.read(JSON.stringify({ type: "search", id: 7, error: "gone" }))
    compare(replies.count, 2)
    compare(svc.searchWatchId, 0, "gone ends the watch")
    svc.searchWatch(8, 0)
    svc.searchUnwatch()
    var w = searchWrites(wire)
    compare(w[w.length - 1], { cmd: "search", id: null })
    svc.searchWatch(9, 0)
    svc.windowOpen = true
    svc.windowOpen = false
    w = searchWrites(wire)
    compare(w[w.length - 1], { cmd: "search", id: null }, "a closed window drops the watch")
  }

  function test_opens_are_detached_and_only_http() {
    var svc = createTemporaryObject(serviceComp, tc)
    verify(!svc.openUrl("javascript:alert(1)"))
    verify(!svc.openUrl("file:///etc/passwd"))
    verify(svc.openUrl("https://example.org/t/1"))
    var p = openProc(svc)
    verify(p !== null)
    compare(p.command, ["setsid", "-f", "xdg-open", "https://example.org/t/1"])
    p.running = false
    svc.openPath("/dl/x")
    compare(p.command, ["setsid", "-f", "xdg-open", "/dl/x"])
  }
}
