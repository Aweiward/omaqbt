import QtQuick
import QtTest
import "../../.."

// The C and T pickers on torrents (slice 3a, Task 6). tst_client_library's
// service stub plus setCategory/editTags. Keys go through Client.handleKey,
// or, for Space vs typed text (Review Focus 5), as real key events through
// the picker's focused TextField (keyClick reaches the Client's window, the
// last one shown).
TestCase {
  id: tc
  name: "ClientPicker"
  when: windowShown

  readonly property string notReady: "Still reading qBittorrent's folders; try again in a moment."

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1, category: "", tags: [], tracker: "", savePath: "/dl", autoTmm: false }
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
      property var torrents: []
      property var categories: []
      property var tags: []
      property var categoryPaths: ({})
      property string defaultSavePath: "/dl"
      property var relocation: ({ torrentChanged: false, categoryPathChanged: false })
      property string homeDir: "/home/u"
      property var filesByHash: ({})
      property var filesStatusByHash: ({})
      property var magnetPending: []
      property var magnetInbox: []
      property var magnetPendingHashes: []
      property var viewState: ({ filter: { group: "status", value: "All" }, sort: "added", desc: true, cursorHash: "", pane: "table" })
      property bool windowOpen: false
      property var calls: []
      property var saved: []
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { saved.push(s); viewState = s }
      function refresh() { rec("refresh", []) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { rec("loadFiles", [h, o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function addCategory(n, p, o) { return rec("addCategory", [n, p, o]) }
      function setCategoryPath(n, p, o) { return rec("setCategoryPath", [n, p, o]) }
      function removeCategory(n, o) { return rec("removeCategory", [n, o]) }
      function renameCategory(a, b, m, o) { return rec("renameCategory", [a, b, m, o]) }
      function addTag(n, o) { return rec("addTag", [n, o]) }
      function removeTag(n, o) { return rec("removeTag", [n, o]) }
      function renameTag(a, b, m, o) { return rec("renameTag", [a, b, m, o]) }
      function setCategory(h, n, o) { return rec("setCategory", [h, n, o]) }
      function editTags(h, ch, o) { return rec("editTags", [h, ch, o]) }
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
  function findText(obj, text) {
    if (!obj) return null
    if (obj.text === text && obj.visible) return obj
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) { var r = findText(kids[i], text); if (r) return r }
    return null
  }
  function winOf(c) { for (var i = 0; i < c.data.length; i++) if (c.data[i] && c.data[i].contentItem) return c.data[i]; return null }
  function line(c) { return findWith(winOf(c).contentItem, "setInput") }
  function filterPane(c) { return findWith(winOf(c).contentItem, "positionAt") }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function lastCall(svc, name) { var l = calls(svc, name); return l.length ? l[l.length - 1] : null }
  function writes(svc) {
    return svc.calls.filter(function(x) { return ["addCategory", "setCategoryPath", "removeCategory", "renameCategory", "addTag", "removeTag", "renameTag", "setCategory", "editTags"].indexOf(x.name) !== -1 })
  }

  // alpha and beta on anime (auto-managed, in anime's default folder),
  // gamma on anime/2026, delta untouched; one tag, seedbox, on alpha.
  function library() {
    return [
      tt(hh("a"), "alpha", { addedOn: 4, category: "anime", tags: ["seedbox"], autoTmm: true, savePath: "/dl/anime" }),
      tt(hh("b"), "beta", { addedOn: 3, category: "anime", autoTmm: true, savePath: "/dl/anime" }),
      tt(hh("c"), "gamma", { addedOn: 2, category: "anime/2026", autoTmm: true, savePath: "/dl/anime/2026" }),
      tt(hh("d"), "delta", { addedOn: 1 })
    ]
  }

  function make(extra) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.categories = ["anime", "anime/2026"]
    svc.tags = ["seedbox"]
    for (var k in extra || {}) svc[k] = extra[k]
    svc.torrents = library()
    return { c: c, svc: svc }
  }

  // Focus the filters pane with its cursor on {group, value}.
  function on(o, group, value) {
    o.c.setPane("filters")
    o.c.setFilterCursor({ group: group, value: value })
    compare(o.c.pane, "filters")
  }

  function type(o, text) { line(o.c).setInput(text) }
  function insertMessage(o) { return findName(winOf(o.c).contentItem, "insertMessage") }
  function prompt(o) { return findName(winOf(o.c).contentItem, "insertPrompt").text }
  function confirmText(o) {
    var p = o.c.confirm ? o.c.confirm : null
    verify(p !== null, "a CONFIRM is up")
    return p.line
  }
  function finish(o, ok, err) { o.svc.actionFinished(o.svc.seq, ok, err || "", "window", []) }

  function catPicker(o) { return findName(winOf(o.c).contentItem, "categoryPicker") }
  function tagPicker(o) { return findName(winOf(o.c).contentItem, "tagPicker") }
  function titles(p) { return p.rows.map(function(r) { return r.title }) }
  function marks(p) { return p.rows.map(function(r) { return (r.prefix || "") + " " + r.title }) }
  function onRow(o, hash) { o.c.setPane("table"); o.c.setCursor(hash) }
  function relocate(o) { o.svc.relocation = { torrentChanged: true, categoryPathChanged: true } }
  function down(o) { key(o.c, "", 0x01000015) }
  function tab(o) { key(o.c, "", 0x01000001) }
  function space(o) { key(o.c, " ", 0x20) }

  // ---- C ---------------------------------------------------------------------------

  function test_C_opens_on_the_cursor_row_and_Esc_changes_nothing() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "C")
    compare(o.c.mode, "PICKER")
    var p = catPicker(o)
    verify(p.visible)
    verify(!tagPicker(o).visible)
    compare(p.counterText, "1 torrent")
    compare(titles(p), ["(no category)", "anime", "anime/2026"])
    compare(p.rows[1].keys, "1 of 1 now")
    compare(p.currentRow().title, "(no category)")
    compare(o.c.typingField(), p.inputField, "WmFocus gives the keys back to the picker's field")
    esc(o)
    compare(o.c.mode, "NORMAL")
    verify(!p.visible)
    compare(writes(o.svc).length, 0)
    compare(o.c.confirm, null)
  }

  function test_C_sets_the_category_with_no_move() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    catPicker(o).setQuery("2026")
    compare(catPicker(o).currentRow().title, "anime/2026")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null, "manual torrent, relocation off: nothing moves")
    var call = lastCall(o.svc, "setCategory")
    compare(call.args[0], hh("d"))
    compare(call.args[1], "anime/2026")
    compare(call.args[2].origin, "window")
    compare(o.c.messageLine.text, "Setting category anime/2026…")
    finish(o, true)
    compare(o.c.messageLine.text, "Category set to anime/2026")
  }

  function test_C_on_the_current_category_does_nothing() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "C")
    down(o)
    compare(catPicker(o).currentRow().title, "anime")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
    compare(o.c.messageLine.text, "", "no busy note either")
  }

  function test_C_move_confirm_names_the_folder_and_n_keeps_everything() {
    var o = make()
    relocate(o)
    onRow(o, hh("a"))
    key(o.c, "C")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    // Final fix wave (ruling BR): alpha is unfinished (progress 0.5).
    compare(confirmText(o), "Changes 1 torrent's category; its files move to /dl; unfinished ones may go to their download folder instead.")
    compare(writes(o.svc).length, 0, "nothing is written before y")
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
    key(o.c, "C")
    enter(o)
    key(o.c, "y")
    var call = lastCall(o.svc, "setCategory")
    compare(call.args[0], hh("a"))
    compare(call.args[1], "", "(no category)")
  }

  function test_C_on_a_VISUAL_range_mixing_managed_and_manual_torrents() {
    var o = make()
    relocate(o)
    onRow(o, hh("b"))
    key(o.c, "V")
    key(o.c, "j")
    key(o.c, "j")
    compare(o.c.visualHashes.length, 3)
    key(o.c, "C")
    compare(o.c.mode, "PICKER")
    var p = catPicker(o)
    compare(p.counterText, "3 torrents")
    compare(p.rows[1].keys, "1 of 3 now")
    compare(Object.keys(o.c.rangeHashes).length, 3, "the captured range stays painted")
    // the cursor moving while the picker is up doesn't change the targets
    o.c.setCursor(hh("a"))
    p.setQuery("anime")
    compare(p.currentRow().title, "anime")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    // Final fix wave (ruling BR): gamma is unfinished (progress 0.5).
    compare(confirmText(o), "Changes 2 torrents' category; 1 torrent's files move to /dl/anime; unfinished ones may go to their download folder instead.",
      "beta is already on anime; gamma moves, delta is manual")
    compare(o.c.confirmHashes, [hh("c"), hh("d")])
    compare(writes(o.svc).length, 0)
    key(o.c, "y")
    compare(o.c.mode, "NORMAL", "VISUAL ended with Enter")
    compare(o.c.anchorHash, "")
    var call = lastCall(o.svc, "setCategory")
    compare(call.args[0], hh("c") + "|" + hh("d"))
    compare(call.args[1], "anime")
    compare(call.args[2].hashes, [hh("c"), hh("d")])
  }

  function test_C_new_category_creates_then_sets() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    var p = catPicker(o)
    p.setQuery("fresh")
    compare(titles(p), ["+ New category \"fresh\""])
    enter(o)
    compare(o.c.mode, "NORMAL")
    var add = lastCall(o.svc, "addCategory")
    compare(add.args[0], "fresh")
    compare(add.args[1], "", "an empty save path: <default>/fresh")
    compare(calls(o.svc, "setCategory").length, 0, "the set waits for the add")
    compare(o.c.messageLine.text, "Creating category fresh…")
    finish(o, true)
    var set = lastCall(o.svc, "setCategory")
    compare(set.args[0], hh("d"))
    compare(set.args[1], "fresh")
    compare(o.c.messageLine.text, "Setting category fresh…")
    finish(o, true)
    compare(o.c.messageLine.text, "Category set to fresh")
    // an exact name offers no + New
    key(o.c, "C")
    p.setQuery("anime")
    compare(titles(p).indexOf("+ New category \"anime\""), -1)
    esc(o)
  }

  function test_C_new_category_confirms_the_move_before_the_add() {
    var o = make({ categoryPaths: { anime: { savePath: "/srv/anime" } } })
    relocate(o)
    onRow(o, hh("a"))
    key(o.c, "C")
    catPicker(o).setQuery("anime/new")
    compare(catPicker(o).currentRow().title, "+ New category \"anime/new\"")
    enter(o)
    // Final fix wave (ruling BR): alpha is unfinished (progress 0.5).
    compare(confirmText(o), "Changes 1 torrent's category; its files move to /srv/anime/new; unfinished ones may go to their download folder instead.")
    compare(writes(o.svc).length, 0, "no category is created before y")
    key(o.c, "y")
    compare(lastCall(o.svc, "addCategory").args[0], "anime/new")
    finish(o, true)
    compare(lastCall(o.svc, "setCategory").args[1], "anime/new")
  }

  function test_C_refuses_an_invalid_new_name_and_stays_open() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    catPicker(o).setQuery("a//b")
    var plus = catPicker(o).rows[catPicker(o).rows.length - 1]
    compare(plus.enabled, false)
    compare(plus.reason, "No // in a category.")
    catPicker(o).cursor = catPicker(o).rows.length - 1
    enter(o)
    compare(o.c.mode, "PICKER", "still open")
    verify(catPicker(o).visible)
    compare(catPicker(o).query, "a//b", "the text stays as typed")
    compare(o.c.messageLine.text, "No // in a category.")
    compare(writes(o.svc).length, 0)
  }

  function test_C_failure_copy_names_the_action() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    down(o)
    enter(o)
    var refreshes = calls(o.svc, "refresh").length
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Setting the category failed: HTTP 409")
    compare(o.c.messageLine.tone, "urgent")
    compare(calls(o.svc, "refresh").length, refreshes + 1, "a refresh follows")
    // + New: created, then the set failed (the new category stays)
    key(o.c, "C")
    catPicker(o).setQuery("omaqbt-test")
    enter(o)
    finish(o, true)
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Created omaqbt-test; setting it failed (HTTP 409)")
    // the add failed: no set at all
    key(o.c, "C")
    catPicker(o).setQuery("other")
    enter(o)
    var sets = calls(o.svc, "setCategory").length
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Creating category other failed: HTTP 409")
    compare(calls(o.svc, "setCategory").length, sets)
  }

  function test_C_waits_for_the_folders_T_does_not() {
    var o = make({ defaultSavePath: "" })
    onRow(o, hh("a"))
    key(o.c, "C")
    compare(o.c.mode, "NORMAL")
    verify(!catPicker(o).visible)
    compare(o.c.messageLine.text, notReady)
    key(o.c, "V")
    key(o.c, "C")
    compare(o.c.mode, "NORMAL", "from VISUAL too")
    compare(o.c.messageLine.text, notReady)
    key(o.c, "T")
    compare(o.c.mode, "PICKER")
    verify(tagPicker(o).visible)
  }

  function test_C_legacy_names_show_as_plain_text_and_can_be_chosen() {
    var legacy = " old//" + "y".repeat(70)
    var o = make()
    o.svc.categories = ["anime", legacy]
    onRow(o, hh("d"))
    key(o.c, "C")
    var p = catPicker(o)
    compare(titles(p)[2], legacy)
    p.cursor = 2
    enter(o)
    compare(lastCall(o.svc, "setCategory").args[1], legacy)
  }

  // ---- final fix wave: G8 at Enter (ruling BQ), the cursor across a blip (BS) --------

  // The bash fallback after a failed preferences read, and an API-down tick.
  function fallbackTick(o) { o.svc.relocation = { torrentChanged: false, categoryPathChanged: false }; o.svc.defaultSavePath = "" }
  function apiDownTick(o) { o.svc.api = false; o.svc.torrents = []; o.svc.categories = [] }

  function test_C_Enter_refuses_when_a_not_ready_tick_lands_after_C() {
    var ticks = [fallbackTick, apiDownTick]
    for (var i = 0; i < ticks.length; i++) {
      var o = make()
      relocate(o)
      onRow(o, hh("d"))
      key(o.c, "C")
      compare(o.c.mode, "PICKER")
      catPicker(o).setQuery("anime")
      compare(catPicker(o).currentRow().title, "anime")
      ticks[i](o)
      enter(o)
      compare(o.c.mode, "PICKER", "refused: the picker stays open (" + i + ")")
      verify(catPicker(o).visible)
      compare(o.c.messageLine.text, notReady)
      compare(o.c.confirm, null)
      compare(writes(o.svc).length, 0, "no write without a confirm (" + i + ")")
      esc(o)
      compare(writes(o.svc).length, 0)
    }
  }

  function test_C_cursor_survives_an_api_blip() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    var p = catPicker(o)
    p.setQuery("ani")
    compare(p.currentRow().title, "anime")
    // an API-down tick, as Service applies it: api first, then the lists
    o.svc.api = false
    o.svc.torrents = []
    o.svc.categories = []
    compare(p.currentRow().title, "anime", "no rebuild while the API is down")
    // recovery
    o.svc.api = true
    o.svc.torrents = library()
    o.svc.categories = ["anime", "anime/2026"]
    compare(p.currentRow().title, "anime")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "addCategory").length, 0, "no \"ani\" category")
    var call = lastCall(o.svc, "setCategory")
    compare(call.args[0], hh("d"))
    compare(call.args[1], "anime")
  }

  function test_C_cursor_survives_an_emptied_list() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    var p = catPicker(o)
    p.setQuery("ani")
    o.svc.categories = []
    compare(p.currentRow().title, "anime", "an emptied list doesn't rebuild the rows")
    o.svc.categories = ["anime", "anime/2026", "anime/2027"]
    compare(p.currentRow().title, "anime")
    verify(titles(p).indexOf("anime/2027") !== -1, "a real change still rebuilds")
    esc(o)
  }

  // Minor 6: a chunked set whose later chunk fails says how many changed.
  function test_C_chunk_failure_counts_what_changed() {
    var o = make()
    var many = []
    for (var i = 0; i < 1001; i++) {
      var h = ("0000000000" + i.toString(16)).slice(-10)
      many.push(tt(h + h + h + h, "t" + i, { addedOn: 2000 - i }))
    }
    o.svc.torrents = many
    function pickAll() {
      onRow(o, many[0].hash)
      key(o.c, "V")
      o.c.setCursor(many[1000].hash)
      compare(o.c.visualHashes.length, 1001)
      key(o.c, "C")
      down(o)
      compare(catPicker(o).currentRow().title, "anime")
      enter(o)
    }
    pickAll()
    compare(calls(o.svc, "setCategory").length, 2, "two chunks")
    var refreshes = calls(o.svc, "refresh").length
    o.svc.actionFinished(o.svc.seq - 1, true, "", "window", [])
    compare(o.c.messageLine.text, "Setting category anime…", "still running")
    o.svc.actionFinished(o.svc.seq, false, "qBittorrent refused it (HTTP 409)", "window", [])
    compare(o.c.messageLine.text, "Category set on 1000 of 1001; the rest failed (HTTP 409)")
    compare(o.c.messageLine.tone, "urgent")
    compare(calls(o.svc, "refresh").length, refreshes + 1, "one refresh")
    // the first chunk failing, the second fine: 1 of 1001 changed
    pickAll()
    o.svc.actionFinished(o.svc.seq - 1, false, "qBittorrent refused it (HTTP 409)", "window", [])
    o.svc.actionFinished(o.svc.seq, true, "", "window", [])
    compare(o.c.messageLine.text, "Category set on 1 of 1001; the rest failed (HTTP 409)")
  }

  // ---- T ---------------------------------------------------------------------------

  function test_T_marks_the_range_and_Enter_sends_only_the_changes() {
    var o = make()
    o.svc.tags = ["seedbox", "keep"]
    onRow(o, hh("a"))
    key(o.c, "V")
    key(o.c, "j")
    key(o.c, "T")
    var p = tagPicker(o)
    verify(p.visible)
    compare(p.counterText, "2 torrents")
    compare(marks(p), ["[~] seedbox", "[ ] keep"])
    space(o)
    compare(marks(p), ["[x] seedbox", "[ ] keep"])
    down(o)
    tab(o)
    compare(marks(p), ["[x] seedbox", "[x] keep"])
    enter(o)
    compare(o.c.mode, "NORMAL", "VISUAL ended with Enter")
    var call = lastCall(o.svc, "editTags")
    compare(call.args[0], hh("a") + "|" + hh("b"))
    compare(call.args[1].add, ["seedbox", "keep"])
    compare(call.args[1].remove, [])
    compare(o.c.messageLine.text, "Changing tags…")
    finish(o, true)
    compare(o.c.messageLine.text, "Tags changed")
  }

  function test_T_Enter_with_nothing_changed_writes_nothing() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "T")
    space(o)
    space(o)
    compare(marks(tagPicker(o)), ["[x] seedbox"], "toggled back")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
    compare(o.c.messageLine.text, "")
  }

  function test_T_Esc_changes_nothing() {
    var o = make()
    o.svc.tags = ["seedbox", "keep"]
    onRow(o, hh("a"))
    key(o.c, "T")
    space(o)
    down(o)
    space(o)
    tagPicker(o).setQuery("brand new")
    tab(o)
    compare(marks(tagPicker(o)), ["[x] brand new"])
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
    key(o.c, "T")
    compare(marks(tagPicker(o)), ["[x] seedbox", "[ ] keep"], "a fresh picker, nothing kept")
  }

  // Review Focus 5 with real key delivery through the picker's TextField.
  function test_T_space_toggles_only_on_an_empty_query_typed_spaces_are_text() {
    var o = make()
    o.svc.tags = ["seedbox", "keep"]
    onRow(o, hh("a"))
    key(o.c, "T")
    var p = tagPicker(o)
    wait(0)
    verify(p.inputField.activeFocus, "the field has the keys")
    keyClick(Qt.Key_Space)
    compare(p.query, "", "Space never reached the field")
    compare(marks(p), ["[ ] seedbox", "[ ] keep"], "Space toggled seedbox")
    keyClick(Qt.Key_A); keyClick(Qt.Key_N); keyClick(Qt.Key_I); keyClick(Qt.Key_M); keyClick(Qt.Key_E)
    keyClick(Qt.Key_Space)
    keyClick(Qt.Key_2); keyClick(Qt.Key_0); keyClick(Qt.Key_2); keyClick(Qt.Key_6)
    compare(p.query, "anime 2026", "a typed space is text")
    compare(p.working.map(function(s) { return s.mark + " " + s.name }), ["[ ] seedbox", "[ ] keep"], "and toggles nothing")
    compare(p.currentRow().title, "+ New tag \"anime 2026\"")
    keyClick(Qt.Key_Tab)
    compare(o.c.mode, "PICKER")
    compare(p.query, "anime 2026", "Tab never types")
    compare(p.working[2].name, "anime 2026")
    compare(p.working[2].state, "all", "Tab toggled the typed row")
    compare(p.currentRow().title, "anime 2026", "the cursor stays on it")
    keyClick(Qt.Key_Return)
    compare(o.c.mode, "NORMAL")
    compare(lastCall(o.svc, "addTag").args[0], "anime 2026")
    compare(calls(o.svc, "editTags").length, 0, "the tag waits for its create")
    finish(o, true)
    var call = lastCall(o.svc, "editTags")
    compare(call.args[0], hh("a"))
    compare(call.args[1].add, ["anime 2026"])
    compare(call.args[1].remove, ["seedbox"])
  }

  function test_T_Enter_on_new_tag_creates_and_adds_it() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "T")
    tagPicker(o).setQuery("keep")
    compare(tagPicker(o).currentRow().title, "+ New tag \"keep\"")
    enter(o)
    compare(lastCall(o.svc, "addTag").args[0], "keep")
    compare(o.c.messageLine.text, "Creating tag keep…")
    finish(o, true)
    compare(lastCall(o.svc, "editTags").args[1].add, ["keep"])
    // a comma is refused and the picker stays open
    key(o.c, "T")
    tagPicker(o).setQuery("a,b")
    enter(o)
    compare(o.c.mode, "PICKER")
    compare(o.c.messageLine.text, "No commas in a tag.")
    tab(o)
    compare(o.c.messageLine.text, "No commas in a tag.", "Tab says why too")
    compare(tagPicker(o).working.length, 1)
  }

  function test_T_failure_copy() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "T")
    space(o)
    enter(o)
    var refreshes = calls(o.svc, "refresh").length
    finish(o, false, "Tags: removing seedbox failed (HTTP 409)")
    compare(o.c.messageLine.text, "Tags: removing seedbox failed (HTTP 409)", "qbt's sentence names the tag")
    compare(calls(o.svc, "refresh").length, refreshes + 1)
    key(o.c, "T")
    tagPicker(o).setQuery("keep")
    enter(o)
    finish(o, true)
    finish(o, false, "Tags: adding keep failed (HTTP 409)")
    compare(o.c.messageLine.text, "Created keep; tags: adding keep failed (HTTP 409)")
    key(o.c, "T")
    tagPicker(o).setQuery("keep2")
    enter(o)
    finish(o, true)
    finish(o, false, "qBittorrent refused it (HTTP 500)")
    compare(o.c.messageLine.text, "Created keep2; tagging failed (HTTP 500)")
  }

  function test_close_with_a_picker_open_closes_it() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "T")
    compare(o.c.mode, "PICKER")
    o.c.close()
    compare(o.c.mode, "NORMAL")
    verify(!tagPicker(o).visible)
    compare(writes(o.svc).length, 0)
  }

  function test_palette_opens_a_picker() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, ":", 0x3a)
    compare(o.c.mode, "COMMAND")
    var pal = findWith(winOf(o.c).contentItem, "complete")
    pal.setQuery("Edit tags")
    enter(o)
    compare(o.c.mode, "PICKER")
    verify(tagPicker(o).visible)
    compare(tagPicker(o).counterText, "1 torrent")
  }
  // ---- slice 5b0 (Task 1): pins for the view-host refactor ----------------------------------
  // Picker precedence (Settings, then Search, then C/T) and how a click on
  // the scrim or a row ends each of the torrents' pickers.

  function cmdsOf(o) {
    return o.c.commands
  }
  function choiceItem(picker, title) {
    return (function find(obj) {
      if (!obj) return null
      if (obj.isRow === true && obj.modelData && String(obj.modelData.title) === title) return obj
      var kids = obj.children || []
      for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) return r }
      return null
    })(picker)
  }

  function test_5b0_openPicker_names_the_C_or_T_picker_by_its_kind_and_closePicker_clears_it() {
    var o = make()
    var cc = cmdsOf(o)
    compare(cc.openPicker(), null, "nothing open")
    onRow(o, hh("a"))
    key(o.c, "C")
    compare(cc.pickerKind, "category")
    compare(cc.pickerTargets, [hh("a")])
    verify(cc.openPicker() === cc.categoryPicker)
    compare(cc.pickerFlags().multi, false)
    cc.closePicker()
    compare(cc.pickerKind, "")
    compare(cc.pickerTargets.length, 0)
    compare(cc.openPicker(), null)
    compare(o.c.mode, "NORMAL")
    verify(!catPicker(o).visible)
    key(o.c, "T")
    compare(cc.pickerKind, "tag")
    verify(cc.openPicker() === cc.tagPicker)
    compare(cc.pickerFlags().multi, true)
    compare(cc.pickerFlags().queryEmpty, true)
    esc(o)
    compare(cc.openPicker(), null)
    compare(cc.pickerFlags(), null, "flags only in PICKER")
  }

  function test_5b0_a_click_on_the_scrim_closes_the_category_picker_and_writes_nothing() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    compare(o.c.mode, "PICKER")
    wait(30)
    mouseClick(catPicker(o), 4, 4)
    compare(o.c.mode, "NORMAL")
    verify(!catPicker(o).visible)
    compare(cmdsOf(o).pickerKind, "")
    compare(writes(o.svc).length, 0)
    compare(o.c.confirm, null)
  }

  function test_5b0_a_click_on_the_scrim_closes_the_tag_picker_and_writes_nothing() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "T")
    space(o)
    wait(30)
    mouseClick(tagPicker(o), 4, 4)
    compare(o.c.mode, "NORMAL")
    verify(!tagPicker(o).visible)
    compare(cmdsOf(o).pickerKind, "")
    compare(writes(o.svc).length, 0)
  }

  function test_5b0_a_click_on_a_category_row_picks_it() {
    var o = make()
    onRow(o, hh("d"))
    key(o.c, "C")
    wait(30)
    var item = choiceItem(catPicker(o), "anime/2026")
    verify(item !== null, "the row is on screen")
    mouseClick(item)
    compare(o.c.mode, "NORMAL")
    verify(!catPicker(o).visible)
    var call = lastCall(o.svc, "setCategory")
    compare(call.args[0], hh("d"))
    compare(call.args[1], "anime/2026")
  }

  function test_5b0_a_click_on_a_tag_row_toggles_it_and_the_picker_stays_open() {
    var o = make()
    onRow(o, hh("a"))
    key(o.c, "T")
    wait(30)
    var p = tagPicker(o)
    compare(marks(p), ["[x] seedbox"])
    var item = choiceItem(p, "seedbox")
    verify(item !== null, "the row is on screen")
    mouseClick(item)
    compare(o.c.mode, "PICKER")
    compare(marks(p), ["[ ] seedbox"])
    compare(writes(o.svc).length, 0)
    enter(o)
    compare(o.c.mode, "NORMAL")
    var call = lastCall(o.svc, "editTags")
    compare(call.args[1].remove, ["seedbox"])
  }
}
