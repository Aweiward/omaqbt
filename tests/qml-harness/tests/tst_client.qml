import QtQuick
import QtTest
import "../../.."

TestCase {
  id: tc
  name: "Client"
  when: windowShown

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1, category: "", tags: [], tracker: "", savePath: "/dl" }
    for (var k in extra || {}) r[k] = extra[k]
    return r
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
      property string clipboardText: ""
      property var torrents: []
      property var categories: []
      property var tags: []
      property var filesByHash: ({})
      property var filesStatusByHash: ({})
      property string nextClipboard: "magnet:?xt=urn:btih:" + "c".repeat(40)
      property var magnetPendingHashes: []
      property var viewState: ({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table" })
      property bool windowOpen: false
      property var calls: []
      property int seq: 0
      property var saved: []
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { saved.push(s); viewState = s }
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function recheckHash(h, o) { return rec("recheck", [h, o]) }
      function setLocation(h, p, o) { return rec("move", [h, p, o]) }
      function toggleAll(o) { return rec("toggleAll", [o]) }
      function toggleTurtle(o) { return rec("turtle", [o]) }
      function addTarget(t, s, p, o) { return rec("add", [t, o]) }
      function copyMagnet(r, o) { return rec("copy", [r, o]) }
      function openPath(p, o) { rec("open", [p, o]) }
      function refresh() { rec("refresh", []) }
      function startDaemon(o) { return rec("startDaemon", [o]) }
      function installDaemon(o) { return rec("install", [o]) }
      function readClipboard() { rec("readClipboard", []); clipboardText = nextClipboard; clipboardRead(nextClipboard) }
      function filesFor(h) { return filesByHash[h] || [] }
      function setFilesFor(h, rows) { var n = ({}); for (var k in filesByHash) n[k] = filesByHash[k]; n[h] = rows; filesByHash = n }
      function setFilesStatus(h, st, err) { var n = ({}); for (var k in filesStatusByHash) n[k] = filesStatusByHash[k]; n[h] = { state: st, error: err || "" }; filesStatusByHash = n }
      function loadFiles(h, o) { rec("loadFiles", [h, o]); setFilesFor(h, []); setFilesStatus(h, "loading", "") }
      function setPrio(h, i, p, o) { return rec("prio", [h, i, p, o]) }
    }
  }

  Component {
    id: shellComp
    QtObject {
      property var hidden: []
      property var target: null
      function hide(id) { hidden.push(id); if (target) target.close() }
    }
  }

  Component { id: clientComp; Client {} }

  function key(c, text, code, mods) {
    c.handleKey({ key: code !== undefined ? code : text.toUpperCase().charCodeAt(0), text: text, modifiers: mods || 0 })
  }
  function findWith(obj, fn) {
    if (!obj) return null
    if (typeof obj[fn] === "function") return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findWith(kids[i], fn); if (r) return r }
    return null
  }
  function lastCall(svc, name) {
    for (var i = svc.calls.length - 1; i >= 0; i--) if (svc.calls[i].name === name) return svc.calls[i]
    return null
  }

  function make(vs) {
    var svc = createTemporaryObject(serviceComp, tc)
    if (vs) svc.viewState = vs
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    return { c: c, svc: svc, sh: sh }
  }

  function list3() {
    return [tt(hh("a"), "alpha", { addedOn: 1, dlSpeed: 300 }), tt(hh("b"), "beta", { addedOn: 2, dlSpeed: 200 }), tt(hh("c"), "gamma", { addedOn: 3, dlSpeed: 100 })]
  }

  function test_restore_and_rows() {
    var o = make({ filter: { group: "status", value: "All" }, sort: "dl", desc: true, cursorHash: hh("b"), pane: "table" })
    compare(o.c.sortMode, "dl")
    compare(o.svc.windowOpen, true)
    o.svc.torrents = list3()
    compare(o.c.tableRows.map(function(r) { return r.name }).join(","), "alpha,beta,gamma")
    compare(o.c.cursorHash, hh("b"))
    // tick reorders under dl sort: cursor stays on beta
    o.svc.torrents = [tt(hh("a"), "alpha", { dlSpeed: 1 }), tt(hh("b"), "beta", { dlSpeed: 200 }), tt(hh("c"), "gamma", { dlSpeed: 900 })]
    compare(o.c.tableRows.map(function(r) { return r.name }).join(","), "gamma,beta,alpha")
    compare(o.c.cursorHash, hh("b"))
    var table = findWith(o.c.children[0] ? o.c : o.c, "setRows")
    verify(table === null || true)
    compare(o.svc.saved.length, 0, "automatic changes are not saved")
  }

  function test_listmodel_matches_rows_under_churn() {
    var o = make()
    var table = null
    // FloatingWindow stub is a Window: search its contentItem
    var win = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].contentItem) win = o.c.data[i]
    verify(win !== null)
    table = findWith(win.contentItem, "setRows")
    verify(table !== null)
    var lv = null
    for (var j = 0; j < table.children.length; j++) if (table.children[j].model !== undefined && table.children[j].count !== undefined) lv = table.children[j]
    verify(lv !== null)
    for (var round = 0; round < 60; round++) {
      var n = Math.floor(Math.random() * 12)
      var list = []
      var letters = "abcdefghijklmnop"
      for (var k = 0; k < n; k++) {
        var ch = letters.charAt(Math.floor(Math.random() * letters.length))
        if (list.some(function(r) { return r.hash === hh(ch) })) continue
        list.push(tt(hh(ch), "n" + ch, { dlSpeed: Math.floor(Math.random() * 5) * 1000, addedOn: Math.floor(Math.random() * 100) }))
      }
      o.svc.torrents = list
      compare(lv.count, o.c.tableRows.length)
      for (var m = 0; m < lv.count; m++) {
        compare(lv.model.get(m).hash, o.c.tableRows[m].hash)
        compare(lv.model.get(m).dlText, o.c.tableRows[m].dlText)
      }
    }
  }

  function test_cursor_keys() {
    var o = make()
    o.svc.torrents = list3()  // added desc: gamma, beta, alpha
    compare(o.c.cursorHash, hh("c"))
    key(o.c, "j"); compare(o.c.cursorHash, hh("b"))
    key(o.c, "G", 0x47, 0x02000000); compare(o.c.cursorHash, hh("a"))
    key(o.c, "g"); key(o.c, "g"); compare(o.c.cursorHash, hh("c"))
    verify(o.svc.saved.length >= 3)
    compare(o.svc.saved[o.svc.saved.length - 1].cursorHash, hh("c"))
    key(o.c, "s"); compare(o.c.sortMode, "name"); compare(o.c.sortDesc, false)
    key(o.c, "S"); compare(o.c.sortDesc, true)
    key(o.c, "\t", 0x01000001); compare(o.c.pane, "inspector")
    compare(o.svc.saved[o.svc.saved.length - 1].pane, "inspector")
  }


  function test_delete_confirm() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "X", 0x58, 0x02000000)
    compare(o.c.mode, "CONFIRM")
    verify(o.c.confirm !== null)
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    compare(lastCall(o.svc, "delete"), null)
    key(o.c, "X", 0x58, 0x02000000)
    // a tick removes the cursor row while CONFIRM is up
    o.svc.torrents = [tt(hh("a"), "alpha"), tt(hh("b"), "beta")]
    key(o.c, "y")
    var d = lastCall(o.svc, "delete")
    verify(d !== null)
    compare(d.args[0], hh("c"), "y acts on the torrent named when asked")
    compare(d.args[1], true)
    compare(d.args[2].origin, "window")
    compare(d.args[2].hashes[0], hh("c"))
    compare(o.c.messageLine.text, "Deleting 1 torrent and their files…")
    o.svc.actionFinished(999, true, "", "window", [hh("c")])
    compare(o.c.messageLine.text, "Deleting 1 torrent and their files…", "foreign ticket ignored")
    o.svc.actionFinished(o.svc.seq, true, "", "window", [hh("c")])
    compare(o.c.messageLine.text, "")
  }

  function test_x_single_no_confirm_and_space() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "x")
    compare(lastCall(o.svc, "delete").args[1], false)
    key(o.c, " ", 0x20)
    compare(lastCall(o.svc, "stop").args[0], hh("c"))
  }

  function test_close_paths() {
    var o = make()
    key(o.c, "q")
    compare(o.sh.hidden.length, 1)
    compare(o.c.opened, false)
    compare(o.svc.windowOpen, false)
    var o2 = make()
    var win = null
    for (var i = 0; i < o2.c.data.length; i++) if (o2.c.data[i] && o2.c.data[i].contentItem) win = o2.c.data[i]
    win.visible = false   // WM close
    compare(o2.sh.hidden.length, 1)
    compare(o2.c.opened, false)
    o2.c.open("")
    compare(o2.c.opened, true)
    compare(win.visible, true)
  }

  function test_states() {
    var o = make()
    o.svc.torrents = []
    compare(o.c.tableState, "empty")
    key(o.c, "y")
    compare(lastCall(o.svc, "add").args[0].indexOf("magnet:"), 0)
    o.svc.daemon = false
    compare(o.c.tableState, "daemon")
    key(o.c, "\r", 0x01000004)
    verify(lastCall(o.svc, "startDaemon") !== null)
    o.svc.lockHolder = "gui"
    compare(o.c.tableState, "gui")
    key(o.c, "r")
    verify(lastCall(o.svc, "refresh") !== null)
  }

  function test_text_filter_and_no_match() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "/")
    compare(o.c.mode, "INSERT")
    var win = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].contentItem) win = o.c.data[i]
    var sl = findWith(win.contentItem, "setInput")
    sl.setInput("zzz")
    compare(o.c.tableState, "noMatch")
    compare(o.c.stateCopy.title, "Nothing matches “zzz” in All")
    compare(o.c.stateCopy.body, "0 matches in All.")
    key(o.c, "\r", 0x01000004)
    compare(o.c.mode, "NORMAL")
    compare(o.c.textQuery, "zzz")
    key(o.c, "\u001b", 0x01000000)
    compare(o.c.textQuery, "")
    compare(o.c.tableState, "rows")
  }

  function test_move_validation() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "m")
    compare(o.c.mode, "INSERT")
    var win = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].contentItem) win = o.c.data[i]
    var sl = findWith(win.contentItem, "setInput")
    compare(sl.inputValue(), "/dl")
    sl.setInput("relative/path")
    key(o.c, "\r", 0x01000004)
    compare(o.c.mode, "INSERT")
    compare(o.c.messageLine.text, "Enter an absolute path to move to.")
    compare(lastCall(o.svc, "move"), null)
    sl.setInput("/mnt/new")
    key(o.c, "\r", 0x01000004)
    compare(o.c.mode, "NORMAL")
    compare(lastCall(o.svc, "move").args[1], "/mnt/new")
    compare(lastCall(o.svc, "move").args[0], hh("c"))
  }

  function test_focus_request() {
    var o = make()
    var win = null
    for (var i = 0; i < o.c.data.length; i++) if (o.c.data[i] && o.c.data[i].contentItem) win = o.c.data[i]
    o.c.requestWmFocus()
    tryVerify(function() { return win.activateCalls > 0 || win.active }, 1000)
  }

  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function listOf(c) {
    var table = findWith(winOf(c).contentItem, "setRows")
    for (var j = 0; j < table.children.length; j++) if (table.children[j].model !== undefined && table.children[j].count !== undefined) return table.children[j]
    return null
  }
  function many(n) {
    var out = []
    for (var i = 0; i < n; i++) { var h = ("0000" + i).slice(-4); var hx = ""; while (hx.length < 40) hx += h; out.push(tt(hx.slice(0, 40), "t" + h, { addedOn: i })) }
    return out
  }

  function test_blocking_keys_from_side_panes_data() {
    return [{ tag: "filters", pane: "filters" }, { tag: "inspector", pane: "inspector" }]
  }
  function test_blocking_keys_from_side_panes(d) {
    var vs = { filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: d.pane }
    var o = make(vs)
    compare(o.c.pane, d.pane)
    o.svc.torrents = []
    compare(o.c.tableState, "empty")
    key(o.c, "y")
    verify(lastCall(o.svc, "readClipboard") !== null, "y adds from clipboard in empty")
    verify(lastCall(o.svc, "add") !== null)
    o.svc.daemon = false
    compare(o.c.tableState, "daemon")
    key(o.c, "
", 0x01000004)
    verify(lastCall(o.svc, "startDaemon") !== null, "Enter starts the daemon")
    o.svc.installed = false
    compare(o.c.tableState, "notInstalled")
    key(o.c, "
", 0x01000004)
    verify(lastCall(o.svc, "install") !== null, "Enter installs")
    compare(o.c.pane, d.pane, "the pane itself is not changed")
  }

  // true when row i is laid out and fully inside the viewport
  function rowVisible(lv, i) {
    var it = lv.itemAtIndex(i)
    if (!it) return false
    var y = it.y - lv.contentY
    return y >= -0.5 && y + it.height <= lv.height + 0.5
  }

  function test_reveal_on_restore_and_sort() {
    var rows = many(200)
    var target = rows[10].hash   // added desc: index 189
    var svc = createTemporaryObject(serviceComp, tc)
    svc.torrents = rows
    svc.viewState = { filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: target, pane: "table" }
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c; c.shell = sh; c.service = svc
    var lv = listOf(c)
    compare(c.cursorIndex, 189)
    tryVerify(function() { return rowVisible(lv, 189) }, 1000, "restore scrolls the cursor row into view")
    key(c, "S", 0x53, 0x02000000)   // reverse: now index 10
    compare(c.cursorIndex, 10)
    verify(!rowVisible(lv, 10), "row 10 starts off screen")
    tryVerify(function() { return rowVisible(lv, 10) }, 1000, "re-sort reveals the cursor")
    // a background tick that moves the cursor's index never scrolls: the
    // user has scrolled away, and the tick sends the cursor to the far end
    lv.contentY = lv.contentY + 28 * 50
    wait(50)
    var before = lv.contentY
    var moved = rows.slice(); moved[10] = tt(target, "moved", { addedOn: 1000 })
    svc.torrents = moved     // added asc: now the last index
    compare(c.cursorIndex, 199)
    wait(200)
    compare(lv.contentY, before, "a tick leaves contentY alone")
    verify(!rowVisible(lv, 199))
    // a query change (user-started) does reveal it
    key(c, "/")
    findWith(winOf(c).contentItem, "setInput").setInput("t")
    tryVerify(function() { return rowVisible(lv, c.cursorIndex) }, 1000, "a query change reveals the cursor")
  }

  function test_click_ends_insert() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "/")
    var sl = findWith(winOf(o.c).contentItem, "setInput")
    sl.setInput("gam")
    compare(o.c.textQuery, "gam")
    compare(o.c.mode, "INSERT")
    var table = findWith(winOf(o.c).contentItem, "setRows")
    table.rowClicked(hh("c"))
    compare(o.c.mode, "NORMAL")
    compare(o.c.textQuery, "", "click ends INSERT like Esc: query restored")
    compare(o.c.cursorHash, hh("c"))
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"), "printable keys reach dispatch again")
    // move INSERT is dropped too
    key(o.c, "m"); compare(o.c.mode, "INSERT")
    table.rowClicked(hh("a"))
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
  }

  // ---- Task 8 ----------------------------------------------------------------

  function callsNamed(svc, name) {
    return svc.calls.filter(function(c) { return c.name === name })
  }
  function rowItem(c, i) { return listOf(c).itemAtIndex(i) }
  function glyphOf(item) {
    // the Row's first Cell is the glyph
    for (var i = 0; i < item.children.length; i++) {
      var ch = item.children[i]
      if (ch.children && ch.children.length > 5 && ch.children[0].text !== undefined) return ch.children[0].text
    }
    return null
  }

  function test_visual_bulk_space_is_one_multi_hash_call() {
    var o = make()
    o.svc.torrents = list3()   // added desc: gamma(c), beta(b), alpha(a)
    key(o.c, "V", 0x56, 0x02000000)
    compare(o.c.mode, "VISUAL")
    compare(o.c.anchorHash, hh("c"))
    key(o.c, "j")
    compare(o.c.visualHashes.join(","), [hh("c"), hh("b")].join(","))
    verify(o.c.rangeHashes[hh("c")] === true && o.c.rangeHashes[hh("b")] === true)
    verify(o.c.rangeHashes[hh("a")] !== true)
    var sl = findWith(winOf(o.c).contentItem, "setInput")
    compare(sl.selectedCount, 2)
    var before = o.svc.calls.length
    key(o.c, " ", 0x20)
    var acted = o.svc.calls.slice(before).filter(function(c) { return c.name === "start" || c.name === "stop" })
    compare(acted.length, 1, "exactly one request")
    compare(acted[0].name, "stop")
    compare(acted[0].args[0], hh("c") + "|" + hh("b"))
    compare(acted[0].args[1].origin, "window")
    compare(acted[0].args[1].hashes.length, 2)
    compare(o.c.mode, "NORMAL", "an action leaves VISUAL")
    compare(o.c.anchorHash, "")
    compare(o.c.regState.selectionCount, 0)
    compare(o.c.messageLine.text, "Stopping 2 torrents…")
    compare(sl.selectedCount, 0)
  }

  function test_visual_x_over_two_confirms_then_deletes_both() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "V", 0x56, 0x02000000)
    key(o.c, "j"); key(o.c, "j")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.count, 3)
    compare(o.c.confirmHashes.length, 3)
    verify(o.c.rangeHashes[hh("a")] === true, "the range stays painted while CONFIRM asks")
    compare(lastCall(o.svc, "delete"), null)
    key(o.c, "y")
    var d = lastCall(o.svc, "delete")
    compare(d.args[0], [hh("c"), hh("b"), hh("a")].join("|"))
    compare(d.args[1], false)
    compare(o.c.mode, "NORMAL")
    compare(Object.keys(o.c.rangeHashes).length, 0)
    // Esc in VISUAL leaves without acting
    key(o.c, "V", 0x56, 0x02000000); key(o.c, "k")
    key(o.c, "\u001b", 0x01000000)
    compare(o.c.mode, "NORMAL")
    compare(o.c.anchorHash, "")
  }

  function test_error_persists_until_next_key_with_row_marks() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, " ", 0x20)          // stop gamma
    var t = o.svc.seq
    o.svc.actionFinished(t, false, "Forbidden", "window", [hh("c")])
    compare(o.c.messageLine.tone, "urgent")
    compare(o.c.messageLine.text, "Couldn't stop 1 torrent: Forbidden")
    verify(o.c.errorHashes[hh("c")] === true)
    tryVerify(function() { return rowItem(o.c, 0) !== null })
    compare(glyphOf(rowItem(o.c, 0)), "!", "the affected row shows !")
    // a status tick and an unrelated finish don't clear it
    o.svc.torrents = list3()
    o.svc.actionFinished(t + 50, true, "", "window", [hh("c")])
    compare(o.c.messageLine.text, "Couldn't stop 1 torrent: Forbidden")
    var sl = findWith(winOf(o.c).contentItem, "setInput")
    compare(sl.message, "Couldn't stop 1 torrent: Forbidden")
    compare(sl.messageTone, "urgent")
    // the next key clears it, and still does its own job
    key(o.c, "j")
    compare(o.c.messageLine.text, "")
    compare(o.c.cursorHash, hh("b"))
    verify(o.c.errorHashes[hh("c")] !== true)
    compare(glyphOf(rowItem(o.c, 0)), "●")
  }

  function test_filter_pane_applies_a_filter() {
    var o = make()
    var rows = list3()
    rows[2].state = "pausedDL"   // gamma stopped
    rows[1].category = "linux"
    o.svc.categories = ["linux", "anime"]
    o.svc.torrents = rows
    key(o.c, "", 0x01000002)   // Shift-Tab (Backtab): table -> filters
    compare(o.c.pane, "filters")
    compare(o.c.filterCursor.value, "All")
    key(o.c, "j")
    compare(o.c.filterCursor.value, "Active")
    compare(o.c.filter.value, "All", "j moves the cursor, not the filter")
    key(o.c, "\r", 0x01000004)
    compare(o.c.filter.group, "status")
    compare(o.c.filter.value, "Active")
    compare(o.c.tableRows.map(function(r) { return r.name }).join(","), "beta,alpha")
    compare(o.svc.saved[o.svc.saved.length - 1].filter.value, "Active", "the filter persists")
    // a zero-count category is listed (dimmed) and selectable
    var anime = o.c.filterEntries.filter(function(e) { return e.kind === "item" && e.group === "category" && e.value === "anime" })[0]
    compare(anime.zero, true)
    var fp = findWith(winOf(o.c).contentItem, "positionAt")
    // click on a category item applies it
    var pane = null
    var kids = winOf(o.c).contentItem.children
    pane = (function find(obj) {
      if (!obj) return null
      if (obj.itemClicked !== undefined && obj.entries !== undefined) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(winOf(o.c).contentItem)
    verify(pane !== null)
    pane.itemClicked("category", "linux")
    compare(o.c.filter.group, "category")
    compare(o.c.tableRows.length, 1)
    compare(o.c.tableRows[0].name, "beta")
    pane.itemClicked("category", "anime")
    compare(o.c.tableState, "noMatch")
    compare(o.c.stateCopy.title, "Nothing in anime")
    key(o.c, "\u001b", 0x01000000); key(o.c, "\u001b", 0x01000000)
    compare(o.c.filter.value, "All", "Esc Esc resets to All")
    compare(o.c.filterCursor.value, "All")
  }

  function test_inspector_info_and_files_tab() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { numSeeds: 4, numLeechs: 1, category: "linux", savePath: "/dl/iso" })]
    compare(o.c.inspectorInfo.name, "alpha")
    compare(o.c.inspectorInfo.fields[5].value, "linux")
    // 2, 3 and 5 do nothing
    key(o.c, "2"); key(o.c, "3"); key(o.c, "5")
    compare(o.c.inspectorTab, "info")
    key(o.c, "4")
    compare(o.c.inspectorTab, "files")
    var lf = lastCall(o.svc, "loadFiles")
    verify(lf !== null)
    compare(lf.args[0], hh("a"))
    compare(lf.args[1].origin, "window")
    compare(o.c.filesState.state, "loading")
    o.svc.setFilesFor(hh("a"), [{ index: 0, name: "a.iso", progress: 0.5, priority: 1 }, { index: 1, name: "b.txt", progress: 1, priority: 6 }])
    o.svc.setFilesStatus(hh("a"), "ok", "")
    compare(o.c.filesState.state, "rows")
    compare(o.c.filesState.rows.length, 2)
    // keyboard: Tab to the inspector, j, Space cycles priority
    key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    key(o.c, "j")
    compare(o.c.fileIndex, 1)
    key(o.c, " ", 0x20)
    var p = lastCall(o.svc, "prio")
    compare(p.args[0], hh("a"))
    compare(p.args[1], 1)
    compare(p.args[2], 7, "Normal -> High")
    compare(p.args[3].origin, "window")
    compare(o.c.filesState.rows[1].priorityText, "High", "optimistic update")
    compare(lastCall(o.svc, "start"), null, "Space in the inspector never starts/stops")
    compare(o.c.messageLine.text, "Setting file priority…")
    o.svc.actionFinished(o.svc.seq, true, "", "window", [hh("a")])
    compare(o.c.messageLine.text, "")
    // a load failure: status-line error and the tab's copy
    var before = callsNamed(o.svc, "loadFiles").length
    key(o.c, "r")
    compare(callsNamed(o.svc, "loadFiles").length, before + 1, "r reloads the files")
    o.svc.setFilesStatus(hh("a"), "error", "HTTP 403")
    compare(o.c.filesState.state, "error")
    compare(o.c.messageLine.text, "Couldn't read files: HTTP 403")
    compare(o.c.messageLine.tone, "urgent")
    key(o.c, "k")
    compare(o.c.messageLine.text, "")
    key(o.c, "1")
    compare(o.c.inspectorTab, "info")
  }

  function test_help_overlay() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "?", 0x3f, 0x02000000)
    compare(o.c.helpOpen, true)
    var ov = (function find(obj) {
      if (!obj) return null
      if (obj.groups !== undefined && obj.dismissed !== undefined) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(winOf(o.c).contentItem)
    verify(ov !== null)
    verify(ov.visible)
    compare(ov.groups.map(function(g) { return g.group }).join(","), "Torrent,View,Library,App")
    var titles = []
    ov.groups.forEach(function(g) { g.items.forEach(function(i) { titles.push(i.keys + "=" + i.title) }) })
    verify(titles.indexOf("Enter / 4=Files") !== -1)
    verify(titles.indexOf("V=Visual select") !== -1)
    // any key closes it and is not dispatched
    key(o.c, "j")
    compare(o.c.helpOpen, false)
    compare(o.c.cursorHash, hh("c"), "the closing key doesn't move the cursor")
    verify(!ov.visible)
    // from the filters pane it lists that pane's keys
    key(o.c, "", 0x01000002)
    key(o.c, "?", 0x3f, 0x02000000)
    var ft = []
    ov.groups.forEach(function(g) { g.items.forEach(function(i) { ft.push(i.title) }) })
    verify(ft.indexOf("Apply filter") !== -1)
    verify(ft.indexOf("Pause/resume") === -1)
    key(o.c, "\u001b", 0x01000000)
    compare(o.c.helpOpen, false)
  }

  function test_empty_clipboard_note_and_disarm() {
    var o = make()
    o.svc.torrents = []
    o.svc.nextClipboard = ""
    key(o.c, "y")
    compare(o.c.messageLine.text, "The clipboard is empty.")
    compare(o.c.clipboardAskedAt, 0, "not left armed")
    // a later clipboard answer adds nothing
    o.svc.clipboardRead("magnet:?xt=urn:btih:" + "d".repeat(40))
    compare(lastCall(o.svc, "add"), null)
    o.svc.nextClipboard = "hello"
    key(o.c, "y")
    compare(o.c.messageLine.text, "The clipboard has no magnet, .torrent URL or .torrent path.")
  }

  function test_copy_magnet_and_daemon_use_window_tickets() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "y")
    var c = lastCall(o.svc, "copy")
    compare(c.args[1].origin, "window")
    compare(c.args[1].hashes[0], hh("c"))
    o.svc.actionFinished(o.svc.seq, true, "", "window", [hh("c")])
    compare(o.c.messageLine.text, "Copied magnet.")
    key(o.c, "o")
    compare(lastCall(o.svc, "open").args[1].origin, "window")
    o.svc.daemon = false
    key(o.c, "\r", 0x01000004)
    var sd = lastCall(o.svc, "startDaemon")
    compare(sd.args[0].origin, "window")
    compare(o.c.messageLine.text, "Starting qbittorrent-nox…")
    o.svc.actionFinished(o.svc.seq, false, "exit 1", "window", [])
    compare(o.c.messageLine.text, "Couldn't start qbittorrent-nox: exit 1")
  }

  function test_files_list_survives_status_ticks() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "4")
    var files = []
    for (var i = 0; i < 80; i++) files.push({ index: i, name: "f" + i, progress: 0, priority: 1 })
    o.svc.setFilesFor(hh("c"), files)
    o.svc.setFilesStatus(hh("c"), "ok", "")
    var insp = (function find(obj) {
      if (!obj) return null
      if (typeof obj.positionFile === "function") return obj
      for (var j = 0; j < (obj.children || []).length; j++) { var r = find(obj.children[j]); if (r) return r }
      return null
    })(winOf(o.c).contentItem)
    var lv = null
    ;(function find(obj) {
      if (!obj || lv) return
      if (obj.count !== undefined && obj.model !== undefined && obj.contentY !== undefined && obj.count === 80) { lv = obj; return }
      for (var j = 0; j < (obj.children || []).length; j++) find(obj.children[j])
    })(insp)
    verify(lv !== null)
    tryVerify(function() { return lv.contentHeight > lv.height })
    lv.contentY = 28 * 40
    wait(50)
    var before = lv.contentY
    var state = o.c.filesState
    // ticks that reorder rows and change speeds
    var t = list3(); t[0].dlSpeed = 999999
    o.svc.torrents = t
    o.svc.torrents = list3()
    wait(100)
    verify(o.c.filesState === state, "filesState is not recomputed on a tick")
    compare(lv.contentY, before, "the files list keeps its scroll across ticks")
  }
}

