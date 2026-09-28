import QtQuick
import QtTest
import "../../.."

// Slice 5a (Task 1): the regression pins for the one-active-view refactor.
// Written against 5aa9adc before Client.activeView existed, so they pass
// on both sides of it. They drive only keys, the palette's own field and
// what the window shows (never an internal name), so a refactor can't make
// them pass by renaming something:
//   - Settings' Esc chains, wide and narrow (a search, a list, the
//     sections overlay, a list section's overlay: Ruling EF);
//   - the palette keeping the torrent pane underneath (Ruling ED/EF): a
//     Settings row runs in Settings, a torrent row leaves Settings first
//     and lands where the torrents were;
//   - a browser magnet's CONFIRM closing Settings.
// The Search section at the end was added with the refactor: Client's
// activeView for Search, through Task 1's placeholder SearchPane.
TestCase {
  id: tc
  name: "ClientViews"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
    for (var k in extra || {}) r[k] = extra[k]
    return r
  }
  function url(c) { return "magnet:?xt=urn:btih:" + hh(c) }

  function prefs() {
    return {
      dl_limit: 0, up_limit: 1048576, listen_port: 51413, upnp: false,
      excluded_file_names_enabled: true, excluded_file_names: "*.exe\n*.scr",
      add_trackers_enabled: true, add_trackers: "udp://a.example/announce",
      banned_IPs: "10.0.0.1\n2001:db8::1",
      web_ui_address: "127.0.0.1", web_ui_port: 8080, current_network_interface: "wg0-mullvad", disk_io_type: 0
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
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function startPending(h, o) { return rec("startPending", [h, o]) }
      function cancelPending(h, o) { return rec("cancelPending", [h, o]) }
      function dropInboxCurrent(o) { return rec("dropInboxCurrent", [o]) }
      function setPref(k, v, o) { return rec("setPref", [k, v, o]) }
      function banList(op, ip, o) { return rec("banList", [op, ip, o]) }
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
  function slash(o) { key(o.c, "/", 0x2f) }
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
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function content(o) { return winOf(o.c).contentItem }
  function line(o) { return findWith(content(o), "setInput") }
  function view(o) { return findName(content(o), "settingsView") }
  function searchPane(o) { return findName(content(o), "searchView") }
  function bigF(o) { key(o.c, "F", 0x46, 0x02000000) }
  function visibleTexts(obj, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj.text)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleTexts(kids[i], out)
    return out
  }
  function shows(o, text) { wait(30); return visibleTexts(content(o)).indexOf(text) >= 0 }
  function palette(o) { return findWith(content(o), "currentRow") }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function paneTitled(o, title) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.collapsed !== undefined && obj.title === title) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(content(o))
  }
  function torrentsShown(o) { return paneTitled(o, "Torrents").visible }

  function make(width) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha", { addedOn: 3 }), tt(hh("b"), "beta", { addedOn: 2 }), tt(hh("c"), "gamma", { addedOn: 1 })]
    var o = { c: c, svc: svc }
    if (width) {
      winOf(c).width = width
      tryVerify(function() { return winOf(c).contentItem.width === width }, 2000)
    }
    return o
  }
  // The torrent pane underneath, set through Tab as a user would.
  function focusTorrentPane(o, pane) {
    for (var i = 0; i < 4 && o.c.pane !== pane; i++) tab(o)
    compare(o.c.pane, pane)
  }
  function openSettings(o) {
    comma(o)
    o.svc.answer({ ok: true, prefs: prefs() })
    verify(view(o).open)
    verify(!torrentsShown(o))
  }
  function goToSection(o, name) {
    var v = view(o)
    for (var i = 0; i < 20 && v.sectionName !== name; i++) key(o.c, "j")
    compare(v.sectionName, name)
  }
  function runPalette(o, text) {
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    palette(o).inputField.text = text
    wait(30)
    enter(o)
  }
  // Settings closed, the torrents shown, keys on `pane`.
  function backOnTorrents(o, pane, why) {
    verify(!view(o).open, why + ": Settings closed")
    verify(torrentsShown(o), why + ": the torrents show")
    compare(o.c.pane, pane, why + ": the torrent pane is kept")
    compare(o.c.keyPane, pane, why + ": keys go to it")
  }

  // ---- Esc chains (wide) --------------------------------------------------------

  function test_wide_esc_from_the_sections_leaves_settings_for_the_pane_it_came_from() {
    var o = make()
    key(o.c, "1")
    focusTorrentPane(o, "inspector")
    openSettings(o)
    compare(o.c.keyPane, "settingsSections")
    esc(o)
    backOnTorrents(o, "inspector", "Esc on the sections")
  }

  function test_wide_esc_from_the_settings_leaves_too() {
    var o = make()
    openSettings(o)
    key(o.c, "l")
    compare(o.c.keyPane, "settingsKeys")
    esc(o)
    backOnTorrents(o, "table", "Esc on the settings")
  }

  function test_wide_esc_clears_a_committed_search_then_leaves() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSettings(o)
    key(o.c, "l")
    slash(o)
    line(o).setInput("port")
    enter(o)
    verify(view(o).searching)
    compare(o.c.keyPane, "settingsKeys")
    esc(o)
    verify(!view(o).searching, "the first Esc clears the search")
    verify(view(o).open)
    compare(o.c.keyPane, "settingsKeys", "back to the column / was pressed in")
    esc(o)
    backOnTorrents(o, "filters", "the second Esc")
  }

  function test_wide_esc_from_a_row_list_goes_back_to_its_row_then_leaves() {
    var o = make()
    openSettings(o)
    goToSection(o, "Downloads")
    key(o.c, "l")
    var v = view(o)
    for (var i = 0; i < 30 && (!v.cursorRow || v.cursorRow.key !== "excluded_file_names"); i++) key(o.c, "j")
    compare(v.cursorRow.key, "excluded_file_names")
    enter(o)
    compare(o.c.keyPane, "settingsList")
    esc(o)
    compare(o.c.keyPane, "settingsKeys", "Esc in a list goes back to its row")
    verify(v.open)
    esc(o)
    backOnTorrents(o, "table", "then Esc leaves")
  }

  function test_wide_esc_from_the_banned_ips_list_goes_to_the_sections_then_leaves() {
    var o = make()
    openSettings(o)
    goToSection(o, "Banned IPs")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsList")
    esc(o)
    compare(o.c.keyPane, "settingsSections")
    verify(view(o).open)
    esc(o)
    backOnTorrents(o, "table", "Esc on the sections")
  }

  // ---- Esc chains (narrow, Ruling EF) ---------------------------------------------

  function test_narrow_esc_closes_the_sections_overlay_first_then_leaves() {
    var o = make(800)
    openSettings(o)
    compare(o.c.keyPane, "settingsKeys", "narrow opens on the settings")
    tab(o)
    compare(o.c.keyPane, "settingsSections", "Tab opens the overlay")
    esc(o)
    compare(o.c.keyPane, "settingsKeys", "Esc closes the overlay")
    verify(view(o).open)
    esc(o)
    backOnTorrents(o, "table", "then Esc leaves")
  }

  function test_narrow_banned_ips_esc_goes_to_the_overlay_then_leaves() {
    var o = make(800)
    openSettings(o)
    tab(o)
    goToSection(o, "Banned IPs")
    enter(o)
    compare(o.c.keyPane, "settingsList")
    esc(o)
    compare(o.c.keyPane, "settingsSections", "the list's Esc opens the overlay")
    esc(o)
    backOnTorrents(o, "table", "Esc in the overlay on a list section")
  }

  function test_a_down_screen_in_settings_still_leaves_on_esc() {
    var o = make()
    focusTorrentPane(o, "filters")
    comma(o)
    o.svc.answer({ ok: false, error: "qBittorrent isn't running." })
    compare(o.c.keyPane, "settingsSections")
    esc(o)
    backOnTorrents(o, "filters", "Esc on the down screen")
  }

  // ---- the palette and the torrent pane --------------------------------------------

  function test_colon_settings_keeps_the_torrent_pane_underneath() {
    var o = make()
    key(o.c, "3")
    focusTorrentPane(o, "inspector")
    runPalette(o, "Settings")
    verify(view(o).open, ":Settings opens Settings")
    compare(o.c.pane, "inspector")
    o.svc.answer({ ok: true, prefs: prefs() })
    esc(o)
    backOnTorrents(o, "inspector", "leaving after :Settings")
    compare(o.c.inspectorTab, "peers")
  }

  function test_a_settings_palette_row_runs_in_settings_and_keeps_the_torrent_pane() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSettings(o)
    goToSection(o, "Banned IPs")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsList")
    runPalette(o, "Add to the list")
    compare(o.c.mode, "INSERT", "the list's add ran in Settings")
    verify(view(o).open)
    compare(o.c.pane, "filters", "the torrent pane underneath stays")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.keyPane, "settingsList")
    esc(o); esc(o)
    backOnTorrents(o, "filters", "leaving afterwards")
  }

  function test_a_torrent_palette_row_leaves_settings_and_runs_on_the_torrents_in_their_pane() {
    var o = make()
    key(o.c, "1")
    focusTorrentPane(o, "inspector")
    openSettings(o)
    var sort = o.c.sortMode
    runPalette(o, "Sort")
    backOnTorrents(o, "inspector", "a torrent command from the palette")
    verify(o.c.sortMode !== sort, "and it ran")
  }

  function test_a_table_only_palette_row_from_settings_lands_on_the_table() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSettings(o)
    runPalette(o, "Pause/resume")
    backOnTorrents(o, "table", "a table command")
    compare(calls(o.svc, "stop").length + calls(o.svc, "start").length, 1, "it acted on the cursor torrent")
  }

  function test_the_palette_is_dismissed_without_leaving_settings() {
    var o = make()
    openSettings(o)
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    esc(o)
    compare(o.c.mode, "NORMAL")
    verify(view(o).open, "Esc on the palette only closes the palette")
    compare(o.c.keyPane, "settingsSections")
  }

  // ---- a browser magnet closes Settings ----------------------------------------------

  function test_a_browser_magnet_confirm_closes_settings_and_keeps_the_torrent_pane() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSettings(o)
    key(o.c, "l")
    wait(900)
    o.svc.magnetPendingHashes = [hh("e")]
    o.svc.torrents = o.svc.torrents.concat([tt(hh("e"), hh("e"), { state: "metaDL", size: 0, addedOn: 9 })])
    o.svc.magnetPending = [{ hash: hh("e"), url: url("e"), hashes: [hh("e")], dn: "", addedAt: Date.now() / 1000 }]
    tryCompare(o.c, "mode", "CONFIRM", 2000)
    verify(!view(o).open, "the question is on the torrent view")
    verify(torrentsShown(o))
    compare(o.c.pane, "filters")
    compare(o.c.keyPane, "filters")
  }

  function test_a_browser_magnet_waits_for_a_settings_insert_then_closes_settings() {
    var o = make()
    openSettings(o)
    slash(o)
    compare(o.c.mode, "INSERT")
    wait(900)
    o.svc.magnetPendingHashes = [hh("e")]
    o.svc.torrents = o.svc.torrents.concat([tt(hh("e"), hh("e"), { state: "metaDL", size: 0, addedOn: 9 })])
    o.svc.magnetPending = [{ hash: hh("e"), url: url("e"), hashes: [hh("e")], dn: "", addedAt: Date.now() / 1000 }]
    wait(100)
    compare(o.c.mode, "INSERT", "the field isn't taken away")
    verify(view(o).open)
    esc(o)
    tryCompare(o.c, "mode", "CONFIRM", 3000)
    verify(!view(o).open)
    verify(torrentsShown(o))
  }

  // ---- Search (slice 5a): the same view model --------------------------------------

  function openSearch(o) {
    bigF(o)
    compare(o.c.activeView, "search")
    verify(searchPane(o).open)
    verify(searchPane(o).visible)
    verify(!torrentsShown(o), "Search replaces the three panes")
    verify(!paneTitled(o, "Filters").visible)
    verify(!paneTitled(o, "Inspector").visible)
    compare(o.c.keyPane, "searchResults")
  }
  function backFromSearch(o, pane, why) {
    compare(o.c.activeView, "torrents", why)
    verify(!searchPane(o).open, why + ": Search closed")
    verify(torrentsShown(o), why + ": the torrents show")
    compare(o.c.pane, pane, why + ": the torrent pane is kept")
    compare(o.c.keyPane, pane, why)
  }

  function test_F_opens_search_and_esc_brings_back_the_torrents_as_they_were() {
    var o = make()
    key(o.c, "j")
    var cursor = o.c.cursorHash
    key(o.c, "2")
    focusTorrentPane(o, "inspector")
    compare(o.c.activeView, "torrents")
    openSearch(o)
    verify(findWith(content(o), "setInput").visible, "the status line stays")
    esc(o)
    backFromSearch(o, "inspector", "Esc")
    compare(o.c.cursorHash, cursor)
    compare(o.c.inspectorTab, "trackers")
    for (var i = 0; i < o.svc.calls.length; i++) verify(o.svc.calls[i].name !== "saveViewState")
    compare(JSON.stringify(o.svc.viewState).indexOf("search"), -1, "view.json never hears of Search")
  }

  function test_torrent_keys_do_nothing_inside_search() {
    var o = make()
    openSearch(o)
    var sort = o.c.sortMode, desc = o.c.sortDesc, tabBefore = o.c.inspectorTab, cursor = o.c.cursorHash
    var before = o.svc.calls.length
    var keys = ["t", "z", "r", "1", "2", "3", "4", "5", "q", "f", "V", ",", "e", "o", "m", "C", "T", "X", "G"]
    for (var i = 0; i < keys.length; i++) key(o.c, keys[i])
    key(o.c, " ", 0x20)
    key(o.c, "\f", 0x4c, 0x04000000)
    compare(o.svc.calls.length, before, JSON.stringify(o.svc.calls.slice(before)))
    compare(o.c.sortMode, sort)
    compare(o.c.sortDesc, desc)
    compare(o.c.inspectorTab, tabBefore)
    compare(o.c.cursorHash, cursor)
    compare(o.c.pane, "table")
    verify(o.c.opened, "q doesn't close the window")
    compare(o.c.activeView, "search")
    compare(o.c.mode, "NORMAL")
  }

  function test_search_panes_move_with_h_l_P_and_esc_closes_the_overlay_first() {
    var o = make()
    openSearch(o)
    key(o.c, "h")
    compare(o.c.keyPane, "searchPlugins")
    key(o.c, "l")
    compare(o.c.keyPane, "searchResults")
    key(o.c, "P", 0x50, 0x02000000)
    compare(o.c.keyPane, "searchPluginList")
    esc(o)
    compare(o.c.keyPane, "searchResults", "the overlay's Esc closes it")
    compare(o.c.activeView, "search")
    esc(o)
    backFromSearch(o, "table", "then Esc leaves")
  }

  function test_no_key_goes_between_settings_and_search() {
    var o = make()
    openSettings(o)
    bigF(o)
    compare(o.c.activeView, "settings", "F is dead in Settings")
    verify(view(o).open)
    esc(o)
    openSearch(o)
    comma(o)
    compare(o.c.activeView, "search", ", is dead in Search")
    verify(!view(o).open)
  }

  function test_colon_search_from_settings_leaves_settings_then_opens_search_keeping_the_pane() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSettings(o)
    runPalette(o, "Search")
    compare(o.c.activeView, "search")
    verify(!view(o).open)
    verify(searchPane(o).open)
    compare(o.c.pane, "filters")
    runPalette(o, "Settings")
    compare(o.c.activeView, "settings", ":Settings from Search")
    verify(!searchPane(o).open)
    compare(o.c.pane, "filters")
    o.svc.answer({ ok: true, prefs: prefs() })
    esc(o)
    backOnTorrents(o, "filters", "leaving Settings")
  }

  function test_colon_search_is_dimmed_while_search_shows() {
    var o = make()
    openSearch(o)
    key(o.c, ":", 0x3a)
    var rows = palette(o).rows.filter(function(r) { return r.id === "search.open" })
    compare(rows.length, 1)
    compare(rows[0].enabled, false)
    compare(rows[0].reason, "already open")
    esc(o)
    compare(o.c.activeView, "search")
  }

  function test_a_torrent_palette_row_leaves_search_and_runs_on_the_torrents() {
    var o = make()
    key(o.c, "1")
    focusTorrentPane(o, "inspector")
    openSearch(o)
    var sort = o.c.sortMode
    runPalette(o, "Sort")
    backFromSearch(o, "inspector", "a torrent command from the palette")
    verify(o.c.sortMode !== sort)
  }

  function test_a_browser_magnet_confirm_closes_search() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSearch(o)
    wait(900)
    o.svc.magnetPendingHashes = [hh("e")]
    o.svc.torrents = o.svc.torrents.concat([tt(hh("e"), hh("e"), { state: "metaDL", size: 0, addedOn: 9 })])
    o.svc.magnetPending = [{ hash: hh("e"), url: url("e"), hashes: [hh("e")], dn: "", addedAt: Date.now() / 1000 }]
    tryCompare(o.c, "mode", "CONFIRM", 2000)
    backFromSearch(o, "filters", "the magnet's question")
  }

  function test_closing_the_window_in_search_reopens_on_the_torrents() {
    var o = make()
    openSearch(o)
    o.c.close()
    o.c.open("")
    backFromSearch(o, "table", "a reopened window")
  }

  function test_search_insert_purposes_go_to_the_search_view() {
    var o = make()
    openSearch(o)
    var cc = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && typeof o.c.data[i].runPaletteRow === "function") cc = o.c.data[i]
    cc.startInput("searchQuery", "")
    compare(o.c.mode, "INSERT")
    compare(findName(content(o), "insertPrompt").text, "Search")
    line(o).setInput(url("f"))
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(calls(o.svc, "addTarget").length + calls(o.svc, "add").length, 0, "a query is never an add target")
    compare(o.c.textQuery, "", "nor a torrent filter")
    cc.startInput("pluginInstall", "")
    compare(findName(content(o), "insertPrompt").text, "Install plugin from")
    o.c.close()
    compare(o.c.mode, "NORMAL", "closing the window ends it")
    compare(o.c.inputPurpose, "")
  }

  function test_question_mark_in_search_names_the_view() {
    var o = make()
    openSearch(o)
    key(o.c, "?", 0x3f, 0x02000000)
    verify(o.c.helpOpen)
    verify(shows(o, "NORMAL · search"))
    verify(shows(o, "Add the result"))
    verify(!shows(o, "Start/stop all"))
    esc(o)
    compare(o.c.activeView, "search")
  }
}
