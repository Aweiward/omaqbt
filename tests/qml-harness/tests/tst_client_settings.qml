import QtQuick
import QtTest
import "../../.."

// The Settings view (slice 4a, Task 5): `,` swaps the torrent panes for
// Settings, Esc brings them back with their state intact, j/k/l/h move
// between the sections and the settings, `/` searches every section, and
// the rows show "—" while preferences load, the lock and dimmed-dependent
// states once they arrive, and the api-down screen when they can't be read.
// The service stub's readPrefs keeps each callback so a test answers it.
TestCase {
  id: tc
  name: "ClientSettings"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
    for (var k in extra || {}) r[k] = extra[k]
    return r
  }
  function url(c) { return "magnet:?xt=urn:btih:" + hh(c) }

  // A few keys from Speed, Connection, Web UI and Advanced: enough for the
  // design's examples (a dimmed schedule, the locked VPN and Web UI rows,
  // restart keys).
  function prefs() {
    return {
      dl_limit: 0, up_limit: 1048576, alt_dl_limit: 10240, alt_up_limit: 10240,
      scheduler_enabled: false, schedule_from_hour: 8, schedule_from_min: 0, schedule_to_hour: 20, schedule_to_min: 0, scheduler_days: 0,
      limit_utp_rate: true, limit_tcp_overhead: false, limit_lan_peers: true,
      listen_port: 51413, upnp: true,
      web_ui_address: "127.0.0.1", web_ui_port: 8080, bypass_local_auth: true,
      current_network_interface: "wg0-mullvad", current_interface_name: "wg0-mullvad", current_interface_address: "",
      disk_io_type: 0, announce_port: 0
    }
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
      property var saved: []
      property var prefsCbs: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { saved.push(s); viewState = s }
      function refresh() { rec("refresh", []) }
      function watch(h, t) { calls.push({ name: "watch", args: [h, t] }) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { calls.push({ name: "loadFiles", args: [h, o] }) }
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function toggleAll(o) { return rec("toggleAll", [o]) }
      function toggleAltSpeed(o) { return rec("toggleAltSpeed", [o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function startPending(h, o) { return rec("startPending", [h, o]) }
      function cancelPending(h, o) { return rec("cancelPending", [h, o]) }
      function dropInboxCurrent(o) { return rec("dropInboxCurrent", [o]) }
      function loadMagnetSnapshot() { rec("loadMagnetSnapshot", []) }
      function addTarget(t, s, c, o) { return rec("addTarget", [t]) }
      function readPrefs(cb) { rec("readPrefs", []); prefsCbs.push(cb) }
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
  function tab(o) { key(o.c, "\t", 0x01000001) }
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
  function visibleTexts(obj, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj.text)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleTexts(kids[i], out)
    return out
  }
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function content(o) { return winOf(o.c).contentItem }
  function line(o) { return findWith(content(o), "setInput") }
  function view(o) { return findName(content(o), "settingsView") }
  function texts(o) { wait(30); return visibleTexts(content(o)) }
  function shows(o, text) { return texts(o).indexOf(text) >= 0 }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function paneTitled(o, title) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.collapsed !== undefined && obj.title === title) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(content(o))
  }
  // The visible settings rows: [{label, text, tag, ...}] from their objectName.
  function rowItems(o) { wait(30); return visibleNamed(content(o), "settingsRow") }
  function rowByLabel(o, label) {
    var rows = rowItems(o)
    for (var i = 0; i < rows.length; i++) if (rows[i].row.label === label) return rows[i]
    return null
  }

  function make(extra) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    for (var k in extra || {}) svc[k] = extra[k]
    if (svc.torrents.length === 0) {
      svc.torrents = [tt(hh("a"), "alpha", { addedOn: 3 }), tt(hh("b"), "beta", { addedOn: 2, state: "stalledUP", progress: 1 }),
        tt(hh("c"), "gamma", { addedOn: 1 })]
    }
    return { c: c, svc: svc }
  }
  // Settings open, preferences answered, the section cursor on `section`.
  function openOn(o, section) {
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    var v = view(o)
    for (var i = 0; i < 10 && v.sectionName !== section; i++) key(o.c, "j")
    compare(v.sectionName, section)
    return v
  }
  function sectionCount(v, name) {
    var list = v.sectionList
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return list[i].count
    return -1
  }

  // ---- open and back -----------------------------------------------------------

  function test_comma_swaps_the_torrent_panes_for_settings_and_reads_preferences() {
    var o = make()
    verify(paneTitled(o, "Torrents").visible)
    comma(o)
    var v = view(o)
    verify(v.open)
    verify(v.visible)
    compare(o.c.keyPane, "settingsSections")
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "readPrefs").length, 1)
    verify(!paneTitled(o, "Torrents").visible, "Settings replaces the three panes")
    verify(!paneTitled(o, "Filters").visible)
    verify(!paneTitled(o, "Inspector").visible)
    verify(findWith(content(o), "setInput").visible, "the status line stays")
  }

  function test_rows_show_a_dash_while_preferences_load() {
    var o = make()
    comma(o)
    var v = view(o)
    compare(v.prefs, null)
    compare(sectionCount(v, "Speed"), 11, "loading counts come from the schema")
    key(o.c, "j"); key(o.c, "j")
    compare(v.sectionName, "Speed")
    key(o.c, "l")
    var rows = rowItems(o)
    verify(rows.length > 0)
    for (var i = 0; i < rows.length; i++) compare(rows[i].row.text, "—", rows[i].row.label)
    verify(shows(o, "—"))
    o.svc.answer({ ok: true, prefs: prefs() })
    verify(shows(o, "1 MiB/s"), "the upload limit arrives")
    verify(!shows(o, "—"))
  }

  function test_esc_returns_to_the_torrents_with_their_state_intact_and_nothing_saved() {
    var o = make()
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"))
    key(o.c, "3")
    tab(o)
    compare(o.c.pane, "inspector")
    compare(o.c.inspectorTab, "peers")
    o.c.applyFilter({ group: "status", value: "Downloading" })
    var filter = JSON.stringify(o.c.filter)
    var cursor = o.c.cursorHash
    var savedBefore = o.svc.saved.length
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    key(o.c, "j"); key(o.c, "l"); key(o.c, "j")
    esc(o)
    verify(!view(o).open)
    verify(!view(o).visible)
    verify(paneTitled(o, "Torrents").visible)
    compare(o.c.pane, "inspector")
    compare(o.c.keyPane, "inspector")
    compare(o.c.inspectorTab, "peers")
    compare(o.c.cursorHash, cursor)
    compare(JSON.stringify(o.c.filter), filter)
    compare(o.svc.saved.length, savedBefore, "view.json never hears of Settings")
    for (var i = 0; i < o.svc.saved.length; i++) verify(JSON.stringify(o.svc.saved[i]).indexOf("settings") < 0)
  }

  function test_reopening_reads_again_and_shows_dashes_until_it_answers() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "l")
    verify(shows(o, "1 MiB/s"))
    esc(o)
    comma(o)
    compare(calls(o.svc, "readPrefs").length, 2)
    compare(view(o).prefs, null)
    compare(view(o).sectionName, "Speed", "the section cursor survives a visit")
    key(o.c, "l")
    verify(!shows(o, "1 MiB/s"))
    verify(shows(o, "—"))
    o.svc.answer({ ok: true, prefs: prefs() })
    verify(shows(o, "1 MiB/s"))
  }

  function test_reopening_the_window_lands_on_the_torrents() {
    var o = make()
    openOn(o, "Speed")
    o.c.close()
    o.c.open("")
    verify(!view(o).open)
    verify(paneTitled(o, "Torrents").visible)
    compare(o.c.keyPane, "table")
  }

  function test_a_late_answer_after_leaving_is_ignored() {
    var o = make()
    comma(o)
    esc(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    compare(view(o).prefs, null)
    verify(!view(o).open)
  }

  // ---- j/k/l/h -------------------------------------------------------------

  function test_j_k_move_the_sections_and_l_h_move_between_the_columns() {
    var o = make()
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    var v = view(o)
    compare(v.sectionName, "Downloads")
    key(o.c, "j")
    compare(v.sectionName, "Connection")
    key(o.c, "k"); key(o.c, "k")
    compare(v.sectionName, "Downloads", "stops at the top")
    for (var i = 0; i < 12; i++) key(o.c, "j")
    compare(v.sectionName, "Advanced", "RSS · slice 5 is never a stop")
    verify(shows(o, "RSS · slice 5"))
    key(o.c, "k"); key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    compare(v.sectionName, "Speed")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsKeys")
    compare(v.cursorRow.label, "Download limit")
    key(o.c, "j"); key(o.c, "j")
    compare(v.cursorRow.label, "Alternative download limit")
    verify(shows(o, "Alternative download limit · "), "the help line names the cursor row")
    key(o.c, "h")
    compare(o.c.keyPane, "settingsSections")
    key(o.c, "k")
    compare(v.sectionName, "Connection")
    enter(o)
    compare(o.c.keyPane, "settingsKeys")
    compare(v.cursorRow.label, "Port for incoming connections")
    key(o.c, "", 0x01000002)
    compare(o.c.keyPane, "settingsSections", "Shift-Tab goes back too")
    key(o.c, "j")
    tab(o)
    compare(o.c.keyPane, "settingsKeys")
    compare(v.cursorRow.label, "Alternative download limit", "each section keeps its own cursor")
    for (i = 0; i < 30; i++) key(o.c, "j")
    compare(v.cursorRow.label, "Apply limits to LAN peers", "the cursor stops at the last row")
  }

  function test_the_cursor_clamps_when_a_reread_has_fewer_rows() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "l")
    for (var i = 0; i < 20; i++) key(o.c, "j")
    compare(view(o).cursorRow.label, "Apply limits to LAN peers")
    var p = prefs()
    delete p.limit_lan_peers
    delete p.limit_tcp_overhead
    view(o).reload()
    o.svc.answer({ ok: true, prefs: p })
    compare(view(o).cursorRow.label, "Apply limits to µTP")
    key(o.c, "k")
    compare(view(o).cursorRow.label, "Days")
  }

  // ---- the rows --------------------------------------------------------------

  function test_rows_carry_label_value_and_type_tag_under_their_group() {
    var o = make()
    openOn(o, "Speed")
    verify(shows(o, "Global limits"))
    verify(shows(o, "Scheduler"))
    var up = rowByLabel(o, "Upload limit")
    verify(up !== null)
    compare(up.height, 28)
    verify(shows(o, "speed"))
    verify(shows(o, "on/off"))
    compare(findName(up, "settingsValue").text, "1 MiB/s")
    compare(findName(up, "settingsTag").text, "speed")
    compare(findName(up, "settingsValue").textFormat, Text.PlainText)
    compare(paneTitled(o, "Speed").titleRight, "11 settings")
    compare(paneTitled(o, "Settings").width, 220)
  }

  function test_dimmed_dependents_show_their_reason() {
    var o = make()
    openOn(o, "Speed")
    verify(shows(o, "08:00 (schedule off)"))
    verify(shows(o, "20:00 (schedule off)"))
    var from = rowByLabel(o, "From")
    verify(from.row.dimmed)
    var normal = rowByLabel(o, "Upload limit")
    verify(String(findName(from, "settingsValue").color) !== String(findName(normal, "settingsValue").color), "a dimmed value is painted dim")
  }

  function test_locked_rows_are_dimmed_and_tagged_omaqbt_with_their_reason_in_the_help_line() {
    var o = make()
    openOn(o, "Advanced")
    key(o.c, "l")
    for (var i = 0; i < 20 && !view(o).cursorRow.locked; i++) key(o.c, "j")
    var row = view(o).cursorRow
    verify(row.locked)
    var item = rowByLabel(o, row.label)
    compare(findName(item, "settingsTag").text, "OmaqBT")
    verify(shows(o, "wg0-mullvad"))
    var help = findName(content(o), "settingsHelp")
    verify(help.text.indexOf("Set by OmaqBT's setup.") >= 0, help.text)
    var plain = rowByLabel(o, "Disk I/O type")
    verify(plain !== null)
    verify(String(findName(item, "settingsLabel").color) !== String(findName(plain, "settingsLabel").color), "a locked label is dimmed")
    verify(String(findName(item, "settingsValue").color) !== String(findName(plain, "settingsValue").color), "and so is its value")
    verify(texts(o).indexOf("🔒") < 0)
  }

  function test_restart_keys_carry_a_muted_after_restart_tag() {
    var o = make()
    openOn(o, "Advanced")
    var disk = null
    var rows = rowItems(o)
    for (var i = 0; i < rows.length; i++) if (rows[i].row.key === "disk_io_type") disk = rows[i]
    verify(disk !== null)
    verify(findName(disk, "settingsRestart").visible)
    compare(findName(disk, "settingsRestart").text, "after restart")
    var iface = null
    for (i = 0; i < rows.length; i++) if (rows[i].row.key === "current_network_interface") iface = rows[i]
    verify(!findName(iface, "settingsRestart").visible)
  }

  // ---- search ---------------------------------------------------------------------

  function test_slash_searches_every_section_and_enter_keeps_the_results() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "/", 0x2f)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "settingsSearch")
    compare(findName(content(o), "insertPrompt").text, "Search settings")
    line(o).setInput("port")
    var v = view(o)
    verify(v.searching)
    var labels = v.shownRows.map(function(r) { return r.label + "@" + r.section })
    verify(labels.indexOf("Port for incoming connections@Connection") >= 0, labels)
    verify(labels.indexOf("Web UI port@Web UI") >= 0, labels)
    verify(shows(o, "· Connection"), "a result names its section")
    compare(paneTitled(o, "Search").titleRight, "“port” · " + v.shownRows.length + " matches")
    enter(o)
    compare(o.c.mode, "NORMAL")
    verify(v.searching, "Enter keeps the results")
    compare(o.c.keyPane, "settingsKeys")
    compare(v.cursorRow.label, v.shownRows[0].label)
    key(o.c, "j")
    compare(v.cursorRow.label, v.shownRows[1].label)
    compare(o.c.textQuery, "", "the torrent filter is untouched")
    esc(o)
    verify(!v.searching, "Esc clears the search first")
    verify(v.open)
    compare(v.sectionName, "Speed")
    esc(o)
    verify(!v.open, "then leaves")
    compare(calls(o.svc, "readPrefs").length, 1)
  }

  function test_esc_in_the_search_field_clears_it() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "/", 0x2f)
    line(o).setInput("port")
    verify(view(o).searching)
    esc(o)
    compare(o.c.mode, "NORMAL")
    verify(!view(o).searching)
    verify(view(o).open)
    compare(o.c.keyPane, "settingsSections", "back where / was pressed")
  }

  function test_a_search_with_no_match_says_so() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "/", 0x2f)
    line(o).setInput("zzqx")
    verify(shows(o, "No setting matches \"zzqx\". Esc clears."))
    enter(o)
    verify(shows(o, "No setting matches \"zzqx\". Esc clears."))
    esc(o)
    verify(!shows(o, "No setting matches \"zzqx\". Esc clears."))
  }

  function test_a_search_never_adds_a_magnet_or_filters_torrents() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "/", 0x2f)
    line(o).setInput(url("e"))
    enter(o)
    compare(calls(o.svc, "add").length + calls(o.svc, "addTarget").length, 0)
    compare(o.c.textQuery, "")
  }

  // ---- down screen --------------------------------------------------------------------

  function test_a_failed_read_shows_the_api_down_screen_and_esc_still_leaves() {
    var o = make()
    comma(o)
    o.svc.answer({ ok: false, error: "qBittorrent isn't running." })
    verify(shows(o, "qbittorrent-nox isn't answering"))
    verify(shows(o, "The daemon is running but its Web API isn't reachable on localhost yet."))
    verify(shows(o, "Back to torrents"))
    verify(!shows(o, "Check again"), "r is dead in Settings, so it isn't offered")
    verify(!paneTitled(o, "Torrents").visible)
    key(o.c, "/", 0x2f)
    compare(o.c.mode, "NORMAL", "nothing to search on the down screen")
    key(o.c, "j"); key(o.c, "l")
    compare(o.c.keyPane, "settingsSections")
    esc(o)
    verify(!view(o).open)
    verify(paneTitled(o, "Torrents").visible)
  }

  function test_the_daemon_down_copy_when_the_daemon_is_down() {
    var o = make({ daemon: false, api: false })
    comma(o)
    compare(o.c.keyPane, "settingsSections")
    o.svc.answer({ ok: false, error: "qBittorrent isn't running." })
    verify(shows(o, "qbittorrent-nox isn't running"))
    esc(o)
    verify(!view(o).open)
  }

  // ---- the any-pane keys and the torrent view ---------------------------------------------

  function test_torrent_keys_do_nothing_inside_settings() {
    var o = make()
    openOn(o, "Speed")
    var sort = o.c.sortMode, desc = o.c.sortDesc, tabBefore = o.c.inspectorTab
    var before = o.svc.calls.length
    var keys = ["t", "s", "S", "z", "r", "1", "2", "3", "4", "5", "q", "f", "x", "V", "y", ","]
    for (var i = 0; i < keys.length; i++) key(o.c, keys[i])
    key(o.c, "\f", 0x4c, 0x04000000)
    compare(o.svc.calls.length, before, JSON.stringify(o.svc.calls.slice(before)))
    compare(o.c.sortMode, sort)
    compare(o.c.sortDesc, desc)
    compare(o.c.inspectorTab, tabBefore)
    compare(o.c.pane, "table")
    verify(o.c.opened, "q doesn't close the window")
    verify(view(o).open)
    compare(o.c.mode, "NORMAL")
  }

  function test_question_mark_lists_the_settings_keys() {
    var o = make()
    openOn(o, "Speed")
    key(o.c, "?", 0x3f, 0x02000000)
    verify(o.c.helpOpen)
    verify(shows(o, "Search all settings"))
    verify(shows(o, "Clear search, or back to torrents"))
    verify(!shows(o, "Start/stop all"))
    verify(shows(o, "NORMAL · settings"))
    esc(o)
    verify(!o.c.helpOpen)
    verify(view(o).open)
  }

  function test_the_palette_runs_settings_and_a_torrent_command_leaves_settings_first() {
    var o = make()
    var p = findWith(content(o), "currentRow")
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    p.inputField.text = "Settings"
    wait(30)
    enter(o)
    verify(view(o).open, ":Settings opens Settings")
    o.svc.answer({ ok: true, prefs: prefs() })
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND", ": stays live in Settings")
    var sort = o.c.sortMode
    p.inputField.text = "Sort"
    wait(30)
    enter(o)
    verify(!view(o).open, "a torrent command runs on the torrents, in view")
    verify(o.c.sortMode !== sort)
  }

  function test_a_browser_magnet_brings_back_the_torrents_for_its_confirm() {
    var o = make()
    openOn(o, "Speed")
    wait(900)
    o.svc.magnetPendingHashes = [hh("e")]
    o.svc.torrents = o.svc.torrents.concat([tt(hh("e"), hh("e"), { state: "metaDL", size: 0, addedOn: 9 })])
    o.svc.magnetPending = [{ hash: hh("e"), url: url("e"), hashes: [hh("e")], dn: "", addedAt: Date.now() / 1000 }]
    tryCompare(o.c, "mode", "CONFIRM", 2000)
    verify(!view(o).open, "the magnet row and its question are on the torrent view")
    verify(paneTitled(o, "Torrents").visible)
  }

  function test_an_unmatched_y_in_settings_never_reads_the_clipboard() {
    var o = make()
    o.svc.torrents = []
    wait(30)
    compare(o.c.tableState, "empty")
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 0)
  }

  function test_esc_in_a_narrow_window_leaves_settings_rather_than_closing_an_overlay() {
    var o = make()
    key(o.c, "1")
    tab(o)
    var win = winOf(o.c)
    win.width = 800
    tryVerify(function() { return win.contentItem.width === 800 }, 2000)
    for (var i = 0; i < 3 && o.c.pane !== "inspector"; i++) tab(o)
    compare(o.c.pane, "inspector")
    compare(o.c.layout.inspector, "collapsed")
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    esc(o)
    verify(!view(o).open, "settings.back ran")
    compare(o.c.pane, "inspector", "the overlay's pane is untouched")
  }
}
