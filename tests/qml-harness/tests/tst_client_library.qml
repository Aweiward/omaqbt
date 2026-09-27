import QtQuick
import QtTest
import "../../.."

// The filters pane's category and tag keys a/c/p/x (slice 3a, Task 5). A
// service stub of its own, with the status fields the move prediction reads
// (categoryPaths, defaultSavePath, relocation, rows' autoTmm), homeDir and
// the library helpers, recording their arguments; tst_client.qml stays as
// it is.
TestCase {
  id: tc
  name: "ClientLibrary"
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
    return svc.calls.filter(function(x) { return ["addCategory", "setCategoryPath", "removeCategory", "renameCategory", "addTag", "removeTag", "renameTag"].indexOf(x.name) !== -1 })
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

  // ---- a -------------------------------------------------------------------------

  function test_a_on_categories_creates_a_category() {
    var o = make()
    on(o, "category", "")
    key(o.c, "a")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "categoryAdd")
    compare(prompt(o), "New category")
    type(o, "linux-isos")
    enter(o)
    compare(o.c.mode, "NORMAL")
    var call = lastCall(o.svc, "addCategory")
    verify(call !== null)
    compare(call.args[0], "linux-isos")
    compare(call.args[1], "", "no save path: qBittorrent's default")
    compare(call.args[2].origin, "window")
    compare(o.c.messageLine.text, "Adding category…")
    finish(o, true)
    compare(o.c.messageLine.text, "Category added")
    compare(o.c.filterCursor.group, "category")
    compare(o.c.filterCursor.value, "linux-isos", "the cursor goes to the new row")
  }

  function test_a_on_a_tag_row_creates_a_tag() {
    var o = make()
    on(o, "tag", "seedbox")
    key(o.c, "a")
    compare(o.c.inputPurpose, "tagAdd")
    compare(prompt(o), "New tag")
    type(o, "keep")
    enter(o)
    compare(lastCall(o.svc, "addTag").args[0], "keep")
    compare(lastCall(o.svc, "addCategory"), null)
    finish(o, true)
    compare(o.c.messageLine.text, "Tag added")
  }

  function test_a_refusals_stay_in_insert_with_the_text() {
    var o = make()
    on(o, "category", "anime")
    key(o.c, "a")
    var cases = [
      ["", "Type a name."],
      [" anime2", "No spaces at the start or end."],
      ["anime2 ", "No spaces at the start or end."],
      ["a//b", "No // in a category."],
      ["/x", "A category can't start or end with /."],
      ["x".repeat(65), "Keep it to 64 characters."],
      ["anime", "\"anime\" already exists."]
    ]
    for (var i = 0; i < cases.length; i++) {
      type(o, cases[i][0])
      enter(o)
      compare(o.c.mode, "INSERT", cases[i][0])
      compare(o.c.inputPurpose, "categoryAdd")
      compare(o.c.messageLine.text, cases[i][1], cases[i][0])
      compare(line(o.c).inputValue(), cases[i][0], "the text stays as typed")
      verify(insertMessage(o).visible)
    }
    compare(writes(o.svc).length, 0)
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.inputPurpose, "")
    // tags: no commas, and a clash with an existing tag
    on(o, "tag", "")
    key(o.c, "a")
    type(o, "a,b"); enter(o)
    compare(o.c.messageLine.text, "No commas in a tag.")
    type(o, "seedbox"); enter(o)
    compare(o.c.messageLine.text, "\"seedbox\" already exists.")
    compare(writes(o.svc).length, 0)
  }

  // ---- the ready gate (BM) ------------------------------------------------------

  function test_category_writes_wait_for_the_folders_tag_writes_do_not() {
    var o = make({ defaultSavePath: "" })
    on(o, "category", "anime")
    var keys = ["a", "c", "p", "x"]
    for (var i = 0; i < keys.length; i++) {
      key(o.c, keys[i])
      compare(o.c.mode, "NORMAL", keys[i])
      compare(o.c.confirm, null, keys[i])
      compare(o.c.messageLine.text, notReady, keys[i])
    }
    on(o, "category", "")
    key(o.c, "a")
    compare(o.c.mode, "NORMAL")
    compare(o.c.messageLine.text, notReady)
    compare(writes(o.svc).length, 0)
    // tags don't wait
    on(o, "tag", "seedbox")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    key(o.c, "n")
    key(o.c, "c")
    compare(o.c.mode, "INSERT")
    esc(o)
    // the folders arrive: the refusal clears
    o.svc.defaultSavePath = "/dl"
    on(o, "category", "anime")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    key(o.c, "n")
    key(o.c, "p")
    compare(o.c.mode, "INSERT")
    esc(o)
  }

  // ---- c ---------------------------------------------------------------------------

  function test_c_renames_directly_when_nothing_moves_or_merges() {
    var o = make()
    on(o, "tag", "seedbox")
    o.c.applyFilter({ group: "tag", value: "seedbox" })
    on(o, "tag", "seedbox")
    key(o.c, "c")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "tagRename")
    compare(prompt(o), "Rename seedbox to")
    compare(line(o.c).inputValue(), "seedbox", "prefilled with the old name")
    type(o, "seeds")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    var call = lastCall(o.svc, "renameTag")
    compare(call.args[0], "seedbox")
    compare(call.args[1], "seeds")
    compare(call.args[2], false, "no --merge")
    compare(call.args[3].origin, "window")
    compare(o.c.messageLine.text, "Renaming seedbox → seeds…")
    finish(o, true)
    compare(o.c.messageLine.text, "Renamed seedbox → seeds")
    // OV9: the filter and the filters cursor follow, and view.json saves
    compare(o.c.filter.group, "tag")
    compare(o.c.filter.value, "seeds")
    compare(o.c.filterCursor.value, "seeds")
    compare(o.svc.saved[o.svc.saved.length - 1].filter.value, "seeds")
  }

  function test_c_category_rename_with_relocation_off_runs_directly() {
    var o = make()
    on(o, "category", "anime/2026")
    key(o.c, "c")
    compare(prompt(o), "Rename anime/2026 to")
    type(o, "films")
    enter(o)
    compare(o.c.confirm, null, "torrent_changed_tmm_enabled off: nothing moves")
    compare(lastCall(o.svc, "renameCategory").args[1], "films")
    compare(lastCall(o.svc, "renameCategory").args[2], false)
  }

  function test_c_same_name_is_a_no_op() {
    var o = make()
    on(o, "category", "anime/2026")
    key(o.c, "c")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    compare(writes(o.svc).length, 0)
  }

  function test_c_merge_raises_one_confirm_then_merges() {
    var o = make({ categories: ["anime", "anime/2026", "animation"] })
    on(o, "category", "anime/2026")
    key(o.c, "c")
    type(o, "animation")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "animation already exists. Move 1 torrent into it and delete anime/2026?")
    compare(o.c.confirm.accept, "merge")
    compare(writes(o.svc).length, 0, "nothing before y")
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
    key(o.c, "c")
    type(o, "animation")
    enter(o)
    key(o.c, "y")
    compare(o.c.mode, "NORMAL")
    var call = lastCall(o.svc, "renameCategory")
    compare(call.args[0], "anime/2026")
    compare(call.args[1], "animation")
    compare(call.args[2], true, "--merge only after y")
    compare(writes(o.svc).length, 1)
  }

  function test_c_move_and_merge_fold_into_one_confirm() {
    // anime's two auto-managed torrents live at /dl/anime; renaming moves
    // them to /dl/animation (animation has an empty save path).
    var o = make({ relocation: { torrentChanged: true, categoryPathChanged: false }, categories: ["anime", "animation"] })
    o.svc.torrents = library().slice(0, 2).concat([tt(hh("d"), "delta")])
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "animation")
    enter(o)
    // Final fix wave (ruling BR): the fixture's torrents are unfinished (progress 0.5).
    compare(confirmText(o), "animation already exists. Move 2 torrents into it and delete anime? Their files move to /dl/animation; unfinished ones may go to their download folder instead.")
    key(o.c, "y")
    compare(o.c.mode, "NORMAL", "one confirm, not two")
    compare(lastCall(o.svc, "renameCategory").args[2], true)
    // a plain rename that moves files still confirms, naming the folder
    o.svc.categories = ["anime"]
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "shows")
    enter(o)
    compare(confirmText(o), "Rename anime to shows? Their files move to /dl/shows; unfinished ones may go to their download folder instead.")
    compare(o.c.confirm.accept, "rename")
    key(o.c, "y")
    compare(lastCall(o.svc, "renameCategory").args[1], "shows")
    compare(lastCall(o.svc, "renameCategory").args[2], false)
    // an explicit path is kept by the rename: a finished torrent doesn't
    // move, no confirm (final fix wave, ruling BR: progress 1 here)
    o.svc.categoryPaths = { anime: { savePath: "/srv/anime", downloadPath: "" } }
    o.svc.torrents = [tt(hh("a"), "alpha", { category: "anime", autoTmm: true, savePath: "/srv/anime", progress: 1, state: "uploading" })]
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "series")
    enter(o)
    compare(o.c.confirm, null)
    compare(lastCall(o.svc, "renameCategory").args[1], "series")
    // ...but an unfinished one may move to its download folder: confirm (BR)
    var renames = calls(o.svc, "renameCategory").length
    o.svc.torrents = [tt(hh("a"), "alpha", { category: "anime", autoTmm: true, savePath: "/srv/anime" })]
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "series")
    enter(o)
    compare(confirmText(o), "Rename anime to series? 1 unfinished torrent's files may move to its download folder.")
    compare(calls(o.svc, "renameCategory").length, renames, "nothing before y")
  }

  function test_c_counts_every_torrent_not_the_filtered_table() {
    var o = make({ categories: ["anime", "animation"] })
    o.c.applyFilter({ group: "status", value: "Seeding" })
    compare(o.c.tableRows.length, 0, "the table shows none of them")
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "animation")
    enter(o)
    compare(confirmText(o), "animation already exists. Move 2 torrents into it and delete anime?")
  }

  function test_c_refusals_stay_in_insert() {
    var o = make({ categories: ["anime", "anime/2026", "x"] })
    on(o, "category", "anime")
    key(o.c, "c")
    type(o, "shows")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.messageLine.text, "anime has subcategories; rename or remove them first.")
    type(o, "a//b")
    enter(o)
    compare(o.c.messageLine.text, "No // in a category.", "nameError first")
    esc(o)
    on(o, "category", "x")
    key(o.c, "c")
    type(o, "x/y")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.messageLine.text, "Can't rename x into its own subcategory.")
    type(o, "")
    enter(o)
    compare(o.c.messageLine.text, "Type a name.")
    compare(writes(o.svc).length, 0)
    compare(o.c.confirm, null)
  }

  function test_c_failure_shows_qbt_message_and_leaves_the_filter() {
    var o = make()
    o.c.applyFilter({ group: "category", value: "anime/2026" })
    on(o, "category", "anime/2026")
    key(o.c, "c")
    type(o, "films")
    enter(o)
    var inc = "Rename incomplete (0 of 1 moved); press c on anime/2026 again to finish."
    finish(o, false, inc)
    compare(o.c.messageLine.text, inc)
    compare(o.c.messageLine.tone, "urgent")
    compare(o.c.filter.value, "anime/2026", "a failed rename doesn't move the filter")
    // another action's ticket never moves it either
    o.svc.actionFinished(o.svc.seq + 5, true, "", "window", [])
    compare(o.c.filter.value, "anime/2026")
  }

  function test_c_target_is_the_row_when_c_was_pressed() {
    var o = make()
    on(o, "category", "anime/2026")
    key(o.c, "c")
    o.c.setFilterCursor({ group: "tag", value: "seedbox" })
    type(o, "films")
    enter(o)
    compare(lastCall(o.svc, "renameCategory").args[0], "anime/2026")
    compare(lastCall(o.svc, "renameTag"), null)
  }

  // ---- p ---------------------------------------------------------------------------

  function test_p_prefills_the_explicit_path_and_sets_it() {
    var o = make({ categoryPaths: { anime: { savePath: "/srv/anime", downloadPath: "" } } })
    on(o, "category", "anime")
    key(o.c, "p")
    compare(o.c.inputPurpose, "categoryPath")
    compare(prompt(o), "Save path for anime")
    compare(line(o.c).inputValue(), "/srv/anime")
    type(o, "")
    enter(o)
    compare(o.c.confirm, null, "category_changed_tmm_enabled off: nothing moves")
    var call = lastCall(o.svc, "setCategoryPath")
    compare(call.args[0], "anime")
    compare(call.args[1], "", "empty = qBittorrent's default")
    compare(call.args[2].origin, "window")
    compare(o.c.messageLine.text, "Setting anime's save path…")
    finish(o, true)
    compare(o.c.messageLine.text, "Save path set")
    // an empty-path category opens empty
    on(o, "category", "anime/2026")
    key(o.c, "p")
    compare(line(o.c).inputValue(), "")
    esc(o)
  }

  function test_p_refuses_a_relative_path() {
    var o = make()
    on(o, "category", "anime")
    key(o.c, "p")
    type(o, "media/anime")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.messageLine.text, "The save path must be absolute or start with ~/.")
    compare(writes(o.svc).length, 0)
  }

  function test_p_confirms_the_move_with_home_expanded() {
    var o = make({ relocation: { torrentChanged: false, categoryPathChanged: true } })
    on(o, "category", "anime")
    key(o.c, "p")
    type(o, "~/media")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "Change anime's save path? 2 torrents' files move to /home/u/media.")
    compare(o.c.confirm.accept, "change")
    compare(writes(o.svc).length, 0)
    key(o.c, "y")
    var call = lastCall(o.svc, "setCategoryPath")
    compare(call.args[0], "anime")
    compare(call.args[1], "~/media", "qbt expands ~/ itself")
    // the same folder: nothing moves, no confirm
    on(o, "category", "anime")
    key(o.c, "p")
    type(o, "/dl/anime")
    enter(o)
    compare(o.c.confirm, null)
    compare(lastCall(o.svc, "setCategoryPath").args[1], "/dl/anime")
  }

  function test_p_is_blocked_on_a_tag() {
    var o = make()
    on(o, "tag", "seedbox")
    key(o.c, "p")
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
  }

  // ---- x ---------------------------------------------------------------------------

  function test_x_deletes_a_category_after_its_confirm_and_the_filter_follows() {
    var o = make()
    o.c.applyFilter({ group: "category", value: "anime" })
    on(o, "category", "anime")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "Delete category anime? 3 torrents become Uncategorized. It also deletes its 1 subcategory.")
    compare(o.c.confirm.accept, "delete")
    key(o.c, "n")
    compare(writes(o.svc).length, 0)
    key(o.c, "x")
    // the cursor moves while the question is up: y still deletes anime
    o.c.setFilterCursor({ group: "tag", value: "seedbox" })
    key(o.c, "y")
    var call = lastCall(o.svc, "removeCategory")
    compare(call.args[0], "anime")
    compare(call.args[1].origin, "window")
    compare(lastCall(o.svc, "removeTag"), null)
    compare(o.c.messageLine.text, "Deleting category anime…")
    finish(o, true)
    compare(o.c.messageLine.text, "Deleted category anime")
    compare(o.c.filter.group, "category")
    compare(o.c.filter.value, "", "Uncategorized")
    compare(o.svc.saved[o.svc.saved.length - 1].filter.value, "")
  }

  function test_x_nested_category_moves_torrents_and_filter_to_the_parent() {
    var o = make({ relocation: { torrentChanged: true, categoryPathChanged: false } })
    o.c.applyFilter({ group: "category", value: "anime/2026" })
    on(o, "category", "anime/2026")
    key(o.c, "x")
    // Final fix wave (ruling BR): gamma is unfinished (progress 0.5).
    compare(confirmText(o), "Delete category anime/2026? 1 torrent moves to anime. Its files move to /dl/anime; unfinished ones may go to their download folder instead.")
    key(o.c, "y")
    compare(lastCall(o.svc, "removeCategory").args[0], "anime/2026")
    finish(o, true)
    compare(o.c.filter.value, "anime", "the parent, not Uncategorized")
    compare(o.c.filterCursor.value, "anime")
  }

  function test_x_top_level_move_names_the_default_folder() {
    var o = make({ relocation: { torrentChanged: true, categoryPathChanged: false }, categories: ["anime"] })
    o.svc.torrents = library().slice(0, 2)
    on(o, "category", "anime")
    key(o.c, "x")
    // Final fix wave (ruling BR): alpha and beta are unfinished (progress 0.5).
    compare(confirmText(o), "Delete category anime? 2 torrents become Uncategorized. Their files move to /dl; unfinished ones may go to their download folder instead.")
  }

  function test_x_unused_category_still_confirms() {
    var o = make({ categories: ["anime", "anime/2026", "empty"] })
    on(o, "category", "empty")
    key(o.c, "x")
    compare(confirmText(o), "Delete category empty? No torrents use it.")
  }

  function test_x_deletes_a_tag_and_the_filter_goes_to_untagged() {
    var o = make()
    o.c.applyFilter({ group: "tag", value: "seedbox" })
    on(o, "tag", "seedbox")
    key(o.c, "x")
    compare(confirmText(o), "Delete tag seedbox? It's removed from 1 torrent.")
    key(o.c, "y")
    compare(lastCall(o.svc, "removeTag").args[0], "seedbox")
    compare(lastCall(o.svc, "removeCategory"), null)
    finish(o, true)
    compare(o.c.messageLine.text, "Deleted tag seedbox")
    compare(o.c.filter.group, "tag")
    compare(o.c.filter.value, "", "Untagged")
    compare(o.c.filterCursor.value, "")
  }

  function test_x_failure_keeps_everything() {
    var o = make()
    o.c.applyFilter({ group: "tag", value: "seedbox" })
    on(o, "tag", "seedbox")
    key(o.c, "x")
    key(o.c, "y")
    finish(o, false, "HTTP 409")
    // Final fix wave (ruling BS, Minor 5): never a bare "HTTP 409".
    compare(o.c.messageLine.text, "Deleting tag seedbox failed: HTTP 409")
    compare(o.c.filter.value, "seedbox")
  }

  function test_uncategorized_and_status_rows_take_no_c_p_x() {
    var o = make()
    on(o, "category", "")
    key(o.c, "c"); key(o.c, "p"); key(o.c, "x")
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    on(o, "status", "All")
    key(o.c, "a"); key(o.c, "c"); key(o.c, "x")
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
  }

  // ---- legacy names (Review Focus 3) ---------------------------------------------

  function test_legacy_names_rename_away_and_delete() {
    var legacy = " old//" + "y".repeat(70)
    var o = make({ categories: ["anime", "anime/2026", legacy], tags: ["seedbox", " spaced"] })
    on(o, "category", legacy)
    key(o.c, "c")
    compare(o.c.mode, "INSERT")
    compare(line(o.c).inputValue(), legacy, "the field shows the legacy name")
    compare(prompt(o), "Rename " + legacy + " to")
    type(o, "clean")
    enter(o)
    var call = lastCall(o.svc, "renameCategory")
    compare(call.args[0], legacy)
    compare(call.args[1], "clean")
    on(o, "category", legacy)
    key(o.c, "x")
    compare(confirmText(o), "Delete category " + legacy + "? No torrents use it.")
    key(o.c, "y")
    compare(lastCall(o.svc, "removeCategory").args[0], legacy)
    on(o, "tag", " spaced")
    key(o.c, "x")
    key(o.c, "y")
    compare(lastCall(o.svc, "removeTag").args[0], " spaced")
  }

  // ---- the pane: footer and empty groups ---------------------------------------

  function footer(o) {
    var fp = filterPane(o.c)
    return (fp.footerKeys || []).map(function(k) { return k.key + " " + k.label }).join(" · ")
  }

  function test_footer_lists_only_the_keys_for_the_cursor_row() {
    var o = make()
    on(o, "category", "anime")
    compare(footer(o), "a add · c rename · p save path · x delete")
    verify(findName(winOf(o.c).contentItem, "filtersFooter").visible)
    on(o, "tag", "seedbox")
    compare(footer(o), "a add · c rename · x delete")
    on(o, "category", "")
    compare(footer(o), "a new category")
    on(o, "status", "All")
    compare(footer(o), "")
    verify(!findName(winOf(o.c).contentItem, "filtersFooter").visible)
    on(o, "category", "anime")
    o.c.setPane("table")
    compare(footer(o), "", "only while the filters pane has the keys")
  }

  function test_empty_groups_show_a_muted_note() {
    var o = make({ categories: [], tags: [] })
    o.svc.torrents = [tt(hh("d"), "delta")]
    var notes = o.c.filterEntries.filter(function(e) { return e.kind === "note" }).map(function(e) { return e.label })
    compare(notes.join("|"), "No categories yet|No tags yet")
    var t = findText(filterPane(o.c), "No categories yet")
    verify(t !== null)
    compare(String(t.color), String(filterPane(o.c).mutedColor))
    verify(findText(filterPane(o.c), "No tags yet") !== null)
    // the cursor skips the notes
    on(o, "category", "")
    key(o.c, "j")
    compare(o.c.filterCursor.group, "tag")
    compare(o.c.filterCursor.value, "")
    compare(footer(o), "a new tag")
  }

  // ---- follow-up only when it applies, and the palette path ---------------------

  function test_success_leaves_an_unrelated_filter_and_view_alone() {
    var o = make()
    o.c.applyFilter({ group: "status", value: "All" })
    on(o, "tag", "seedbox")
    key(o.c, "c")
    type(o, "seeds")
    enter(o)
    var saves = o.svc.saved.length
    finish(o, true)
    compare(o.c.filter.group, "status")
    compare(o.c.filter.value, "All")
    compare(o.svc.saved.length, saves, "nothing to follow: no save")
    compare(o.c.filterCursor.value, "seeds", "the cursor was on the renamed row")
  }

  function test_palette_delete_from_the_filters_pane_builds_the_same_confirm() {
    var o = make()
    on(o, "category", "anime/2026")
    key(o.c, ":")
    compare(o.c.mode, "COMMAND")
    var p = findWith(winOf(o.c).contentItem, "setQuery")
    verify(p !== null)
    var row = null
    for (var i = 0; i < p.rows.length; i++) if (p.rows[i].id === "library.remove") row = p.rows[i]
    verify(row !== null)
    compare(row.enabled, true)
    p.activated(row)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), "Delete category anime/2026? 1 torrent moves to anime.")
    key(o.c, "y")
    compare(lastCall(o.svc, "removeCategory").args[0], "anime/2026")
  }

  // ---- final fix wave: G8 at Enter (ruling BQ) ---------------------------------------

  // The bash fallback after a failed preferences read, and an API-down tick.
  function fallbackTick(o) { o.svc.relocation = { torrentChanged: false, categoryPathChanged: false }; o.svc.defaultSavePath = "" }
  function apiDownTick(o) { o.svc.api = false; o.svc.torrents = [] }

  function test_c_and_p_refuse_at_Enter_when_a_not_ready_tick_lands_after_the_key() {
    var ticks = [fallbackTick, apiDownTick]
    // c on anime/2026 (a rename qbt would take), p on anime
    var starts = [["c", "shows", "anime/2026"], ["p", "/srv/anime", "anime"]]
    for (var i = 0; i < ticks.length; i++) {
      for (var j = 0; j < starts.length; j++) {
        var what = starts[j][0] + " tick " + i
        var o = make({ relocation: { torrentChanged: true, categoryPathChanged: true } })
        on(o, "category", starts[j][2])
        key(o.c, starts[j][0])
        compare(o.c.mode, "INSERT", what)
        type(o, starts[j][1])
        ticks[i](o)
        enter(o)
        compare(o.c.mode, "INSERT", "refused, the field stays open: " + what)
        compare(line(o.c).inputValue(), starts[j][1], what)
        compare(o.c.messageLine.text, notReady, what)
        compare(o.c.confirm, null, what)
        compare(writes(o.svc).length, 0, "no write without a confirm: " + what)
        esc(o)
        compare(writes(o.svc).length, 0, what)
      }
    }
  }

  function test_x_confirm_runs_the_frozen_delete_after_a_not_ready_tick() {
    var o = make({ relocation: { torrentChanged: true, categoryPathChanged: false } })
    on(o, "category", "anime/2026")
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    var shown = confirmText(o)
    verify(shown.indexOf("Its files move to /dl/anime") !== -1, shown)
    fallbackTick(o)
    apiDownTick(o)
    key(o.c, "y")
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 1, "exactly the confirmed write")
    var call = lastCall(o.svc, "removeCategory")
    compare(call.args[0], "anime/2026")
    compare(call.args[1].origin, "window")
  }

  // ---- final fix wave: the empty library's filters pane (BS, Important 4) ---------

  function test_empty_library_filters_pane_takes_its_keys_and_y_still_reads_the_clipboard() {
    var o = make({ categories: [], tags: [] })
    o.svc.torrents = []
    compare(o.c.tableState, "empty")
    on(o, "category", "")
    key(o.c, "a")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "categoryAdd")
    type(o, "linux-isos")
    enter(o)
    compare(lastCall(o.svc, "addCategory").args[0], "linux-isos")
    compare(o.c.pane, "filters")
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 1, "y in the filters pane")
    o.c.setPane("table")
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 2, "and in the table")
    // with rows, an unmatched y in the filters pane does nothing
    o.svc.torrents = library()
    on(o, "category", "")
    key(o.c, "y")
    compare(calls(o.svc, "readClipboard").length, 2)
  }

  // ---- final fix wave: failures name the action (BS, Minor 5) ----------------------

  function test_a_p_x_failures_name_the_action() {
    var o = make()
    on(o, "category", "")
    key(o.c, "a")
    type(o, "fresh")
    enter(o)
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Adding category fresh failed: HTTP 409")
    on(o, "tag", "")
    key(o.c, "a")
    type(o, "keep")
    enter(o)
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Adding tag keep failed: HTTP 409")
    on(o, "category", "anime")
    key(o.c, "p")
    type(o, "/srv/anime")
    enter(o)
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Setting anime's save path failed: HTTP 409")
    on(o, "category", "anime")
    key(o.c, "x")
    key(o.c, "y")
    finish(o, false, "qBittorrent refused it (HTTP 409)")
    compare(o.c.messageLine.text, "Deleting category anime failed: HTTP 409")
    compare(o.c.messageLine.tone, "urgent")
  }
}
