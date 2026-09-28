import QtQuick
import QtTest
import "../../.."

// The Info tab's Limits group (slice 3b, Task 5): the cursor, Enter's
// INSERT with inline parse errors, the D8 share-limit confirm, Space on the
// toggles, and Ruling CJ's Space on a no-metadata torrent. A service stub of
// its own, with the status fields the Limits rows and the confirm read
// (the rows' limits, categoryLimits, shareDefaults, defaultSavePath) and
// the four limit helpers, recording their arguments.
TestCase {
  id: tc
  name: "ClientLimits"
  when: windowShown

  readonly property string notReady: "Still reading qBittorrent's share limits; try again in a moment."

  function hh(c) { var s = ""; for (var i = 0; i < 40; i++) s += c; return s }
  function tt(hash, name, extra) {
    var r = { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl", autoTmm: false,
      dlLimit: 0, upLimit: 0, ratioLimit: -2, seedingTimeLimit: -2, inactiveSeedingTimeLimit: -2, shareLimitAction: "Default",
      seqDl: false, firstLast: false, maxRatio: -1, maxSeedingTime: -1, seedingTime: 0 }
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
      property bool sidecarDown: false
      property string lastError: ""
      property var torrents: []
      property var categories: []
      property var tags: []
      property var categoryPaths: ({})
      property string defaultSavePath: "/dl"
      property var relocation: ({ torrentChanged: false, categoryPathChanged: false })
      property var categoryLimits: ({})
      property var shareDefaults: ({ ratio: -1, seedingTime: -1, action: "Stop" })
      property string homeDir: "/home/u"
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
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal clipboardRead(string text)
      function rec(name, args) { calls.push({ name: name, args: args }); seq++; return seq }
      function saveViewState(s) { saved.push(s); viewState = s }
      function refresh() { calls.push({ name: "refresh", args: [] }) }
      function watch(h, t) { calls.push({ name: "watch", args: [h, t] }) }
      function readClipboard() { rec("readClipboard", []) }
      function filesFor(h) { return [] }
      function loadFiles(h, o) { calls.push({ name: "loadFiles", args: [h, o] }) }
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function setShareLimits(h, l, f, o) { return rec("setShareLimits", [h, l, f, o]) }
      function setSequential(h, on, o) { return rec("setSequential", [h, on, o]) }
      function setFirstLast(h, on, o) { return rec("setFirstLast", [h, on, o]) }
      function setSpeedLimit(h, k, b, o) { return rec("setSpeedLimit", [h, k, b, o]) }
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
  function line(c) { return findWith(winOf(c).contentItem, "setInput") }
  function shows(c, text) { wait(30); return visibleTexts(winOf(c).contentItem).indexOf(text) >= 0 }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function lastCall(svc, name) { var l = calls(svc, name); return l.length ? l[l.length - 1] : null }
  function writes(svc) {
    return svc.calls.filter(function(x) { return ["setShareLimits", "setSequential", "setFirstLast", "setSpeedLimit", "start", "stop"].indexOf(x.name) !== -1 })
  }
  function type(o, text) { line(o.c).setInput(text) }
  function prompt(o) { return findName(winOf(o.c).contentItem, "insertPrompt").text }
  function finish(o, ok, err) { o.svc.actionFinished(o.svc.seq, ok, err || "", "window", []) }

  // alpha (newest, the first cursor row) is downloading; beta seeds.
  function list() {
    return [
      tt(hh("a"), "alpha", { addedOn: 2 }),
      tt(hh("b"), "beta", { addedOn: 1, state: "stalledUP", progress: 1, ratio: 2, seedingTime: 7200 })
    ]
  }

  function make(torrents, extra) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    for (var k in extra || {}) svc[k] = extra[k]
    svc.torrents = torrents || list()
    return { c: c, svc: svc }
  }

  // The inspector focused on Info, on the cursor torrent.
  function onInfo(o) {
    key(o.c, "1")
    if (o.c.pane !== "inspector") key(o.c, "\t", 0x01000001)
    compare(o.c.pane, "inspector")
    compare(o.c.inspectorTab, "info")
  }
  function cursorKey(o) { return o.c.inspectorNow.limitCursorKey }
  // j until the Limits cursor is on rowKey.
  function toRow(o, rowKey) {
    for (var i = 0; i < 6 && cursorKey(o) !== rowKey; i++) key(o.c, "j")
    compare(cursorKey(o), rowKey)
  }
  function cursorFills(o) { wait(30); return visibleNamed(winOf(o.c).contentItem, "limitCursor") }
  function helpTitles(o) {
    key(o.c, "?", 0x3f, 0x02000000)
    var ov = (function find(obj) {
      if (!obj) return null
      if (obj.groups !== undefined && obj.dismissed !== undefined) return obj
      for (var i = 0; i < (obj.children || []).length; i++) { var r = find(obj.children[i]); if (r) return r }
      return null
    })(winOf(o.c).contentItem)
    var out = []
    ov.groups.forEach(function(g) { g.items.forEach(function(i) { out.push(i.keys + "=" + i.title) }) })
    key(o.c, "", 0x01000000)
    return out
  }

  // ---- the group and its cursor --------------------------------------------------

  function test_the_group_sits_between_transfer_and_torrent_with_a_cursor_only_on_focused_info() {
    var o = make()
    key(o.c, "1")
    verify(shows(o.c, "Limits"))
    verify(shows(o.c, "↓ limit"))
    verify(shows(o.c, "unlimited"))
    verify(shows(o.c, "default (none)"))
    verify(shows(o.c, "Sequential"))
    verify(shows(o.c, "First/last"))
    var groups = findWith(winOf(o.c).contentItem, "positionFile").groups.map(function(g) { return g.title })
    compare(groups, ["Transfer", "Limits", "Torrent"])
    // The table has the keys: no cursor, no Limits keys in the footer.
    if (o.c.pane === "inspector") o.c.setPane("table")
    compare(cursorFills(o).length, 0)
    compare(cursorKey(o), null)
    verify(!shows(o.c, "edit"))
    verify(shows(o.c, "open folder"))
    onInfo(o)
    compare(cursorKey(o), "dlLimit", "the first row")
    compare(cursorFills(o).length, 1)
    verify(shows(o.c, "j/k"))
    verify(shows(o.c, "edit"))
    verify(shows(o.c, "open folder"), "the tab's own keys stay")
    // Another tab: no cursor.
    key(o.c, "4")
    compare(cursorKey(o), null)
    key(o.c, "1")
    compare(cursorKey(o), "dlLimit")
  }

  function test_j_k_move_and_clamp_and_the_cursor_is_kept_per_torrent() {
    var o = make()
    onInfo(o)
    compare(o.c.cursorHash, hh("a"))
    key(o.c, "k")
    compare(cursorKey(o), "dlLimit", "clamped at the top")
    key(o.c, "j")
    key(o.c, "j")
    compare(cursorKey(o), "ratioLimit")
    for (var i = 0; i < 8; i++) key(o.c, "j")
    compare(cursorKey(o), "firstLast", "clamped at the bottom")
    key(o.c, "k")
    key(o.c, "k")
    key(o.c, "k")
    compare(cursorKey(o), "ratioLimit")
    compare(o.c.cursorHash, hh("a"), "j/k on Info never move the table")
    // Another torrent starts at the top; coming back finds its own row.
    o.c.setCursor(hh("b"))
    compare(cursorKey(o), "dlLimit")
    key(o.c, "j")
    compare(cursorKey(o), "upLimit")
    o.c.setCursor(hh("a"))
    compare(cursorKey(o), "ratioLimit")
    o.c.setCursor(hh("b"))
    compare(cursorKey(o), "upLimit")
    // A status tick keeps it.
    o.svc.torrents = list()
    compare(cursorKey(o), "upLimit")
  }

  // ---- Enter: every row's edit -------------------------------------------------------

  function test_enter_edits_the_download_and_upload_limits() {
    var o = make()
    onInfo(o)
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "limit:dlLimit")
    compare(prompt(o), "↓ limit for alpha")
    compare(line(o.c).inputValue(), "u", "prefilled with the current value in input form")
    type(o, "500K")
    enter(o)
    compare(o.c.mode, "NORMAL")
    var call = lastCall(o.svc, "setSpeedLimit")
    verify(call !== null)
    compare(call.args[0], hh("a"))
    compare(call.args[1], "dl")
    compare(call.args[2], 512000)
    compare(call.args[3].origin, "window")
    compare(call.args[3].hashes, [hh("a")])
    compare(o.c.messageLine.text, "Setting the ↓ limit…")
    finish(o, true)
    compare(o.c.messageLine.text, "↓ limit set to 500 KiB/s")
    // The status comes back with the new value; ↑ from there.
    o.svc.torrents = [tt(hh("a"), "alpha", { addedOn: 2, dlLimit: 512000 }), list()[1]]
    enter(o)
    compare(line(o.c).inputValue(), "500K")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "setSpeedLimit").length, 1, "Esc sends nothing")
    key(o.c, "j")
    enter(o)
    compare(prompt(o), "↑ limit for alpha")
    type(o, "1.5M")
    enter(o)
    call = lastCall(o.svc, "setSpeedLimit")
    compare(call.args[1], "up")
    compare(call.args[2], 1572864)
    finish(o, true)
    compare(o.c.messageLine.text, "↑ limit set to 1.5 MiB/s")
    key(o.c, "k")
    enter(o)
    type(o, "0")
    enter(o)
    compare(lastCall(o.svc, "setSpeedLimit").args[2], 0)
    finish(o, true)
    compare(o.c.messageLine.text, "↓ limit set to unlimited")
  }

  function test_enter_edits_the_ratio_and_seed_time_without_a_confirm_when_nothing_is_met() {
    var o = make()
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    compare(o.c.inputPurpose, "limit:ratioLimit")
    compare(prompt(o), "Ratio limit for alpha")
    compare(line(o.c).inputValue(), "g")
    type(o, "1.5")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null, "alpha is downloading: nothing is met")
    var call = lastCall(o.svc, "setShareLimits")
    compare(call.args[0], hh("a"))
    compare(call.args[1], { ratio: 1.5 })
    compare(call.args[2], false, "no --force")
    compare(call.args[3].hashes, [hh("a")])
    compare(o.c.messageLine.text, "Setting the ratio limit…")
    finish(o, true)
    compare(o.c.messageLine.text, "Ratio limit set to 1.50 (applies once seeding)")
    key(o.c, "j")
    enter(o)
    compare(prompt(o), "Seed time for alpha")
    compare(line(o.c).inputValue(), "g")
    type(o, "2h")
    enter(o)
    call = lastCall(o.svc, "setShareLimits")
    compare(call.args[1], { seedingTime: 120 })
    compare(call.args[2], false)
    finish(o, true)
    compare(o.c.messageLine.text, "Seed time limit set to 2h (applies once seeding)")
    // g and n.
    enter(o)
    type(o, "n")
    enter(o)
    compare(lastCall(o.svc, "setShareLimits").args[1], { seedingTime: -1 })
    finish(o, true)
    compare(o.c.messageLine.text, "Seed time limit set to none (applies once seeding)")
  }

  function test_every_parse_error_stays_in_insert_with_its_message() {
    var o = make()
    onInfo(o)
    var cases = [
      ["dlLimit", "abc", "Use a number with K or M, or 0."],
      ["dlLimit", "3000M", "Use at most 2047 MiB/s."],
      ["dlLimit", "1.234K", "Use at most 2 decimals."],
      ["dlLimit", "", "Use a number with K or M, or 0."],
      ["upLimit", " 5K", "Use a number with K or M, or 0."],
      ["ratioLimit", "x", "Use a ratio like 1.5, g for default or n for none."],
      ["ratioLimit", "1.234", "Use at most 2 decimals."],
      ["ratioLimit", "9999", "Use at most 9998."],
      ["seedingTimeLimit", "90x", "Use a time like 90m, 2h or 3d, g for default or n for none."],
      ["seedingTimeLimit", "400d", "Use at most 365d."]
    ]
    for (var i = 0; i < cases.length; i++) {
      toRow(o, cases[i][0])
      enter(o)
      type(o, cases[i][1])
      enter(o)
      compare(o.c.mode, "INSERT", cases[i][1])
      compare(o.c.messageLine.text, cases[i][2], cases[i][1])
      compare(o.c.messageLine.tone, "urgent")
      esc(o)
      compare(o.c.mode, "NORMAL")
      key(o.c, "k"); key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    }
    compare(writes(o.svc).length, 0, "nothing sent")
  }

  function test_enter_on_a_toggle_row_does_nothing() {
    var o = make()
    onInfo(o)
    toRow(o, "seqDl")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
  }

  // ---- the D8 confirm ------------------------------------------------------------------

  function test_d8_confirm_names_the_removal_and_y_passes_force() {
    // beta seeds at ratio 2 and removes itself with its files.
    var o = make([tt(hh("b"), "beta", { state: "stalledUP", progress: 1, ratio: 2, seedingTime: 7200, shareLimitAction: "RemoveWithContent" })])
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    type(o, "1")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.line, "Set the ratio limit to 1? 1 torrent already meets it and will be removed with its files.")
    compare(writes(o.svc).length, 0, "nothing sent before y")
    verify(shows(o.c, " set"), "the hint reads y set")
    key(o.c, "y")
    compare(o.c.mode, "NORMAL")
    var call = lastCall(o.svc, "setShareLimits")
    verify(call !== null)
    compare(call.args[0], hh("b"))
    compare(call.args[1], { ratio: 1 })
    compare(call.args[2], true, "--force after y")
    finish(o, true)
    compare(o.c.messageLine.text, "Ratio limit set to 1.00")
  }

  function test_d8_confirm_n_or_esc_sends_nothing() {
    var o = make([tt(hh("b"), "beta", { state: "stalledUP", progress: 1, ratio: 2, seedingTime: 7200, shareLimitAction: "RemoveWithContent" })])
    onInfo(o)
    toRow(o, "seedingTimeLimit")
    enter(o)
    type(o, "90m")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(o.c.confirm.line, "Set the seed time limit to 1h 30m? 1 torrent already meets it and will be removed with its files.")
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    enter(o)
    type(o, "90m")
    enter(o)
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(writes(o.svc).length, 0)
  }

  function test_d8_confirm_resolves_the_category_and_global_chain() {
    // The torrent defers everything: its category removes, the global stops.
    var o = make([tt(hh("b"), "beta", { state: "stalledUP", progress: 1, ratio: 2, seedingTime: 7200, category: "anime/2026" })], {
      categoryLimits: { anime: { ratioLimit: -2, seedingTimeLimit: -2, shareLimitAction: "Remove" } },
      shareDefaults: { ratio: 1, seedingTime: -1, action: "Stop" }
    })
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    type(o, "g")
    enter(o)
    compare(o.c.mode, "CONFIRM", "-2 resolves to the global 1, already met")
    compare(o.c.confirm.line, "Set the ratio limit to default? 1 torrent already meets it and will be removed.")
    key(o.c, "y")
    compare(lastCall(o.svc, "setShareLimits").args[1], { ratio: -2 })
    compare(lastCall(o.svc, "setShareLimits").args[2], true)
    // A Stop-only outcome confirms without --force.
    o.svc.categoryLimits = ({})
    enter(o)
    type(o, "1.5")
    enter(o)
    compare(o.c.confirm.line, "Set the ratio limit to 1.5? 1 torrent already meets it and will be stopped.")
    key(o.c, "y")
    compare(lastCall(o.svc, "setShareLimits").args[2], false)
  }

  function test_the_target_is_captured_at_key_time() {
    var o = make()
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    // The cursor moves to beta while INSERT is open (a status tick, a click).
    o.c.setCursor(hh("b"))
    type(o, "3")
    enter(o)
    compare(lastCall(o.svc, "setShareLimits").args[0], hh("a"), "alpha, the torrent Enter was pressed on")
    // A CONFIRM keeps its frozen args too.
    o.svc.torrents = [tt(hh("a"), "alpha", { addedOn: 2 }), tt(hh("b"), "beta", { addedOn: 1, state: "stalledUP", progress: 1, ratio: 2, shareLimitAction: "Remove" })]
    compare(o.c.cursorHash, hh("b"))
    compare(cursorKey(o), "dlLimit")
    toRow(o, "ratioLimit")
    enter(o)
    type(o, "0.5")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    o.c.setCursor(hh("a"))
    key(o.c, "y")
    var call = lastCall(o.svc, "setShareLimits")
    compare(call.args[0], hh("b"))
    compare(call.args[1], { ratio: 0.5 })
    compare(call.args[2], true)
  }

  // ---- readiness (Ruling CG) -------------------------------------------------------------

  function test_share_limit_edits_wait_for_the_preferences_at_the_key_and_at_enter() {
    var o = make(null, { defaultSavePath: "" })
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(o.c.messageLine.text, notReady)
    key(o.c, "j")
    enter(o)
    compare(o.c.messageLine.text, notReady)
    compare(o.c.mode, "NORMAL")
    // Speeds need no gate.
    key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    enter(o)
    compare(o.c.mode, "INSERT")
    esc(o)
    // Ready at the key, not at Enter.
    o.svc.defaultSavePath = "/dl"
    toRow(o, "ratioLimit")
    enter(o)
    compare(o.c.mode, "INSERT")
    type(o, "2")
    o.svc.api = false
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.messageLine.text, notReady)
    o.svc.api = true
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(lastCall(o.svc, "setShareLimits").args[1], { ratio: 2 })
  }

  // ---- failures ------------------------------------------------------------------------------

  function test_a_failure_names_the_action_and_qbts_guard_refusal_shows_as_is() {
    var o = make()
    onInfo(o)
    toRow(o, "ratioLimit")
    enter(o)
    type(o, "2")
    enter(o)
    finish(o, false, "qBittorrent refused it (HTTP 409)\n")
    compare(o.c.messageLine.text, "Setting the ratio limit failed: HTTP 409")
    compare(o.c.messageLine.tone, "urgent")
    verify(calls(o.svc, "refresh").length > 0, "a failure refreshes, so what did change shows")
    enter(o)
    type(o, "2")
    enter(o)
    finish(o, false, "1 torrent already meets that limit, and qBittorrent would remove it with its files.")
    compare(o.c.messageLine.text, "1 torrent already meets that limit, and qBittorrent would remove it with its files.")
    key(o.c, "k"); key(o.c, "k")
    enter(o)
    type(o, "5K")
    enter(o)
    finish(o, false, "Couldn't reach qBittorrent.")
    compare(o.c.messageLine.text, "Setting the ↓ limit failed: Couldn't reach qBittorrent.")
    toRow(o, "seqDl")
    space(o)
    finish(o, false, "qBittorrent refused it (HTTP 403)")
    compare(o.c.messageLine.text, "Setting sequential download failed: HTTP 403")
  }

  // ---- Space on the toggles ----------------------------------------------------------------

  function test_space_sends_the_shown_toggle_value_negated() {
    var o = make([tt(hh("a"), "alpha", { firstLast: true })])
    onInfo(o)
    space(o)
    compare(writes(o.svc).length, 0, "Space on a value row does nothing")
    compare(o.c.messageLine.text, "", "and says nothing")
    toRow(o, "seqDl")
    verify(shows(o.c, "turn on"))
    space(o)
    var call = lastCall(o.svc, "setSequential")
    verify(call !== null)
    compare(call.args[0], hh("a"))
    compare(call.args[1], true)
    compare(call.args[2].origin, "window")
    compare(o.c.confirm, null, "no confirm")
    finish(o, true)
    compare(o.c.messageLine.text, "Sequential download on")
    key(o.c, "j")
    verify(shows(o.c, "turn off"))
    space(o)
    call = lastCall(o.svc, "setFirstLast")
    compare(call.args[1], false)
    finish(o, true)
    compare(o.c.messageLine.text, "First and last pieces first off")
    compare(calls(o.svc, "start").length + calls(o.svc, "stop").length, 0, "Space never pauses from the inspector")
  }

  function test_a_double_space_before_the_status_refreshes_converges() {
    var o = make()
    onInfo(o)
    toRow(o, "seqDl")
    space(o)
    space(o)
    var sent = calls(o.svc, "setSequential")
    compare(sent.length, 2)
    compare(sent[0].args[1], true)
    compare(sent[1].args[1], true, "both send on: the status still shows off, and qbt's on is idempotent")
    // The status catches up: the row shows on, and the next Space sends off.
    o.svc.torrents = [tt(hh("a"), "alpha", { addedOn: 2, seqDl: true }), list()[1]]
    verify(shows(o.c, "turn off"))
    space(o)
    compare(lastCall(o.svc, "setSequential").args[1], false)
  }

  // ---- a no-metadata torrent (Ruling CJ) ---------------------------------------------------

  function test_no_metadata_space_starts_on_a_value_row_and_toggles_on_a_toggle_row() {
    var o = make([tt(hh("a"), "magnet", { size: 0, state: "stoppedDL", progress: 0 })])
    onInfo(o)
    verify(shows(o.c, "Start download"))
    verify(helpTitles(o).indexOf("Space=Start download") !== -1)
    compare(cursorKey(o), "dlLimit")
    space(o)
    compare(calls(o.svc, "start").length, 1, "a value row: Start download")
    compare(calls(o.svc, "start")[0].args[0], hh("a"))
    toRow(o, "seqDl")
    verify(!shows(o.c, "Start download"), "Space flips the toggle here")
    verify(shows(o.c, "turn on"))
    verify(shows(o.c, "Fetch metadata only"))
    var help = helpTitles(o)
    verify(help.indexOf("Space=Toggle limit") !== -1, help.join("|"))
    verify(help.indexOf("Space=Start download") === -1)
    space(o)
    compare(calls(o.svc, "start").length, 1, "no start")
    compare(lastCall(o.svc, "setSequential").args[1], true)
    // Off the Limits cursor (the table pane): no Limits keys.
    o.c.setPane("table")
    verify(!shows(o.c, "turn on"))
    verify(shows(o.c, "Start download"))
  }
}
