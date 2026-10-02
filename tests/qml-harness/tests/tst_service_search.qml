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

  // A private plugin's link can carry a passkey: it goes to qbt on stdin,
  // written once the child starts, never on argv.
  function test_search_add_puts_the_link_on_stdin() {
    var svc = createTemporaryObject(serviceComp, tc)
    var jobs = lane(svc, "jobs")
    var h = svc.helperPath
    var link = "https://tracker.example/download.php?id=7&passkey=SECRETpass123"
    svc.searchAdd(link, "jackett")
    compare(jobs.command, [h, "search", "add", "--stdin", "jackett"])
    verify(jobs.command.join(" ").indexOf("SECRETpass123") === -1, "no passkey on argv")
    verify(jobs.stdinEnabled, "stdin open for the link")
    jobs.started()
    compare(jobs.writes, [link])
    verify(!jobs.stdinEnabled, "stdin closed after the write")
    jobs.started()
    compare(jobs.writes, [link], "written once")
    // A second add queued behind the first writes its own link.
    var link2 = "magnet:?xt=urn:btih:" + "e".repeat(40) + "&tr=https%3A%2F%2Ft.example%2FSECRETtwo%2Fannounce"
    svc.searchAdd(link2, "")
    finish(jobs, 0, "{\"ok\":true,\"via\":\"add\"}")
    compare(jobs.command, [h, "search", "add", "--stdin"])
    verify(jobs.stdinEnabled, "the queued add opens stdin again")
    jobs.started()
    compare(jobs.writes, [link, link2])
    finish(jobs, 0, "{\"ok\":true,\"via\":\"add\"}")
    // A stop needs no stdin.
    svc.searchStop(7)
    verify(!jobs.stdinEnabled, "no stdin for a stop")
    finish(jobs, 0, "{\"ok\":true}")
  }

  // A search add that never starts hands the queued one its own link, and
  // writes nothing of its own.
  function test_a_failed_start_hands_the_next_search_add_its_own_link() {
    var svc = createTemporaryObject(serviceComp, tc)
    var jobs = lane(svc, "jobs")
    var first = "https://tracker.example/download.php?passkey=FIRSTsecret"
    var second = "https://tracker.example/download.php?passkey=SECONDsecret"
    svc.searchAdd(first, "")
    svc.searchAdd(second, "")
    jobs.running = false
    wait(0)
    verify(jobs.running, "the queued add started")
    verify(jobs.stdinEnabled, "with stdin open")
    jobs.started()
    compare(jobs.writes, [second])
    verify(!jobs.stdinEnabled)
    finish(jobs, 0, "{\"ok\":true,\"via\":\"add\"}")
  }

  function test_every_verb_has_its_argv() {
    var svc = createTemporaryObject(serviceComp, tc)
    var jobs = lane(svc, "jobs"), plug = lane(svc, "plugins")
    var h = svc.helperPath
    svc.searchStop(7);                       compare(jobs.command, [h, "search", "stop", "7"]); finish(jobs, 0, "{\"ok\":true}")
    svc.searchAdd("magnet:?xt=urn:btih:x", "");  compare(jobs.command, [h, "search", "add", "--stdin"], "no empty plugin argument"); finish(jobs, 0, "")
    svc.searchAdd("https://e.org/d/1", "piratebay"); compare(jobs.command, [h, "search", "add", "--stdin", "piratebay"]); finish(jobs, 0, "")
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

  // W1: the window is rebuilt on every toggle, so a start it gave up on
  // (it closed) is Service's to clean up: its job is deleted once its id
  // arrives, whether it was running or still queued at the close.
  function test_a_start_the_closed_window_gave_up_on_is_deleted() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(finishedSpy, svc)
    var jobs = lane(svc, "jobs")
    var h = svc.helperPath
    svc.windowOpen = true
    var t1 = svc.searchStart("one", "all")
    var t2 = svc.searchStart("two", "all")
    svc.windowOpen = false
    svc.windowOpen = true
    var t3 = svc.searchStart("three", "all")
    finish(jobs, 0, "{\"id\":3}\n", "")
    compare(s.signalArguments[0][0], t1, "the start still reports")
    compare(jobs.command, [h, "search", "start", "--pattern", "two", "--category", "all"], "the queued start runs next")
    compare(svc.searchJobQueue.length, 2, "then the new start, then the delete")
    compare(svc.searchJobQueue[1].cmd, [h, "search", "delete", "3"], "the running start's job is deleted")
    finish(jobs, 0, "{\"id\":4}\n", "")
    compare(s.signalArguments[1][0], t2)
    compare(jobs.command, [h, "search", "start", "--pattern", "three", "--category", "all"])
    compare(svc.searchJobQueue[1].cmd, [h, "search", "delete", "4"], "and the queued start's job")
    finish(jobs, 0, "{\"id\":5}\n", "")
    compare(s.signalArguments[2][0], t3)
    compare(jobs.command, [h, "search", "delete", "3"])
    finish(jobs, 0, "{\"ok\":true}\n", "")
    compare(jobs.command, [h, "search", "delete", "4"])
    finish(jobs, 0, "{\"ok\":true}\n", "")
    compare(svc.searchJobQueue.length, 0, "the reopened window's start is kept")
    // A failed or unreadable abandoned start deletes nothing.
    svc.searchStart("four", "all")
    svc.searchStart("five", "all")
    svc.windowOpen = false
    finish(jobs, 1, "", "qBittorrent refused it (HTTP 409)\n")
    finish(jobs, 0, "{\"id\":\"6; rm\"}\n", "")
    compare(svc.searchJobQueue.length, 0)
    verify(svc.searchJobItem === null, "nothing more runs")
  }

  // W1: a plugin change running (or queued) is Service's to say, so a
  // reopened window still shows it and waits for it.
  function test_the_plugin_change_flag() {
    var svc = createTemporaryObject(serviceComp, tc)
    var plug = lane(svc, "plugins")
    compare(svc.searchPluginChange, "")
    svc.searchPluginList()
    compare(svc.searchPluginChange, "", "a list isn't a change")
    svc.searchPluginUpdate()
    compare(svc.searchPluginChange, "update", "queued behind the list")
    finish(plug, 0, "[]")
    compare(svc.searchPluginChange, "update")
    svc.searchPluginEnable("eztv", true)
    finish(plug, 0, "{\"ok\":true}")
    compare(svc.searchPluginChange, "toggle")
    finish(plug, 0, "")
    compare(svc.searchPluginChange, "")
    svc.searchPluginInstall("https://example.org/jackett.py")
    compare(svc.searchPluginChange, "install")
    finish(plug, 1, "", "no\n")
    svc.searchPluginUninstall("eztv")
    compare(svc.searchPluginChange, "uninstall")
    finish(plug, 0, "")
    compare(svc.searchPluginChange, "")
  }

  // A window that reads the list the moment the change flag clears (as
  // SearchPane does) is queued behind the list already waiting, never
  // started over it: every run reports once, in order.
  function test_a_list_asked_for_as_the_change_ends_is_queued() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(finishedSpy, svc)
    var plug = lane(svc, "plugins")
    var h = svc.helperPath
    var t1 = svc.searchPluginUpdate()
    var t2 = svc.searchPluginList()
    var asked = []
    var hook = function() { if (svc.searchPluginChange === "" && asked.length === 0) asked.push(svc.searchPluginList()) }
    svc.searchPluginChangeChanged.connect(hook)
    finish(plug, 0, "")
    svc.searchPluginChangeChanged.disconnect(hook)
    compare(asked.length, 1)
    compare(plug.command, [h, "search-plugin", "list"])
    compare(svc.searchPluginQueue.length, 1, "the new list waits behind the queued one")
    finish(plug, 0, "[]")
    finish(plug, 0, "[]")
    compare(s.count, 3)
    compare([s.signalArguments[0][0], s.signalArguments[1][0], s.signalArguments[2][0]], [t1, t2, asked[0]])
    verify(svc.searchPluginItem === null)
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
