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
}
