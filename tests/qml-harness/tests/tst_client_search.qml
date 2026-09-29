import QtQuick
import QtTest
import "../../.."
import "../../../ClientView.js" as View

// Slice 5a (Task 3): the Search view through the Client, against a stub
// Service that records every qbt search* call and lets a test end each run
// (searchFinished) and play the sidecar's replies (searchReply). Keys only,
// as a user would press them; a few reads of SearchPane's state where the
// screen can't say it more directly.
TestCase {
  id: tc
  name: "ClientSearch"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
    for (var k in extra || {}) r[k] = extra[k]
    return r
  }
  function magnet(c) { return "magnet:?xt=urn:btih:" + hh(c) + "&dn=x" }
  function row(c, extra) {
    var r = { fileName: "result " + c, fileUrl: magnet(c), fileSize: 1024, nbSeeders: 5, nbLeechers: 1, engineName: "piratebay",
      siteUrl: "https://thepiratebay.org", descrLink: "https://thepiratebay.org/d/" + c, pubDate: 1757894400 }
    for (var k in extra || {}) r[k] = extra[k]
    return r
  }
  function plugins() {
    return [
      { name: "piratebay", fullName: "The Pirate Bay", version: "3.3", enabled: true, url: "https://tpb.example", supportedCategories: [{ id: "movies", name: "Movies" }, { id: "tv", name: "TV shows" }] },
      { name: "eztv", fullName: "EZTV", version: "1.16", enabled: false, url: "https://eztv.example", supportedCategories: [{ id: "tv", name: "TV shows" }] }
    ]
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
      property var searchRecent: []
      property var calls: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal secretFinished(int ticket, bool ok, string error)
      signal clipboardRead(string text)
      signal searchFinished(int ticket, bool ok, string error, var data)
      signal searchReply(var reply)
      signal searchWatchLost()
      function rec(name, args) { seq++; calls.push({ name: name, args: args, ticket: seq }); return seq }
      function saveViewState(s) { viewState = s }
      function refresh() {}
      function refreshSlow() {}
      function watch(h, t) {}
      function readClipboard() {}
      function filesFor(h) { return [] }
      function loadFiles(h, o) {}
      function loadMagnetSnapshot() {}
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function toggleHash(h, o) { return rec("toggle", [h, o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function recheckHash(h, o) { return rec("recheck", [h, o]) }
      function toggleAll(o) { return rec("toggleAll", [o]) }
      function toggleTurtle(o) { return rec("turtle", [o]) }
      function addTarget(t, s, p, o) { return rec("addTarget", [t]) }
      function copyMagnet(r, o) { return rec("copyMagnet", [r]) }
      function openPath(p, o) { return rec("openPath", [p]) }
      function copyText(t, o) { return rec("copyText", [t]) }
      function openUrl(u) { rec("openUrl", [u]); return true }
      function searchStart(p, c) { return rec("searchStart", [p, c]) }
      function searchStop(id) { return rec("searchStop", [id]) }
      function searchDelete(id) { return rec("searchDelete", [id]) }
      function searchAdd(link, plugin) { return rec("searchAdd", plugin ? [link, plugin] : [link]) }
      function searchPluginList() { return rec("searchPluginList", []) }
      // Service's searchPluginChange: set while a plugin change runs, clear
      // before searchFinished reaches the window (this handler connects first).
      property string searchPluginChange: ""
      property int changeTicket: 0
      function change(kind, name, args) { var t = rec(name, args); searchPluginChange = kind; changeTicket = t; return t }
      onSearchFinished: function(ticket, ok, error, data) { if (ticket === changeTicket) { changeTicket = 0; searchPluginChange = "" } }
      function searchPluginInstall(u) { return change("install", "searchPluginInstall", [u]) }
      function searchPluginUninstall(n) { return change("uninstall", "searchPluginUninstall", [n]) }
      function searchPluginEnable(n, on) { return change("toggle", "searchPluginEnable", [n, on]) }
      function searchPluginUpdate() { return change("update", "searchPluginUpdate", []) }
      function searchWatch(id, off) { rec("searchWatch", [id, off]); return true }
      function searchUnwatch() { rec("searchUnwatch", []) }
      function readPrefs(cb) { rec("readPrefs", []) }
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
  function slash(o) { key(o.c, "/", 0x2f) }
  function space(o) { key(o.c, " ", 0x20) }
  function shifted(o, ch) { key(o.c, ch, ch.charCodeAt(0), 0x02000000) }
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
  function sp(o) { return findName(content(o), "searchView") }
  function visibleTexts(obj, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj.text)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleTexts(kids[i], out)
    return out
  }
  function shows(o, text) { wait(30); return visibleTexts(content(o)).indexOf(text) >= 0 }
  function showsIn(o, name, text) { wait(30); return visibleTexts(findName(content(o), name)).indexOf(text) >= 0 }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function last(svc, name) { var l = calls(svc, name); return l.length > 0 ? l[l.length - 1] : null }
  function finishCall(o, name, ok, err, data) {
    var c = last(o.svc, name)
    verify(c !== null, name + " was called")
    o.svc.searchFinished(c.ticket, ok, err || "", data === undefined ? null : data)
  }
  function statusText(o) { return o.c.statusMessage.text }
  function confirmText(o) { var p = View.confirmLine(o.c.confirm); return p.lead + p.strong + p.tail }
  function reply(o, extra) {
    var r = { type: "search", id: 7, status: "Running", total: 0, offset: 0, rows: [], capped: false }
    for (var k in extra) r[k] = extra[k]
    o.svc.searchReply(r)
  }

  function make(width) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha", { addedOn: 3 }), tt(hh("b"), "beta", { addedOn: 2 })]
    var o = { c: c, svc: svc, sh: sh }
    if (width) {
      winOf(c).width = width
      tryVerify(function() { return winOf(c).contentItem.width === width }, 2000)
    }
    return o
  }
  // Closes the window and builds a new one on the same Service, as the
  // shell does on every toggle (the old Client is destroyed).
  function reopen(o) {
    o.c.close()
    o.c.destroy()
    wait(0)
    var c = createTemporaryObject(clientComp, tc)
    o.sh.target = c
    c.shell = o.sh
    c.service = o.svc
    c.open("")
    o.c = c
  }
  // F, and the plugin list's answer.
  function openSearch(o, list) {
    shifted(o, "F")
    compare(o.c.activeView, "search")
    finishCall(o, "searchPluginList", true, "", list === undefined ? plugins() : list)
  }
  // `/` query Enter, and qbt search start's {"id":7}.
  function startSearch(o, q, id) {
    slash(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "searchQuery")
    line(o).setInput(q)
    enter(o)
    compare(o.c.mode, "NORMAL")
    finishCall(o, "searchStart", true, "", { id: id || 7 })
  }
  function streaming(o) {
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 2, rows: [row("c", { nbSeeders: 3 }), row("d", { nbSeeders: 9, fileName: "debian.iso", fileSize: 663748608 })] })
  }

  // ---- the States table ----------------------------------------------------------------------

  function test_no_plugins_state_and_slash_blocked() {
    var o = make()
    openSearch(o, [])
    verify(showsIn(o, "searchResultsPane", "No search plugins yet"))
    verify(shows(o, "plugins none"))
    slash(o)
    compare(o.c.mode, "NORMAL", "OV8: / needs a plugin")
    compare(statusText(o), "No search plugins yet (P).")
    compare(calls(o.svc, "searchStart").length, 0)
  }

  function test_all_plugins_off_blocks_slash() {
    var o = make()
    var list = plugins()
    list[0].enabled = false
    openSearch(o, list)
    slash(o)
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), "All plugins are off (P).")
  }

  function test_running_then_done_with_the_final_reply() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian 13")
    compare(last(o.svc, "searchStart").args, ["debian 13", "all"])
    compare(last(o.svc, "searchWatch").args, [7, 0], "the watch starts at offset 0")
    verify(shows(o, "searching… · 0 results"))
    verify(findName(content(o), "searchRunBar").visible, "the thin accent bar")
    verify(showsIn(o, "searchResultsPane", "No results yet"))
    reply(o, { total: 3, rows: [row("c", { nbSeeders: 3 }), row("d", { nbSeeders: 9 })] })
    verify(shows(o, "searching… · 2 results"))
    compare(sp(o).shownKeys.length, 2)
    compare(sp(o).currentResult.name, "result c", "the cursor stays on its row")
    compare(sp(o).shownKeys[0], "h:" + hh("c"), "appended as they arrive, not re-sorted")
    compare(calls(o.svc, "searchDelete").length, 0)
    reply(o, { status: "Stopped", total: 3, offset: 2, rows: [row("e", { nbSeeders: 1 })] })
    verify(shows(o, "done · 3 results"))
    verify(!findName(content(o), "searchRunBar").visible)
    compare(sp(o).shownKeys[0], "h:" + hh("d"), "re-sorted by seeds when the search finishes")
    compare(sp(o).currentResult.name, "result c", "and the cursor stays on its row")
    compare(last(o.svc, "searchDelete").args, [7], "OV14: deleted after the final read")
    verify(calls(o.svc, "searchUnwatch").length > 0)
    verify(shows(o, "The Pirate Bay"))
  }

  function test_finished_empty_says_no_results_for_the_query() {
    var o = make()
    openSearch(o)
    startSearch(o, "xyz")
    reply(o, { status: "Stopped", total: 0, rows: [] })
    verify(shows(o, "done · 0 results"))
    verify(showsIn(o, "searchResultsPane", "No results for \"xyz\". Try fewer words, or check which plugins are on (P)."))
    compare(last(o.svc, "searchDelete").args, [7])
  }

  function test_esc_stops_a_running_search_then_leaves() {
    var o = make()
    streaming(o)
    esc(o)
    compare(o.c.activeView, "search", "the first Esc only stops")
    compare(last(o.svc, "searchStop").args, [7])
    verify(shows(o, "stopped · 2 results"))
    reply(o, { status: "Stopped", total: 2, offset: 2, rows: [] })
    verify(shows(o, "stopped · 2 results"), "stays stopped after the final reply")
    compare(last(o.svc, "searchDelete").args, [7])
    esc(o)
    compare(o.c.activeView, "torrents")
    shifted(o, "F")
    compare(sp(o).shownKeys.length, 2, "D7: the results survive leaving")
  }

  function test_esc_before_the_start_answers_stops_once_the_id_arrives() {
    var o = make()
    openSearch(o)
    slash(o)
    line(o).setInput("debian")
    enter(o)
    esc(o)
    compare(o.c.activeView, "search")
    compare(calls(o.svc, "searchStop").length, 0)
    finishCall(o, "searchStart", true, "", { id: 9 })
    compare(last(o.svc, "searchStop").args, [9])
    verify(shows(o, "stopped · 0 results"))
  }

  function test_a_start_qbt_refuses_shows_its_sentence() {
    var o = make()
    openSearch(o)
    slash(o)
    line(o).setInput("debian")
    enter(o)
    finishCall(o, "searchStart", false, "Search needs Python on this machine.")
    compare(statusText(o), "Search needs Python on this machine.")
    compare(calls(o.svc, "searchWatch").length, 0)
    slash(o)
    line(o).setInput("again")
    enter(o)
    finishCall(o, "searchStart", true, "", { nope: 1 })
    compare(statusText(o), "qBittorrent sent something unreadable")
  }

  function test_a_refused_pattern_stays_in_insert() {
    var o = make()
    openSearch(o)
    slash(o)
    line(o).setInput("   ")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(statusText(o), "Type something to search for.")
    compare(calls(o.svc, "searchStart").length, 0)
  }

  function test_gone_says_qbittorrent_restarted() {
    var o = make()
    streaming(o)
    o.svc.searchReply({ type: "search", id: 7, error: "gone" })
    compare(statusText(o), "The search ended when qBittorrent restarted.")
    reply(o, { offset: 2, rows: [row("z")] })
    compare(sp(o).shownKeys.length, 2, "nothing after gone")
  }

  // ---- streaming correctness (OV7, Ruling FB) ----------------------------------------------------

  function test_offsets_continue_after_a_sidecar_restart_and_stale_replies_drop() {
    var o = make()
    streaming(o)
    var watches = calls(o.svc, "searchWatch").length
    reply(o, { total: 4, offset: 0, rows: [row("c"), row("d")] })
    compare(sp(o).shownKeys.length, 2, "a duplicate is dropped")
    compare(last(o.svc, "searchWatch").args, [7, 2], "and the watch re-sent at the rows held")
    reply(o, { total: 9, offset: 5, rows: [row("x")] })
    compare(sp(o).shownKeys.length, 2, "a gap is dropped")
    compare(last(o.svc, "searchWatch").args, [7, 2])
    reply(o, { id: 6, total: 9, offset: 2, rows: [row("y")] })
    compare(sp(o).shownKeys.length, 2, "another job's reply is dropped")
    compare(calls(o.svc, "searchWatch").length, watches + 2, "with no re-send")
    o.svc.searchWatchLost()
    compare(last(o.svc, "searchWatch").args, [7, 2], "a restarted sidecar resumes at the rows held")
    reply(o, { total: 3, offset: 2, rows: [row("e")] })
    compare(sp(o).held, 3)
    compare(sp(o).shownKeys.length, 3)
  }

  function test_merged_rows_keep_the_raw_offset_and_name_both_plugins() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 2, rows: [row("c"), row("c", { engineName: "eztv" })] })
    compare(sp(o).shownKeys.length, 1, "OV11: the same hash from two plugins is one row")
    compare(sp(o).held, 2, "the offset counts raw rows")
    verify(shows(o, "The Pirate Bay, EZTV"))
    reply(o, { total: 3, offset: 2, rows: [row("d")] })
    compare(sp(o).shownKeys.length, 2, "no re-send loop")
  }

  function test_capped_says_showing_2000_of_n() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 5120, rows: [row("c")], capped: true })
    verify(shows(o, "sorted by seeds ▾ · 1 · showing 2000 of 5120"))
  }

  function test_a_new_search_replaces_the_old_job() {
    var o = make()
    streaming(o)
    slash(o)
    compare(line(o).inputValue(), "debian", "/ offers the last query")
    line(o).setInput("ubuntu")
    enter(o)
    verify(calls(o.svc, "searchUnwatch").length > 0, "the old watch goes")
    compare(sp(o).shownKeys.length, 0)
    reply(o, { total: 3, offset: 2, rows: [row("q")] })
    compare(sp(o).shownKeys.length, 0, "the old job's replies are stale")
    finishCall(o, "searchStart", true, "", { id: 8 })
    compare(last(o.svc, "searchWatch").args, [8, 0])
    compare(o.svc.searchRecent, ["ubuntu", "debian"], "Recent, newest first")
    verify(shows(o, "debian"), "Recent shows in the Plugins column")
  }

  function test_only_the_latest_start_counts() {
    var o = make()
    openSearch(o)
    slash(o); line(o).setInput("one"); enter(o)
    var first = last(o.svc, "searchStart")
    slash(o); line(o).setInput("two"); enter(o)
    o.svc.searchFinished(first.ticket, true, "", { id: 3 })
    compare(calls(o.svc, "searchWatch").length, 0, "the first start's job is never watched")
    finishCall(o, "searchStart", true, "", { id: 4 })
    compare(last(o.svc, "searchWatch").args, [4, 0])
  }

  function test_closing_the_window_deletes_the_job() {
    var o = make()
    streaming(o)
    o.c.close()
    compare(last(o.svc, "searchDelete").args, [7])
    verify(calls(o.svc, "searchUnwatch").length > 0)
  }

  // ---- results: Enter, y, d ---------------------------------------------------------------------------

  function test_enter_confirms_then_adds_a_magnet_and_says_added_once_in_the_library() {
    var o = make()
    streaming(o)
    key(o.c, "j")
    compare(sp(o).currentResult.name, "debian.iso")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "Add debian.iso (633.0 MiB) from thepiratebay.org?")
    key(o.c, "y")
    compare(last(o.svc, "searchAdd").args, [magnet("d"), "piratebay"])
    finishCall(o, "searchAdd", true, "", { ok: true, via: "add" })
    verify(statusText(o).indexOf("Added") === -1, "not before the hash is in the library")
    o.svc.torrents = o.svc.torrents.concat([tt(hh("d"), "debian.iso")])
    compare(statusText(o), "Added debian.iso.")
  }

  function test_a_plugin_add_says_sent() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c", { fileUrl: "https://tpb.example/download/123", fileName: "big buck bunny" })] })
    enter(o)
    compare(confirmText(o), "Add big buck bunny (1.0 KiB) from tpb.example?")
    key(o.c, "y")
    compare(last(o.svc, "searchAdd").args, ["https://tpb.example/download/123", "piratebay"])
    finishCall(o, "searchAdd", true, "", { ok: true, via: "plugin" })
    compare(statusText(o), "Sent big buck bunny to qBittorrent · it appears when its download finishes.")
  }

  function test_in_library_says_so_and_adds_nothing() {
    var o = make()
    openSearch(o)
    startSearch(o, "alpha")
    reply(o, { total: 1, rows: [row("a")] })
    verify(shows(o, "in library"))
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), "Already in your library.")
    compare(calls(o.svc, "searchAdd").length, 0)
  }

  function test_an_unusable_link_is_refused_before_the_confirm() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c", { fileUrl: "http://e.example/x.torrent", engineName: "" })] })
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), "That result has no usable link.")
  }

  function test_d_confirms_the_host_then_opens_detached() {
    var o = make()
    streaming(o)
    key(o.c, "d")
    compare(confirmText(o), "Open thepiratebay.org in your browser? It won't go through the VPN.")
    key(o.c, "n")
    compare(calls(o.svc, "openUrl").length, 0)
    key(o.c, "d")
    key(o.c, "y")
    compare(last(o.svc, "openUrl").args, ["https://thepiratebay.org/d/c"])
  }

  function test_d_refuses_a_javascript_link() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c", { descrLink: "javascript:alert(1)" })] })
    key(o.c, "d")
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), "That page link isn't http or https.")
  }

  function test_y_copies_the_link() {
    var o = make()
    streaming(o)
    key(o.c, "y")
    compare(last(o.svc, "copyText").args, [magnet("c")])
  }

  // ---- sort and the Plugins column -----------------------------------------------------------------

  function test_s_and_S_sort_and_the_plugins_column_filters() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 3, rows: [row("c", { fileName: "b" }), row("d", { fileName: "a", engineName: "eztv" }), row("e", { fileName: "c", engineName: "" })] })
    key(o.c, "s")
    verify(shows(o, "sorted by name ▴ · 3"))
    compare(sp(o).shownKeys[0], "h:" + hh("d"))
    shifted(o, "S")
    compare(sp(o).shownKeys[0], "h:" + hh("e"))
    key(o.c, "h")
    compare(o.c.keyPane, "searchPlugins")
    verify(shows(o, "All results"))
    verify(shows(o, "other"), "the other bucket")
    key(o.c, "j")
    compare(sp(o).shownKeys.length, 3, "review 7: the filter waits for the keys to pause")
    tryCompare(sp(o), "shownKeys", ["h:" + hh("c")], 1000, "j filters to The Pirate Bay")
    key(o.c, "j")
    tryCompare(sp(o), "shownKeys", ["h:" + hh("d")], 1000, "EZTV (off, but it has results)")
    key(o.c, "j")
    tryCompare(sp(o), "shownKeys", ["h:" + hh("e")], 1000, "other")
    key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    compare(sp(o).shownKeys, ["h:" + hh("e")], "held keys don't rebuild on every row")
    tryVerify(function() { return sp(o).shownKeys.length === 3 }, 1000, "All results")
  }

  function test_category_picker_lists_what_enabled_plugins_support() {
    var o = make()
    openSearch(o)
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    var rows = sp(o).picker.rows.map(function(r) { return r.title })
    compare(rows, ["All categories", "Movies", "TV shows"])
    key(o.c, "", 0x01000015)
    enter(o)
    compare(sp(o).category, "movies")
    verify(shows(o, "category Movies"))
    startSearch(o, "big buck bunny")
    compare(last(o.svc, "searchStart").args, ["big buck bunny", "movies"])
  }

  // ---- the plugins overlay ---------------------------------------------------------------------------

  function test_plugins_overlay_toggle_uninstall_update() {
    var o = make()
    openSearch(o)
    shifted(o, "P")
    compare(o.c.keyPane, "searchPluginList")
    var ov = findName(content(o), "searchPluginOverlay")
    verify(ov && ov.visible)
    verify(!ov.inputField.visible, "no field: the keys stay NORMAL")
    verify(shows(o, "2 installed · 1 enabled"))
    verify(shows(o, "The Pirate Bay v3.3"))
    key(o.c, "j")
    space(o)
    compare(last(o.svc, "searchPluginEnable").args, ["eztv", true])
    verify(shows(o, "saving…"))
    key(o.c, "x")
    compare(o.c.mode, "NORMAL", "x waits for the change")
    var lists = calls(o.svc, "searchPluginList").length
    finishCall(o, "searchPluginEnable", true, "", { ok: true })
    compare(calls(o.svc, "searchPluginList").length, lists + 1, "the list is read again")
    key(o.c, "x")
    compare(confirmText(o), "Uninstall eztv?")
    key(o.c, "y")
    compare(last(o.svc, "searchPluginUninstall").args, ["eztv"])
    finishCall(o, "searchPluginUninstall", false, "Couldn't confirm the uninstall of eztv.")
    compare(statusText(o), "Couldn't confirm the uninstall of eztv.")
    shifted(o, "U")
    shifted(o, "U")
    compare(calls(o.svc, "searchPluginUpdate").length, 1, "U waits while an update runs")
    verify(shows(o, "updating…"))
    finishCall(o, "searchPluginUpdate", true, "", { ok: true })
    shifted(o, "U")
    compare(calls(o.svc, "searchPluginUpdate").length, 2)
    esc(o)
    compare(o.c.keyPane, "searchResults")
  }

  function test_install_checks_the_url_in_insert_then_confirms_with_d4_copy() {
    var o = make()
    openSearch(o)
    shifted(o, "P")
    key(o.c, "i")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "pluginInstall")
    line(o).setInput("http://example.org/jackett.py")
    enter(o)
    compare(o.c.mode, "INSERT", "a refused URL stays in INSERT")
    compare(statusText(o), "Plugin URLs must start with https://.")
    line(o).setInput("https://user:pw@example.org/jackett.py")
    enter(o)
    compare(statusText(o), "Use a URL without a user name or password.")
    line(o).setInput("https://Bücher.example/plugins/jackett.py")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "Install jackett from xn--bcher-kva.example? This runs Python code as qBittorrent, with access to your downloads.")
    key(o.c, "y")
    compare(last(o.svc, "searchPluginInstall").args, ["https://Bücher.example/plugins/jackett.py"])
    verify(shows(o, "installing…"))
    finishCall(o, "searchPluginInstall", false, "jackett v4.0 is already installed.")
    compare(statusText(o), "jackett v4.0 is already installed.")
  }

  // ---- the down screen (OV4) ------------------------------------------------------------------------

  function test_one_missed_status_during_an_update_keeps_the_view() {
    var o = make()
    openSearch(o)
    shifted(o, "P")
    shifted(o, "U")
    o.svc.api = false
    wait(50)
    verify(!findName(content(o), "searchDown").visible, "one missed status line doesn't flip to the down screen")
    tryVerify(function() { return findName(content(o), "searchDown").visible }, 4000, "a longer outage does")
    o.svc.api = true
    tryVerify(function() { return !findName(content(o), "searchDown").visible }, 2000)
  }

  function test_qbittorrent_down_shows_the_down_screen_at_once_otherwise() {
    var o = make()
    openSearch(o)
    o.svc.api = false
    wait(50)
    verify(findName(content(o), "searchDown").visible)
    esc(o)
    compare(o.c.activeView, "torrents")
  }

  // ---- keys and text ---------------------------------------------------------------------------------

  function test_torrent_keys_never_reach_the_torrents_from_search() {
    var o = make()
    streaming(o)
    // Review 1: what the torrents hold before, not just the calls.
    var before = JSON.stringify({ vs: o.svc.viewState, pane: o.c.pane, cursor: o.c.cursorHash, filter: o.c.filter,
      tab: o.c.inspectorTab, sort: o.c.sortMode, desc: o.c.sortDesc, query: o.c.textQuery })
    var keys = ["t", "z", "r", "1", "2", "3", "4", "5", "q", "f", "V", ",", "e", "o", "m", "C", "T", "X", "G", "x", "p", "a", "u"]
    for (var i = 0; i < keys.length; i++) {
      key(o.c, keys[i])
      if (o.c.mode !== "NORMAL") esc(o)
    }
    space(o)
    shifted(o, "P")
    space(o)
    esc(o)
    var torrentCalls = ["start", "stop", "toggle", "delete", "recheck", "toggleAll", "turtle", "addTarget", "copyMagnet", "openPath"]
    for (var j = 0; j < torrentCalls.length; j++) compare(calls(o.svc, torrentCalls[j]).length, 0, torrentCalls[j])
    compare(o.c.activeView, "search")
    verify(o.c.opened)
    compare(JSON.stringify({ vs: o.svc.viewState, pane: o.c.pane, cursor: o.c.cursorHash, filter: o.c.filter,
      tab: o.c.inspectorTab, sort: o.c.sortMode, desc: o.c.sortDesc, query: o.c.textQuery }), before, "the torrent view is as it was")
    esc(o)
    esc(o)
    compare(o.c.activeView, "torrents", "Esc stops the search, then leaves")
    compare(JSON.stringify({ vs: o.svc.viewState, pane: o.c.pane, cursor: o.c.cursorHash, filter: o.c.filter,
      tab: o.c.inspectorTab, sort: o.c.sortMode, desc: o.c.sortDesc, query: o.c.textQuery }), before, "and still is after leaving")
  }

  function test_every_text_is_plain_text() {
    var o = make()
    var list = plugins()
    list[0].fullName = "<b>Pirate</b>"
    list[0].supportedCategories = [{ id: "movies", name: "<i>Movies</i>" }]
    openSearch(o, list)
    startSearch(o, "<i>q</i>")
    reply(o, { total: 2, rows: [row("c", { fileName: "<a href='x'>evil</a>‮", engineName: "piratebay" }), row("d", { engineName: "<u>e</u>" })] })
    // Every Text in Search and the status line (its CONFIRM and notes),
    // with the add confirm up, then with the plugins overlay up. A text
    // field and its placeholder are typed into or ours, never markup.
    function richTexts() {
      var rich = []
      var walk = function(obj) {
        if (!obj) return
        if (typeof obj.text === "string" && obj.font !== undefined && obj.textFormat !== undefined && obj.textFormat !== Text.PlainText
          && obj.cursorPosition === undefined && !(obj.parent && obj.parent.cursorPosition !== undefined)) rich.push(String(obj) + ": " + obj.text)
        var kids = obj.children || []
        for (var i = 0; i < kids.length; i++) walk(kids[i])
      }
      walk(sp(o))
      walk(line(o))
      return rich
    }
    enter(o)
    compare(o.c.mode, "CONFIRM")
    wait(30)
    compare(richTexts().length, 0, JSON.stringify(richTexts()))
    key(o.c, "n")
    shifted(o, "P")
    wait(30)
    compare(richTexts().length, 0, JSON.stringify(richTexts()))
    esc(o)
    // Review 6: the category picker, with a markup category name.
    key(o.c, "c")
    compare(o.c.mode, "PICKER")
    wait(30)
    compare(sp(o).picker.rows[1].title, "<i>Movies</i>")
    compare(richTexts().length, 0, JSON.stringify(richTexts()))
    esc(o)
    verify(shows(o, "<a href='x'>evil</a>"), "shown as text, the bidi override stripped")
  }

  // ---- narrow -----------------------------------------------------------------------------------------

  function test_narrow_chip_overlay_and_columns() {
    var o = make(700)
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c")] })
    verify(sp(o).narrow)
    verify(!findName(content(o), "searchPluginsPane").visible, "the column is a chip")
    verify(shows(o, "All results ▾"))
    verify(!shows(o, "Published") && !shows(o, "Peers"), "Published and Peers hide first")
    verify(shows(o, "Plugin"), "700 px still shows Plugin")
    tab(o)
    compare(o.c.keyPane, "searchPlugins")
    verify(findName(content(o), "searchPluginsPane").visible, "Tab opens it as an overlay")
    esc(o)
    compare(o.c.keyPane, "searchResults")
    compare(o.c.activeView, "search")
    // The 640 px minimum window reaches it (Ruling FD): below 700 px.
    var n = make(660)
    openSearch(n)
    startSearch(n, "debian")
    reply(n, { total: 1, rows: [row("c")] })
    verify(!shows(n, "Plugin"), "then Plugin")
  }

  // ---- fix round 1 ---------------------------------------------------------------------------------------

  function test_no_plugins_explains_what_plugins_are() {
    var o = make()
    openSearch(o, [])
    verify(showsIn(o, "searchResultsPane", "qBittorrent searches through plugins it runs with Python on this machine. P manages them; i installs one from an https URL."))
  }

  // W1: the start's job is Service's to delete (tst_service_search); the
  // rebuilt window never touches the old start, and keeps its own job.
  function test_a_close_while_starting_leaves_the_old_start_to_service() {
    var o = make()
    openSearch(o)
    slash(o); line(o).setInput("one"); enter(o)
    var first = last(o.svc, "searchStart")
    reopen(o)
    compare(o.svc.windowOpen, true)
    openSearch(o)
    slash(o); line(o).setInput("two"); enter(o)
    var second = last(o.svc, "searchStart")
    verify(second.ticket !== first.ticket)
    o.svc.searchFinished(first.ticket, true, "", { id: 3 })
    compare(calls(o.svc, "searchWatch").length, 0, "the old start's job is never watched")
    compare(calls(o.svc, "searchDelete").length, 0, "nor deleted by the window (Service does it)")
    o.svc.searchFinished(second.ticket, true, "", { id: 4 })
    compare(calls(o.svc, "searchDelete").length, 0, "the new job is kept")
    compare(last(o.svc, "searchWatch").args, [4, 0])
    verify(shows(o, "searching… · 0 results"))
  }

  // W1: a plugin change started before the window was rebuilt still shows,
  // still holds Space/i/U, and OV4's hold still covers the update.
  function test_a_reopened_window_waits_for_the_plugin_change() {
    var o = make()
    openSearch(o)
    shifted(o, "P")
    shifted(o, "U")
    compare(calls(o.svc, "searchPluginUpdate").length, 1)
    reopen(o)
    openSearch(o)
    shifted(o, "P")
    compare(o.c.keyPane, "searchPluginList")
    verify(shows(o, "updating…"))
    shifted(o, "U")
    space(o)
    key(o.c, "i")
    compare(o.c.mode, "NORMAL", "i waits")
    compare(calls(o.svc, "searchPluginUpdate").length, 1, "U waits")
    compare(calls(o.svc, "searchPluginEnable").length, 0, "Space waits")
    o.svc.api = false
    wait(50)
    verify(!findName(content(o), "searchDown").visible, "one missed status line during the update keeps the view")
    o.svc.api = true
    wait(30)
    var lists = calls(o.svc, "searchPluginList").length
    finishCall(o, "searchPluginUpdate", true, "", { ok: true })
    compare(calls(o.svc, "searchPluginList").length, lists + 1, "the list is read again")
    verify(!shows(o, "updating…"))
    shifted(o, "U")
    compare(calls(o.svc, "searchPluginUpdate").length, 2)
  }

  // W2: over the down screen only Esc acts.
  function test_the_down_screen_blocks_the_search_keys() {
    var o = make()
    streaming(o)
    reply(o, { status: "Stopped", total: 2, offset: 2, rows: [] })
    verify(sp(o).currentResult !== null)
    o.svc.api = false
    wait(50)
    verify(findName(content(o), "searchDown").visible)
    compare(sp(o).flags.result, null)
    compare(sp(o).flags.plugin, null)
    compare(sp(o).flags.enabledPlugins, 0)
    enter(o)
    compare(o.c.mode, "NORMAL", "Enter adds nothing")
    compare(o.c.confirm, null)
    slash(o)
    compare(o.c.mode, "NORMAL", "/ is blocked")
    shifted(o, "P")
    compare(o.c.keyPane, "searchResults", "P is blocked")
    key(o.c, "c")
    compare(o.c.mode, "NORMAL", "c is blocked")
    compare(calls(o.svc, "searchStart").length, 1)
    esc(o)
    compare(o.c.activeView, "torrents", "Esc still leaves")
  }

  // W3: a held row that gains the filtered plugin shows at once.
  function test_a_row_gaining_the_filtered_plugin_shows_at_once() {
    var o = make()
    var list = plugins()
    list[1].enabled = true
    openSearch(o, list)
    startSearch(o, "debian")
    reply(o, { total: 3, rows: [row("c"), row("d", { engineName: "eztv" })] })
    key(o.c, "h")
    key(o.c, "j"); key(o.c, "j")
    tryCompare(sp(o), "shownKeys", ["h:" + hh("d")], 1000, "filtered to EZTV")
    reply(o, { total: 3, offset: 2, rows: [row("c", { engineName: "eztv" })] })
    compare(sp(o).shownKeys, ["h:" + hh("d"), "h:" + hh("c")], "the merged row is appended while the search runs")
    verify(showsIn(o, "searchResultsPane", "The Pirate Bay, EZTV"))
    reply(o, { total: 3, offset: 3, rows: [row("c", { engineName: "eztv" })] })
    compare(sp(o).shownKeys.length, 2, "once")
  }

  // Esc before the id with the sidecar down: the job is deleted once the id
  // arrives, never stopped or watched.
  function test_esc_before_the_id_with_the_sidecar_down_deletes_the_job() {
    var o = make()
    o.svc.sidecarState = "down"
    o.svc.sidecarDown = true
    openSearch(o)
    slash(o)
    line(o).setInput("debian")
    enter(o)
    esc(o)
    compare(o.c.activeView, "search")
    compare(calls(o.svc, "searchDelete").length, 0)
    finishCall(o, "searchStart", true, "", { id: 9 })
    compare(last(o.svc, "searchDelete").args, [9])
    compare(calls(o.svc, "searchStop").length, 0)
    compare(calls(o.svc, "searchWatch").length, 0)
    verify(shows(o, "stopped · 0 results"))
  }

  // Ruling FG: the stalled line only once the sidecar is down, not while it starts.
  function test_the_stalled_line_waits_for_the_sidecar_to_be_down() {
    var o = make()
    streaming(o)
    o.svc.sidecarState = "starting"
    wait(30)
    verify(!findName(content(o), "searchStalled").visible, "a starting sidecar says nothing")
    o.svc.sidecarState = "down"
    verify(findName(content(o), "searchStalled").visible)
    o.svc.sidecarState = "up"
    verify(!findName(content(o), "searchStalled").visible)
  }

  function test_sidecar_down_says_nothing_arrives_and_esc_deletes_the_job() {
    var o = make()
    streaming(o)
    verify(!findName(content(o), "searchStalled").visible, "a quiet search says nothing")
    wait(200)
    verify(!findName(content(o), "searchStalled").visible)
    o.svc.sidecarState = "down"
    verify(findName(content(o), "searchStalled").visible)
    verify(shows(o, "No results are arriving; press Esc and try again."))
    esc(o)
    compare(calls(o.svc, "searchStop").length, 0)
    compare(last(o.svc, "searchDelete").args, [7], "review 4: deleted at once")
    verify(!findName(content(o), "searchStalled").visible, "stopped")
    verify(shows(o, "stopped · 2 results"))
  }

  function test_a_magnet_that_never_arrives_is_reported() {
    var o = make()
    streaming(o)
    sp(o).addConfirmMs = 300
    enter(o)
    key(o.c, "y")
    finishCall(o, "searchAdd", true, "", { ok: true, via: "add" })
    tryVerify(function() { return o.c.statusMessage.text === "Couldn't confirm result c was added." }, 3000, o.c.statusMessage.text)
    o.svc.torrents = o.svc.torrents.concat([tt(hh("c"), "late")])
    wait(50)
    verify(o.c.statusMessage.text.indexOf("Added") === -1, "reported once")
  }

  function test_an_empty_engine_name_is_the_plugin_with_that_site() {
    var o = make()
    var list = plugins()
    list.push({ name: "linuxtracker", fullName: "Linux Tracker", version: "1.0", enabled: true, url: "https://linuxtracker.org", supportedCategories: [] })
    openSearch(o, list)
    startSearch(o, "debian")
    reply(o, { total: 2, rows: [row("c", { engineName: "", siteUrl: "https://linuxtracker.org", fileUrl: "https://linuxtracker.org/dl/1" }),
      row("d", { engineName: "", siteUrl: "https://unknown.example" })] })
    var col = sp(o).columnRows
    var lt = col.filter(function(r) { return r.engine === "linuxtracker" })[0]
    compare(lt.count, 1, "counted under its plugin")
    compare(col.filter(function(r) { return r.engine === "" })[0].count, 1, "the rest is other")
    verify(shows(o, "Linux Tracker"))
    enter(o)
    compare(confirmText(o), "Add result c (1.0 KiB) from linuxtracker.org?")
    key(o.c, "y")
    compare(last(o.svc, "searchAdd").args, ["https://linuxtracker.org/dl/1", "linuxtracker"], "and qbt search add gets its name")
  }

  function test_rows_before_the_plugin_list_are_mapped_when_it_arrives() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c", { engineName: "", siteUrl: "https://linuxtracker.org" })] })
    compare(sp(o).columnRows.filter(function(r) { return r.engine === "" })[0].count, 1)
    var list = plugins()
    list.push({ name: "linuxtracker", fullName: "Linux Tracker", version: "1.0", enabled: true, url: "https://linuxtracker.org", supportedCategories: [] })
    sp(o).setPlugins(list)
    compare(sp(o).columnRows.filter(function(r) { return r.engine === "linuxtracker" })[0].count, 1)
    compare(sp(o).currentResult.engine, "linuxtracker")
  }

  function test_enter_on_a_recent_row_searches_it_again() {
    var o = make()
    streaming(o)
    reply(o, { status: "Stopped", total: 2, offset: 2, rows: [] })
    slash(o); line(o).setInput("ubuntu"); enter(o)
    finishCall(o, "searchStart", true, "", { id: 8 })
    key(o.c, "h")
    var col = sp(o).columnRows
    var at = -1
    for (var i = 0; i < col.length; i++) if (col[i].kind === "recent" && col[i].query === "debian") at = i
    verify(at > 0, "Recent rows are in the column")
    for (var j = 0; j < at; j++) key(o.c, "j")
    compare(sp(o).columnIndex, at)
    wait(250)
    compare(sp(o).pluginFilter, null, "a Recent row doesn't filter")
    key(o.c, "l")
    compare(o.c.keyPane, "searchResults", "l only moves to the results")
    compare(last(o.svc, "searchStart").args[0], "ubuntu")
    key(o.c, "h")
    enter(o)
    compare(last(o.svc, "searchStart").args, ["debian", "all"], "Enter searches it again")
    compare(o.c.keyPane, "searchResults")
  }

  function test_a_filter_with_no_rows_says_so() {
    var o = make()
    openSearch(o)
    startSearch(o, "debian")
    reply(o, { total: 1, rows: [row("c", { engineName: "eztv" })] })
    key(o.c, "h")
    key(o.c, "j")
    tryCompare(sp(o), "pluginFilter", "piratebay", 1000)
    verify(showsIn(o, "searchResultsPane", "No results from The Pirate Bay."))
  }

  function test_the_pattern_trims_like_qt() {
    var o = make()
    openSearch(o)
    slash(o)
    line(o).setInput("\u3000\u00a0\u2028")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(statusText(o), "Type something to search for.")
    line(o).setInput("\u3000debian\u00a0")
    enter(o)
    compare(last(o.svc, "searchStart").args, ["debian", "all"])
  }
  // ---- slice 5b0 (Task 1): pins for the view-host refactor ----------------------------------

  function settingsPane(o) { return findName(content(o), "settingsView") }
  function paletteOf(o) { return findWith(content(o), "complete") }
  function paletteRow(o, id) {
    var rows = paletteOf(o).rows.filter(function(r) { return r.id === id })
    return rows.length === 0 ? null : rows[0]
  }

  function test_5b0_closing_the_window_with_a_search_confirm_drops_it_and_deletes_the_job() {
    var o = make()
    streaming(o)
    key(o.c, "j")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    verify(o.c.confirm !== null)
    compare(calls(o.svc, "searchDelete").length, 0)
    o.c.close()
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null)
    compare(calls(o.svc, "searchAdd").length, 0, "the question was never answered")
    compare(calls(o.svc, "searchDelete").length, 1)
    compare(last(o.svc, "searchDelete").args, [7])
    verify(calls(o.svc, "searchUnwatch").length > 0)
    compare(o.c.activeView, "torrents")
  }

  function test_5b0_showView_leaves_settings_before_search_opens() {
    var o = make()
    key(o.c, ",", 0x2c)
    compare(o.c.activeView, "settings")
    var st = settingsPane(o)
    var seq = st.readSeq
    var log = []
    st.readSeqChanged.connect(function() { log.push("settings left after " + calls(o.svc, "searchPluginList").length + " plugin list reads") })
    o.c.showView("search")
    compare(o.c.activeView, "search")
    compare(log, ["settings left after 0 plugin list reads"], "Settings' closeView runs first")
    compare(calls(o.svc, "searchPluginList").length, 1, "then Search's openView loads the plugins")
    compare(calls(o.svc, "readPrefs").length, 1, "Settings isn't opened again")
    verify(st.readSeq > seq)
    verify(!st.open)
    verify(sp(o).open)
  }

  function test_5b0_showView_leaves_search_before_settings_opens() {
    var o = make()
    openSearch(o)
    var pane = sp(o)
    pane.column = "searchPlugins"
    var log = []
    pane.columnChanged.connect(function() { log.push("search left after " + calls(o.svc, "readPrefs").length + " preference reads") })
    var lists = calls(o.svc, "searchPluginList").length
    o.c.showView("settings")
    compare(o.c.activeView, "settings")
    compare(log, ["search left after 0 preference reads"], "Search's closeView runs first")
    compare(calls(o.svc, "readPrefs").length, 1, "then Settings' openView reads the preferences")
    compare(calls(o.svc, "searchPluginList").length, lists, "Search isn't opened again")
    compare(pane.column, "searchResults")
    verify(!pane.open)
  }

  function test_5b0_the_palette_in_search_judges_search_rows_with_its_flags() {
    var o = make()
    openSearch(o)
    key(o.c, ":", 0x3a)
    compare(paletteRow(o, "search.add").reason, "needs a result")
    compare(paletteRow(o, "search.copyLink").enabled, false)
    esc(o)
    compare(o.c.mode, "NORMAL")
    esc(o)
    streaming(o)
    key(o.c, ":", 0x3a)
    compare(paletteRow(o, "search.add").enabled, true)
    compare(paletteRow(o, "search.add").reason, "")
    compare(paletteRow(o, "search.copyLink").enabled, true)
    compare(paletteRow(o, "search.sort").enabled, true)
    compare(paletteRow(o, "plugin.toggle").reason, "open the plugins (P)")
    compare(paletteRow(o, "search.open").reason, "already open")
    compare(paletteRow(o, "settings.undo").reason, "open Settings")
    esc(o)
    key(o.c, "h")
    key(o.c, ":", 0x3a)
    compare(paletteRow(o, "search.add").reason, "focus the results", "judged from the Plugins column")
    esc(o)
    shifted(o, "P")
    compare(o.c.keyPane, "searchPluginList")
    key(o.c, ":", 0x3a)
    wait(30)
    compare(paletteRow(o, "plugin.toggle").enabled, true, "judged from the plugins overlay")
    esc(o)
  }

  function test_5b0_a_magnet_still_awaited_when_the_window_closes_is_never_reported() {
    var o = make()
    streaming(o)
    sp(o).addConfirmMs = 300
    enter(o)
    key(o.c, "y")
    finishCall(o, "searchAdd", true, "", { ok: true, via: "add" })
    o.c.close()
    o.c.open("")
    wait(1500)
    o.svc.torrents = o.svc.torrents.concat([tt(hh("c"), "late")])
    wait(1200)
    verify(statusText(o).indexOf("Added") === -1, statusText(o))
    verify(statusText(o).indexOf("Couldn't confirm") === -1, statusText(o))
  }

  function test_5b0_two_magnets_are_tracked_together_and_each_is_reported_once() {
    var o = make()
    streaming(o)
    sp(o).addConfirmMs = 400
    enter(o)
    key(o.c, "y")
    finishCall(o, "searchAdd", true, "", { ok: true, via: "add" })
    key(o.c, "j")
    enter(o)
    key(o.c, "y")
    finishCall(o, "searchAdd", true, "", { ok: true, via: "add" })
    o.svc.torrents = o.svc.torrents.concat([tt(hh("d"), "debian.iso")])
    compare(statusText(o), "Added debian.iso.")
    tryVerify(function() { return statusText(o) === "Couldn't confirm result c was added." }, 3000, statusText(o))
  }
}
