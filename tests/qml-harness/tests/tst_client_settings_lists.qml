import QtQuick
import QtTest
import qs.Commons
import "../../.."
import "../../../SettingsSchema.js" as Schema
import "../../../SettingsView.js" as SettingsView
import "../../../ClientView.js" as View
import "../../../CommandRegistry.js" as Registry

// Slice 4b (Task 3): the list editor (banned IPs, add_trackers,
// excluded_file_names), the secret field, and the narrow Settings layout.
// The service stub records setPref, setSecret, clearSecret and banList and
// keeps each readPrefs callback so a test answers it; finish() plays
// Service's actionFinished, finishSecret its secretFinished. The secret
// sweep walks SettingsCommands, SettingsPane and the Client's own
// properties after a send (Service's own is in tst_service.qml).
TestCase {
  id: tc
  name: "ClientSettingsLists"
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
    var d = o.c.data
    for (var i = 0; i < d.length; i++) if (d[i] && typeof d[i].commitSecret === "function") return d[i]
    return null
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

  // ---- the list editor ------------------------------------------------------------

  // Replaces 4a's test_a_multiline_row_does_nothing (Ruling DH is lifted).
  function test_enter_on_a_list_row_opens_its_lines_and_esc_goes_back() {
    var o = make()
    focusKey(o, "excluded_file_names")
    compare(findName(rowItem(o, "excluded_file_names"), "settingsTag").text, "list")
    compare(valueText(o, "excluded_file_names"), "2 patterns")
    enter(o)
    compare(o.c.keyPane, "settingsList")
    compare(o.c.mode, "NORMAL")
    compare(listTexts(o), ["*.exe", "*.scr"])
    key(o.c, "j")
    compare(view(o).listItem.value, "*.scr")
    key(o.c, "j")
    compare(view(o).listIndex, 1, "stops at the end")
    esc(o)
    compare(o.c.keyPane, "settingsKeys")
    compare(view(o).cursorRow.key, "excluded_file_names")
    compare(writes(o).length, 0)
    verify(view(o).open)
  }

  function test_a_adds_a_line_after_the_cursor_and_writes_the_whole_list_exactly() {
    var o = make(prefs({ excluded_file_names: "*.exe\n\n say \"hi\" \\ \u{1F98A}" }))
    openListOf(o, "excluded_file_names")
    compare(listTexts(o), ["*.exe", "(empty line)", " say \"hi\" \\ \u{1F98A}"])
    key(o.c, "a")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "settingEdit")
    compare(line(o).inputPrompt.prompt, "Add a file name pattern")
    compare(line(o).inputValue(), "")
    typeAndEnter(o, "")
    compare(o.c.mode, "INSERT")
    compare(status(o), "Use a pattern such as *.exe.")
    typeAndEnter(o, "*.bat")
    compare(o.c.mode, "NORMAL")
    compare(writes(o), [["excluded_file_names", "*.exe\n*.bat\n\n say \"hi\" \\ \u{1F98A}"]], "every other line exactly as it was")
    compare(view(o).listItems.length, 3, "the list shows qBittorrent's value until the re-read")
    key(o.c, "a")
    compare(o.c.mode, "NORMAL", "no second write while one saves")
    finish(o, true)
    compare(status(o), "Added *.bat to Excluded file names")
    o.svc.answer({ ok: true, prefs: prefs({ excluded_file_names: "*.exe\n*.bat\n\n say \"hi\" \\ \u{1F98A}" }) })
    compare(view(o).listItem.value, "*.bat", "the cursor on the new line")
  }

  function test_an_add_whose_list_changed_while_typing_writes_nothing() {
    var o = make()
    openListOf(o, "excluded_file_names")
    key(o.c, "a")
    view(o).reload(true)
    o.svc.answer({ ok: true, prefs: prefs({ excluded_file_names: "*.exe\n*.scr\n*.com" }) })
    typeAndEnter(o, "*.bat")
    compare(o.c.mode, "NORMAL")
    compare(writes(o).length, 0, "the newer list isn't written over")
    compare(status(o), "The list changed; nothing was added.")
  }

  function test_tab_and_shift_tab_in_a_list_do_nothing_wide_or_narrow() {
    var o = make()
    openListOf(o, "excluded_file_names")
    tab(o); backtab(o); key(o.c, "h")
    compare(o.c.keyPane, "settingsList")
    compare(o.c.pane, "table", "the torrent pane underneath is untouched")
    winOf(o.c).width = 800
    wait(30)
    tab(o); backtab(o)
    compare(o.c.keyPane, "settingsList")
    compare(o.c.pane, "table")
  }

  function test_x_removes_the_cursor_line_without_a_confirm() {
    var o = make()
    openListOf(o, "excluded_file_names")
    key(o.c, "x")
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    compare(writes(o), [["excluded_file_names", "*.scr"]])
    finish(o, false, "qBittorrent ignored Excluded file names")
    compare(status(o), "qBittorrent ignored Excluded file names")
    compare(listTexts(o), ["*.exe", "*.scr"], "a failure keeps the list")
  }

  function test_trackers_show_tier_breaks_and_an_empty_add_is_the_next_tier() {
    var o = make(lists())
    openListOf(o, "add_trackers")
    compare(listTexts(o), ["udp://a.example/announce", "— next tier —", "http://b.example/announce"])
    key(o.c, "j"); key(o.c, "j")
    key(o.c, "a")
    compare(line(o).inputPrompt.prompt, "Add a tracker URL (empty: next tier)")
    typeAndEnter(o, "wss://c.example/announce")
    compare(status(o), "Use an http, https or udp tracker URL.")
    typeAndEnter(o, "— next tier —")
    compare(o.c.mode, "INSERT", "the marker isn't a URL")
    typeAndEnter(o, "")
    compare(writes(o), [["add_trackers", "udp://a.example/announce\n\nhttp://b.example/announce\n"]])
    finish(o, true)
    compare(status(o), "Next tier added to Trackers to add")
  }

  // Ruling EC: qbt checks only the lines it doesn't already store.
  function test_a_stored_line_qbt_would_refuse_does_not_block_a_valid_add() {
    // qBittorrent's own UI may have stored it.
    var o = make(lists({ add_trackers: "udp://a.example/announce\nhttp://has space/announce" }))
    openListOf(o, "add_trackers")
    key(o.c, "a")
    typeAndEnter(o, "http://also bad/announce")
    compare(o.c.mode, "INSERT", "the new line is still checked")
    compare(status(o), "Use an http, https or udp tracker URL.")
    typeAndEnter(o, "udp://c.example/announce")
    compare(o.c.mode, "NORMAL")
    compare(writes(o), [["add_trackers", "udp://a.example/announce\nudp://c.example/announce\nhttp://has space/announce"]],
      "the stored odd line round-trips unchanged")
  }

  function test_x_on_a_tier_break_joins_the_tiers_and_touches_nothing_else() {
    var o = make(lists())
    openListOf(o, "add_trackers")
    key(o.c, "j")
    compare(view(o).listItem.tierBreak, true)
    key(o.c, "x")
    compare(writes(o), [["add_trackers", "udp://a.example/announce\nhttp://b.example/announce"]])
  }

  function test_a_dimmed_list_row_does_not_open() {
    var o = make(lists({ add_trackers_enabled: false }))
    focusKey(o, "add_trackers")
    enter(o)
    compare(o.c.keyPane, "settingsKeys")
    compare(o.c.mode, "NORMAL")
  }

  function test_an_empty_list_says_how_to_add() {
    var o = make(lists({ add_trackers: "" }))
    openListOf(o, "add_trackers")
    compare(listTexts(o), [])
    compare(findName(content(o), "settingsListEmpty").text, "No trackers to add. Press a to add a tracker URL.")
    key(o.c, "x")
    compare(writes(o).length, 0)
    key(o.c, "a")
    typeAndEnter(o, "")
    compare(o.c.mode, "NORMAL", "a lone tier break changes nothing")
    compare(writes(o).length, 0)
  }

  // ---- Banned IPs -----------------------------------------------------------------

  function test_banned_ips_is_a_section_whose_column_is_the_list() {
    var o = make(lists())
    var v = view(o)
    var names = v.sectionList.map(function(s) { return s.name })
    compare(names.indexOf("Banned IPs"), names.indexOf("Advanced") + 1)
    focusSection(o, "Banned IPs")
    compare(listTexts(o), ["10.0.0.1", "2001:db8::1"], "previewed while the sections have focus")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsList")
    compare(v.listKey, "banned_IPs")
    key(o.c, "a")
    compare(line(o).inputPrompt.prompt, "Ban an IP address")
    typeAndEnter(o, " 203.0.113.5")
    compare(status(o), "Use an IPv4 or IPv6 address.")
    typeAndEnter(o, "2001:DB8:0:0:0:0:0:1")
    compare(o.c.mode, "NORMAL")
    compare(status(o), "2001:db8::1 is already banned.")
    compare(calls(o.svc, "banList").length, 0)
    // Checked against the list as it stands at Enter, not at a.
    key(o.c, "a")
    view(o).reload(true)
    o.svc.answer({ ok: true, prefs: lists({ banned_IPs: "10.0.0.1\n2001:db8::1\n198.51.100.7" }) })
    typeAndEnter(o, "198.51.100.7")
    compare(status(o), "198.51.100.7 is already banned.")
    compare(calls(o.svc, "banList").length, 0)
    key(o.c, "a")
    typeAndEnter(o, "2001:DB8::5")
    compare(calls(o.svc, "banList").map(function(x) { return [x.args[0], x.args[1]] }), [["add", "2001:db8::5"]], "sent in QHostAddress form")
    compare(calls(o.svc, "banList")[0].args[2].origin, "window")
    var reads = calls(o.svc, "readPrefs").length
    finish(o, true)
    compare(status(o), "Banned 2001:db8::5")
    compare(calls(o.svc, "readPrefs").length, reads + 1)
    o.svc.answer({ ok: true, prefs: lists({ banned_IPs: "10.0.0.1\n198.51.100.7\n2001:db8::1\n2001:db8::5" }) })
    key(o.c, "k"); key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    key(o.c, "x")
    compare(o.c.confirm, null, "unbanning asks nothing")
    compare(calls(o.svc, "banList")[1].args.slice(0, 2), ["remove", "10.0.0.1"])
    finish(o, false, "qBittorrent still bans 10.0.0.1.")
    compare(status(o), "qBittorrent still bans 10.0.0.1.", "qbt's ban sentences show as they are")
    esc(o)
    compare(o.c.keyPane, "settingsSections", "back to the sections")
    verify(v.open)
  }

  function test_no_banned_ips_shows_the_design_empty_state() {
    var o = make(lists({ banned_IPs: "" }))
    focusSection(o, "Banned IPs")
    key(o.c, "l")
    compare(findName(content(o), "settingsListEmpty").text, "No banned IPs. Ban a peer with b on the Peers tab, or a to add one here.")
  }

  // ---- secrets ----------------------------------------------------------------------

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
    var d = o.c.data
    for (var i = 0; i < d.length; i++) if (d[i] && typeof d[i].runPaletteRow === "function") return d[i]
    return null
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

  function test_the_sweep_finds_a_planted_value() {
    var o = make(secrets())
    compare(sweepAll(o, secret), [])
    view(o).error = "x" + secret
    verify(sweepAll(o, secret).indexOf("SettingsPane.error") !== -1, "a planted value is caught")
    view(o).error = ""
    cmds(o).input = { kind: "value", key: "k", label: secret }
    verify(sweepAll(o, secret).indexOf("SettingsCommands.input") !== -1)
    cmds(o).input = null
    verify(findWith(content(o), "complete").evalState !== undefined, "the sweep reaches the palette")
    line(o).setInput(secret)
    verify(sweepAll(o, secret).some(function(h) { return h.indexOf("StatusLine") === 0 }), "and the status line's field")
    line(o).setInput("")
    clientCommands(o).paletteRange = [secret]
    verify(sweepAll(o, secret).indexOf("ClientCommands.paletteRange") !== -1, "and ClientCommands")
    clientCommands(o).paletteRange = []
    o.c.messages = View.msgNote(o.c.messages, secret, "muted")
    verify(sweepAll(o, secret).length > 0, "the Client's messages are swept")
  }

  function test_enter_on_a_secret_opens_a_masked_field_and_sends_the_value_to_setSecret_only() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    compare(valueText(o, "proxy_password"), "not set")
    verify(findName(content(o), "settingsHelp").text.indexOf("4b") === -1, "no 'arrives in 4b'")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "settingEdit")
    compare(line(o).inputPrompt.prompt, "Proxy password")
    compare(line(o).inputValue(), "", "never prefilled")
    compare(field(o).echoMode, TextInput.Password)
    typeAndEnter(o, secret)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "setSecret").map(function(x) { return [x.args[0], x.args[1]] }), [["proxy_password", secret]])
    compare(writes(o).length, 0, "never pref-set --")
    compare(field(o).text, "", "the field is emptied at once")
    compare(field(o).echoMode, TextInput.Normal)
    compare(status(o), "Saving Proxy password…")
    compare(valueText(o, "proxy_password"), "saving…")
    compare(sweepAll(o, secret), [], "the value is in no property")
    var reads = calls(o.svc, "readPrefs").length
    finishSecret(o, true)
    compare(status(o), "Proxy password set")
    compare(calls(o.svc, "readPrefs").length, reads + 1)
    o.svc.answer({ ok: true, prefs: secrets({ proxy_password: { set: true } }) })
    compare(valueText(o, "proxy_password"), "set")
    compare(sweepAll(o, secret), [])
  }

  function test_an_empty_enter_on_a_secret_changes_nothing() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    enter(o)
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "setSecret").length, 0)
    compare(field(o).echoMode, TextInput.Normal)
  }

  function test_a_refused_secret_stays_masked_and_esc_empties_the_field() {
    var o = make(secrets())
    focusKey(o, "dyndns_password")
    enter(o)
    var long = ""
    for (var i = 0; i < 1025; i++) long += "a"
    typeAndEnter(o, long)
    compare(o.c.mode, "INSERT")
    compare(status(o), "Use at most 1024 characters.")
    compare(field(o).echoMode, TextInput.Password)
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(field(o).text, "", "Esc leaves nothing in the field")
    compare(field(o).echoMode, TextInput.Normal)
    compare(calls(o.svc, "setSecret").length, 0)
    compare(sweepAll(o, long), [])
  }

  function test_a_failed_secret_write_says_why_and_never_the_value() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    enter(o)
    typeAndEnter(o, secret)
    finishSecret(o, false, "Keep it to one line.")
    compare(status(o), "Keep it to one line.")
    compare(valueText(o, "proxy_password"), "not set")
    compare(sweepAll(o, secret), [])
  }

  function test_closing_the_window_while_typing_a_secret_empties_the_field() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    enter(o)
    line(o).setInput(secret)
    o.c.close()
    compare(field(o).text, "")
    compare(sweepAll(o, secret), [])
  }

  function test_x_on_a_set_secret_confirms_then_clears() {
    var o = make(secrets({ proxy_password: { set: true } }))
    focusKey(o, "proxy_password")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    compare(View.confirmLine(o.c.confirm).lead, "Clear the proxy password? ")
    key(o.c, "n")
    compare(calls(o.svc, "clearSecret").length, 0)
    key(o.c, "x")
    key(o.c, "y")
    compare(calls(o.svc, "clearSecret").map(function(x) { return x.args[0] }), ["proxy_password"])
    finish(o, true)
    compare(status(o), "Proxy password cleared")
  }

  function test_x_does_nothing_on_an_unset_or_dimmed_secret_and_a_dimmed_one_does_not_edit() {
    var o = make(secrets())
    focusKey(o, "proxy_password")
    key(o.c, "x")
    compare(o.c.mode, "NORMAL")
    focusKey(o, "mail_notification_password")
    compare(valueText(o, "mail_notification_password"), "set (SMTP login off)")
    key(o.c, "x")
    enter(o)
    compare(o.c.mode, "NORMAL", "Ruling EB: dimmed shows set but doesn't edit")
    compare(calls(o.svc, "clearSecret").length + calls(o.svc, "setSecret").length, 0)
  }

  function test_closing_settings_drops_a_clear_question() {
    var o = make(secrets({ proxy_password: { set: true } }))
    focusKey(o, "proxy_password")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
  }

  // ---- palette and ? -----------------------------------------------------------------

  function test_the_palette_and_help_see_the_settings_state() {
    var o = make(secrets({ proxy_password: { set: true } }))
    focusKey(o, "proxy_password")
    var st = View.paletteState(o.c.tableState, false, o.c.inspectorState, o.c.pane, true, cmds(o).flags(), o.c.keyPane)
    var rows = View.paletteRows("", Registry.commands, [], st)
    var clear = rows.filter(function(r) { return r.id === "settings.clearSecret" })[0]
    compare(clear.enabled, true)
    compare(rows.filter(function(r) { return r.id === "list.add" })[0].reason, "open a list")
    key(o.c, "?")
    verify(o.c.helpOpen)
    var help = Registry.helpFor("NORMAL", o.c.helpPane, o.c.inspectorTab, o.c.registryState([])).map(function(r) { return r.id })
    verify(help.indexOf("settings.clearSecret") !== -1)
    key(o.c, "?")
    focusKey(o, "excluded_file_names")
    help = Registry.helpFor("NORMAL", "settingsKeys", o.c.inspectorTab, o.c.registryState([])).map(function(r) { return r.id })
    verify(help.indexOf("settings.openList") !== -1, "? lists Enter on a list row")
    enter(o)
    help = Registry.helpFor("NORMAL", o.c.keyPane, o.c.inspectorTab, o.c.registryState([])).map(function(r) { return r.id })
    verify(help.indexOf("list.add") !== -1 && help.indexOf("list.remove") !== -1)
  }

  function test_clear_secret_from_the_palette_asks_as_x_does_and_stays_in_settings() {
    var o = make(secrets({ proxy_password: { set: true } }))
    esc(o)
    o.c.setPane("inspector")
    comma(o)
    o.svc.answer({ ok: true, prefs: secrets({ proxy_password: { set: true } }) })
    focusKey(o, "proxy_password")
    var cc = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && typeof o.c.data[i].runPaletteRow === "function") cc = o.c.data[i]
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    var st = View.paletteState(o.c.tableState, false, o.c.inspectorState, o.c.pane, true, cmds(o).flags(), o.c.keyPane)
    var row = View.paletteRows("clear the secret", Registry.commands, [], st)[0]
    compare(row.id, "settings.clearSecret")
    cc.runPaletteRow(row)
    verify(view(o).open, "a Settings action keeps Settings open")
    compare(o.c.mode, "CONFIRM")
    key(o.c, "y")
    compare(calls(o.svc, "clearSecret").map(function(x) { return x.args[0] }), ["proxy_password"])
    compare(o.c.pane, "inspector", "the torrent pane underneath is kept")
    esc(o); esc(o)
    verify(!view(o).open)
    compare(o.c.keyPane, "inspector", "leaving Settings lands where it was")
  }

  // ---- narrow ----------------------------------------------------------------------

  function narrowClient(p) {
    var o = make(p)
    winOf(o.c).width = 800
    wait(30)
    verify(view(o).narrow)
    return o
  }

  function test_narrow_the_sections_are_a_chip_and_tab_h_shift_tab_open_the_overlay() {
    var o = make()
    esc(o)
    winOf(o.c).width = 800
    wait(30)
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    compare(o.c.keyPane, "settingsKeys", "narrow opens on the settings")
    wait(30)
    var chip = findName(content(o), "settingsChip")
    verify(chip.visible)
    compare(chip.children[0].text, "Downloads ▾")
    tab(o)
    compare(o.c.keyPane, "settingsSections", "Tab opens the overlay")
    key(o.c, "j")
    compare(view(o).sectionName, "Connection")
    enter(o)
    compare(o.c.keyPane, "settingsKeys", "choosing a section closes it and focuses the settings")
    compare(view(o).sectionName, "Connection")
    key(o.c, "h")
    compare(o.c.keyPane, "settingsSections", "h opens it")
    esc(o)
    compare(o.c.keyPane, "settingsKeys", "Esc closes the overlay first")
    verify(view(o).open)
    backtab(o)
    compare(o.c.keyPane, "settingsSections", "Shift-Tab opens it")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsKeys")
    esc(o)
    verify(!view(o).open, "Esc on the settings still leaves Settings")
    compare(o.c.pane, "table")
    compare(o.c.keyPane, "table", "the torrent keys are unchanged")
  }

  function test_narrow_tags_hide_and_the_help_wraps_while_wide_they_show() {
    var o = narrowClient()
    focusKey(o, "listen_port")
    wait(30)
    compare(findName(rowItem(o, "listen_port"), "settingsTag").visible, false, "type tags hide first")
    var label = findName(rowItem(o, "listen_port"), "settingsLabel")
    var value = findName(rowItem(o, "listen_port"), "settingsValue")
    verify(value.width >= value.implicitWidth - 1, "the value keeps its width")
    compare(findName(content(o), "settingsHelp").maximumLineCount, 6)
    winOf(o.c).width = 1600
    wait(30)
    verify(!view(o).narrow)
    compare(findName(rowItem(o, "listen_port"), "settingsTag").visible, true)
    compare(findName(content(o), "settingsChip").visible, false)
    key(o.c, "h")
    compare(o.c.keyPane, "settingsSections", "wide h goes back to the sections column")
    esc(o)
    verify(!view(o).open, "wide Esc on the sections leaves")
  }

  function test_a_resize_to_narrow_with_the_sections_focused_hands_focus_to_the_settings() {
    var o = make()
    compare(o.c.keyPane, "settingsSections")
    winOf(o.c).width = 800
    wait(30)
    compare(o.c.keyPane, "settingsKeys")
  }

  // Ruling EF: a section-level list (Banned IPs) goes back to the overlay,
  // and Esc there leaves Settings; no list <-> overlay bounce.
  function test_narrow_banned_ips_esc_goes_to_the_overlay_then_out_of_settings() {
    var o = narrowClient(lists())
    o.c.pane = "inspector"
    tab(o)
    focusSection(o, "Banned IPs")
    enter(o)
    compare(o.c.keyPane, "settingsList")
    compare(view(o).listKey, "banned_IPs")
    esc(o)
    compare(o.c.keyPane, "settingsSections", "Esc goes back to the sections (the overlay)")
    esc(o)
    verify(!view(o).open, "Esc in the overlay on a list section leaves Settings")
    compare(o.c.keyPane, "inspector")
  }

  function test_narrow_esc_in_the_overlay_on_a_settings_section_closes_it() {
    var o = narrowClient(lists())
    tab(o)
    esc(o)
    compare(o.c.keyPane, "settingsKeys")
    verify(view(o).open)
  }

  function test_a_resize_to_narrow_on_the_banned_ips_section_opens_its_list() {
    var o = make(lists())
    focusSection(o, "Banned IPs")
    compare(o.c.keyPane, "settingsSections")
    winOf(o.c).width = 800
    wait(30)
    verify(view(o).open, "a resize never leaves Settings")
    compare(o.c.keyPane, "settingsList")
  }

  function test_row_lists_still_return_to_their_row_narrow() {
    var o = narrowClient(lists())
    openListOf(o, "add_trackers")
    esc(o)
    compare(o.c.keyPane, "settingsKeys")
    compare(view(o).cursorRow.key, "add_trackers")
  }
}
