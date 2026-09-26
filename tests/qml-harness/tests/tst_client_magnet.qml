import QtQuick
import QtTest
import "../../.."

// The window's browser-magnet confirm (slice 1b Task 4, D3). A service stub
// of its own, with the magnet queue and the calls the confirm makes; the
// Client tests in tst_client.qml stay as they are.
TestCase {
  id: tc
  name: "ClientMagnet"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function url(c) { return "magnet:?xt=urn:btih:" + hh(c) }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1, category: "", tags: [], tracker: "", savePath: "/dl" }
    for (var k in extra || {}) r[k] = extra[k]
    return r
  }
  function pend(c, extra) {
    var p = { hash: hh(c), url: url(c), hashes: [hh(c)], dn: "", addedAt: Date.now() / 1000 }
    for (var k in extra || {}) p[k] = extra[k]
    return p
  }

  Component {
    id: serviceComp
    QtObject {
      property bool installed: true
      property bool daemon: true
      property string lockHolder: "none"
      property bool api: true
      property bool altSpeed: false
      property real dlSpeed: 0
      property real upSpeed: 0
      property string vpnIface: ""
      property string bindIface: ""
      property bool vpnUnbound: false
      property string sidecarState: "up"
      property string lastError: ""
      property var torrents: []
      property var categories: []
      property var tags: []
      property var filesByHash: ({})
      property var filesStatusByHash: ({})
      property var magnetPending: []
      property var magnetInbox: []
      property var magnetPendingHashes: []
      property var viewState: ({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table" })
      property bool windowOpen: false
      property var calls: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { viewState = s }
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function refresh() { rec("refresh", []) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { rec("loadFiles", [h, o]) }
      property bool busy: false
      function startPending(h, o) { var t = rec("startPending", [h, o]); return busy ? 0 : t }
      function cancelPending(h, o) { return rec("cancelPending", [h, o]) }
      function dropInboxCurrent(o) { return rec("dropInboxCurrent", [o]) }
      function loadMagnetSnapshot() { rec("loadMagnetSnapshot", []) }
    }
  }

  Component {
    id: shellComp
    QtObject {
      property var target: null
      function hide(id) { if (target) target.close() }
    }
  }

  Component { id: clientComp; Client {} }

  function key(c, text, code, mods) {
    c.handleKey({ key: code !== undefined ? code : text.toUpperCase().charCodeAt(0), text: text, modifiers: mods || 0 })
  }
  function esc(c) { key(c, "", 0x01000000) }
  function enter(c) { key(c, "", 0x01000004) }
  function findWith(obj, fn) {
    if (!obj) return null
    if (typeof obj[fn] === "function") return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findWith(kids[i], fn); if (r) return r }
    return null
  }
  function findText(obj, text) {
    if (!obj) return null
    if (obj.text === text && obj.visible) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findText(kids[i], text); if (r) return r }
    return null
  }
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function row(c) { return findWith(winOf(c).contentItem, "act") }
  function line(c) { return findWith(winOf(c).contentItem, "setInput") }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  // Past the magnet CONFIRM's grace (Registry.MAGNET_GRACE_MS, 600 ms):
  // Esc and n only cancel once it is over.
  function pastGrace() { wait(620) }
  function magnetCalls(svc) {
    return svc.calls.filter(function(x) { return ["startPending", "cancelPending", "dropInboxCurrent", "delete"].indexOf(x.name) !== -1 })
  }

  function make() {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha", { addedOn: 1 }), tt(hh("b"), "beta", { addedOn: 2 })]
    return { c: c, svc: svc }
  }

  // A pending magnet whose status row is still named by its hash, or (ready)
  // has its real name and is stopped.
  function addPending(o, c, ready) {
    var r = ready ? tt(hh(c), "Big Buck Bunny", { state: "stoppedDL", size: 276134947, addedOn: 9 })
      : tt(hh(c), hh(c), { state: "metaDL", size: 0, addedOn: 9 })
    o.svc.magnetPendingHashes = [hh(c)]
    o.svc.torrents = o.svc.torrents.concat([r])
    o.svc.magnetPending = [pend(c)]
  }

  function test_pending_magnet_shows_pinned_row_and_magnet_line() {
    var o = make()
    var mr = row(o.c)
    verify(mr !== null)
    compare(mr.visible, false)
    compare(mr.height, 0)
    addPending(o, "d", false)
    compare(o.c.tableRows.length, 2, "the pending torrent stays out of the table")
    compare(mr.visible, true)
    verify(mr.height > 0)
    verify(findText(mr, "↓") !== null)
    verify(findText(mr, "Fetching name…") !== null)
    compare(o.c.mode, "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(o.c.confirm, null)
    var sl = line(o.c)
    verify(findText(sl, "MAGNET") !== null)
    compare(sl.magnetParts.lead + sl.magnetParts.title + sl.magnetParts.tail, "Start \"Fetching name…\"?")
    compare(sl.magnetParts.more, "")
    compare(sl.hints.length > 0, true)
    verify(findText(sl, "Enter") !== null)
    verify(findText(sl, " start") !== null)
    verify(findText(sl, " cancel") !== null)
    // the name and size arrive, and a second magnet waits
    o.svc.torrents = o.svc.torrents.map(function(t) { return t.hash === hh("d") ? tt(hh("d"), "Big Buck Bunny", { state: "stoppedDL", size: 276134947 }) : t })
    o.svc.magnetInbox = [{ url: url("e"), ts: 1 }]
    verify(findText(mr, "Big Buck Bunny") !== null)
    verify(findText(mr, "263.3 MiB") !== null)
    compare(sl.magnetParts.title, "Big Buck Bunny")
    compare(sl.magnetParts.more, "+1 more")
    verify(findText(sl, "+1 more") !== null)
  }

  function test_other_keys_do_nothing_while_a_magnet_waits() {
    var o = make()
    addPending(o, "d", false)
    var cursor = o.c.cursorHash
    key(o.c, "j"); key(o.c, "x"); key(o.c, ":"); key(o.c, "q"); key(o.c, " ", 0x20)
    compare(o.c.mode, "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(o.c.cursorHash, cursor)
    compare(o.c.opened, true)
    compare(o.svc.calls.filter(function(x) { return x.name !== "loadFiles" && x.name !== "refresh" }).length, 0)
  }

  function test_enter_while_fetching_notes_and_makes_no_call() {
    var o = make()
    addPending(o, "d", false)
    enter(o.c)
    compare(calls(o.svc, "startPending").length, 0)
    compare(o.c.messageLine.text, "Still fetching the name…")
    verify(findText(line(o.c), "Still fetching the name…") !== null)
    compare(o.c.mode, "CONFIRM")
    key(o.c, "y")
    compare(calls(o.svc, "startPending").length, 0)
  }

  function test_enter_when_ready_starts_with_window_origin_once() {
    var o = make()
    addPending(o, "d", true)
    enter(o.c)
    var s = calls(o.svc, "startPending")
    compare(s.length, 1)
    compare(s[0].args[0], hh("d"))
    compare(s[0].args[1].origin, "window")
    compare(s[0].args[1].hashes, [hh("d")])
    compare(o.c.mode, "NORMAL", "back to NORMAL while the snapshot catches up")
    compare(row(o.c).visible, false)
    enter(o.c)
    compare(calls(o.svc, "startPending").length, 1, "the same magnet is never started twice")
    compare(o.c.mode, "NORMAL")
    // the snapshot drops it
    o.svc.magnetPending = []
    compare(o.c.mode, "NORMAL")
  }

  function test_y_starts_too() {
    var o = make()
    addPending(o, "d", true)
    key(o.c, "y")
    compare(calls(o.svc, "startPending").length, 1)
  }

  function test_esc_cancels_the_pending_torrent() {
    var o = make()
    addPending(o, "d", false)
    pastGrace()
    esc(o.c)
    var c = calls(o.svc, "cancelPending")
    compare(c.length, 1)
    compare(c[0].args[0], hh("d"))
    compare(c[0].args[1].origin, "window")
    compare(c[0].args[1].hashes, [hh("d")])
    compare(calls(o.svc, "dropInboxCurrent").length, 0)
    compare(o.c.mode, "NORMAL")
    esc(o.c)
    compare(calls(o.svc, "cancelPending").length, 1, "a second Esc clears the filter, not the magnet")
  }

  function test_n_cancels_too() {
    var o = make()
    addPending(o, "d", false)
    pastGrace()
    key(o.c, "n")
    compare(calls(o.svc, "cancelPending").length, 1)
  }

  function test_inbox_only_item_esc_drops_the_inbox_line() {
    var o = make()
    o.svc.magnetInbox = [{ url: url("e"), ts: 1, notified: false, ids: [], dn: "" }]
    compare(o.c.mode, "CONFIRM")
    verify(findText(row(o.c), "Fetching name…") !== null)
    enter(o.c)
    compare(o.c.messageLine.text, "Still fetching the name…")
    pastGrace()
    esc(o.c)
    compare(calls(o.svc, "cancelPending").length, 0)
    var d = calls(o.svc, "dropInboxCurrent")
    compare(d.length, 1)
    compare(d[0].args[0].origin, "window")
    compare(o.c.mode, "NORMAL")
  }

  function test_error_inbox_line_shows_the_error_and_esc_drops_it() {
    var o = make()
    o.svc.magnetInbox = [{ url: url("e"), ts: 1, error: "unidentified" }]
    compare(o.c.mode, "CONFIRM")
    verify(findText(row(o.c), "unidentified") !== null)
    var sl = line(o.c)
    compare(sl.magnetParts.error, "unidentified")
    verify(findText(sl, " dismiss") !== null)
    enter(o.c)
    compare(magnetCalls(o.svc).length, 0)
    pastGrace()
    esc(o.c)
    compare(calls(o.svc, "dropInboxCurrent").length, 1)
  }

  function test_the_drained_line_keeps_the_confirm_and_the_next_magnet_follows() {
    var o = make()
    o.svc.magnetInbox = [{ url: url("d"), ts: 1 }]
    compare(o.c.mode, "CONFIRM")
    // the drain moves it to pending (same url)
    o.svc.magnetInbox = [{ url: url("e"), ts: 2 }]
    addPending(o, "d", true)
    compare(o.c.mode, "CONFIRM")
    enter(o.c)
    compare(o.c.mode, "NORMAL")
    // the snapshot drops it; the next one is offered once the Enter settles
    o.svc.magnetPending = []
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(row(o.c).visible, true)
  }

  function test_palette_esc_closes_the_palette_and_never_cancels_the_magnet() {
    var o = make()
    key(o.c, ":")
    compare(o.c.mode, "COMMAND")
    addPending(o, "d", false)
    compare(o.c.mode, "COMMAND", "a magnet waits for NORMAL")
    compare(row(o.c).visible, true)
    esc(o.c)
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(magnetCalls(o.svc).length, 0)
    verify(findText(line(o.c), "MAGNET") !== null)
  }

  function test_insert_and_visual_esc_never_cancel_the_magnet() {
    var o = make()
    key(o.c, "/")
    compare(o.c.mode, "INSERT")
    addPending(o, "d", false)
    compare(o.c.mode, "INSERT")
    esc(o.c)
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
    var o2 = make()
    key(o2.c, "V", 0x56, 0x02000000)
    compare(o2.c.mode, "VISUAL")
    addPending(o2, "d", false)
    compare(o2.c.mode, "VISUAL")
    esc(o2.c)
    compare(magnetCalls(o2.svc).length, 0)
    tryCompare(o2.c, "mode", "CONFIRM")
  }

  function test_delete_confirm_is_answered_first() {
    var o = make()
    key(o.c, "x")
    compare(o.c.regState.pending.kind, "remove")
    addPending(o, "d", false)
    compare(o.c.regState.pending.kind, "remove", "the open question stays")
    key(o.c, "n")
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
  }

  function test_overlay_esc_never_cancels_the_magnet() {
    var o = make()
    var win = winOf(o.c)
    win.width = 850
    tryVerify(function() { return win.contentItem.width === 850 }, 2000)
    compare(o.c.layout.filters, "collapsed")
    key(o.c, "\b", 0x48, 0x04000000)   // Ctrl-h: the filters overlay
    compare(o.c.pane, "filters")
    addPending(o, "d", false)
    compare(o.c.mode, "NORMAL", "an open overlay waits")
    esc(o.c)
    compare(o.c.pane, "table")
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
  }

  function ticketOf(svc, name) {
    for (var i = svc.calls.length - 1; i >= 0; i--) if (svc.calls[i].name === name) return i + 1
    return 0
  }

  function test_a_failed_start_offers_the_magnet_again() {
    var o = make()
    addPending(o, "d", true)
    enter(o.c)
    compare(o.c.mode, "NORMAL")
    var t = ticketOf(o.svc, "startPending")
    verify(t > 0)
    o.svc.actionFinished(t + 99, false, "boom", "window", [hh("d")])
    compare(o.c.mode, "NORMAL", "another ticket with the same hash is ignored")
    o.svc.actionFinished(t, false, "boom", "window", [hh("d")])
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(row(o.c).visible, true)
    enter(o.c)
    compare(calls(o.svc, "startPending").length, 2)
  }

  function test_a_failed_cancel_offers_the_magnet_again() {
    var o = make()
    addPending(o, "d", false)
    pastGrace()
    esc(o.c)
    compare(o.c.mode, "NORMAL")
    var t = ticketOf(o.svc, "cancelPending")
    o.svc.actionFinished(t, true, "", "window", [hh("d")])
    compare(o.c.mode, "NORMAL", "success keeps it handled")
    o.svc.actionFinished(t, false, "boom", "window", [hh("d")])
    compare(o.c.mode, "NORMAL", "only this row's ticket, once")
    var o2 = make()
    addPending(o2, "d", false)
    pastGrace()
    esc(o2.c)
    o2.svc.actionFinished(ticketOf(o2.svc, "cancelPending"), false, "boom", "window", [hh("d")])
    tryCompare(o2.c, "mode", "CONFIRM")
    compare(o2.c.regState.pending.kind, "magnet")
    compare(row(o2.c).visible, true)
    pastGrace()
    esc(o2.c)
    compare(calls(o2.svc, "cancelPending").length, 2)
  }

  function test_a_busy_start_leaves_the_magnet_offered() {
    var o = make()
    o.svc.busy = true
    addPending(o, "d", true)
    enter(o.c)
    compare(calls(o.svc, "startPending").length, 1)
    compare(o.c.mode, "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(row(o.c).visible, true)
    compare(o.c.messageLine.text, "Busy, try again.")
    o.svc.busy = false
    enter(o.c)
    compare(calls(o.svc, "startPending").length, 2)
    compare(o.c.mode, "NORMAL")
  }

  function test_help_overlay_waits_and_its_closing_key_never_cancels() {
    var o = make()
    key(o.c, "?")
    compare(o.c.helpOpen, true)
    addPending(o, "d", false)
    compare(o.c.mode, "NORMAL", "the help overlay waits")
    esc(o.c)
    compare(o.c.helpOpen, false)
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
  }

  function test_a_new_magnet_asks_for_attention() {
    var o = make()
    var wm = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].focusAttempts !== undefined) wm = o.c.data[i]
    verify(wm !== null)
    tryVerify(function() { return !wm.retry.running }, 3000)
    addPending(o, "d", false)
    verify(wm.retry.running, "requestWmFocus on arrival")
    tryVerify(function() { return !wm.retry.running }, 3000)
    o.svc.magnetPending = o.svc.magnetPending.concat([])   // a snapshot tick, nothing new
    verify(!wm.retry.running)
  }

  function test_no_attention_request_while_the_palette_owns_the_keys() {
    var o = make()
    var wm = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].focusAttempts !== undefined) wm = o.c.data[i]
    tryVerify(function() { return !wm.retry.running }, 3000)
    key(o.c, ":")
    addPending(o, "d", false)
    verify(!wm.retry.running, "the palette field keeps its focus")
    esc(o.c)
    tryVerify(function() { return wm.retry.running }, 1000)
  }

  // ---- final review: a double Esc never cancels (settle + grace) -----------

  function wmOf(c) {
    for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].focusAttempts !== undefined) return c.data[i]
    return null
  }
  function palette(c) { return findWith(winOf(c).contentItem, "focusField") }
  readonly property string waitNote: "Magnet waiting \u2014 finish, then confirm"

  // The key after the one that left a mode does its NORMAL job (Esc:
  // filter.clearText, arming Esc Esc), the magnet CONFIRM comes only once
  // the keys stop, and nothing is cancelled. The waits let the event loop
  // run between keys, as a real reflexive double Esc does (~100 ms apart),
  // so a raise deferred by one tick would land between them.
  function doubleEscNeverCancels(o) {
    wait(100)
    esc(o.c)
    compare(o.c.mode, "NORMAL")
    compare(o.c.regState.prefix, "Esc", "the second Esc is filter.clearText")
    compare(magnetCalls(o.svc).length, 0)
    wait(100)
    esc(o.c)   // Esc Esc: filter.reset
    compare(o.c.mode, "NORMAL")
    compare(magnetCalls(o.svc).length, 0)
    tryCompare(o.c, "mode", "CONFIRM")
    compare(o.c.regState.pending.kind, "magnet")
    compare(magnetCalls(o.svc).length, 0)
  }

  function test_double_esc_from_insert_never_cancels() {
    var o = make()
    key(o.c, "/")
    addPending(o, "d", false)
    esc(o.c)
    doubleEscNeverCancels(o)
  }

  function test_double_esc_from_the_palette_never_cancels() {
    var o = make()
    key(o.c, ":")
    addPending(o, "d", false)
    esc(o.c)
    doubleEscNeverCancels(o)
  }

  function test_double_esc_from_visual_never_cancels() {
    var o = make()
    key(o.c, "V", 0x56, 0x02000000)
    compare(o.c.mode, "VISUAL")
    addPending(o, "d", false)
    esc(o.c)
    doubleEscNeverCancels(o)
  }

  function test_double_esc_from_an_overlay_never_cancels() {
    var o = make()
    var win = winOf(o.c)
    win.width = 850
    tryVerify(function() { return win.contentItem.width === 850 }, 2000)
    key(o.c, "\b", 0x48, 0x04000000)   // Ctrl-h: the filters overlay
    compare(o.c.pane, "filters")
    addPending(o, "d", false)
    esc(o.c)
    compare(o.c.pane, "table")
    doubleEscNeverCancels(o)
  }

  function test_double_esc_from_help_never_cancels() {
    var o = make()
    key(o.c, "?")
    addPending(o, "d", false)
    esc(o.c)
    compare(o.c.helpOpen, false)
    doubleEscNeverCancels(o)
  }

  function test_double_esc_after_n_on_a_delete_confirm_never_cancels() {
    var o = make()
    key(o.c, "x")
    compare(o.c.regState.pending.kind, "remove")
    addPending(o, "d", false)
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    doubleEscNeverCancels(o)
    var o2 = make()
    key(o2.c, "x")
    addPending(o2, "d", false)
    key(o2.c, "n")
    wait(100)
    key(o2.c, "n")
    compare(magnetCalls(o2.svc).length, 0)
    tryCompare(o2.c, "mode", "CONFIRM")
    compare(magnetCalls(o2.svc).length, 0)
  }

  function test_esc_right_at_the_raise_is_ignored_and_a_deliberate_esc_cancels() {
    var o = make()
    key(o.c, ":")
    addPending(o, "d", false)
    esc(o.c)
    tryCompare(o.c, "mode", "CONFIRM")
    esc(o.c)
    key(o.c, "n")
    compare(magnetCalls(o.svc).length, 0, "within the grace")
    compare(o.c.mode, "CONFIRM")
    pastGrace()
    esc(o.c)
    var c = calls(o.svc, "cancelPending")
    compare(c.length, 1, "a deliberate Esc after the grace cancels")
    compare(c[0].args[0], hh("d"))
  }

  function test_keys_keep_the_magnet_waiting_until_they_stop() {
    var o = make()
    key(o.c, "j")
    addPending(o, "d", false)
    compare(o.c.mode, "NORMAL", "a key just now: it waits")
    for (var i = 0; i < 4; i++) { wait(300); key(o.c, "j") }
    compare(o.c.mode, "NORMAL", "each key restarts the settle")
    tryCompare(o.c, "mode", "CONFIRM")
  }

  // ---- final review: a waiting magnet is never silent ----------------------

  function test_the_wait_note_shows_in_insert_and_command_and_never_over_a_message() {
    var o = make()
    key(o.c, "/")
    addPending(o, "d", false)
    compare(o.c.mode, "INSERT")
    var sl = line(o.c)
    compare(sl.message, waitNote)
    compare(sl.messageTone, "muted")
    verify(findText(sl, waitNote) !== null)
    compare(o.c.messageLine.text, "", "derived, not a note a key would clear")
    o.c.note("Enter an absolute path to move to.", "urgent")
    compare(sl.message, "Enter an absolute path to move to.", "a message wins")
    esc(o.c)   // any key ends the note
    compare(o.c.mode, "NORMAL")
    compare(sl.message, waitNote, "still waiting while it settles")
    tryCompare(o.c, "mode", "CONFIRM")
    verify(findText(sl, waitNote) === null)
    var o2 = make()
    key(o2.c, ":")
    addPending(o2, "d", false)
    compare(o2.c.mode, "COMMAND")
    var sl2 = line(o2.c)
    compare(sl2.message, waitNote)
    verify(findText(sl2, waitNote) !== null)
  }

  function inactive(c) {
    var fake = { active: false, asks: 0, requestActivate: function() { this.asks++ } }
    winOf(c)._backingWindow = fake
    return fake
  }

  function test_an_inactive_window_is_asked_for_but_the_insert_field_keeps_the_keys() {
    var o = make()
    var wm = wmOf(o.c)
    tryVerify(function() { return !wm.retry.running }, 3000)
    key(o.c, "/")
    var field = line(o.c).inputField
    verify(field.activeFocus)
    var fake = inactive(o.c)
    addPending(o, "d", false)
    verify(wm.retry.running, "activation requested in INSERT")
    compare(wm.focusTarget, field)
    verify(field.activeFocus, "typing is never stolen")
    tryVerify(function() { return fake.asks > 0 }, 1000)
    fake.active = true
    tryVerify(function() { return !wm.retry.running }, 1000)
    verify(field.activeFocus, "activation lands on the field, not keyRoot")
    compare(o.c.mode, "INSERT")
  }

  function test_an_inactive_window_is_asked_for_but_the_palette_field_keeps_the_keys() {
    var o = make()
    var wm = wmOf(o.c)
    tryVerify(function() { return !wm.retry.running }, 3000)
    key(o.c, ":")
    var field = palette(o.c).inputField
    verify(field.activeFocus)
    var fake = inactive(o.c)
    addPending(o, "d", false)
    verify(wm.retry.running, "activation requested in COMMAND")
    compare(wm.focusTarget, field)
    verify(field.activeFocus)
    fake.active = true
    tryVerify(function() { return !wm.retry.running }, 1000)
    verify(field.activeFocus)
    compare(o.c.mode, "COMMAND")
  }

  function test_an_active_window_in_insert_is_not_asked_again() {
    var o = make()
    var wm = wmOf(o.c)
    tryVerify(function() { return !wm.retry.running }, 3000)
    key(o.c, "/")
    addPending(o, "d", false)
    verify(!wm.retry.running)
    verify(line(o.c).inputField.activeFocus)
  }

  function test_a_field_closed_before_activation_hands_the_keys_to_the_window() {
    var o = make()
    var wm = wmOf(o.c)
    tryVerify(function() { return !wm.retry.running }, 3000)
    key(o.c, "/")
    var field = line(o.c).inputField
    var fake = inactive(o.c)
    addPending(o, "d", false)
    compare(wm.focusTarget, field)
    esc(o.c)
    compare(o.c.mode, "NORMAL")
    fake.active = true
    tryVerify(function() { return !wm.retry.running }, 1000)
    verify(!field.activeFocus)
    verify(wm.keyItem.activeFocus, "a closed field never keeps the keys")
  }
}
