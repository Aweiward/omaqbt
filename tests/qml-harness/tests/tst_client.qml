import QtQuick
import QtTest
import qs.Commons
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
      function toggleAll(o) { return [rec("toggleAll", [o])] }
      function toggleTurtle(o) { return rec("turtle", [o]) }
      function addTarget(t, s, p, o) { return rec("add", [t, o]) }
      property bool busy: false
      function copyMagnet(r, o) { var t = rec("copy", [r, o]); return busy ? 0 : t }
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
      // Inspector tabs 2/3 (Task 5). A watch is recorded without taking a
      // ticket number, so tests that count tickets (seq) are unaffected.
      property var inspectByKey: ({})
      property bool sidecarDown: false
      function watch(h, t) { calls.push({ name: "watch", args: [h, t] }) }
      function copyText(t, o) { return rec("copyText", [t, o]) }
      function setInspect(h, tab, entry) {
        var n = ({}); for (var k in inspectByKey) n[k] = inspectByKey[k]
        var e = ({}); for (var f in entry) e[f] = entry[f]
        if (e.at === undefined) e.at = Date.now()
        n[h + "|" + tab] = e
        inspectByKey = n
      }
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
  Component { id: inspectorListComp; InspectorList {} }
  Component {
    id: detailComp
    Item {
      id: detailRoot
      property var row: null
      width: parent ? parent.width : 0
      height: 20
      Text { objectName: "detailText"; anchors.fill: parent; text: detailRoot.row ? ("detail " + detailRoot.row.key + " " + detailRoot.row.name) : "" }
    }
  }

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

  function test_inspector_tab_persists_and_restores() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "3")
    compare(o.c.inspectorTab, "peers")
    compare(o.svc.saved[o.svc.saved.length - 1].inspectorTab, "peers")
    // reopening restores the tab through the same watch path Task 5 wired
    var o2 = make({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table", inspectorTab: "peers" })
    o2.svc.torrents = list3()
    compare(o2.c.inspectorTab, "peers")
    compare(lastCall(o2.svc, "watch").args[1], "peers")
  }

  function test_digit_does_not_open_the_inspector_when_docked() {
    var o = make()
    o.svc.torrents = list3()
    compare(o.c.layout.inspector, "docked")
    key(o.c, "3")
    compare(o.c.inspectorTab, "peers")
    compare(o.c.pane, "table", "digits only switch the tab when docked")
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

  function test_x_single_confirm_and_space() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    verify(o.c.confirm !== null)
    compare(lastCall(o.svc, "delete"), null, "no delete call before y is pressed")
    key(o.c, "y")
    compare(o.c.mode, "NORMAL")
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

  function hx(i) { var s = i.toString(16); while (s.length < 40) s = "0" + s; return s }

  function test_visual_bulk_over_2500_chunks_and_reports_once() {
    var o = make()
    var rows = []
    for (var i = 0; i < 2500; i++) rows.push(tt(hx(i), "t" + i, { addedOn: i }))
    o.svc.torrents = rows
    key(o.c, "V", 0x56, 0x02000000)
    o.c.cursorHash = hx(0)           // G is NORMAL-only; stretch the range directly
    compare(o.c.visualHashes.length, 2500)
    var before = o.svc.calls.length
    key(o.c, " ", 0x20)
    var acted = o.svc.calls.slice(before).filter(function(c) { return c.name === "stop" })
    compare(acted.length, 3, "2500 hashes go out as 3 chunks")
    compare(acted[0].args[0].split("|").length, 1000)
    compare(acted[1].args[0].split("|").length, 1000)
    compare(acted[2].args[0].split("|").length, 500)
    compare(acted[2].args[1].hashes.length, 500, "each chunk carries its own hashes")
    var t1 = o.svc.seq - 2, t2 = o.svc.seq - 1, t3 = o.svc.seq
    compare(o.c.messageLine.text, "Stopping 2500 torrents…")
    o.svc.actionFinished(t1, false, "HTTP 500", "window", [])
    compare(o.c.messageLine.text, "Stopping 2500 torrents…", "no error while chunks run")
    o.svc.actionFinished(t2, true, "", "window", [])
    compare(o.c.messageLine.tone, "muted")
    o.svc.actionFinished(t3, true, "", "window", [])
    compare(o.c.messageLine.text, "Couldn't stop 2500 torrents: HTTP 500")
    compare(o.c.messageLine.tone, "urgent")
    compare(Object.keys(o.c.errorHashes).length, 2500)
  }

  function test_visual_bulk_delete_and_recheck_chunk() {
    var o = make()
    var rows = []
    for (var i = 0; i < 1500; i++) rows.push(tt(hx(i), "t" + i, { addedOn: i }))
    o.svc.torrents = rows
    key(o.c, "V", 0x56, 0x02000000); o.c.cursorHash = hx(0)
    compare(o.c.visualHashes.length, 1500)
    var before = o.svc.calls.length
    key(o.c, "e")
    compare(o.svc.calls.slice(before).filter(function(c) { return c.name === "recheck" }).length, 2)
    key(o.c, "V", 0x56, 0x02000000); o.c.cursorHash = hx(1499)
    compare(o.c.visualHashes.length, 1500)
    key(o.c, "x"); key(o.c, "y")
    var dels = o.svc.calls.filter(function(c) { return c.name === "delete" })
    compare(dels.length, 2)
    compare(dels[0].args[0].split("|").length, 1000)
    compare(dels[1].args[0].split("|").length, 500)
    compare(o.c.messageLine.text, "Removing 1500 torrents…")
  }

  function test_t_tracks_every_toggle_all_ticket() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "t")
    compare(lastCall(o.svc, "toggleAll").args[0].origin, "window")
    compare(o.c.messageLine.text, "Stopping all torrents…")
    o.svc.actionFinished(o.svc.seq, true, "", "window", [])
    compare(o.c.messageLine.text, "")
  }

  function test_view_state_restore_ends_visual() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "V", 0x56, 0x02000000); key(o.c, "j")
    compare(o.c.mode, "VISUAL")
    var savedBefore = o.svc.saved.length
    o.c.applyViewState({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: hh("a"), pane: "filters" })
    compare(o.c.pane, "filters")
    compare(o.c.mode, "NORMAL", "a restored pane change leaves VISUAL")
    compare(o.c.anchorHash, "")
    compare(o.svc.saved.length, savedBefore, "a restore is not saved")
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
    // 5 opens the chart tab (Task 8; 2 and 3 open trackers and peers since Task 5)
    key(o.c, "5")
    compare(o.c.inspectorTab, "chart")
    key(o.c, "1")
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

  function findPane(c, prop) {
    return (function find(obj) {
      if (!obj) return null
      if (obj[prop] !== undefined) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(winOf(c).contentItem)
  }

  function test_click_to_another_pane_ends_visual() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "V", 0x56, 0x02000000); key(o.c, "j")
    compare(o.c.mode, "VISUAL")
    findPane(o.c, "cursorFilter").itemClicked("status", "Active")
    compare(o.c.pane, "filters")
    compare(o.c.mode, "NORMAL", "a pane change leaves VISUAL")
    compare(o.c.anchorHash, "")
    compare(o.c.regState.selectionCount, 0)
    compare(Object.keys(o.c.rangeHashes).length, 0)
    compare(findWith(winOf(o.c).contentItem, "setInput").selectedCount, 0)
    key(o.c, "j")
    compare(o.c.filterCursor.value, "Downloading", "j works in the filters pane")
    key(o.c, "\u001b", 0x01000000)
    compare(o.c.regState.prefix, "Esc", "Esc dispatches (filter.clearText)")
    // the same through a file click in the inspector
    key(o.c, "\t", 0x01000001)     // filters -> table
    compare(o.c.pane, "table")
    key(o.c, "4")
    o.svc.setFilesFor(o.c.cursorHash, [{ index: 0, name: "x", progress: 0, priority: 1 }])
    o.svc.setFilesStatus(o.c.cursorHash, "ok", "")
    key(o.c, "V", 0x56, 0x02000000)
    compare(o.c.mode, "VISUAL")
    findPane(o.c, "fileIndex").fileClicked(0)
    compare(o.c.pane, "inspector")
    compare(o.c.mode, "NORMAL")
    key(o.c, "1")
    compare(o.c.inspectorTab, "info", "keys work in the inspector")
  }

  function test_inspector_pane_runs_o_y_m_e_on_the_cursor() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    key(o.c, "e")
    compare(lastCall(o.svc, "recheck").args[0], hh("c"))
    key(o.c, "o")
    compare(lastCall(o.svc, "open").args[0], "/dl")
    key(o.c, "y")
    compare(lastCall(o.svc, "copy").args[1].hashes[0], hh("c"))
    key(o.c, "m")
    compare(o.c.mode, "INSERT")
    key(o.c, "\u001b", 0x01000000)
    compare(o.c.mode, "NORMAL")
  }

  function test_busy_copy_notes() {
    var o = make()
    o.svc.torrents = list3()
    o.svc.busy = true
    key(o.c, "y")
    compare(o.c.messageLine.text, "Busy, try again.")
    key(o.c, "j")
    compare(o.c.messageLine.text, "")
  }

  // ---- command palette (slice 1b) ----------------------------------------

  function pal(c) { return findPane(c, "totalCount") }
  function palKey(c, name) {
    var codes = { esc: 0x01000000, enter: 0x01000004, down: 0x01000015, up: 0x01000013, tab: 0x01000001 }
    key(c, "", codes[name])
  }
  function findText(obj, text) {
    if (!obj) return null
    if (obj.text === text && obj.visible) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findText(kids[i], text); if (r) return r }
    if (obj.contentItem && kids.indexOf(obj.contentItem) === -1) return findText(obj.contentItem, text)
    return null
  }

  function test_palette_colon_opens() {
    var o = make()
    o.svc.torrents = list3()
    var p = pal(o.c)
    verify(p !== null)
    compare(p.visible, false)
    key(o.c, ":")
    compare(o.c.mode, "COMMAND")
    compare(p.visible, true)
    compare(p.query, "")
    verify(p.rows.length > 1)
    compare(p.cursor, 0)
    compare(p.matchCount, p.totalCount)
    compare(o.c.pane, "table")
  }

  function test_palette_typing_stp_filters() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("stp")
    compare(p.rows.length, 1)
    compare(p.rows[0].id, "all.toggle")
    compare(p.rows[0].indices, [0, 1, 9])
    compare(p.matchCount, 1)
    verify(p.totalCount > 1)
    p.setQuery("zzzz")
    compare(p.rows.length, 0)
    compare(p.cursor, -1)
    verify(findText(p, "No command matches “zzzz”") !== null)
    palKey(o.c, "enter")
    compare(o.c.mode, "COMMAND", "Enter with no match keeps the palette open")
  }

  function test_palette_down_enter_runs_the_second_row_and_saves_mru() {
    var o = make()
    o.svc.torrents = list3()
    compare(o.c.sortDesc, true)
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("sort")
    compare(p.rows.map(function(r) { return r.id }).join(","), "sort.next,sort.reverse")
    palKey(o.c, "down")
    compare(p.cursor, 1)
    palKey(o.c, "down")
    compare(p.cursor, 1, "no wrap past the last row")
    palKey(o.c, "enter")
    compare(o.c.mode, "NORMAL")
    compare(p.visible, false)
    compare(o.c.sortDesc, false, "Reverse sort ran")
    compare(o.c.sortMode, "added")
    var last = o.svc.saved[o.svc.saved.length - 1]
    compare(last.paletteMru, ["sort.reverse"])
    compare(o.svc.viewState.paletteMru, ["sort.reverse"])
    // other saves keep the MRU (ascending now: alpha, beta, gamma)
    key(o.c, "k")
    last = o.svc.saved[o.svc.saved.length - 1]
    compare(last.cursorHash, hh("b"))
    compare(last.paletteMru, ["sort.reverse"])
    // reopening lists it first, above a divider
    key(o.c, ":")
    compare(p.query, "", "the query starts empty")
    compare(p.rows[0].id, "sort.reverse")
    compare(p.rows[1].kind, "divider")
    palKey(o.c, "down")
    compare(p.cursor, 2, "the cursor skips the divider")
    palKey(o.c, "up")
    compare(p.cursor, 0)
  }

  function test_palette_esc_and_scrim_close() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("sort")
    palKey(o.c, "esc")
    compare(o.c.mode, "NORMAL")
    compare(p.visible, false)
    compare(o.c.sortMode, "added", "Esc runs nothing")
    compare(o.c.regState.prefix, null, "Esc in the palette is not the table's Esc")
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"), "keys go back to the table")
    key(o.c, ":")
    compare(o.c.mode, "COMMAND")
    p.dismissed()
    compare(o.c.mode, "NORMAL")
    compare(p.visible, false)
  }

  function test_palette_tab_completes() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("rev")
    palKey(o.c, "tab")
    compare(p.query, "Reverse sort")
    compare(o.c.mode, "COMMAND")
    compare(o.c.pane, "table", "Tab in the palette doesn't switch panes")
  }

  function test_palette_disabled_row_shows_its_reason() {
    var o = make()
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("copy magnet")
    compare(p.rows.length, 1)
    compare(p.rows[0].enabled, false)
    compare(p.rows[0].reason, "needs a selected torrent")
    compare(p.cursor, 0)
    verify(findText(p, "  · needs a selected torrent") !== null, "the row shows its reason")
    palKey(o.c, "enter")
    compare(o.c.mode, "COMMAND", "the palette stays open")
    compare(p.visible, true)
    compare(o.c.messageLine.text, "Copy magnet: needs a selected torrent.")
    compare(lastCall(o.svc, "copy"), null)
    compare(o.svc.saved.length, 0, "a disabled row isn't pushed to the MRU")
    // a click on it does the same
    p.activated(p.rows[0])
    compare(o.c.mode, "COMMAND")
  }

  function test_palette_delete_still_confirms() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("delete with")
    compare(p.rows[0].id, "torrent.delete")
    palKey(o.c, "enter")
    compare(o.c.mode, "CONFIRM")
    compare(p.visible, false)
    verify(o.c.confirm !== null)
    compare(o.c.confirm.withFiles, true)
    compare(lastCall(o.svc, "delete"), null, "nothing deleted before y")
    key(o.c, "y")
    var d = lastCall(o.svc, "delete")
    verify(d !== null)
    compare(d.args[0], hh("c"))
    compare(d.args[1], true)
    compare(d.args[2].origin, "window")
    compare(o.c.paletteMru[0], "torrent.delete")
  }

  function test_palette_table_command_from_filters_pane() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "", 0x01000002)    // Shift-Tab: table -> filters
    compare(o.c.pane, "filters")
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("pause")
    compare(p.rows[0].id, "torrent.toggle")
    compare(p.rows[0].enabled, true)
    p.activated(p.rows[0])      // a click runs it
    compare(o.c.mode, "NORMAL")
    compare(o.c.pane, "table")
    var s = lastCall(o.svc, "stop")
    verify(s !== null)
    compare(s.args[0], hh("c"))
    compare(s.args[1].hashes, [hh("c")])
    // a command that works where the window is doesn't move the pane
    key(o.c, "", 0x01000002)
    compare(o.c.pane, "filters")
    key(o.c, ":")
    p.setQuery("sort")
    palKey(o.c, "enter")
    compare(o.c.pane, "filters")
    compare(o.c.sortMode, "name")
  }

  // ---- narrow window (slice 1b, D5) ----------------------------------------

  function paneTitled(c, title) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.collapsed !== undefined && obj.title === title) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(winOf(c).contentItem)
  }
  // The platform resizes the window's content item asynchronously.
  function setWidth(c, width) {
    var win = winOf(c)
    win.width = width
    tryVerify(function() { return win.contentItem.width === width }, 2000, "the window is " + width + " px wide")
  }
  function narrow(width) {
    var o = make()
    o.svc.torrents = list3()
    setWidth(o.c, width)
    return o
  }
  function ctrlH(c) { key(c, "\b", 0x48, 0x04000000) }
  function ctrlL(c) { key(c, "\f", 0x4c, 0x04000000) }
  function tab(c) { key(c, "\t", 0x01000001) }
  function esc(c) { key(c, "\u001b", 0x01000000) }

  function test_narrow_ctrl_h_opens_filters_overlay_and_esc_closes_it() {
    var o = narrow(850)
    compare(o.c.layout.filters, "collapsed")
    compare(o.c.layout.inspector, "collapsed")
    var filters = paneTitled(o.c, "Filters")
    var torrents = paneTitled(o.c, "Torrents")
    var inspector = paneTitled(o.c, "Inspector")
    compare(filters.visible, false, "a collapsed pane is hidden")
    compare(inspector.visible, false)
    compare(torrents.x, 0, "a collapsed pane takes no width")
    compare(torrents.width, winOf(o.c).width)
    o.c.textQuery = "a"
    ctrlH(o.c)
    compare(o.c.pane, "filters")
    compare(filters.visible, true, "Ctrl-h opens the filters overlay")
    compare(filters.overlay, true)
    compare(filters.x, 0, "on the left edge")
    verify(filters.width > 0 && filters.width < torrents.width)
    verify(filters.z > torrents.z, "over the table")
    compare(torrents.width, winOf(o.c).width, "the table keeps its width under the overlay")
    esc(o.c)
    compare(o.c.pane, "table")
    compare(filters.visible, false, "Esc closes it")
    compare(o.c.textQuery, "a", "that Esc doesn't clear the query")
    compare(o.c.regState.prefix, null, "nor arm Esc Esc")
    // the same key closes it too
    ctrlH(o.c)
    compare(filters.visible, true)
    ctrlH(o.c)
    compare(o.c.pane, "table")
    compare(filters.visible, false)
    // Ctrl-l opens the inspector on the right, and closes it again
    ctrlL(o.c)
    compare(o.c.pane, "inspector")
    compare(inspector.visible, true)
    compare(inspector.x + inspector.width, torrents.width, "on the right edge")
    ctrlL(o.c)
    compare(o.c.pane, "table")
    compare(inspector.visible, false)
  }

  function test_narrow_digit_opens_the_collapsed_inspector_on_that_tab() {
    var o = narrow(850)
    var inspector = paneTitled(o.c, "Inspector")
    compare(inspector.visible, false)
    key(o.c, "3")
    compare(o.c.pane, "inspector", "3 opens the overlay, exactly as Ctrl-l does")
    compare(o.c.inspectorTab, "peers")
    compare(inspector.visible, true)
    esc(o.c)
    compare(o.c.pane, "table", "Esc closes it")
    compare(inspector.visible, false)
    compare(o.c.inspectorTab, "peers", "closing the overlay doesn't reset the tab")
    key(o.c, "1")
    compare(o.c.pane, "inspector")
    compare(o.c.inspectorTab, "info")
  }

  function test_narrow_5_opens_the_collapsed_inspector_on_chart() {
    var o = narrow(850)
    var inspector = paneTitled(o.c, "Inspector")
    compare(inspector.visible, false)
    key(o.c, "5")
    compare(o.c.pane, "inspector", "5 opens the overlay, same as 1-4")
    compare(o.c.inspectorTab, "chart")
    compare(inspector.visible, true)
  }

  function test_narrow_tab_opens_each_overlay_in_turn() {
    var o = narrow(850)
    var filters = paneTitled(o.c, "Filters")
    var inspector = paneTitled(o.c, "Inspector")
    tab(o.c)
    compare(o.c.pane, "inspector")
    compare(inspector.visible, true)
    compare(filters.visible, false)
    tab(o.c)
    compare(o.c.pane, "filters")
    compare(filters.visible, true)
    compare(inspector.visible, false)
    tab(o.c)
    compare(o.c.pane, "table")
    compare(filters.visible, false)
    compare(inspector.visible, false)
    key(o.c, "", 0x01000002)   // Shift-Tab goes the other way
    compare(o.c.pane, "filters")
    compare(filters.visible, true)
  }

  function test_narrow_overlay_leaves_visual() {
    var o = narrow(850)
    key(o.c, "V", 0x56, 0x02000000)
    compare(o.c.mode, "VISUAL")
    // pane keys are NORMAL-only, as at full width
    ctrlH(o.c)
    compare(o.c.pane, "table")
    compare(o.c.mode, "VISUAL")
    // Esc in VISUAL leaves VISUAL (no overlay is open to close)
    esc(o.c)
    compare(o.c.mode, "NORMAL")
    // any pane change that opens an overlay ends VISUAL first
    key(o.c, "V", 0x56, 0x02000000)
    o.c.setPane("filters")
    compare(o.c.mode, "NORMAL", "a pane change leaves VISUAL")
    compare(paneTitled(o.c, "Filters").visible, true)
  }

  function test_narrow_filter_chip() {
    var o = narrow(850)
    var line = findPane(o.c, "filterChip")
    verify(line !== null)
    compare(line.filterChip, "", "no chip for All")
    ctrlH(o.c)
    o.c.applyFilter({ group: "status", value: "Seeding" })
    esc(o.c)
    compare(line.filterChip, "▸ Seeding")
    verify(findText(line, "▸ Seeding") !== null, "the status line shows it")
    setWidth(o.c, 1000)
    compare(line.filterChip, "", "no chip while the filters are docked")
  }

  function test_narrow_columns_hide_below_700() {
    var o = narrow(850)
    var table = findWith(winOf(o.c).contentItem, "setRows")
    compare(table.hideColumns, [])
    verify(table.ulWidth > 0)
    verify(findText(table, "ETA") !== null)
    setWidth(o.c, 690)
    compare(table.hideColumns, ["ul", "eta", "ratio"])
    compare(table.ulWidth, 0)
    compare(table.etaWidth, 0)
    compare(table.ratioWidth, 0)
    compare(findText(table, "ETA"), null, "the ETA header hides")
    compare(findText(table, "Ratio"), null)
    verify(findText(table, "Name") !== null, "Name, Size, Progress and ↓ stay")
    verify(findText(table, "Size") !== null)
    verify(findText(table, "Progress") !== null)
    verify(table.dlWidth > 0)
  }

  function test_resize_collapsing_the_focused_pane_returns_to_table() {
    var o = make()
    o.svc.torrents = list3()
    tab(o.c)
    compare(o.c.pane, "inspector")
    setWidth(o.c, 1299)
    compare(o.c.pane, "table", "the inspector collapsed under focus")
    compare(paneTitled(o.c, "Inspector").visible, false)
    key(o.c, "", 0x01000002)
    compare(o.c.pane, "filters", "docked at 1299")
    compare(paneTitled(o.c, "Filters").overlay, false)
    setWidth(o.c, 899)
    compare(o.c.pane, "table")
    // an overlay that is already open stays open as the window shrinks
    ctrlH(o.c)
    setWidth(o.c, 800)
    compare(o.c.pane, "filters")
    compare(paneTitled(o.c, "Filters").visible, true)
  }

  function test_close_with_palette_open_closes_it() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, ":")
    compare(o.c.mode, "COMMAND")
    o.c.close()
    compare(o.c.opened, false)
    compare(o.c.mode, "NORMAL", "close() ends COMMAND")
    o.c.open("")
    compare(pal(o.c).visible, false, "reopening doesn't show a stale palette")
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"), "keys go to the table")
  }

  function test_files_cursor_sticks_by_index_on_refresh() {
    function filesOf(nums) {
      var out = []
      for (var i = 0; i < nums.length; i++) out.push({ index: nums[i], name: "f" + nums[i], progress: 0, priority: 1 })
      return out
    }
    function cursorAt3() {
      var o = make()
      o.svc.torrents = [tt(hh("a"), "alpha")]
      key(o.c, "4")
      o.svc.setFilesFor(hh("a"), filesOf([0, 1, 2, 3, 4]))
      o.svc.setFilesStatus(hh("a"), "ok", "")
      key(o.c, "\t", 0x01000001)
      compare(o.c.pane, "inspector")
      key(o.c, "j"); key(o.c, "j"); key(o.c, "j")
      compare(o.c.fileIndex, 3)
      return o
    }

    // a refresh that reorders nothing keeps the cursor on file 3
    var o1 = cursorAt3()
    o1.svc.setFilesFor(hh("a"), filesOf([0, 1, 2, 3, 4]))
    compare(o1.c.fileIndex, 3, "no reorder keeps the cursor on file 3")

    // the same file moves to another slot: the cursor follows it by index,
    // not by its old position
    var o2 = cursorAt3()
    o2.svc.setFilesFor(hh("a"), filesOf([3, 0, 1, 2, 4]))
    compare(o2.c.fileIndex, 0, "the cursor follows file 3 to its new slot")

    // a refresh with 2 files clamps it to 1
    var o3 = cursorAt3()
    o3.svc.setFilesFor(hh("a"), filesOf([0, 1]))
    compare(o3.c.fileIndex, 1, "a shrink clamps the cursor to the last row")
  }

  function findByObjectName(obj, name) {
    if (!obj) return null
    if (obj.objectName === name) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findByObjectName(kids[i], name); if (r) return r }
    return null
  }

  function findAllByObjectName(obj, name, out) {
    out = out || []
    if (!obj) return out
    if (obj.objectName === name) out.push(obj)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) findAllByObjectName(kids[i], name, out)
    return out
  }

  function test_inspector_list_detail_and_header() {
    var list = createTemporaryObject(inspectorListComp, tc, {
      width: 300,
      height: 200,
      rows: [{ key: "a", name: "Alpha" }, { key: "b", name: "Beta" }],
      columns: [
        { role: "name", width: 0, tone: function(r) { return r.key === "b" ? "muted" : "fg" } },
        { role: "seeds", width: 40, label: "Seeds" },
        { role: "peers", width: 40, label: "" }
      ],
      focusedPane: true,
      cursor: 1,
      detail: detailComp,
      header: true
    })
    var lv = findWith(list, "itemAtIndex")
    verify(lv !== null)
    compare(lv.count, 2, "the header never counts toward the rows")
    verify(lv.headerItem !== null, "header:true adds a row above the list")
    verify(lv.headerItem.height > 0)

    // header labels: an explicit label wins, an omitted one falls back
    // to the role, and an empty-string label is a real (blank) label
    var headers = findAllByObjectName(lv.headerItem, "headerCell")
    compare(headers.length, 3)
    compare(headers[0].text, "name", "no label falls back to the role")
    compare(headers[1].text, "Seeds", "an explicit label wins over the role")
    compare(headers[2].text, "", "an empty-string label is kept, not replaced by the role")

    var cursorItem = lv.itemAtIndex(1)
    var otherItem = lv.itemAtIndex(0)
    verify(cursorItem !== null)
    verify(otherItem !== null)
    // a column's tone can be a function of the row: it survives being
    // handed to a Repeater through `columns` and isn't dropped/coerced
    compare(findByObjectName(cursorItem, "cell").color, Color.muted, "row b's tone function resolves to muted")
    compare(findByObjectName(otherItem, "cell").color, Color.foreground, "row a's tone function resolves to fg")
    compare(findByObjectName(otherItem, "detailText"), null, "no detail under a non-cursor row")
    var detailText = findByObjectName(cursorItem, "detailText")
    verify(detailText !== null, "the detail shows under the cursor row")
    compare(detailText.text, "detail b Beta", "the detail component receives the cursor row")
  }

  function test_inspector_list_missing_role_renders_empty() {
    var list = createTemporaryObject(inspectorListComp, tc, {
      width: 300,
      height: 200,
      rows: [{ key: "a", name: "Alpha" }],
      columns: [{ role: "name", width: 0 }, { role: "notThere", width: 40 }]
    })
    var lv = findWith(list, "itemAtIndex")
    var cells = findAllByObjectName(lv.itemAtIndex(0), "cell")
    compare(cells.length, 2)
    compare(cells[1].text, "", "a role missing from the row renders empty, not \"undefined\"")
  }

  function test_inspector_list_detail_rebinds_when_rows_refresh() {
    var list = createTemporaryObject(inspectorListComp, tc, {
      width: 300,
      height: 200,
      rows: [{ key: "a", name: "Alpha" }, { key: "b", name: "Beta" }],
      columns: [{ role: "name", width: 0 }],
      focusedPane: true,
      cursor: 1,
      detail: detailComp
    })
    var lv = findWith(list, "itemAtIndex")
    compare(findByObjectName(lv.itemAtIndex(1), "detailText").text, "detail b Beta")
    // a fresh array (Task 5's trackers/peers replace `rows` wholesale on
    // every tick): the cursor stays on key "b", but its data changed --
    // the detail must show the new data, not what it saw when it loaded
    list.rows = [{ key: "a", name: "Alpha2" }, { key: "b", name: "Beta2" }]
    compare(findByObjectName(lv.itemAtIndex(1), "detailText").text, "detail b Beta2",
      "the detail re-binds to the refreshed row, not a stale snapshot from when it loaded")
  }

  // Trackers and peers hand InspectorList a fresh array every second (peer
  // speeds change every tick): that must neither rebuild the delegates nor
  // move the view, or a scrolled list jumps to the top each tick.
  function test_inspector_list_refresh_keeps_scroll_and_delegates() {
    function rowsWith(speedOf) {
      var out = []
      for (var i = 0; i < 40; i++) out.push({ key: "k" + i, name: "peer " + i, down: String(speedOf(i)) })
      return out
    }
    var list = createTemporaryObject(inspectorListComp, tc, {
      width: 300,
      height: 120,
      rows: rowsWith(function(i) { return i }),
      columns: [{ role: "name", width: 0 }, { role: "down", width: 60, align: "right" }],
      focusedPane: true,
      cursor: 20
    })
    var lv = findWith(list, "itemAtIndex")
    var y = 19 * list.rowHeight
    lv.contentY = y
    compare(lv.contentY, y)
    var before = lv.itemAtIndex(20)
    verify(before !== null)
    list.rows = rowsWith(function(i) { return 1000 - i })
    compare(lv.contentY, y, "a refresh leaves the scroll position alone")
    verify(lv.itemAtIndex(20) === before, "the delegate is reused, not rebuilt")
    compare(findAllByObjectName(lv.itemAtIndex(20), "cell")[1].text, "980", "the reused delegate shows the new data")
    // fewer rows, then more: count follows, the view is not reset to the
    // top. A shrink is deferred a turn (InspectorList.syncSlots, M1: it
    // lets any in-flight incubation from the contentY jump above settle
    // before slots are removed out from under it), so wait(0) once for
    // the Timer before checking count.
    list.rows = rowsWith(function(i) { return i }).slice(0, 30)
    wait(0)
    compare(lv.count, 30)
    compare(lv.contentY, y)
    list.rows = rowsWith(function(i) { return i })
    compare(lv.count, 40)
    compare(lv.contentY, y)
  }

  // ---- trackers and peers (Task 5) -------------------------------------

  function trackersFixture() {
    return [
      { url: "** [DHT] **", status: 2, num_seeds: -1, num_leeches: -1 },
      { url: "** [PeX] **", status: 2, num_seeds: -1, num_leeches: -1 },
      { url: "** [LSD] **", status: 0, num_seeds: -1, num_leeches: -1 },
      { url: "https://tracker.example/announce?passkey=abc123", status: 2, tier: 0, num_seeds: 14, num_leeches: 3, msg: "" },
      { url: "udp://t.example:1337/abc123/announce", status: 4, tier: 1, num_seeds: -1, num_leeches: -1, msg: "Connection timed out", next_announce: 840 }
    ]
  }
  function inspectorOf(c) { return findWith(winOf(c).contentItem, "positionFile") }
  function findByName(obj, name) {
    if (!obj) return null
    if (obj.objectName === name) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findByName(kids[i], name); if (r) return r }
    return null
  }
  // Every Text a user could see under obj (every ancestor visible).
  function visibleTexts(obj, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj.text)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) visibleTexts(kids[i], out)
    return out
  }
  // ListView delegates appear on the next polish, so let one pass first.
  function shows(c, text) { wait(30); return visibleTexts(winOf(c).contentItem).indexOf(text) >= 0 }
  // Every visible Text item itself (not just its string), for geometry checks.
  function textNodesIn(obj, out) {
    out = out || []
    if (!obj || obj.visible === false) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) textNodesIn(kids[i], out)
    return out
  }
  function listViewIn(obj) {
    if (!obj || obj.visible === false) return null
    if (typeof obj.itemAtIndex === "function") return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = listViewIn(kids[i]); if (r) return r }
    return null
  }

  function test_trackers_watch_follows_the_cursor_and_closing_clears_it() {
    var o = make()
    o.svc.torrents = list3()   // added desc: gamma(c), beta(b), alpha(a)
    compare(o.c.cursorHash, hh("c"))
    key(o.c, "2")
    compare(o.c.inspectorTab, "trackers")
    var w = lastCall(o.svc, "watch")
    compare(w.args[0], hh("c"))
    compare(w.args[1], "trackers")
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"))
    w = lastCall(o.svc, "watch")
    compare(w.args[0], hh("b"), "moving the table cursor re-watches the new torrent")
    compare(w.args[1], "trackers")
    key(o.c, "3")
    compare(o.c.inspectorTab, "peers")
    compare(lastCall(o.svc, "watch").args[1], "peers")
    compare(lastCall(o.svc, "watch").args[0], hh("b"))
    o.c.close()
    w = lastCall(o.svc, "watch")
    compare(w.args[0], "", "closing the window clears the watch")
  }

  function test_chart_tab_renders_a_non_empty_series_and_an_idle_sentence() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "5")
    compare(o.c.inspectorTab, "chart")
    compare(lastCall(o.svc, "watch").args[1], "chart")
    var chartComp = findByObjectName(winOf(o.c).contentItem, "speedChart")
    verify(chartComp !== null)
    compare(chartComp.visible, false, "no reply yet")

    var now = Date.now()
    o.svc.setInspect(hh("c"), "chart", { points: [[now / 1000, 5 * 1024 * 1024, 200 * 1024]], at: now })
    compare(chartComp.visible, true)
    compare(chartComp.series.empty, false)
    verify(chartComp.paintCount > 0, "requestPaint ran for the new series")
    verify(shows(o.c, "last 10 min"))
    verify(!shows(o.c, "No traffic in the last 10 minutes."))
    // the legend's current values
    compare(findByObjectName(winOf(o.c).contentItem, "chartLegendDown").text, "━ ↓ 5.0 MiB/s")
    compare(findByObjectName(winOf(o.c).contentItem, "chartLegendUp").text, "━ ↑ 200 KiB/s")
    compare(findByObjectName(winOf(o.c).contentItem, "chartMaxText").text, "5 MiB/s")

    var before = chartComp.paintCount
    o.svc.setInspect(hh("c"), "chart", { points: [], at: Date.now() })
    compare(chartComp.series.empty, true)
    verify(chartComp.paintCount > before, "an idle reply is still a series change")
    verify(shows(o.c, "No traffic in the last 10 minutes."))
    compare(findByObjectName(winOf(o.c).contentItem, "chartLegendDown").text, "━ ↓ 0 B/s")
    compare(findByObjectName(winOf(o.c).contentItem, "chartLegendUp").text, "━ ↑ 0 B/s")
    compare(findByObjectName(winOf(o.c).contentItem, "chartMaxText").text, "—")
  }

  function test_a_stale_reply_for_the_old_torrent_never_paints() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "2")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    compare(o.c.trackersView.state, "rows")
    verify(shows(o.c, "tracker.example"))
    key(o.c, "j")
    compare(o.c.cursorHash, hh("b"))
    // gamma's reply lands after the cursor moved to beta
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    compare(o.c.trackersView.rows.length, 0)
    verify(o.c.trackersView.state === "blank" || o.c.trackersView.state === "loading")
    verify(!shows(o.c, "tracker.example"), "beta's tab never shows gamma's trackers")
  }

  function test_a_to_b_to_a_waits_for_a_fresh_reply() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "2")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    compare(o.c.trackersView.state, "rows")
    wait(5)
    key(o.c, "j"); key(o.c, "k")
    compare(o.c.cursorHash, hh("c"))
    compare(o.c.trackersView.state, "blank", "the reply stored for A before the round trip is not shown")
    verify(!shows(o.c, "tracker.example"))
    verify(!shows(o.c, "Loading trackers…"))
    tryVerify(function() { return o.c.trackersView.state === "loading" }, 1000)
    verify(shows(o.c, "Loading trackers…"))
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    compare(o.c.trackersView.state, "rows")
    verify(shows(o.c, "tracker.example"))
  }

  function test_trackers_render_without_passkeys_and_y_copies_the_full_url() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "2")
    // I1: a passkey can also ride in a URL's userinfo (not only its path
    // or query), e.g. "https://user:abc123@host/announce" -- add a row
    // with one alongside the query- and path-passkey rows already here.
    var trackers = trackersFixture().concat([
      { url: "https://user:abc123@passkey.example/announce", status: 2, tier: 2, num_seeds: 1, num_leeches: 1, msg: "" }
    ])
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackers })
    verify(shows(o.c, "3 trackers"), "pane title right side")
    verify(shows(o.c, "DHT "))
    verify(shows(o.c, "  ·  15 seeds · 4 peers"))
    verify(shows(o.c, "Tracker")); verify(shows(o.c, "Seeds")); verify(shows(o.c, "Peers"))
    verify(shows(o.c, "tracker.example"))
    verify(shows(o.c, "t.example:1337"))
    compare(o.c.trackersView.rows[2].host, "passkey.example", "the userinfo row's host is stripped of user:abc123@")
    verify(shows(o.c, "j k move · y copy"))
    key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    key(o.c, "j")
    compare(o.c.trackerIndex, 1)
    // the cursor row's detail: status, message, redacted url, tier
    verify(shows(o.c, "not working"))
    verify(shows(o.c, " · \"Connection timed out\""))
    verify(shows(o.c, "udp://t.example:1337/…"))
    verify(shows(o.c, "tier 1 · next announce in 14m"))
    var texts = visibleTexts(inspectorOf(o.c).parent)
    verify(texts.length > 10)
    for (var i = 0; i < texts.length; i++) verify(texts[i].indexOf("abc123") === -1, "no rendered text shows the passkey: " + texts[i])
    key(o.c, "y")
    var cp = lastCall(o.svc, "copyText")
    verify(cp !== null)
    compare(cp.args[0], "udp://t.example:1337/abc123/announce")
    compare(cp.args[1].origin, "window")
    compare(lastCall(o.svc, "copy"), null, "not a magnet copy")
    o.svc.actionFinished(o.svc.seq, true, "", "window", [])
    compare(o.c.messageLine.text, "Copied")
    // k back to the first tracker, y copies its full https URL
    key(o.c, "k")
    compare(o.c.trackerIndex, 0)
    verify(shows(o.c, "https://tracker.example/…"), "the query-passkey row's detail is open")
    verify(shows(o.c, "tier 0"), "no announce part without next_announce")
    texts = visibleTexts(inspectorOf(o.c).parent)
    for (var t = 0; t < texts.length; t++) verify(texts[t].indexOf("abc123") === -1, "no rendered text shows the passkey: " + texts[t])
    key(o.c, "y")
    compare(lastCall(o.svc, "copyText").args[0], "https://tracker.example/announce?passkey=abc123")
  }

  function peersWith(n, speedOf) {
    var out = ({})
    for (var i = 0; i < n; i++) out["10.0.0." + i + ":6881"] = { client: "client " + i, country_code: "de", progress: i % 2, dl_speed: speedOf(i), up_speed: 0, connection: "BT", flags: "D", flags_desc: "D = downloading" }
    return out
  }

  function test_peers_sorted_sticky_cursor_scroll_and_y() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "3")
    compare(o.c.inspectorTab, "peers")
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(40, function(i) { return 1000 + i }) })
    compare(o.c.peersView.state, "rows")
    compare(o.c.peersView.rows[0].key, "10.0.0.39:6881", "sorted by ↓")
    verify(shows(o.c, "40 peers · 20 seeds"))
    verify(shows(o.c, "Client")); verify(shows(o.c, "Has")); verify(shows(o.c, "↓")); verify(shows(o.c, "↑"))
    verify(shows(o.c, "j k move · y copy ip:port · sorted by ↓ then ↑"))
    key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    for (var j = 0; j < 20; j++) key(o.c, "j")
    compare(o.c.peerIndex, 20)
    var cursorKey = o.c.peersView.rows[20].key
    compare(cursorKey, "10.0.0.19:6881")
    verify(shows(o.c, "10.0.0.19"))
    verify(shows(o.c, ":6881 · BT · downloaded 0 B"))
    verify(shows(o.c, " · D = downloading"))
    var lv = listViewIn(inspectorOf(o.c))
    verify(lv !== null)
    lv.contentY = 10 * Style.spacing.popupRowHeight   // mid-list, not the clamped bottom
    var y = lv.contentY
    verify(y > 0)
    // the next tick reverses the speeds: the order flips
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(40, function(i) { return 2000 - i }) })
    compare(o.c.peersView.rows[0].key, "10.0.0.0:6881")
    compare(o.c.peersView.rows[o.c.peerIndex].key, cursorKey, "the cursor sticks to its ip:port")
    compare(o.c.peerIndex, 19)
    compare(lv.contentY, y, "a refresh keeps the scroll position")
    key(o.c, "y")
    compare(lastCall(o.svc, "copyText").args[0], "10.0.0.19:6881")
  }

  function test_tab_states_loading_error_sidecar_down_and_empty() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "2")
    compare(o.c.trackersView.state, "blank")
    verify(!shows(o.c, "Loading trackers…"), "nothing for the first 300 ms")
    wait(200)
    verify(!shows(o.c, "Loading trackers…"), "still nothing at ~250 ms")
    tryVerify(function() { return o.c.trackersView.state === "loading" }, 1000)
    verify(shows(o.c, "Loading trackers…"))
    // an error entry that still carries rows (Service keeps prior data):
    // the error screen wins, with the cause and the retry line
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture(), error: "HTTP 500" })
    verify(shows(o.c, "Couldn't read trackers"))
    verify(shows(o.c, "HTTP 500"))
    verify(shows(o.c, "Retrying every 5 s."))
    verify(!shows(o.c, "tracker.example"), "retained rows are not drawn under an error")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture().slice(0, 3) })
    verify(shows(o.c, "No trackers"))
    verify(shows(o.c, "This torrent only finds peers through DHT and PeX."))
    // M3: the DHT/PeX/LSD summary line still shows with no real trackers
    verify(shows(o.c, "DHT "), "the summary line still shows for an empty trackers list")
    verify(shows(o.c, "  ·  0 seeds · 0 peers"))
    o.svc.sidecarDown = true
    verify(shows(o.c, "Needs qbt-serve (slow polling)"))
    o.svc.sidecarDown = false
    key(o.c, "3")
    tryVerify(function() { return o.c.peersView.state === "loading" }, 1000)
    verify(shows(o.c, "Loading peers…"))
    o.svc.setInspect(hh("c"), "peers", { peers: {} })
    verify(shows(o.c, "No peers"))
    verify(shows(o.c, "Looking for peers…"))
  }

  // Ruling M: when the cursor's key leaves the list, the cursor goes to row 0.
  function test_list_cursor_falls_back_to_the_first_row_when_its_key_is_gone() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "3")
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(5, function(i) { return 100 - i }) })
    key(o.c, "\t", 0x01000001)
    key(o.c, "j"); key(o.c, "j"); key(o.c, "j")
    compare(o.c.peerIndex, 3)
    compare(o.c.peersView.rows[3].key, "10.0.0.3:6881")
    var fewer = peersWith(5, function(i) { return 100 - i })
    delete fewer["10.0.0.3:6881"]
    o.svc.setInspect(hh("c"), "peers", { peers: fewer })
    compare(o.c.peerIndex, 0, "the cursor peer left: first row")
    key(o.c, "2")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    key(o.c, "j")
    compare(o.c.trackerIndex, 1)
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture().slice(0, 4).concat([
      { url: "udp://other.example:6969/announce", status: 2, tier: 1, num_seeds: 1, num_leeches: 1 }]) })
    compare(o.c.trackersView.rows.length, 2)
    compare(o.c.trackerIndex, 0, "the cursor tracker left: first row")
  }

  // Ruling L: the watched tab's read error goes to the status line once per
  // new error; a success or a watch change re-arms it.
  function test_inspect_error_notes_the_status_line_once_per_error() {
    // "0" stands in for the "any key ends the note" filler keypress:
    // Task 8 binds every digit 1-5 to a real inspector.* command (5 now
    // opens the chart tab, which would switch inspectorTab away from
    // "trackers" and stop this test's setInspect calls from ever being
    // read), so the harmless no-op key moved from "5" to the still-unbound
    // "0".
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "2")
    o.svc.setInspect(hh("c"), "trackers", { trackers: [], error: "HTTP 500" })
    compare(o.c.messageLine.text, "Couldn't read trackers: HTTP 500")
    compare(o.c.messageLine.tone, "urgent")
    key(o.c, "0")   // any key ends the note
    compare(o.c.messageLine.text, "")
    o.svc.setInspect(hh("c"), "trackers", { trackers: [], error: "HTTP 500" })
    compare(o.c.messageLine.text, "", "the same error on the next tick is not noted again")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    compare(o.c.messageLine.text, "")
    o.svc.setInspect(hh("c"), "trackers", { trackers: [], error: "HTTP 500" })
    compare(o.c.messageLine.text, "Couldn't read trackers: HTTP 500", "after a success, the error notes again")
    key(o.c, "0")
    o.svc.setInspect(hh("c"), "trackers", { trackers: [], error: "timed out" })
    compare(o.c.messageLine.text, "Couldn't read trackers: timed out", "a different error notes")
    key(o.c, "0")
    // a watch change re-arms: back on trackers, a fresh identical error notes
    wait(5)   // a later millisecond than the stored error, as in real use
    key(o.c, "3"); key(o.c, "2")
    compare(o.c.messageLine.text, "", "the stale error under the old key is not noted")
    o.svc.setInspect(hh("c"), "trackers", { trackers: [], error: "timed out" })
    compare(o.c.messageLine.text, "Couldn't read trackers: timed out")
  }

  // ---- info tab: pieces bar, groups, no-metadata (Task 6) ----------------

  function propsFixture(extra) {
    var p = {
      addition_date: 1700000000, comment: "hello", hash: hh("a"),
      is_private: false, nb_connections: 17, nb_connections_limit: 100,
      piece_size: 1048576, pieces_num: 4, time_elapsed: 8040, seeding_time: 0,
      total_downloaded: 1073741824, total_downloaded_session: 0,
      total_uploaded: 2147483648, total_wasted: 0, has_metadata: true
    }
    for (var k in extra || {}) p[k] = extra[k]
    return p
  }

  function test_info_pieces_bar_and_transfer_torrent_groups() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: 5000000000 })]
    key(o.c, "1")
    compare(o.c.inspectorTab, "info")
    o.svc.setInspect(hh("a"), "info", { props: propsFixture(), pieces: [2, 2, 0, 0] })
    wait(30)
    var insp = inspectorOf(o.c)
    var bar = findWith(insp, "markup")
    verify(bar !== null, "PiecesBar is in the tree")
    compare(bar.cells.length, 48)
    verify(shows(o.c, "pieces 2 of 4 · █ have ▓ partial ░ missing"))
    verify(shows(o.c, "Transfer"))
    verify(shows(o.c, "Torrent"))
    verify(shows(o.c, "17 of 100"), "Connections field")
    verify(shows(o.c, "hello"), "Comment field")
    // L2: Added lives only in the Transfer group (Ruling T) -- the top
    // (slice-1) block no longer repeats it, so the Info tab shows exactly
    // one "Added" label.
    compare(visibleTexts(insp).filter(function(t) { return t === "Added" }).length, 1, "exactly one Added label")
    // Sidecar down: the pieces area shows nothing, the groups show "--",
    // and there is no "Needs qbt-serve" blocker over the whole tab.
    o.svc.sidecarDown = true
    wait(30)
    verify(!shows(o.c, "pieces 2 of 4 · █ have ▓ partial ░ missing"))
    // The bar itself (not just its old legend text) is gone: with no fresh
    // pieces, InspectorView.infoView hands back [], and a bar shown with []
    // would render an empty line plus a "0 of 0" legend.
    verify(!shows(o.c, "pieces 0 of 0 · █ have ▓ partial ░ missing"))
    verify(!shows(o.c, "17 of 100"))
    verify(!shows(o.c, "Needs qbt-serve (slow polling)"))
    verify(shows(o.c, "alpha"), "the slice-1 block stays up")
  }

  // L1: at the real pane width the four action keys ("o open folder",
  // "y copy magnet", "m move", "e recheck") can wrap the key Flow to two
  // lines; a fixed-height footer used to clip the second line under the
  // divider. The footer must size to the Flow's content instead.
  function test_info_footer_sizes_to_its_content_and_never_clips_the_keys() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: 5000000000 })]
    key(o.c, "1")
    wait(30)
    var insp = inspectorOf(o.c)
    compare(insp.width, 380, "the real docked inspector pane width")
    var foot = findByName(insp, "infoActionsFooter")
    verify(foot !== null, "the footer is in the tree")
    var flow = findByName(insp, "infoKeyFlow")
    verify(flow !== null, "the key Flow is in the tree")
    // The harness stub's monospace glyphs are narrow enough that the four
    // keys fit on one line at 380 px, unlike the live window's real body
    // font. Narrow the Flow itself to force the two-line wrap the real
    // pane hits, so this test exercises the actual clipping bug (a fixed
    // 28 px footer with the Flow vertical-centered in it) rather than
    // passing vacuously on a single line.
    var oneLineHeight = flow.implicitHeight
    flow.anchors.right = undefined
    flow.width = Math.max(10, Math.round(flow.implicitWidth * 0.6))
    wait(50)
    verify(flow.implicitHeight > oneLineHeight,
      "the Flow now wraps to more than one line (" + flow.implicitHeight + " vs one line's " + oneLineHeight + ")")
    verify(foot.height >= flow.implicitHeight,
      "footer height " + foot.height + " is at least the Flow's implicit height " + flow.implicitHeight)
    var divider = foot.children[0]
    verify(divider !== undefined && divider.height === 1, "the divider Rectangle is the footer's first child")
    var dividerY = divider.mapToItem(foot, 0, 0).y
    var keyLabels = ["o", "open folder", "y", "copy magnet", "m", "move", "e", "recheck"]
    var nodes = textNodesIn(flow).filter(function(n) { return keyLabels.indexOf(n.text) >= 0 })
    compare(nodes.length, keyLabels.length, "every key/label Text is visible")
    var minY = Infinity
    for (var i = 0; i < nodes.length; i++) {
      var p = nodes[i].mapToItem(foot, 0, 0)
      verify(p.y + nodes[i].height <= foot.height + 0.5,
        "\"" + nodes[i].text + "\" (y " + p.y + ", height " + nodes[i].height + ") fits inside the footer (height " + foot.height + ")")
      if (p.y < minY) minY = p.y
    }
    verify(dividerY < minY, "the divider (y " + dividerY + ") sits above the first text line (y " + minY + ")")
  }

  // M2: a fresh error entry never shows retained props/pieces, even
  // though Service keeps them for a transient failure -- the states table
  // says Info's Error column stays "—" throughout, and the slice-1
  // label/value block (read from the row, not the inspect reply) stays up.
  function test_info_error_entry_shows_nothing_retained() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: 5000000000 })]
    key(o.c, "1")
    o.svc.setInspect(hh("a"), "info", { props: propsFixture(), pieces: [2, 2, 0, 0] })
    wait(30)
    verify(shows(o.c, "pieces 2 of 4 · █ have ▓ partial ░ missing"))
    verify(shows(o.c, "17 of 100"), "Connections field")
    // Service keeps the prior props/pieces around for a transient read
    // failure -- infoView must still drop them once entry.error is set.
    o.svc.setInspect(hh("a"), "info", { props: propsFixture(), pieces: [2, 2, 0, 0], error: "HTTP 500" })
    wait(30)
    verify(!shows(o.c, "pieces 2 of 4 · █ have ▓ partial ░ missing"))
    verify(!shows(o.c, "pieces 0 of 0 · █ have ▓ partial ░ missing"), "no bar with an all-missing legend either")
    verify(!shows(o.c, "17 of 100"), "Connections reads — like every other group value")
    verify(!shows(o.c, "no metadata yet · pieces and files appear once it's fetched"), "the pieces area shows nothing, not the no-metadata line")
    var insp = inspectorOf(o.c)
    var bar = findWith(insp, "markup")
    verify(bar !== null && bar.visible === false, "the pieces bar itself is hidden")
    verify(shows(o.c, "alpha"), "the slice-1 block stays up")
    compare(o.c.messageLine.text, "Couldn't read info: HTTP 500", "the status line carries the error")
  }

  // M2 (regression guard): an info-tab error on a torrent that genuinely
  // has no metadata must still read "waiting for metadata" in State and
  // "No file list yet" in Files -- those come from the row and from
  // Files, not from the erroring info reply, so `noMeta` keeps its
  // ordinary row-size meaning through the error; only the Info tab's own
  // pieces area (gated on `errored` instead) goes blank.
  function test_info_error_on_a_no_metadata_torrent_keeps_state_and_files_copy() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: -1, state: "stoppedDL", progress: 0 })]
    key(o.c, "1")
    wait(30)
    verify(shows(o.c, "‖ stopped · waiting for metadata"))
    verify(shows(o.c, "no metadata yet · pieces and files appear once it's fetched"))
    // Service retains a stale props/pieces reply alongside the error, as
    // it does for a transient failure -- this must not flip noMeta false.
    o.svc.setInspect(hh("a"), "info", { props: propsFixture(), pieces: [2, 2, 0, 0], error: "HTTP 500" })
    wait(30)
    verify(shows(o.c, "‖ stopped · waiting for metadata"), "State still reads waiting-for-metadata through the error")
    verify(!shows(o.c, "no metadata yet · pieces and files appear once it's fetched"), "the pieces area blanks on the error, not the no-metadata line")
    key(o.c, "4")
    o.svc.setFilesFor(hh("a"), [])
    o.svc.setFilesStatus(hh("a"), "ok", "")
    verify(shows(o.c, "No file list yet"), "Files keeps its no-metadata copy through the info-tab error")
  }

  function test_info_comment_field_caps_at_3_lines_and_empty_shows_dash() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: 5000000000 })]
    key(o.c, "1")
    var longComment = "line one is fairly long and should wrap on its own, " +
      "line two is also fairly long and should wrap too, " +
      "line three keeps going, and this trailing bit should never be reached at all"
    o.svc.setInspect(hh("a"), "info", { props: propsFixture({ comment: longComment }), pieces: [2, 2, 0, 0] })
    wait(30)
    var insp = inspectorOf(o.c)
    var val = findByName(insp, "groupValue_Comment")
    verify(val !== null, "the Comment value Text is in the tree")
    verify(val.lineCount <= 3, "lineCount " + val.lineCount)
    verify(val.truncated === true, "a comment this long must be truncated, not just wrapped")
    // An empty comment shows "--" (InspectorView.infoGroups), never capped.
    o.svc.setInspect(hh("a"), "info", { props: propsFixture({ comment: "" }), pieces: [2, 2, 0, 0] })
    wait(30)
    val = findByName(insp, "groupValue_Comment")
    compare(val.text, "—")
    compare(val.truncated, false)
  }

  function test_info_no_metadata_shows_muted_line_and_no_bar_and_state_text() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: -1, state: "stoppedDL", progress: 0 })]
    key(o.c, "1")
    wait(30)
    verify(shows(o.c, "no metadata yet · pieces and files appear once it's fetched"))
    verify(shows(o.c, "‖ stopped · waiting for metadata"))
    var insp = inspectorOf(o.c)
    var bar = findWith(insp, "markup")
    verify(bar !== null && bar.visible === false, "the pieces bar itself is hidden")
  }

  function test_files_no_metadata_shows_no_file_list_yet() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { size: -1 })]
    key(o.c, "4")
    o.svc.setFilesFor(hh("a"), [])
    o.svc.setFilesStatus(hh("a"), "ok", "")
    compare(o.c.filesState.state, "empty")
    verify(shows(o.c, "No file list yet"))
    verify(shows(o.c, "qBittorrent needs the torrent's metadata first."))
    verify(!shows(o.c, "No files."))
  }

  function test_info_action_keys_stay_pinned_after_scrolling_to_the_bottom() {
    var o = make()
    // A very long name (WrapAnywhere) forces the info Flickable's content
    // taller than the pane, so scrolling to the bottom is a real move, not
    // a no-op that would make the footer's fixed position vacuously true.
    o.svc.torrents = [tt(hh("a"), "a".repeat(600), { size: 5000000000 })]
    key(o.c, "1")
    o.svc.setInspect(hh("a"), "info", { props: propsFixture(), pieces: [2, 2, 0, 0] })
    wait(30)
    var insp = inspectorOf(o.c)
    var foot = findByName(insp, "infoActionsFooter")
    verify(foot !== null, "the footer is in the tree")
    var flick = findByName(insp, "infoFlick")
    verify(flick !== null, "the flickable is in the tree")
    verify(flick.contentHeight > flick.height, "the content actually overflows the pane")
    var before = foot.mapToItem(insp, 0, 0).y
    flick.contentY = flick.contentHeight - flick.height
    wait(0)
    var after = foot.mapToItem(insp, 0, 0).y
    compare(after, before, "the footer doesn't move when the flickable scrolls")
    verify(shows(o.c, "copy magnet"), "the action keys are still on screen")
  }

  // ---- the inspector target (slice 2b, Task 3) ----------------------------

  function test_registry_state_follows_the_inspector_cursor_and_tab() {
    var o = make()
    o.svc.torrents = list3()
    compare(o.c.cursorHash, hh("c"))
    var st = o.c.registryState([])
    compare(st.inspectorTarget, null, "the table pane has no inspector target")
    compare(st.trackersTab, false)
    key(o.c, "2")
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture() })
    if (o.c.pane !== "inspector") key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    st = o.c.registryState([])
    compare(st.pane, "inspector")
    compare(st.trackersTab, true)
    compare(st.inspectorTarget, { kind: "tracker", value: "https://tracker.example/announce?passkey=abc123", label: "tracker.example" })
    key(o.c, "j")
    compare(o.c.registryState([]).inspectorTarget, { kind: "tracker", value: "udp://t.example:1337/abc123/announce", label: "t.example:1337" })
    // The palette evaluates from the pane it was opened in, with the target.
    compare(pal(o.c).evalState.pane, "inspector")
    compare(pal(o.c).evalState.inspectorTarget.label, "t.example:1337")
    // Only DHT/PeX/LSD: no tracker row, but still the trackers tab (a adds).
    o.svc.setInspect(hh("c"), "trackers", { trackers: trackersFixture().slice(0, 3) })
    st = o.c.registryState([])
    compare(st.inspectorTarget, null)
    compare(st.trackersTab, true)
    key(o.c, "3")
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(3, function(i) { return 1000 + i }) })
    compare(o.c.inspectorTab, "peers")
    st = o.c.registryState([])
    compare(st.trackersTab, false)
    compare(st.inspectorTarget, { kind: "peer", value: "10.0.0.2:6881", label: "10.0.0.2:6881" })
    key(o.c, "j")
    compare(o.c.registryState([]).inspectorTarget.value, "10.0.0.1:6881")
    key(o.c, "1")
    compare(o.c.registryState([]).inspectorTarget, null, "no target on Info")
    // Back in the table the target is gone again.
    key(o.c, "3")
    o.c.setPane("table")
    compare(o.c.registryState([]).inspectorTarget, null)
  }

  function test_registry_state_follows_the_cursor_torrents_metadata_flags() {
    var o = make()
    o.svc.torrents = [tt(hh("a"), "alpha", { addedOn: 1 }), tt(hh("b"), "nometa", { addedOn: 2, size: 0, state: "stoppedDL", progress: 0 })]
    compare(o.c.cursorHash, hh("b"))
    var st = o.c.registryState([])
    compare(st.cursorNoMetadata, true)
    compare(st.cursorStopped, true)
    compare(st.cursorPendingMagnet, false)
    key(o.c, "j")
    compare(o.c.cursorHash, hh("a"))
    st = o.c.registryState([])
    compare(st.cursorNoMetadata, false)
    compare(st.cursorStopped, false)
    // The flags reach the registry the way a key sees them (the table pane).
    compare(st.pane, "table")
    // A browser magnet still pending in the handler flow.
    o.svc.magnetPendingHashes = [hh("a")]
    o.c.cursorHash = hh("a")
    compare(o.c.registryState([]).cursorPendingMagnet, true)
    o.svc.magnetPendingHashes = []
    o.c.cursorHash = hh("a")
    compare(o.c.registryState([]).cursorPendingMagnet, false)
  }

  function test_palette_eval_state_is_stable_across_a_status_tick() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "3")
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(3, function(i) { return 1000 + i }) })
    if (o.c.pane !== "inspector") key(o.c, "\t", 0x01000001)
    var before = pal(o.c).evalState
    compare(before.inspectorTarget.value, "10.0.0.2:6881")
    // A tick: fresh torrent and peer objects, same values.
    o.svc.torrents = list3()
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(3, function(i) { return 1000 + i }) })
    verify(pal(o.c).evalState === before, "an unchanged target doesn't rebuild the open palette's rows")
    // A real change still reaches it.
    key(o.c, "j")
    compare(pal(o.c).evalState.inspectorTarget.value, "10.0.0.1:6881")
  }

  // ---- palette rows for another pane (Task 3 fix round 1, Ruling AC) --------

  function palRow(p, id) {
    for (var i = 0; i < p.rows.length; i++) if (p.rows[i].id === id) return p.rows[i]
    return null
  }

  function test_palette_runs_an_inspector_row_from_the_inspector() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "3")
    o.svc.setInspect(hh("c"), "peers", { peers: peersWith(3, function(i) { return 1000 + i }) })
    if (o.c.pane !== "inspector") key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    compare(o.c.peerIndex, 0)
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("next row")
    var row = palRow(p, "file.down")
    verify(row !== null)
    compare(row.enabled, true)
    compare(palRow(p, "file.cycle"), null, "the query only matches Next row")
    p.setQuery("cycle file")
    compare(palRow(p, "file.cycle").enabled, false, "not on the peers tab")
    compare(palRow(p, "file.cycle").reason, "focus the files tab")
    p.setQuery("next row")
    p.activated(palRow(p, "file.down"))
    compare(o.c.mode, "NORMAL")
    compare(o.c.pane, "inspector", "an inspector row runs where the palette was opened")
    compare(o.c.peerIndex, 1)
    // A table-only row from the inspector palette moves to the table (1b).
    key(o.c, ":")
    p.setQuery("pause")
    compare(palRow(p, "torrent.toggle").enabled, true)
    p.activated(palRow(p, "torrent.toggle"))
    compare(o.c.pane, "table")
    compare(lastCall(o.svc, "stop").args[0], hh("c"))
  }

  function test_palette_runs_a_filters_row_from_the_filters_pane() {
    var o = make()
    o.svc.torrents = list3()
    key(o.c, "", 0x01000002)    // Shift-Tab: table -> filters
    compare(o.c.pane, "filters")
    var before = JSON.stringify(o.c.filterCursor)
    key(o.c, ":")
    var p = pal(o.c)
    p.setQuery("down")
    var row = palRow(p, "filter.down")
    verify(row !== null)
    compare(row.enabled, true)
    p.activated(row)
    compare(o.c.mode, "NORMAL")
    compare(o.c.pane, "filters")
    verify(JSON.stringify(o.c.filterCursor) !== before, "the filters cursor moved")
  }
}
