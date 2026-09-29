import QtQuick
import QtTest
import "../../.."

// Slice 5b1 (Task 3): Service's RSS side against the stub Quickshell.Io
// Process (nothing is spawned): the one serial `qbt rss` lane, its stdin
// framing (every value on stdin, NUL-separated, argv only the
// subcommand; tests/fixtures/rss-contract.md), the reads' callbacks, the
// writes' rssFinished, and the items read that didn't change.
TestCase {
  id: tc
  name: "ServiceRss"

  Component { id: serviceComp; Service {} }
  Component { id: finishedSpy; SignalSpy { signalName: "rssFinished" } }
  function spy(svc) { var s = createTemporaryObject(finishedSpy, tc); s.target = svc; return s }

  function lane(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.rssLane === "rss") return o
    }
    return null
  }
  // The child starts (Quickshell's started: the lane writes its stdin then).
  function begin(p) { p.started() }
  function finish(p, code, out, err) {
    p.stdout.text = out || ""
    p.stderr.text = err || ""
    p.running = false
    p.exited(code, 0)
  }
  function writesOf(p) { return p.writes.slice() }

  function test_every_command_puts_its_values_on_stdin_never_argv() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = lane(svc)
    verify(p !== null)
    var h = svc.helperPath
    var hostile = "a;b $(rm -rf /) \"q\" -- --flag"
    var cases = [
      { call: function() { return svc.rssItems(function() {}) }, argv: "items", stdin: null },
      { call: function() { return svc.rssArticle("Distros\\Debian", "guid 1", function() {}) }, argv: "article", stdin: "Distros\\Debian\u0000guid 1" },
      { call: function() { return svc.rssError(hostile, function() {}) }, argv: "error", stdin: hostile },
      { call: function() { return svc.rssAddFeed("https://e.example/rss", "Distros\\News") }, argv: "add-feed", stdin: "https://e.example/rss\u0000Distros\\News" },
      { call: function() { return svc.rssAddFolder("Distros") }, argv: "add-folder", stdin: "Distros" },
      { call: function() { return svc.rssRename("Distros\\News", "Distros\\Old news") }, argv: "rename", stdin: "Distros\\News\u0000Distros\\Old news" },
      { call: function() { return svc.rssRemove(" Debian ") }, argv: "remove", stdin: " Debian " },
      { call: function() { return svc.rssRefresh("") }, argv: "refresh", stdin: "" },
      { call: function() { return svc.rssRefresh("News") }, argv: "refresh", stdin: "News" },
      { call: function() { return svc.rssMarkRead("News", "g1", 0) }, argv: "mark-read", stdin: "News\u0000g1\u00000" },
      { call: function() { return svc.rssMarkRead("", "", 12) }, argv: "mark-read", stdin: "\u0000\u000012" },
      { call: function() { return svc.rssAdd("magnet:?xt=urn:btih:x", "https://e.example/a") }, argv: "add", stdin: "magnet:?xt=urn:btih:x\u0000https://e.example/a" }
    ]
    for (var i = 0; i < cases.length; i++) {
      var c = cases[i]
      p.writes = []
      var t = c.call()
      verify(t > 0, c.argv)
      compare(p.command, [h, "rss", c.argv], c.argv + ": argv holds only the subcommand")
      compare(p.stdinEnabled, c.stdin !== null, c.argv + ": stdin open exactly when it takes values")
      begin(p)
      compare(writesOf(p), c.stdin === null ? [] : [c.stdin], c.argv + ": the values, NUL-joined, no trailing NUL")
      compare(p.stdinEnabled, false, c.argv + ": stdin closed after the one write")
      finish(p, 0, "{\"ok\":true}")
    }
  }

  function test_one_lane_runs_one_at_a_time_in_order() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(svc)
    var p = lane(svc)
    var read = []
    var t1 = svc.rssItems(function(ok, err, data, same) { read.push({ ok: ok, data: data, same: same }) })
    var t2 = svc.rssRemove("News")
    var t3 = svc.rssRefresh("")
    verify(t1 > 0 && t2 > t1 && t3 > t2, "serial tickets")
    compare(p.command[2], "items")
    begin(p)
    finish(p, 0, "{\"processing\":false,\"refreshInterval\":30,\"feeds\":[],\"articles\":[]}\n")
    compare(read.length, 1)
    compare(read[0].ok, true)
    compare(read[0].data.refreshInterval, 30, "the parsed JSON")
    compare(read[0].same, false)
    compare(s.count, 0, "a read answers its callback, not rssFinished")
    compare(p.command[2], "remove", "the queued write starts next")
    begin(p)
    compare(p.writes[p.writes.length - 1], "News")
    finish(p, 1, "", "noise\nThat feed is gone.\n")
    compare(s.count, 1)
    compare(s.signalArguments[0][0], t2)
    compare(s.signalArguments[0][1], false)
    compare(s.signalArguments[0][2], "That feed is gone.", "a refusal carries stderr's sentence")
    compare(s.signalArguments[0][3], null)
    compare(p.command[2], "refresh")
    begin(p)
    finish(p, 0, "{\"ok\":true}\n")
    compare(s.signalArguments[1][0], t3)
    compare(s.signalArguments[1][1], true)
    compare(s.signalArguments[1][3], { ok: true }, "rssFinished carries the parsed JSON")
    verify(!p.running)
  }

  function test_mark_read_ok_false_is_an_answer() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(svc)
    var p = lane(svc)
    var t = svc.rssMarkRead("", "", 3)
    begin(p)
    finish(p, 0, "{\"ok\": false, \"unread\": 5}\n")
    compare(s.signalArguments[0][0], t)
    compare(s.signalArguments[0][1], true, "exit 0: not a failure")
    compare(s.signalArguments[0][3], { ok: false, unread: 5 })
  }

  function test_an_unchanged_items_read_is_flagged_same_with_the_last_data() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = lane(svc)
    var got = []
    var cb = function(ok, err, data, same) { got.push({ ok: ok, err: err, data: data, same: same }) }
    var text = "{\"processing\":true,\"refreshInterval\":5,\"feeds\":[],\"articles\":[]}\n"
    svc.rssItems(cb); begin(p); finish(p, 0, text)
    svc.rssItems(cb); begin(p); finish(p, 0, text)
    compare(got[0].same, false)
    compare(got[1].same, true, "the same raw stdout: the view skips applying it")
    compare(got[1].data.refreshInterval, 5, "still carries the data, for a rebuilt window that has none")
    svc.rssItems(cb); begin(p); finish(p, 1, "", "qBittorrent isn't reachable.")
    compare(got[2].ok, false)
    compare(got[2].err, "qBittorrent isn't reachable.")
    svc.rssItems(cb); begin(p); finish(p, 0, text)
    compare(got[3].same, false, "a failure in between: applied again")
    // An article read is never flagged.
    svc.rssArticle("News", "g", cb); begin(p); finish(p, 0, "{\"text\":\"x\",\"truncated\":false}")
    svc.rssArticle("News", "g", cb); begin(p); finish(p, 0, "{\"text\":\"x\",\"truncated\":false}")
    compare(got[5].same, false)
    compare(got[5].data.text, "x")
  }

  function test_a_run_that_never_starts_still_finishes_and_the_lane_moves_on() {
    var svc = createTemporaryObject(serviceComp, tc)
    var s = spy(svc)
    var p = lane(svc)
    var t = svc.rssRefresh("")
    var t2 = svc.rssAddFolder("X")
    p.running = false
    wait(20)
    compare(s.count, 1)
    compare(s.signalArguments[0][0], t)
    compare(s.signalArguments[0][1], false)
    compare(s.signalArguments[0][2], "Could not run the qbt helper")
    compare(p.command[2], "add-folder")
    begin(p)
    compare(p.writes[p.writes.length - 1], "X", "the next run writes its own stdin")
    finish(p, 0, "{\"ok\":true,\"path\":\"X\"}")
    compare(s.signalArguments[1][0], t2)
    compare(s.signalArguments[1][3].path, "X")
  }

  function test_a_closed_window_s_reads_answer_nobody() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = lane(svc)
    var got = 0
    svc.windowOpen = true
    svc.rssItems(function() { got++ })
    svc.rssArticle("News", "g", function() { got++ })
    svc.windowOpen = false
    begin(p); finish(p, 0, "{}")
    begin(p); finish(p, 0, "{}")
    compare(got, 0, "the callbacks belonged to the window that closed")
    verify(!p.running)
  }

  function test_an_add_refreshes_the_library_and_a_stopped_service_runs_nothing() {
    var svc = createTemporaryObject(serviceComp, tc)
    var p = lane(svc)
    // With the sidecar down, refresh() is the bash status read.
    svc.sidecarState = "down"
    svc.rssAdd("magnet:?xt=urn:btih:x", "")
    begin(p)
    finish(p, 0, "{\"ok\":true,\"via\":\"magnet\"}")
    var status = null
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.command !== undefined && o.command.length === 2 && o.command[1] === "status") status = o
    }
    verify(status !== null && status.running, "the library is read again, so AddAwaiter sees the magnet")
    svc.stop()
    compare(svc.rssRefresh(""), 0)
    compare(svc.rssItems(function() {}), 0)
    verify(!p.running)
  }
}
