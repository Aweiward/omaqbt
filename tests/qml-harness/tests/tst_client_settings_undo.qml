import QtQuick
import QtTest
import qs.Commons
import "../../.."
import "../../../SettingsSchema.js" as Schema
import "../../../SettingsView.js" as SettingsView
import "../../../ClientView.js" as View
import "../../../CommandRegistry.js" as Registry

// Slice 4b (Task 4): undo of this visit's settings changes (design D3, eng
// D11/D12, Rulings EC and EH). The helpers and the Service stub are
// tst_client_settings_lists.qml's: readPrefs keeps each callback so a test
// answers it (the re-read after a write, and u's own re-read); finish()
// plays actionFinished, finishSecret secretFinished.
TestCase {
  id: tc
  name: "ClientSettingsUndo"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name) {
    return { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
  }

  // One or more keys of every editor type, the locked and multi-line rows,
  // and two keys the schema doesn't know (Other).
  function prefs(extra) {
    var p = {
      dl_limit: 0, up_limit: 1048576,
      scheduler_enabled: true, schedule_from_hour: 8, schedule_from_min: 0, schedule_to_hour: 20, schedule_to_min: 0,
      listen_port: 51413, upnp: false, max_connec: 500,
      dht: true, pex: true, lsd: true, encryption: 0, anonymous_mode: false,
      torrent_content_layout: "Original", save_path: "/srv/dl", announce_ip: "",
      excluded_file_names_enabled: true, excluded_file_names: "*.exe\n*.scr",
      web_ui_address: "127.0.0.1", web_ui_port: 8080, current_network_interface: "wg0-mullvad",
      disk_io_type: 0,
      zz_new_flag: false, zz_new_count: 7
    }
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
      property bool sidecarDown: false
      property string lastError: ""
      property var torrents: []
      property var categories: []
      property var tags: []
      property var filesByHash: ({})
      property var filesStatusByHash: ({})
      property var inspectByKey: ({})
      property var magnetPending: []
      property var magnetInbox: []
      property var magnetPendingHashes: []
      property var viewState: ({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table" })
      property bool windowOpen: false
      property var calls: []
      property var prefsCbs: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal secretFinished(int ticket, bool ok, string error)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { viewState = s }
      function refresh() { rec("refresh", []) }
      function refreshSlow() { rec("refreshSlow", []) }
      function watch(h, t) { calls.push({ name: "watch", args: [h, t] }) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { calls.push({ name: "loadFiles", args: [h, o] }) }
      function loadMagnetSnapshot() { rec("loadMagnetSnapshot", []) }
      // busy: Service refuses a window call with 0 while its queue is full.
      property bool busy: false
      function setPref(k, v, o) { if (busy) { calls.push({ name: "setPref", args: [k, v, o] }); return 0 } return rec("setPref", [k, v, o]) }
      function readPrefs(cb) { rec("readPrefs", []); prefsCbs.push(cb) }
      // The stub keeps what it was sent (a real Service keeps nothing).
      function setSecret(k, v, o) { return rec("setSecret", [k, v, o]) }
      function clearSecret(k, o) { return rec("clearSecret", [k, o]) }
      function banList(op, ip, o) { return rec("banList", [op, ip, o]) }
      function answer(result) { var cb = prefsCbs.shift(); cb(result) }
      // Slice 5b2 (D8): the auto-download count.
      property var autoCbs: []
      // autoRefused: the Service refuses the count with 0 (never answers).
      property bool autoRefused: false
      function rssAutoPreview(cb) { var t = rec("rssAutoPreview", []); if (autoRefused) return 0; autoCbs.push(cb); return t }
      function answerAuto(ok, err, data) { var cb = autoCbs.shift(); cb(ok, err, data) }
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
  function esc(o) { key(o.c, "", 0x01000000) }
  function enter(o) { key(o.c, "", 0x01000004) }
  function space(o) { key(o.c, " ", 0x20) }
  function comma(o) { key(o.c, ",", 0x2c) }
  function findWith(obj, fn) {
    if (!obj) return null
    if (typeof obj[fn] === "function") return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findWith(kids[i], fn); if (r) return r }
    return null
  }
  function findName(obj, name) {
    if (!obj) return null
    if (obj.objectName === name) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findName(kids[i], name); if (r) return r }
    return null
  }
  function visibleNamed(obj, name, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (obj.objectName === name) out.push(obj)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleNamed(kids[i], name, out)
    return out
  }
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function content(o) { return winOf(o.c).contentItem }
  function line(o) { return findWith(content(o), "setInput") }
  function view(o) { return findName(content(o), "settingsView") }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function writes(o) { return calls(o.svc, "setPref").map(function(x) { return [x.args[0], x.args[1]] }) }
  function rowItem(o, key) {
    wait(30)
    var rows = visibleNamed(content(o), "settingsRow")
    for (var i = 0; i < rows.length; i++) if (rows[i].row.key === key) return rows[i]
    return null
  }
  function valueText(o, key) { var r = rowItem(o, key); return r ? findName(r, "settingsValue").text : null }
  function status(o) { return o.c.statusMessage.text }

  function make(p) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha")]
    var o = { c: c, svc: svc }
    comma(o)
    svc.answer({ ok: true, prefs: p || prefs() })
    return o
  }
  // The settings cursor on `key` (its section, then its row), as j/k/l would.
  function focusKey(o, k) {
    var v = view(o)
    var row = SettingsView.rowFor(k, v.prefs)
    verify(row !== null, k + " shows")
    for (var i = 0; i < v.sectionList.length; i++) if (v.sectionList[i].name === row.section) v.sectionIndex = i
    compare(v.sectionName, row.section)
    var rows = v.shownRows
    var at = -1
    for (var j = 0; j < rows.length; j++) if (rows[j].key === k) at = j
    verify(at >= 0, k + " in its section")
    var cur = {}
    for (var s in v.cursors) cur[s] = v.cursors[s]
    cur[row.section] = at
    v.cursors = cur
    v.column = "settingsKeys"
    compare(v.cursorRow.key, k)
  }
  function finish(o, ok, err) { o.svc.actionFinished(o.svc.seq, ok, err || "", "window", []) }
  function typeAndEnter(o, text) { line(o).setInput(text); enter(o) }
  function picker(o) { return view(o).picker }
  function choose(o, value) {
    var p = picker(o)
    var at = -1
    for (var i = 0; i < p.rows.length; i++) if (String(p.rows[i].value) === String(value)) at = i
    verify(at >= 0, "the picker lists " + value)
    p.cursor = at
    enter(o)
  }

  function finishSecret(o, ok, err) { o.svc.secretFinished(o.svc.seq, ok, err || "") }
  function tab(o) { key(o.c, "", 0x01000001) }
  function backtab(o) { key(o.c, "", 0x01000002) }
  function cmds(o) {
    return o.c.settingsCmds
  }
  function field(o) { return line(o).inputField }
  function listTexts(o) {
    wait(30)
    return visibleNamed(content(o), "settingsListText").map(function(t) { return t.text })
  }
  // The settings cursor on a section by name (as j/k would).
  function focusSection(o, name) {
    var v = view(o)
    for (var i = 0; i < v.sectionList.length; i++) if (v.sectionList[i].name === name) v.sectionIndex = i
    compare(v.sectionName, name)
  }
  function openListOf(o, k) {
    focusKey(o, k)
    enter(o)
    compare(o.c.keyPane, "settingsList")
    compare(view(o).listKey, k)
  }
  function lists(extra) {
    var p = prefs({ add_trackers_enabled: true, add_trackers: "udp://a.example/announce\n\nhttp://b.example/announce",
      banned_IPs: "10.0.0.1\n2001:db8::1" })
    for (var k in extra || {}) p[k] = extra[k]
    return p
  }
  function secrets(extra) {
    var p = prefs({ proxy_type: "SOCKS5", proxy_password: { set: false }, dyndns_enabled: true, dyndns_password: { set: true },
      mail_notification_auth_enabled: false, mail_notification_password: { set: true } })
    for (var k in extra || {}) p[k] = extra[k]
    return p
  }


  readonly property string secret: " s3cr3t \\ \u{1F98A} "

  // Whether v holds s: a string containing it, or a plain object or array
  // with one somewhere inside (walked, not JSON.stringify'd: JSON escapes
  // the backslash the secret carries). QObjects are walked by sweep.
  function hold(v, s, depth) {
    var d = depth === undefined ? 6 : depth
    if (v === null || v === undefined || d < 0) return false
    if (typeof v === "string") return v.indexOf(s) !== -1
    if (typeof v !== "object" || v.objectName !== undefined) return false
    for (var k in v) {
      var x
      try { x = v[k] } catch (e) { continue }
      if (hold(x, s, d - 1) || (typeof k === "string" && k.indexOf(s) !== -1)) return true
    }
    return false
  }
  // Every property of obj (QObject-valued ones walked through data and
  // children, to depth), paths of those holding s.
  function sweep(obj, s, depth, path, seen, hits) {
    if (!obj || depth < 0 || seen.indexOf(obj) !== -1) return hits
    seen.push(obj)
    for (var k in obj) {
      if (k === "data" || k === "children" || k === "resources" || k === "parent") continue
      var v
      try { v = obj[k] } catch (e) { continue }
      if (typeof v === "function") continue
      if (v && typeof v === "object" && v.objectName !== undefined) continue
      if (hold(v, s)) hits.push(path + "." + k)
    }
    var kids = []
    var lists = [obj.data, obj.children]
    for (var l = 0; l < lists.length; l++) {
      var list = lists[l]
      if (!list) continue
      for (var i = 0; i < list.length; i++) kids.push(list[i])
    }
    for (var j = 0; j < kids.length; j++) sweep(kids[j], s, depth - 1, path + "/" + (kids[j].objectName || j), seen, hits)
    return hits
  }
  function clientCommands(o) {
    return o.c.commands
  }
  function sweepAll(o, s) {
    var hits = []
    sweep(cmds(o), s, 1, "SettingsCommands", [], hits)
    sweep(view(o), s, 6, "SettingsPane", [], hits)
    sweep(clientCommands(o), s, 1, "ClientCommands", [], hits)
    // The status line walked down to its TextField (text, displayText, …).
    sweep(line(o), s, 8, "StatusLine", [], hits)
    sweep(findWith(content(o), "complete"), s, 8, "CommandPalette", [], hits)
    var own = []
    for (var k in o.c) {
      var v
      try { v = o.c[k] } catch (e) { continue }
      if (typeof v !== "function" && !(v && typeof v === "object" && v.objectName !== undefined) && hold(v, s)) own.push("Client." + k)
    }
    return hits.concat(own)
  }


  // ---- undo helpers ---------------------------------------------------------------

  function stack(o) { return cmds(o).undoStack }
  // The write's success and its re-read (qBittorrent now holds after).
  function saved(o, after) { finish(o, true); o.svc.answer({ ok: true, prefs: after }) }
  // u, and its re-read answered with now.
  function undo(o, now) {
    var reads = calls(o.svc, "readPrefs").length
    key(o.c, "u")
    compare(calls(o.svc, "readPrefs").length, reads + 1, "u re-reads first")
    o.svc.answer({ ok: true, prefs: now })
  }
  function editTo(o, k, text) { focusKey(o, k); enter(o); typeAndEnter(o, text) }
  function footerKeys(o) {
    wait(30)
    var out = []
    var walk = function(obj) {
      if (!obj || obj.visible === false) return
      if (Array.isArray(obj.keys) && obj.keys.length && obj.keys[0].key !== undefined && obj.keys[0].label !== undefined) out = out.concat(obj.keys.map(function(k) { return k.key }))
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) walk(kids[i])
    }
    walk(view(o))
    return out
  }
  function leaveSettings(o) {
    for (var i = 0; i < 4 && view(o).open; i++) esc(o)
    verify(!view(o).open, "left Settings")
  }

  // ---- recording --------------------------------------------------------------

  function test_a_write_records_what_qbittorrent_held_before_and_after() {
    var o = make()
    compare(stack(o), [])
    editTo(o, "up_limit", "10.3M")
    compare(writes(o), [["up_limit", "10800128"]], "10.3M rounded to whole KiB")
    compare(stack(o), [], "nothing until the write succeeds and the re-read is in")
    finish(o, true)
    compare(stack(o), [], "nor before the re-read")
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10801152 }) })
    compare(stack(o), [{ key: "up_limit", label: "Upload limit", from: 1048576, to: 10801152 }], "the read-back values, not what was typed")
    compare(o.c.registryState([]).settingsUndoCount, 1)
    compare(view(o).undoCount, 1)
  }

  function test_a_composite_records_hour_and_min_and_undo_writes_hh_mm() {
    var o = make()
    editTo(o, "schedule_from", "09:30")
    compare(writes(o), [["schedule_from", "09:30"]])
    saved(o, prefs({ schedule_from_hour: 9, schedule_from_min: 30 }))
    compare(stack(o), [{ key: "schedule_from", label: "From", from: { hour: 8, min: 0 }, to: { hour: 9, min: 30 } }])
    undo(o, prefs({ schedule_from_hour: 9, schedule_from_min: 30 }))
    compare(o.c.confirm, null)
    compare(writes(o)[1], ["schedule_from", "08:00"])
    compare(stack(o), [])
    saved(o, prefs())
    compare(status(o), "From back to 08:00")
    compare(stack(o), [], "an undo records nothing")
  }

  function test_a_write_whose_read_back_is_unchanged_records_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs())
    compare(stack(o), [], "EC: a no-op isn't recorded")
  }

  function test_a_failed_write_or_a_failed_re_read_records_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    finish(o, false, "qBittorrent ignored Upload limit")
    compare(stack(o), [])
    editTo(o, "up_limit", "10M")
    finish(o, true)
    o.svc.answer({ ok: false, error: "HTTP 500" })
    compare(stack(o), [])
    view(o).reload(true)
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10485760 }) })
    compare(stack(o), [], "a later read doesn't bring it back")
  }

  function test_secrets_are_never_recorded_and_stay_in_no_property() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    enter(o)
    typeAndEnter(o, secret)
    compare(calls(o.svc, "setSecret").length, 1)
    finishSecret(o, true)
    o.svc.answer({ ok: true, prefs: secrets({ proxy_password: { set: true } }) })
    compare(stack(o), [], "Ruling EH: a secret set isn't undoable")
    focusKey(o, "dyndns_password")
    key(o.c, "x")
    key(o.c, "y")
    compare(calls(o.svc, "clearSecret").length, 1)
    finishSecret(o, true)
    o.svc.answer({ ok: true, prefs: secrets({ proxy_password: { set: true }, dyndns_password: { set: false } }) })
    compare(stack(o), [], "nor a clear")
    compare(sweepAll(o, secret), [], "the value is in no property, the history included")
  }

  function test_a_ban_add_is_not_recorded_and_an_unban_that_changed_nothing_is_not_either() {
    var o = make(lists())
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    key(o.c, "a")
    typeAndEnter(o, "198.51.100.7")
    saved(o, lists({ banned_IPs: "10.0.0.1\n2001:db8::1\n198.51.100.7" }))
    compare(stack(o), [], "ban adds aren't undone")
    key(o.c, "x")
    compare(calls(o.svc, "banList")[1].args.slice(0, 2), ["remove", "10.0.0.1"])
    saved(o, lists({ banned_IPs: "10.0.0.1\n2001:db8::1\n198.51.100.7" }))
    compare(stack(o), [], "EC: still banned after the re-read, so nothing to undo")
  }

  // ---- u ------------------------------------------------------------------------

  function test_u_writes_the_old_value_back_and_notes_it_with_what_is_left() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    editTo(o, "dl_limit", "2M")
    saved(o, prefs({ up_limit: 10485760, dl_limit: 2097152 }))
    compare(stack(o).length, 2)
    verify(footerKeys(o).indexOf("u") !== -1, "the footer shows u undo")
    undo(o, prefs({ up_limit: 10485760, dl_limit: 2097152 }))
    compare(writes(o)[2], ["dl_limit", "0"], "newest first")
    compare(o.c.confirm, null, "unchanged since the edit and not risky: no question")
    compare(status(o), "Saving Download limit…")
    saved(o, prefs({ up_limit: 10485760 }))
    compare(status(o), "Download limit back to unlimited · 1 more to undo")
    compare(stack(o).length, 1)
    undo(o, prefs({ up_limit: 10485760 }))
    compare(writes(o)[3], ["up_limit", "1048576"])
    saved(o, prefs())
    compare(status(o), "Upload limit back to 1 MiB/s")
    compare(stack(o), [])
    verify(footerKeys(o).indexOf("u") === -1, "and hides it once there's nothing left")
    var reads = calls(o.svc, "readPrefs").length
    key(o.c, "u")
    compare(calls(o.svc, "readPrefs").length, reads, "an empty history reads nothing")
    compare(writes(o).length, 4, "and writes nothing")
  }

  function test_u_works_from_a_list_and_restores_tiers_and_empty_lines_exactly() {
    var before = "udp://a.example/announce\n\nhttp://b.example/announce"
    var o = make(lists())
    openListOf(o, "add_trackers")
    key(o.c, "j")
    key(o.c, "x")
    compare(writes(o), [["add_trackers", "udp://a.example/announce\nhttp://b.example/announce"]])
    saved(o, lists({ add_trackers: "udp://a.example/announce\nhttp://b.example/announce" }))
    compare(stack(o)[0].from, before)
    compare(o.c.keyPane, "settingsList")
    undo(o, lists({ add_trackers: "udp://a.example/announce\nhttp://b.example/announce" }))
    compare(writes(o)[1], ["add_trackers", before], "the whole value, tier break included")
    saved(o, lists())
    compare(status(o), "Trackers to add back to 2 trackers in 2 tiers")
  }

  function test_u_re_adds_an_unbanned_address_as_stored() {
    var o = make(lists())
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    key(o.c, "j")
    key(o.c, "x")
    compare(calls(o.svc, "banList")[0].args.slice(0, 2), ["remove", "2001:db8::1"])
    saved(o, lists({ banned_IPs: "10.0.0.1" }))
    compare(stack(o), [{ kind: "ban", ip: "2001:db8::1" }])
    undo(o, lists({ banned_IPs: "10.0.0.1" }))
    compare(o.c.confirm, null)
    compare(calls(o.svc, "banList")[1].args.slice(0, 2), ["add", "2001:db8::1"])
    compare(writes(o).length, 0, "through ban-list, never pref-set")
    saved(o, lists())
    compare(status(o), "Banned 2001:db8::1 again")
    compare(stack(o), [])
  }

  function test_u_on_an_address_banned_again_since_writes_nothing() {
    var o = make(lists())
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    key(o.c, "x")
    saved(o, lists({ banned_IPs: "2001:db8::1" }))
    undo(o, lists())
    compare(calls(o.svc, "banList").length, 1)
    compare(status(o), "10.0.0.1 is already banned")
    compare(stack(o), [])
  }

  function test_u_on_a_value_changed_since_asks_once_and_y_sets_it_back() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    undo(o, prefs({ up_limit: 20971520 }))
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.line, "Upload limit changed to 20 MiB/s since your edit. Set it back to 1 MiB/s?")
    compare(o.c.confirm.detail, "")
    compare(o.c.confirm.accept, "set back")
    compare(writes(o).length, 1, "nothing written over the newer value without asking")
    key(o.c, "y")
    compare(o.c.mode, "NORMAL")
    compare(writes(o)[1], ["up_limit", "1048576"])
    saved(o, prefs())
    compare(status(o), "Upload limit back to 1 MiB/s")
    compare(stack(o), [], "and the undo itself isn't recorded")
  }

  function test_n_on_a_changed_value_keeps_it_and_the_next_u_moves_on() {
    var o = make()
    editTo(o, "dl_limit", "2M")
    saved(o, prefs({ dl_limit: 2097152 }))
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ dl_limit: 2097152, up_limit: 10485760 }))
    undo(o, prefs({ dl_limit: 2097152, up_limit: 20971520 }))
    compare(o.c.mode, "CONFIRM")
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    compare(writes(o).length, 2, "n writes nothing")
    compare(stack(o).length, 1, "that entry is done with")
    undo(o, prefs({ dl_limit: 2097152, up_limit: 20971520 }))
    compare(writes(o)[2], ["dl_limit", "0"])
  }

  function test_a_risky_undo_confirms_with_its_reason() {
    var o = make(prefs({ listen_port: 51413 }))
    editTo(o, "listen_port", "51414")
    compare(o.c.mode, "CONFIRM", "changing the port asks")
    key(o.c, "y")
    saved(o, prefs({ listen_port: 51414 }))
    undo(o, prefs({ listen_port: 51414 }))
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.line, "Set Port for incoming connections to 51413?")
    compare(o.c.confirm.detail, SettingsView.confirmFor("listen_port", 51414, 51413))
    verify(o.c.confirm.detail !== "")
    compare(writes(o).length, 1)
    key(o.c, "y")
    compare(writes(o)[1], ["listen_port", "51413"])
    saved(o, prefs({ listen_port: 51413 }))
    compare(status(o), "Port for incoming connections back to 51413")
  }

  function test_a_stale_risky_undo_is_one_merged_confirm() {
    var o = make(prefs({ encryption: 1 }))
    focusKey(o, "encryption")
    enter(o)
    choose(o, 0)
    compare(o.c.mode, "NORMAL", "Prefer asks nothing")
    compare(writes(o), [["encryption", "0"]])
    saved(o, prefs({ encryption: 0 }))
    undo(o, prefs({ encryption: 2 }))
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.line, "Encryption changed to Disable since your edit. Set it back to Require?")
    compare(o.c.confirm.detail, "Peers that don't encrypt are dropped.")
    key(o.c, "y")
    compare(o.c.mode, "NORMAL", "one CONFIRM, never two in a row")
    compare(writes(o)[1], ["encryption", "1"])
    saved(o, prefs({ encryption: 1 }))
    compare(status(o), "Encryption back to Require")
  }

  function test_u_on_a_value_already_back_writes_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    undo(o, prefs())
    compare(o.c.confirm, null)
    compare(writes(o).length, 1)
    compare(status(o), "Upload limit is already 1 MiB/s")
    compare(stack(o), [])
  }

  function test_u_skips_a_value_qbt_would_refuse_with_a_note() {
    var o = make(prefs({ excluded_file_names: "*.exe\n\n*.scr" }))
    openListOf(o, "excluded_file_names")
    key(o.c, "j")
    key(o.c, "x")
    compare(writes(o), [["excluded_file_names", "*.exe\n*.scr"]])
    saved(o, prefs({ excluded_file_names: "*.exe\n*.scr" }))
    compare(stack(o).length, 1)
    undo(o, prefs({ excluded_file_names: "*.exe\n*.scr" }))
    compare(writes(o).length, 1, "an empty pattern qbt would refuse isn't sent")
    compare(o.c.confirm, null)
    compare(status(o), "Skipped undoing Excluded file names: Use a pattern such as *.exe")
    compare(stack(o), [])
  }

  function test_u_skips_an_unban_ban_list_add_would_refuse() {
    var o = make(lists({ banned_IPs: "fe80::1%eth0\n10.0.0.1" }))
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    key(o.c, "x")
    compare(calls(o.svc, "banList")[0].args.slice(0, 2), ["remove", "fe80::1%eth0"])
    saved(o, lists({ banned_IPs: "10.0.0.1" }))
    compare(stack(o), [{ kind: "ban", ip: "fe80::1%eth0" }])
    undo(o, lists({ banned_IPs: "10.0.0.1" }))
    compare(calls(o.svc, "banList").length, 1)
    compare(status(o), "Skipped undoing the unban of fe80::1%eth0: Use an IPv4 or IPv6 address")
  }

  function test_u_skips_a_setting_dimmed_since() {
    var o = make()
    editTo(o, "schedule_to", "21:00")
    saved(o, prefs({ schedule_to_hour: 21 }))
    undo(o, prefs({ schedule_to_hour: 21, scheduler_enabled: false }))
    compare(writes(o).length, 1)
    compare(status(o), "Skipped undoing To: schedule off")
  }

  function test_a_failed_undo_write_puts_its_entry_back() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    undo(o, prefs({ up_limit: 10485760 }))
    compare(stack(o), [])
    finish(o, false, "qBittorrent ignored Upload limit")
    compare(status(o), "qBittorrent ignored Upload limit")
    compare(stack(o).length, 1, "u can try again")
  }

  function test_a_failed_undo_read_keeps_the_entry() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    key(o.c, "u")
    o.svc.answer({ ok: false, error: "HTTP 500" })
    compare(writes(o).length, 1)
    compare(status(o), "Couldn't read the settings; nothing was undone.")
    compare(stack(o).length, 1)
  }

  function test_u_waits_while_a_write_is_saving() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    editTo(o, "dl_limit", "2M")
    var reads = calls(o.svc, "readPrefs").length
    key(o.c, "u")
    compare(calls(o.svc, "readPrefs").length, reads)
    compare(status(o), "Wait for the change to save, then undo.")
    compare(writes(o).length, 2)
  }

  function test_a_re_read_landing_on_an_open_field_changes_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    key(o.c, "u")
    focusKey(o, "listen_port")
    enter(o)
    compare(o.c.mode, "INSERT")
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 20971520 }) })
    compare(o.c.mode, "INSERT", "no question over the field")
    compare(o.c.confirm, null)
    compare(writes(o).length, 1)
    compare(stack(o).length, 1, "the entry stays")
    esc(o)
    compare(o.c.mode, "NORMAL")
    undo(o, prefs({ up_limit: 10485760 }))
    compare(writes(o)[1], ["up_limit", "1048576"])
  }

  function test_the_empty_history_notes_nothing_to_undo_and_writes_nothing() {
    var o = make()
    compare(Registry.needsReason("undoEntry", o.c.registryState([])), "nothing to undo", "the palette row says why")
    cmds(o).run("settings.undo", {})
    compare(status(o), "Nothing to undo.")
    compare(calls(o.svc, "readPrefs").length, 1, "only the read on open")
    compare(writes(o).length, 0)
  }

  // ---- leaving -----------------------------------------------------------------

  function test_leaving_settings_clears_the_history() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    compare(stack(o).length, 1)
    leaveSettings(o)
    compare(stack(o), [])
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10485760 }) })
    compare(stack(o), [])
    compare(o.c.registryState([]).settingsUndoCount, 0)
  }

  function test_a_write_that_ends_after_leaving_is_not_recorded_on_return() {
    var o = make()
    editTo(o, "up_limit", "10M")
    leaveSettings(o)
    comma(o)
    finish(o, true)
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10485760 }) })
    compare(stack(o), [], "the write belongs to the last visit")
  }

  function test_an_undo_question_is_dropped_with_the_window() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    undo(o, prefs({ up_limit: 20971520 }))
    compare(o.c.mode, "CONFIRM")
    o.c.close()
    compare(o.c.confirm, null)
    compare(stack(o), [])
  }

  // ---- the final fix wave (window lane) ------------------------------------------

  // E1 (Ruling EI): u as a key with nothing to undo says so; the other
  // Settings keys a row blocks stay silent (their row already says why).
  function test_u_as_a_key_with_nothing_to_undo_says_so() {
    var o = make()
    focusKey(o, "listen_port")
    key(o.c, "u")
    compare(status(o), "Nothing to undo.")
    compare(calls(o.svc, "readPrefs").length, 1, "only the read on open")
    compare(writes(o).length, 0)
    key(o.c, "j")
    compare(status(o), "")
    focusKey(o, "listen_port")
    space(o)
    compare(status(o), "", "Space on a value row is still blocked with no note")
    focusKey(o, "dht")
    enter(o)
    compare(status(o), "", "Enter on an on/off row too")
  }

  // E2: a failed undo write goes back at its own depth, under newer entries.
  function test_a_failed_undo_write_goes_back_under_newer_entries() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    editTo(o, "dl_limit", "2M")
    saved(o, prefs({ up_limit: 10485760, dl_limit: 2097152 }))
    undo(o, prefs({ up_limit: 10485760, dl_limit: 2097152 }))
    compare(writes(o)[2], ["dl_limit", "0"])
    var undoTicket = o.svc.seq
    editTo(o, "max_connec", "600")
    compare(writes(o)[3], ["max_connec", "600"])
    saved(o, prefs({ up_limit: 10485760, dl_limit: 2097152, max_connec: 600 }))
    compare(stack(o).map(function(e) { return e.key }), ["up_limit", "max_connec"])
    o.svc.actionFinished(undoTicket, false, "qBittorrent ignored Download limit", "window", [])
    compare(stack(o).map(function(e) { return e.key }), ["up_limit", "dl_limit", "max_connec"], "back where it was")
    compare(Object.keys(stack(o)[1]).sort(), ["from", "key", "label", "to"], "as it was recorded")
  }

  function test_a_failed_confirmed_undo_write_goes_back_under_newer_entries_too() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    editTo(o, "dl_limit", "2M")
    saved(o, prefs({ up_limit: 10485760, dl_limit: 2097152 }))
    undo(o, prefs({ up_limit: 10485760, dl_limit: 4194304 }))
    compare(o.c.mode, "CONFIRM", "changed since: asks")
    key(o.c, "y")
    compare(writes(o)[2], ["dl_limit", "0"])
    var undoTicket = o.svc.seq
    editTo(o, "max_connec", "600")
    saved(o, prefs({ up_limit: 10485760, dl_limit: 4194304, max_connec: 600 }))
    compare(stack(o).map(function(e) { return e.key }), ["up_limit", "max_connec"])
    o.svc.actionFinished(undoTicket, false, "qBittorrent ignored Download limit", "window", [])
    compare(stack(o).map(function(e) { return e.key }), ["up_limit", "dl_limit", "max_connec"], "back where it was")
    compare(Object.keys(stack(o)[1]).sort(), ["from", "key", "label", "to"])
  }

  // E3: u does nothing under the down screen.
  function test_u_under_the_down_screen_reads_and_writes_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    o.svc.api = false
    verify(view(o).failed)
    var reads = calls(o.svc, "readPrefs").length
    key(o.c, "u")
    compare(calls(o.svc, "readPrefs").length, reads, "no read under the down screen")
    compare(status(o), "The settings aren't loaded; nothing was undone.")
    compare(writes(o).length, 1)
    compare(stack(o).length, 1, "the entry stays for when they're back")
  }

  function test_u_whose_read_lands_on_the_down_screen_writes_nothing() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    key(o.c, "u")
    o.svc.api = false
    verify(view(o).failed)
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10485760 }) })
    verify(view(o).failed, "the down screen stays")
    compare(writes(o).length, 1)
    compare(stack(o).length, 1)
  }

  // E4: a second u while the first one's read is out says so.
  function test_a_second_u_while_the_read_is_out_says_so() {
    var o = make()
    editTo(o, "up_limit", "10M")
    saved(o, prefs({ up_limit: 10485760 }))
    var reads = calls(o.svc, "readPrefs").length
    key(o.c, "u")
    key(o.c, "u")
    compare(calls(o.svc, "readPrefs").length, reads + 1, "one read")
    compare(status(o), "Still checking the last undo.")
    o.svc.answer({ ok: true, prefs: prefs({ up_limit: 10485760 }) })
    compare(writes(o)[1], ["up_limit", "1048576"])
    compare(writes(o).length, 2, "one undo")
  }

  // E5 (Ruling EJ): a write u can undo says so; ban adds, secrets and undo's
  // own writes don't.
  function test_the_done_note_of_an_undoable_write_says_u_undoes() {
    var o = make(lists(secrets()))
    editTo(o, "up_limit", "10M")
    finish(o, true)
    compare(status(o), "Upload limit set to 10 MiB/s · u undoes")
    o.svc.answer({ ok: true, prefs: lists(secrets({ up_limit: 10485760 })) })
    undo(o, lists(secrets({ up_limit: 10485760 })))
    finish(o, true)
    verify(status(o).indexOf("u undoes") === -1, "an undo's own note: " + status(o))
    o.svc.answer({ ok: true, prefs: lists(secrets()) })
    focusKey(o, "proxy_password")
    enter(o)
    typeAndEnter(o, secret)
    finishSecret(o, true)
    compare(status(o), "Proxy password set")
    o.svc.answer({ ok: true, prefs: lists(secrets({ proxy_password: { set: true } })) })
    key(o.c, "h")
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    key(o.c, "a")
    typeAndEnter(o, "198.51.100.7")
    finish(o, true)
    compare(status(o), "Banned 198.51.100.7")
    o.svc.answer({ ok: true, prefs: lists(secrets({ banned_IPs: "10.0.0.1\n2001:db8::1\n198.51.100.7" })) })
    key(o.c, "x")
    finish(o, true)
    verify(/^Unbanned \S+ · u undoes$/.test(status(o)), "an unban: " + status(o))
  }

  function test_a_write_that_ends_after_leaving_does_not_offer_u() {
    var o = make()
    editTo(o, "up_limit", "10M")
    leaveSettings(o)
    finish(o, true)
    compare(status(o), "Upload limit set to 10 MiB/s")
  }

  // ---- slice 5b2 (D8): undo never turns auto-download on unasked ----------------------

  function test_u_turning_auto_download_back_on_counts_and_asks_first() {
    var k = "rss_auto_downloading_enabled"
    var o = make(prefs({ rss_auto_downloading_enabled: true }))
    focusKey(o, k)
    space(o)
    compare(writes(o), [[k, "false"]], "turning it off asks nothing")
    saved(o, prefs({ rss_auto_downloading_enabled: false }))
    compare(stack(o).length, 1)
    undo(o, prefs({ rss_auto_downloading_enabled: false }))
    compare(calls(o.svc, "rssAutoPreview").length, 1, "the undo counts first")
    compare(writes(o).length, 1, "and writes nothing yet")
    o.svc.answerAuto(true, "", { rules: 1, will: 2, noTorrent: 0 })
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.kind, "rssAutoDlOn")
    compare(o.c.confirm.line, SettingsView.AUTO_DL.confirmAutoDl.replace("<r>", "1").replace("<n>", "2"))
    key(o.c, "y")
    compare(writes(o)[1], [k, "true"])
    saved(o, prefs({ rss_auto_downloading_enabled: true }))
    compare(stack(o).length, 0, "undo's own write records nothing")
    compare(status(o), SettingsView.undoDoneNote(k, "RSS auto-downloading", true, 0))
  }

  function test_u_turning_auto_download_on_refuses_on_no_torrent_links() {
    var k = "rss_auto_downloading_enabled"
    var o = make(prefs({ rss_auto_downloading_enabled: true }))
    focusKey(o, k)
    space(o)
    saved(o, prefs({ rss_auto_downloading_enabled: false }))
    undo(o, prefs({ rss_auto_downloading_enabled: false }))
    o.svc.answerAuto(true, "", { rules: 1, will: 2, noTorrent: 4 })
    compare(o.c.mode, "NORMAL", "no confirm")
    compare(writes(o).length, 1, "nothing more is written")
    compare(status(o), SettingsView.AUTO_DL.autoDlNoTorrent.replace("<m>", "4"))
    compare(stack(o).length, 1, "the entry is back for a later u")
  }

  function test_n_on_the_undo_auto_download_question_writes_nothing() {
    var k = "rss_auto_downloading_enabled"
    var o = make(prefs({ rss_auto_downloading_enabled: true }))
    focusKey(o, k)
    space(o)
    saved(o, prefs({ rss_auto_downloading_enabled: false }))
    undo(o, prefs({ rss_auto_downloading_enabled: false }))
    o.svc.answerAuto(false, "down", null)
    compare(o.c.confirm.line, SettingsView.AUTO_DL.confirmAutoDlUncounted)
    key(o.c, "n")
    compare(writes(o).length, 1)
    compare(stack(o).length, 0, "n is a decision, as for any undo question")
  }
}
