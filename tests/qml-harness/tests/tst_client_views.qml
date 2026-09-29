import QtQuick
import QtTest
import "../../.."
import "../../../CommandRegistry.js" as Registry
import "../../../SettingsView.js" as SettingsView

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

  // ---- fix round 1 (Ruling FB): the category picker and closing on a CONFIRM ------------

  function test_c_opens_the_category_picker_and_enter_takes_a_row() {
    var o = make()
    openSearch(o)
    var sp = searchPane(o)
    key(o.c, "c")
    compare(o.c.mode, "NORMAL", "no plugin on: c is blocked")
    compare(o.c.statusMessage.text, "No search plugins yet (P).")
    // Task 3: the counts come from the plugin list (qbt search-plugin list).
    sp.setPlugins([{ name: "a", enabled: false }, { name: "b", enabled: false }])
    key(o.c, "c")
    compare(o.c.statusMessage.text, "All plugins are off (P).")
    sp.setPlugins([{ name: "a", enabled: true }, { name: "b", enabled: false }])
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    verify(sp.pickerOpen)
    compare(sp.picker.objectName, "searchCategoryPicker")
    compare(sp.picker.rows[0].value, "all")
    compare(o.c.typingField(), sp.picker.inputField, "the picker's field has the keys")
    key(o.c, "", 0x01000015)
    enter(o)
    compare(o.c.mode, "NORMAL")
    verify(!sp.pickerOpen)
    compare(sp.category, "all")
    compare(o.c.keyPane, "searchResults")
    key(o.c, "h")
    key(o.c, "c")
    compare(o.c.mode, "PICKER", "from the Plugins column too")
    esc(o)
    compare(o.c.mode, "NORMAL")
    verify(!sp.pickerOpen)
    compare(o.c.activeView, "search", "Esc closes only the picker")
    compare(o.c.keyPane, "searchPlugins")
  }

  function test_closing_the_window_drops_an_open_category_picker() {
    var o = make()
    openSearch(o)
    searchPane(o).setPlugins([{ name: "a", enabled: true }])
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    verify(!searchPane(o).pickerOpen)
    o.c.open("")
    backFromSearch(o, "table", "reopened")
  }

  function test_closing_the_window_drops_a_search_confirm() {
    var o = make()
    openSearch(o)
    var r = Registry.raiseConfirm(o.c.regState, "search.add", "searchAdd", { result: { fileName: "debian.iso" } })
    o.c.regState = r.state
    o.c.confirmHashes = []
    o.c.confirm = { commandId: "search.add", kind: "searchAdd", line: "Add debian.iso (650 MiB) from example.org?" }
    compare(o.c.mode, "CONFIRM")
    o.c.close()
    compare(o.c.mode, "NORMAL", "the question never outlives the window")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null)
    o.c.open("")
    backFromSearch(o, "table", "reopened")
  }
  // ---- slice 5b0 (Task 1): pins for the view-host refactor ---------------------------------
  // What Client, ClientCommands and ClientView do today at every site the
  // refactor rewrites, through keys and what the window shows.

  function cmdsOf(o) {
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && typeof o.c.data[i].runPaletteRow === "function") return o.c.data[i]
    return null
  }
  function statusLineOf(o) { return findWith(content(o), "focusInput") }
  function hintsOf(o) { return statusLineOf(o).hints.map(function(h) { return h.key + " " + h.label }).join(" | ") }
  function paletteRowOf(o, id) {
    var rows = palette(o).rows.filter(function(r) { return r.id === id })
    return rows.length === 0 ? null : rows[0]
  }
  function torrentsState(o) {
    return JSON.stringify({ vs: o.svc.viewState, pane: o.c.pane, cursor: o.c.cursorHash, filter: o.c.filter, tab: o.c.inspectorTab,
      sort: o.c.sortMode, desc: o.c.sortDesc, query: o.c.textQuery, calls: o.svc.calls.length })
  }
  function focusSettingKey(o, k) {
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
  function choiceItem(picker, value) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.isRow === true && obj.modelData && String(obj.modelData.value) === String(value)) return obj
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) return r }
      return null
    })(picker)
  }

  // Review Focus 1: a key never reaches the hidden torrents from a view.
  function test_5b0_torrent_keys_change_nothing_from_settings() {
    var o = make()
    openSettings(o)
    var before = torrentsState(o)
    var keys = ["t", "s", "z", "r", "q", "1", "2", "3", "4", "5"]
    for (var i = 0; i < keys.length; i++) key(o.c, keys[i])
    key(o.c, " ", 0x20)
    compare(torrentsState(o), before)
    compare(o.c.mode, "NORMAL")
    compare(o.c.activeView, "settings")
    verify(o.c.opened, "q doesn't close the window")
    compare(o.c.keyPane, "settingsSections")
  }

  function test_5b0_torrent_keys_change_nothing_from_search() {
    var o = make()
    openSearch(o)
    var before = torrentsState(o)
    var keys = ["t", "s", "z", "r", "q", "1", "2", "3", "4", "5"]
    for (var i = 0; i < keys.length; i++) key(o.c, keys[i])
    key(o.c, " ", 0x20)
    compare(torrentsState(o), before)
    compare(o.c.mode, "NORMAL")
    compare(o.c.activeView, "search")
    verify(o.c.opened, "q doesn't close the window")
    compare(o.c.keyPane, "searchResults")
  }

  // The keyPane and the search flags follow the active view.
  function test_5b0_keyPane_and_searchFlags_follow_the_active_view() {
    var o = make()
    compare(o.c.keyPane, "table")
    compare(o.c.searchFlags, null)
    openSearch(o)
    compare(o.c.keyPane, "searchResults")
    verify(o.c.searchFlags !== null)
    compare(o.c.searchFlags.plugins, 0)
    compare(o.c.searchFlags.down, false)
    searchPane(o).setPlugins([{ name: "a", enabled: true }, { name: "b", enabled: false }])
    compare(o.c.searchFlags.plugins, 2)
    compare(o.c.searchFlags.enabledPlugins, 1)
    key(o.c, "h")
    compare(o.c.keyPane, "searchPlugins")
    esc(o)
    compare(o.c.activeView, "torrents")
    compare(o.c.searchFlags, null, "null again once Search stands down")
    openSettings(o)
    compare(o.c.keyPane, "settingsSections")
    compare(o.c.searchFlags, null, "Settings has none")
    key(o.c, "l")
    compare(o.c.keyPane, "settingsKeys")
  }

  // Review Focus 2: Settings' INSERT cleanup runs for every purpose.
  function test_5b0_esc_on_a_move_insert_drops_a_settings_edit_input_object() {
    var o = make()
    var cc = cmdsOf(o)
    key(o.c, "m")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "move")
    cc.settingsCommands.input = { kind: "value", key: "listen_port", label: "Port", prompt: "Port", from: "1", prefs: {}, after: null }
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(cc.settingsCommands.input, null)
    compare(o.c.moveHashes.length, 0)
  }

  function test_5b0_esc_on_a_filter_insert_drops_a_settings_edit_input_object_and_restores_the_query() {
    var o = make()
    var cc = cmdsOf(o)
    slash(o)
    compare(o.c.inputPurpose, "filter")
    line(o).setInput("alp")
    compare(o.c.textQuery, "alp")
    cc.settingsCommands.input = { kind: "value", key: "listen_port", label: "Port", prompt: "Port", from: "1", prefs: {}, after: null }
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.textQuery, "", "the query goes back to what it was before /")
    compare(cc.settingsCommands.input, null)
  }

  function test_5b0_leaveInsert_on_a_click_drops_a_settings_edit_input_object() {
    var o = make()
    var cc = cmdsOf(o)
    key(o.c, "m")
    compare(o.c.inputPurpose, "move")
    cc.settingsCommands.input = { kind: "value", key: "listen_port", label: "Port", prompt: "Port", from: "1", prefs: {}, after: null }
    o.c.leaveInsert()
    compare(o.c.mode, "NORMAL")
    compare(cc.settingsCommands.input, null)
  }

  function test_5b0_esc_on_the_settings_search_clears_it_and_on_a_search_query_changes_nothing_of_settings() {
    var o = make()
    openSettings(o)
    slash(o)
    compare(o.c.inputPurpose, "settingsSearch")
    line(o).setInput("port")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(view(o).query, "")
    compare(view(o).searching, false)
    verify(view(o).open)
    esc(o)
    openSearch(o)
    var cc = cmdsOf(o)
    cc.startInput("searchQuery", "")
    line(o).setInput("debian")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(o.c.textQuery, "")
    compare(o.c.activeView, "search", "Esc in the field only cancels it")
  }

  // Review Focus 3: picker precedence, Settings, then Search, then C/T.
  function test_5b0_a_search_picker_wins_over_a_stale_torrent_picker_kind_and_closePicker_drops_it() {
    var o = make()
    var cc = cmdsOf(o)
    openSearch(o)
    var sp = searchPane(o)
    sp.setPlugins([{ name: "a", enabled: true }])
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    verify(cc.openPicker() === sp.picker, "Search's picker")
    cc.pickerKind = "category"
    verify(cc.openPicker() === sp.picker, "still Search's, whatever the C/T kind says")
    cc.pickerTargets = [hh("a")]
    cc.closePicker()
    compare(cc.pickerKind, "")
    compare(cc.pickerTargets.length, 0)
    compare(sp.pickerOpen, false)
    compare(o.c.mode, "NORMAL")
    compare(o.c.activeView, "search")
  }

  function test_5b0_a_settings_picker_wins_over_a_stale_torrent_picker_kind_and_closePicker_drops_it() {
    var o = make()
    var cc = cmdsOf(o)
    openSettings(o)
    focusSettingKey(o, "disk_io_type")
    enter(o)
    compare(o.c.mode, "PICKER")
    var p = view(o).picker
    verify(p !== null && p !== undefined)
    verify(cc.openPicker() === p, "Settings' picker")
    cc.pickerKind = "tag"
    verify(cc.openPicker() === p, "still Settings', whatever the C/T kind says")
    cc.closePicker()
    compare(cc.pickerKind, "")
    compare(view(o).pickerOpen, false)
    compare(o.c.mode, "NORMAL")
    verify(view(o).open)
    compare(calls(o.svc, "setPref").length, 0)
  }

  function test_5b0_the_settings_picker_opens_and_enter_accepts_and_esc_closes() {
    var o = make()
    openSettings(o)
    focusSettingKey(o, "disk_io_type")
    enter(o)
    compare(o.c.mode, "PICKER")
    wait(30)
    compare(o.c.typingField(), view(o).picker.inputField, "the picker's field has the keys")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(view(o).pickerOpen, false)
    compare(calls(o.svc, "setPref").length, 0)
    enter(o)
    compare(o.c.mode, "PICKER")
    wait(30)
    var p = view(o).picker
    p.cursor = 1
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(view(o).pickerOpen, false)
    compare(calls(o.svc, "setPref").length, 1)
    compare(calls(o.svc, "setPref")[0].args[0], "disk_io_type")
    wait(30)
  }

  function test_5b0_a_click_on_the_scrim_closes_the_search_category_picker_and_a_row_click_chooses() {
    var o = make()
    openSearch(o)
    var sp = searchPane(o)
    sp.setPlugins([{ name: "a", enabled: true, supportedCategories: [{ id: "movies", name: "Movies" }] }])
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    wait(30)
    mouseClick(sp.picker, 4, 4)
    compare(o.c.mode, "NORMAL")
    compare(sp.pickerOpen, false)
    compare(sp.category, "all", "nothing chosen")
    compare(o.c.activeView, "search")
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    wait(30)
    var item = choiceItem(sp.picker, "movies")
    verify(item !== null, "Movies is on screen")
    mouseClick(item)
    compare(o.c.mode, "NORMAL")
    compare(sp.pickerOpen, false)
    compare(sp.category, "movies")
  }

  // handleBlocked: a view's blocked key says why, muted, with a full stop.
  function test_5b0_a_blocked_key_in_settings_says_why_muted_and_never_reads_the_clipboard() {
    var o = make()
    o.svc.torrents = []
    wait(60)
    compare(o.c.tableState, "empty")
    openSettings(o)
    key(o.c, "l")
    compare(o.c.keyPane, "settingsKeys")
    key(o.c, "u")
    compare(o.c.statusMessage.text, "Nothing to undo.")
    compare(o.c.statusMessage.tone, "muted")
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 0)
  }

  function test_5b0_a_blocked_key_in_search_says_why_muted_and_never_reads_the_clipboard() {
    var o = make()
    o.svc.torrents = []
    wait(60)
    compare(o.c.tableState, "empty")
    openSearch(o)
    key(o.c, "y")
    compare(o.c.statusMessage.text, "Needs a result.")
    compare(o.c.statusMessage.tone, "muted")
    key(o.c, "c")
    compare(o.c.statusMessage.text, "No search plugins yet (P).")
    compare(o.c.statusMessage.tone, "muted")
    compare(calls(o.svc, "readClipboard").length, 0)
  }

  function test_5b0_y_on_the_empty_library_reads_the_clipboard_on_the_torrents_only() {
    var o = make()
    o.svc.torrents = []
    wait(60)
    compare(o.c.tableState, "empty")
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 1)
  }

  // The status line's INSERT routing: a view's field reaches its own view.
  function test_5b0_typing_in_the_settings_search_reaches_setSearch_live() {
    var o = make()
    openSettings(o)
    slash(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "settingsSearch")
    line(o).setInput("port")
    compare(view(o).query, "port", "before Enter")
    compare(o.c.textQuery, "", "never a torrent filter")
    line(o).setInput("por")
    compare(view(o).query, "por")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(view(o).query, "por", "Enter keeps the results")
    compare(o.c.textQuery, "")
  }

  function test_5b0_typing_in_the_search_query_touches_neither_settings_nor_the_torrent_filter() {
    var o = make()
    openSearch(o)
    var cc = cmdsOf(o)
    cc.startInput("searchQuery", "")
    compare(o.c.mode, "INSERT")
    line(o).setInput("debian")
    compare(view(o).query, "", "Settings' search")
    compare(o.c.textQuery, "", "the torrent filter")
    compare(o.c.mode, "INSERT")
    cc.cancelInput()
    cc.startInput("pluginInstall", "")
    line(o).setInput("https://example.org/x.py")
    compare(view(o).query, "")
    compare(o.c.textQuery, "")
    esc(o)
    compare(o.c.mode, "NORMAL")
  }

  function test_5b0_typing_in_the_torrent_filter_narrows_the_table_and_touches_no_view() {
    var o = make()
    slash(o)
    compare(o.c.inputPurpose, "filter")
    line(o).setInput("alp")
    compare(o.c.textQuery, "alp")
    compare(view(o).query, "")
    esc(o)
    compare(o.c.textQuery, "")
  }

  // Footer hints: the flags each view feeds the status line.
  function test_5b0_the_footer_hints_follow_the_view_and_its_flags() {
    var o = make()
    compare(hintsOf(o), "j/k move | Space start/stop | V visual | / filter | s sort | ? keys | q close")
    openSettings(o)
    compare(hintsOf(o), "j/k section | l keys | / search all | Esc back | ? keys")
    key(o.c, "l")
    compare(hintsOf(o), "j/k move | Space toggle | h sections | / search | Esc back | ? keys")
    slash(o)
    compare(hintsOf(o), "Enter keep results | Esc clear")
    line(o).setInput("port")
    enter(o)
    compare(hintsOf(o), "j/k move | Enter edit | h sections | / search | Esc clear search | ? keys")
    esc(o)
    esc(o)
    compare(o.c.activeView, "torrents")
    openSearch(o)
    compare(hintsOf(o), "j/k move | h plugins column | P plugins | Esc back | ? keys")
    searchPane(o).setPlugins([{ name: "a", enabled: true }])
    compare(hintsOf(o), "j/k move | / search | c category | h plugins column | P plugins | Esc back | ? keys")
    slash(o)
    compare(o.c.inputPurpose, "searchQuery")
    compare(hintsOf(o), "Enter search | Esc cancel")
    esc(o)
    compare(hintsOf(o), "j/k move | / search | c category | h plugins column | P plugins | Esc back | ? keys")
  }

  function test_5b0_a_search_confirm_shows_its_accept_word_in_the_footer() {
    var o = make()
    openSearch(o)
    var r = Registry.raiseConfirm(o.c.regState, "search.add", "searchAdd", { result: { fileName: "debian.iso" } })
    o.c.regState = r.state
    o.c.confirmHashes = []
    o.c.confirm = { commandId: "search.add", kind: "searchAdd", line: "Add debian.iso (650 MiB) from example.org?" }
    compare(o.c.mode, "CONFIRM")
    compare(hintsOf(o), "y add | n/Esc keep")
    o.c.close()
  }

  // The palette's evaluation state: which view it opened from.
  function test_5b0_the_palette_judges_its_rows_from_the_torrents_settings_and_search() {
    var o = make()
    key(o.c, ":", 0x3a)
    var r = paletteRowOf(o, "search.open")
    compare(r.enabled, true)
    compare(r.reason, "")
    r = paletteRowOf(o, "settings.open")
    compare(r.enabled, true)
    compare(r.reason, "")
    r = paletteRowOf(o, "settings.undo")
    compare(r.enabled, false)
    compare(r.reason, "open Settings")
    compare(paletteRowOf(o, "search.add"), null, "a Search row isn't listed outside Search")
    esc(o)
    openSettings(o)
    key(o.c, ":", 0x3a)
    r = paletteRowOf(o, "search.open")
    compare(r.enabled, true, ":Search from Settings")
    compare(r.reason, "")
    r = paletteRowOf(o, "settings.open")
    compare(r.enabled, false)
    compare(r.reason, "already open")
    r = paletteRowOf(o, "settings.undo")
    compare(r.enabled, false)
    compare(r.reason, "focus the settings", "judged from the sections column")
    compare(paletteRowOf(o, "search.add"), null)
    esc(o)
    compare(o.c.activeView, "settings")
    key(o.c, "l")
    key(o.c, ":", 0x3a)
    r = paletteRowOf(o, "settings.undo")
    compare(r.enabled, false)
    compare(r.reason, "nothing to undo", "judged in the settings column with Settings' flags")
    esc(o)
    compare(o.c.activeView, "settings")
    esc(o)
    openSearch(o)
    searchPane(o).setPlugins([{ name: "a", enabled: true }])
    key(o.c, ":", 0x3a)
    r = paletteRowOf(o, "search.open")
    compare(r.enabled, false)
    compare(r.reason, "already open")
    r = paletteRowOf(o, "settings.open")
    compare(r.enabled, true, ":Settings from Search")
    r = paletteRowOf(o, "settings.undo")
    compare(r.reason, "open Settings")
    r = paletteRowOf(o, "search.add")
    compare(r.enabled, false)
    compare(r.reason, "needs a result", "judged with Search's flags")
    compare(paletteRowOf(o, "search.new").enabled, true)
    esc(o)
    compare(o.c.activeView, "search")
  }

  // Client.run's routing.
  function test_5b0_run_hands_a_command_to_the_view_that_owns_it() {
    var o = make()
    var sp = null
    o.c.run("search.sort", {}, null, [])
    compare(o.c.activeView, "torrents")
    compare(o.c.sortMode, "added", "a Search command isn't a torrent one")
    openSearch(o)
    sp = searchPane(o)
    var sort = sp.sortMode
    o.c.run("search.sort", {}, null, [])
    verify(sp.sortMode !== sort, "Search's row ran in Search")
    compare(o.c.sortMode, "added")
    o.c.run("search.focusPlugins", {}, null, [])
    compare(o.c.keyPane, "searchPlugins")
    esc(o)
    esc(o)
    compare(o.c.activeView, "torrents")
    o.c.run("sort.next", {}, null, [])
    verify(o.c.sortMode !== "added", "anything else goes to the torrents' commands")
    o.c.run("search.open", {}, null, [])
    compare(o.c.activeView, "search", "the opener isn't Search's")
  }

  function test_5b0_run_hands_a_settings_command_to_settings() {
    var o = make()
    openSettings(o)
    o.c.run("settings.sectionsClose", {}, null, [])
    compare(o.c.activeView, "settings")
    o.c.run("settings.undo", {}, null, [])
    compare(o.c.statusMessage.text, "Nothing to undo.")
    var sort = o.c.sortMode
    o.c.run("settings.sections", {}, null, [])
    compare(o.c.sortMode, sort)
  }

  // showView: the one standing in leaves, then the new one opens.
  function test_5b0_showView_closes_settings_before_opening_search() {
    var o = make()
    openSettings(o)
    goToSection(o, "Speed")
    key(o.c, "l")
    slash(o)
    line(o).setInput("port")
    enter(o)
    compare(view(o).query, "port")
    var seq = view(o).readSeq
    var reads = calls(o.svc, "readPrefs").length
    o.c.showView("search")
    compare(o.c.activeView, "search")
    verify(!view(o).open)
    verify(searchPane(o).open)
    compare(view(o).query, "", "Settings' closeView ran")
    compare(view(o).column, "settingsSections")
    verify(view(o).readSeq > seq)
    compare(calls(o.svc, "readPrefs").length, reads, "Settings' openView didn't run")
    compare(searchPane(o).column, "searchResults")
    compare(o.c.keyPane, "searchResults")
  }

  function test_5b0_showView_closes_search_before_opening_settings() {
    var o = make()
    openSearch(o)
    var sp = searchPane(o)
    sp.column = "searchPlugins"
    o.c.showView("settings")
    compare(o.c.activeView, "settings")
    verify(!sp.open)
    verify(view(o).open)
    compare(sp.column, "searchResults", "Search's closeView ran")
    compare(calls(o.svc, "readPrefs").length, 1, "Settings' openView ran")
    compare(view(o).prefs, null)
    o.svc.answer({ ok: true, prefs: prefs() })
    compare(o.c.keyPane, "settingsSections")
  }

  function test_5b0_showView_to_the_active_view_is_a_no_op_and_an_unknown_name_means_the_torrents() {
    var o = make()
    openSearch(o)
    var sp = searchPane(o)
    sp.column = "searchPlugins"
    o.c.showView("search")
    compare(sp.column, "searchPlugins", "openView didn't run again")
    o.c.showView("nowhere")
    compare(o.c.activeView, "torrents")
    verify(!sp.open)
    compare(sp.column, "searchResults", "closeView ran")
    o.c.showView("torrents")
    compare(o.c.activeView, "torrents")
    o.c.showView("")
    compare(o.c.activeView, "torrents")
  }

  // close(): the window drops what the views hold.
  function test_5b0_close_from_the_palette_in_a_view_ends_the_palette_and_reopens_on_the_torrents() {
    var o = make()
    openSearch(o)
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    o.c.open("")
    backFromSearch(o, "table", "reopened")
    openSettings(o)
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    o.c.open("")
    backOnTorrents(o, "table", "reopened")
  }

  function test_5b0_close_ends_a_settings_edit_input_and_search_insert_purposes() {
    var o = make()
    openSettings(o)
    key(o.c, "l")
    slash(o)
    compare(o.c.inputPurpose, "settingsSearch")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    compare(view(o).query, "")
    compare(cmdsOf(o).settingsCommands.input, null)
    o.c.open("")
    compare(o.c.activeView, "torrents")
  }

  // ClientCommands.runPaletteRow: a row that runs on the torrents leaves the view first.
  function test_5b0_a_palette_row_from_a_view_runs_in_that_view_and_a_torrent_row_leaves_it() {
    var o = make()
    focusTorrentPane(o, "filters")
    openSearch(o)
    searchPane(o).setPlugins([{ name: "a", enabled: true }])
    var mru = o.c.paletteMru.slice()
    runPalette(o, "Sort results")
    compare(o.c.activeView, "search", "a Search row runs in Search")
    compare(o.c.pane, "filters", "the torrent pane underneath stays")
    verify(o.c.paletteMru.length === mru.length + 1, "and goes to the top of the MRU")
    compare(o.c.paletteMru[0], "search.sort")
    runPalette(o, "Settings")
    compare(o.c.activeView, "settings")
    compare(o.c.pane, "filters")
  }

  // Slice 5b0 (Task 3): every view but the torrents has a host with the
  // whole contract (docs/plans/slice-5b0.md), looked up by name.
  function test_every_view_has_a_complete_host() {
    var o = make()
    var client = o.c
    var names = Registry.VIEWS.filter(function (v) { return v !== "torrents" })
    compare(JSON.stringify(client.hostNames), JSON.stringify(names))
    var fns = ["flagsNow", "openView", "closeView", "windowClosed", "owns", "run", "commitInput",
               "cancelInput", "inputEdited", "acceptPicker", "dropPicker", "togglePicker"]
    for (var i = 0; i < names.length; i++) {
      var h = client.viewHost(names[i])
      verify(h !== null, names[i])
      compare(h.name, names[i])
      verify(typeof h.column === "string")
      verify(Array.isArray(h.inputPurposes))
      for (var j = 0; j < fns.length; j++) compare(typeof h[fns[j]], "function", names[i] + "." + fns[j])
    }
    compare(client.viewHost("torrents"), null)
    compare(client.viewHost("nope"), null)
  }
}
