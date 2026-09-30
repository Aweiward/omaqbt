import QtQuick
import QtTest
import "../../.."
import "../../../ClientView.js" as View
import "../../../RssRules.js" as RR
import "../../../LinkRules.js" as Links

// Slice 5b2 (Task 3): the RSS rules area through the Client, against a stub
// Service with scripted `qbt rss rules`, rule-check and rule-preview
// answers (a test answers each read's callback) and a log of every call
// (a test ends each write with rssFinished). Keys only, as a user would
// press them; a few reads of the rules area's state where the screen can't
// say it more directly. Every sentence is the case file's, through
// RssRules' WINDOW and SENTENCES (tests/rss-rules.test.js checks those
// against tests/fixtures/rss-autorules-cases.json). The second TestCase
// pins Service's rules calls on the one `qbt rss` lane.
Item {
  id: root
  width: 10
  height: 10

TestCase {
  id: tc
  name: "ClientRssRules"
  when: windowShown

  readonly property var w: RR.WINDOW
  readonly property var s: RR.SENTENCES
  function fill(t, v) { return Links.fill(t, v) }

  readonly property string archUrl: "https://archlinux.org/feeds/news/"
  readonly property string debUrl: "https://www.debian.org/News/news"
  readonly property string newsUrl: "https://news.example/rss"
  readonly property string goneUrl: "https://gone.example/rss"

  function hh(c) { var x = ""; for (var i = 0; i < 40; i++) x += c; return x }
  function tt(hash, name) {
    return { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
  }

  // The feeds: Feeds rows 0 Unread, 1 All articles, 2 Distros, 3 Arch,
  // 4 Debian, 5 News.
  function feedObj(path, url) {
    var segs = path.split("\\")
    return { path: path, name: segs[segs.length - 1], depth: segs.length - 1, folder: false, url: url, title: "", isLoading: false, hasError: false,
      unread: 0, total: 0 }
  }
  function items() {
    return { processing: true, refreshInterval: 30, articles: [],
      feeds: [{ path: "Distros", name: "Distros", depth: 0, folder: true, unread: 0, total: 0, feeds: 2 },
        feedObj("Distros\\Arch", archUrl), feedObj("Distros\\Debian", debUrl), feedObj("News", newsUrl)] }
  }

  // The rules (`qbt rss rules`): rows 0 Arch ISO (off), 1 Debian (on), 2 Zed
  // (off, one feed gone). o.auto: auto-download on; o.set: per-name field
  // overrides; o.drop: names left out.
  function fields(extra) {
    var f = { enabled: false, mustContain: "", mustNotContain: "", useRegex: false, episodeFilter: "", smartFilter: false, affectedFeeds: [],
      category: "", savePath: "", addStopped: "default", ignoreDays: 0 }
    for (var k in extra || {}) f[k] = extra[k]
    return f
  }
  function rulesFx(opts) {
    var o = opts || {}
    var base = [
      { name: "Arch ISO", f: { mustContain: "Arch", affectedFeeds: [archUrl] }, raw: { torrentParams: { use_auto_tmm: true } } },
      { name: "Debian", f: { enabled: true, affectedFeeds: [debUrl] }, raw: {} },
      { name: "Zed", f: { affectedFeeds: [archUrl, goneUrl] }, raw: {} }
    ]
    var out = []
    for (var i = 0; i < base.length; i++) {
      var b = base[i]
      if (o.drop && o.drop.indexOf(b.name) !== -1) continue
      var f = fields(b.f)
      var more = o.set && o.set[b.name] ? o.set[b.name] : {}
      for (var k in more) f[k] = more[k]
      out.push({ name: b.name, enabled: f.enabled, fields: f, raw: b.raw })
    }
    for (var j = 0; j < (o.add || []).length; j++) out.push(o.add[j])
    return { autoDownload: o.auto === true, rules: out }
  }
  function preview(will, noTorrent, read, unp) {
    function arts(list) { return (list || []).map(function(t, i) { return typeof t === "string" ? { feedPath: "Distros\\Arch", guid: "g" + i + t, title: t, dup: 1 } : t }) }
    return { will: arts(will), noTorrent: arts(noTorrent), read: arts(read), unpreviewable: unp || [], gone: [] }
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
      property var cbs: ({})
      property int seq: 0
      signal actionFinished(int ticket, bool ok, string error, string origin, var hashes)
      signal secretFinished(int ticket, bool ok, string error)
      signal clipboardRead(string text)
      signal rssFinished(int ticket, bool ok, string error, var data)
      function rec(name, args) { seq++; calls.push({ name: name, args: args, ticket: seq }); return seq }
      function read(name, args, cb) { var t = rec(name, args); cbs[String(t)] = cb; return t }
      function saveViewState(s) { viewState = s }
      function refresh() {}
      function refreshSlow() {}
      function watch(h, t) {}
      function readClipboard() {}
      function filesFor(h) { return [] }
      function loadFiles(h, o) {}
      function loadMagnetSnapshot() {}
      function openUrl(u) { rec("openUrl", [u]); return true }
      function setPref(k, v, o) { return rec("setPref", [k, v]) }
      function readPrefs(cb) { rec("readPrefs", []) }
      function rssItems(cb) { return read("rssItems", [], cb) }
      function rssArticle(p, g, cb) { return read("rssArticle", [p, g], cb) }
      function rssError(u, cb) { return read("rssError", [u], cb) }
      function rssRules(cb) { return read("rssRules", [], cb) }
      function rssRuleCheck(k, v, r, cb) { return read("rssRuleCheck", [k, v, r], cb) }
      function rssRulePreview(n, cb) { return read("rssRulePreview", [n], cb) }
      function rssRuleCreate(n, u) { return rec("rssRuleCreate", [n, u]) }
      function rssRuleSet(n, c, s, e) { return rec("rssRuleSet", [n, c, s, e]) }
      function rssRuleRename(f, t) { return rec("rssRuleRename", [f, t]) }
      function rssRuleRemove(n) { return rec("rssRuleRemove", [n]) }
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
  function space(o) { key(o.c, " ", 0x20) }
  function shifted(o, ch) { key(o.c, ch, ch.charCodeAt(0), 0x02000000) }
  function j(o, n) { for (var i = 0; i < (n || 1); i++) key(o.c, "j") }
  // In PICKER the field types j and k; the arrows move.
  function down(o) { key(o.c, "", 0x01000015) }
  function up(o) { key(o.c, "", 0x01000013) }
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
  function rp(o) { return findName(content(o), "rssView") }
  function rr(o) { return findName(content(o), "rssRulesView") }
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
  function paneShown(o, name) { var p = findName(content(o), name); return !!p && p.visible && !p.swappedOut }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function last(svc, name) { var l = calls(svc, name); return l.length > 0 ? l[l.length - 1] : null }
  function finishCall(o, name, ok, err, data) {
    var c = last(o.svc, name)
    verify(c !== null, name + " was called")
    o.svc.rssFinished(c.ticket, ok, err || "", data === undefined ? null : data)
  }
  function answer(o, name, ok, err, data) {
    var c = last(o.svc, name)
    verify(c !== null, name + " was called")
    answerCall(o, c, ok, err, data)
  }
  function answerCall(o, c, ok, err, data) {
    var cb = o.svc.cbs[String(c.ticket)]
    verify(typeof cb === "function", c.name + " has a callback")
    delete o.svc.cbs[String(c.ticket)]
    cb(ok, err || "", data === undefined ? null : data, false)
  }
  function waiting(o, name) {
    var n = 0
    for (var t in o.svc.cbs) {
      var c = o.svc.calls.filter(function(x) { return String(x.ticket) === t })[0]
      if (c && c.name === name) n++
    }
    return n
  }
  function statusText(o) { return o.c.statusMessage.text }
  function confirmText(o) { var p = View.confirmLine(o.c.confirm); return p.lead + p.strong + p.tail }
  function sets(o) { return calls(o.svc, "rssRuleSet").length }

  function make(width) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha")]
    svc.categories = ["anime", "tv"]
    var o = { c: c, svc: svc, sh: sh }
    if (width) {
      winOf(c).width = width
      tryVerify(function() { return winOf(c).contentItem.width === width }, 2000)
    }
    return o
  }
  // N, the items, R, and the rules' answer.
  function openRules(o, data) {
    shifted(o, "N")
    compare(o.c.activeView, "rss")
    answer(o, "rssItems", true, "", items())
    shifted(o, "R")
    compare(o.c.keyPane, "rssRules")
    answer(o, "rssRules", true, "", data === undefined ? rulesFx() : data)
  }
  // The list cursor to row idx, then Enter on a disabled rule: the fields,
  // and the preview asked for on the way in, answered with p (or nothing).
  function editRule(o, idx, p) {
    if (idx > 0) j(o, idx)
    enter(o)
    compare(o.c.keyPane, "rssRuleFields")
    if (p !== undefined) answer(o, "rssRulePreview", true, "", p)
  }
  // The fields cursor to key's row (from the top).
  function toField(o, fieldKey) {
    for (var i = 0; i < 12; i++) key(o.c, "k")
    for (var n = 0; n < RR.RULE_FIELDS.length && RR.RULE_FIELDS[n].key !== fieldKey; n++) key(o.c, "j")
    compare(rr(o).flags.rssField.key, fieldKey)
  }
  // Enter on an INSERT field, text, Enter, and qbt's check answer.
  function typeField(o, fieldKey, text, reply) {
    toField(o, fieldKey)
    enter(o)
    compare(o.c.inputPurpose, "rssRuleField")
    line(o).setInput(text)
    enter(o)
    compare(last(o.svc, "rssRuleCheck").args[0], fieldKey)
    compare(last(o.svc, "rssRuleCheck").args[1], text)
    if (reply !== undefined) answer(o, "rssRuleCheck", reply.ok !== false, reply.error || "", reply.ok !== false ? { ok: true, value: reply.value } : null)
  }

  // ---- R, the empty state ---------------------------------------------------------------------

  function test_R_opens_the_rules_the_empty_state_and_esc_goes_back() {
    var o = make()
    openRules(o, { autoDownload: false, rules: [] })
    compare(calls(o.svc, "rssRules").length, 1, "openRules reads the rules")
    verify(shows(o, w.rulesTitle))
    verify(shows(o, w.rulesEmpty))
    verify(paneShown(o, "rssRuleListPane"))
    // No rule: Enter, x, n and e say why.
    enter(o)
    compare(statusText(o), w.reasonRule)
    esc(o)
    compare(o.c.keyPane, "rssFeeds")
    compare(o.c.activeView, "rss")
    verify(!rr(o).visible)
  }

  function test_the_rule_list_shows_each_name_and_its_state() {
    var o = make()
    openRules(o)
    verify(showsIn(o, "rssRuleListPane", "Arch ISO"))
    verify(showsIn(o, "rssRuleListPane", "Debian"))
    verify(showsIn(o, "rssRuleListPane", w.stateOn))
    verify(showsIn(o, "rssRuleListPane", w.stateOff))
    compare(rr(o).flags.rssRule.name, "Arch ISO")
    j(o)
    compare(rr(o).flags.rssRule.name, "Debian")
    compare(rr(o).flags.rssRule.enabled, true)
  }

  // ---- a: a new rule is created disabled, with the Feeds cursor's feed ------------------------

  function test_a_creates_a_disabled_rule_with_the_feed_under_the_feeds_cursor() {
    var o = make()
    shifted(o, "N")
    answer(o, "rssItems", true, "", items())
    j(o, 3)
    compare(rp(o).currentFeed.path, "Distros\\Arch")
    shifted(o, "R")
    answer(o, "rssRules", true, "", rulesFx())
    key(o.c, "a")
    compare(o.c.inputPurpose, "rssRuleName")
    line(o).setInput(" \t")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(statusText(o), s.ruleNameEmpty)
    line(o).setInput("Debian")
    enter(o)
    compare(o.c.mode, "INSERT", "a name qbt already has stays in INSERT")
    compare(statusText(o), fill(s.ruleExists, { name: "Debian" }))
    compare(calls(o.svc, "rssRuleCreate").length, 0)
    line(o).setInput("  Kernel  ")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(last(o.svc, "rssRuleCreate").args, ["Kernel", archUrl], "the trimmed name and the Feeds cursor's feed")
    var reads = calls(o.svc, "rssRules").length
    finishCall(o, "rssRuleCreate", true, "", { ok: true, name: "Kernel" })
    compare(statusText(o), fill(w.noteCreated, { name: "Kernel" }))
    compare(calls(o.svc, "rssRules").length, reads + 1, "a write reads the rules back")
    var k = { name: "Kernel", enabled: false, fields: fields({ affectedFeeds: [archUrl] }), raw: {} }
    var data = rulesFx()
    data.rules.splice(2, 0, k)
    answer(o, "rssRules", true, "", data)
    compare(rr(o).flags.rssRule.name, "Kernel", "the cursor follows the new rule")
    compare(rr(o).flags.rssRule.enabled, false)
    // From a folder (or Unread): no feed.
    esc(o)
    key(o.c, "k")
    compare(rp(o).currentFeed.kind, "folder")
    shifted(o, "R")
    answer(o, "rssRules", true, "", data)
    key(o.c, "a")
    line(o).setInput("Other")
    enter(o)
    compare(last(o.svc, "rssRuleCreate").args, ["Other", ""])
    // qbt's refusal speaks.
    finishCall(o, "rssRuleCreate", false, fill(s.unconfirmedAdd, { name: "Other" }))
    compare(statusText(o), fill(s.unconfirmedAdd, { name: "Other" }))
  }

  // ---- Enter: disabled straight in, enabled after "Editing turns … off" -----------------------

  function test_enter_on_a_disabled_rule_goes_in_and_on_an_enabled_one_turns_it_off_first() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    compare(sets(o), 0)
    compare(rr(o).flags.rssRule.name, "Arch ISO")
    verify(showsIn(o, "rssRuleFieldsPane", w.labelMustContain))
    verify(showsIn(o, "rssRuleFieldsPane", "Arch"))
    key(o.c, "h")
    compare(o.c.keyPane, "rssRules")
    j(o)
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmEditOff, { name: "Debian" }))
    key(o.c, "n")
    compare(o.c.keyPane, "rssRules")
    compare(sets(o), 0, "n writes nothing")
    enter(o)
    key(o.c, "y")
    compare(sets(o), 1)
    compare(last(o.svc, "rssRuleSet").args, ["Debian", {}, {}, "off"])
    compare(o.c.keyPane, "rssRules", "the fields wait for the write")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    answer(o, "rssRules", true, "", rulesFx({ set: { Debian: { enabled: false } } }))
    compare(o.c.keyPane, "rssRuleFields")
    compare(rr(o).flags.rssRule.name, "Debian")
    compare(rr(o).flags.rssRule.enabled, false)
    compare(sets(o), 1, "nothing but the turn-off")
  }

  // ---- auto-download off: each commit saves and previews ---------------------------------------

  function test_auto_download_off_a_commit_checks_saves_and_previews_and_a_refusal_stays_in_insert() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview(["Arch old"]))
    verify(showsIn(o, "rssRulePreviewPane", "Arch old"))
    typeField(o, "mustContain", "Arch ISO", undefined)
    compare(o.c.mode, "INSERT", "the INSERT stays open while qbt checks")
    compare(last(o.svc, "rssRuleCheck").args, ["mustContain", "Arch ISO", false])
    answer(o, "rssRuleCheck", true, "", { ok: true, value: "Arch ISO" })
    compare(o.c.mode, "NORMAL")
    compare(sets(o), 1)
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { mustContain: "Arch ISO" }, { mustContain: "Arch", enabled: false }, "keep"])
    var previews = calls(o.svc, "rssRulePreview").length
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(calls(o.svc, "rssRulePreview").length, previews + 1, "a saved commit previews")
    verify(showsIn(o, "rssRulePreviewPane", w.previewUpdating))
    answer(o, "rssRulePreview", true, "", preview(["Arch ISO 2026.10"]))
    verify(showsIn(o, "rssRulePreviewPane", "Arch ISO 2026.10"))
    verify(!showsIn(o, "rssRulePreviewPane", w.previewUpdating))
    // The snapshot is now the written value: the next save compares to it.
    typeField(o, "mustContain", "Arch", { ok: true, value: "Arch" })
    compare(last(o.svc, "rssRuleSet").args[2], { mustContain: "Arch ISO", enabled: false })
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    answer(o, "rssRulePreview", false, "boom")
    verify(showsIn(o, "rssRulePreviewPane", w.previewFailed))
  }

  function test_review_focus_3_a_hostile_pattern_stays_in_insert_with_qbts_sentence() {
    var o = make()
    openRules(o, rulesFx({ set: { "Arch ISO": { useRegex: true } } }))
    editRule(o, 0, preview([]))
    var cases = [
      { text: "(", error: s.badRegex },
      { text: "a\nb", error: s.multiLine },
      { text: "a".repeat(10000), error: s.regexUnchecked }
    ]
    for (var i = 0; i < cases.length; i++) {
      typeField(o, "mustContain", cases[i].text, { ok: false, error: cases[i].error })
      compare(o.c.mode, "INSERT", cases[i].error)
      compare(o.c.inputPurpose, "rssRuleField")
      compare(statusText(o), cases[i].error)
      compare(line(o).inputValue(), cases[i].text, "the text stays to fix")
      compare(last(o.svc, "rssRuleCheck").args[2], true, "useRegex rides along")
      esc(o)
    }
    compare(sets(o), 0, "nothing refused is written")
    // PCRE2 accepts what Python refuses: qbt's ok is taken.
    typeField(o, "mustContain", "a\\Kb", { ok: true, value: "a\\Kb" })
    compare(o.c.mode, "NORMAL")
    compare(last(o.svc, "rssRuleSet").args[1], { mustContain: "a\\Kb" })
    // A check answer after Esc is dropped.
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    typeField(o, "mustNotContain", "x", undefined)
    esc(o)
    answer(o, "rssRuleCheck", true, "", { ok: true, value: "x" })
    compare(o.c.mode, "NORMAL")
    compare(sets(o), 1, "a cancelled INSERT never saves")
  }

  function test_auto_download_off_a_save_refusal_reverts_the_field_and_says_why() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Other", { ok: true, value: "Other" })
    finishCall(o, "rssRuleSet", false, fill(s.ruleChanged, { name: "Arch ISO" }))
    compare(statusText(o), fill(s.ruleChanged, { name: "Arch ISO" }))
    compare(rr(o).flags.rssField.value, "Arch", "the field is back to the saved value")
    compare(rr(o).flags.rssRuleDirty, false)
  }

  function test_d12_one_preview_at_a_time_and_a_stale_answer_is_dropped() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch ISO", { ok: true, value: "Arch ISO" })
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    var p1 = last(o.svc, "rssRulePreview")
    // A toggle commits before that preview answers.
    toField(o, "smartFilter")
    space(o)
    compare(sets(o), 2)
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { smartFilter: true }, { smartFilter: false, enabled: false }, "keep"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(last(o.svc, "rssRulePreview"), p1, "one at a time: the next waits")
    answerCall(o, p1, true, "", preview(["Stale title"]))
    verify(!showsIn(o, "rssRulePreviewPane", "Stale title"), "the stale answer is dropped")
    var p2 = last(o.svc, "rssRulePreview")
    verify(p2 !== p1, "the queued preview runs")
    // Two more commits while it runs: only the newest queued one runs after.
    toField(o, "useRegex")
    space(o)
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    space(o)
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(waiting(o, "rssRulePreview"), 1)
    answerCall(o, p2, true, "", preview(["Stale two"]))
    compare(waiting(o, "rssRulePreview"), 1, "one queued run, not two")
    answer(o, "rssRulePreview", true, "", preview(["Fresh title"]))
    verify(showsIn(o, "rssRulePreviewPane", "Fresh title"))
    compare(waiting(o, "rssRulePreview"), 0)
  }

  // ---- auto-download on: the draft, p, leaving, discarding (Review Focus 2) ----------------------

  function test_review_focus_2_auto_download_on_no_write_until_confirmed() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    j(o)
    enter(o)
    compare(confirmText(o), fill(w.confirmEditOff, { name: "Debian" }))
    compare(sets(o), 0, "no write before the confirm")
    key(o.c, "y")
    compare(sets(o), 1)
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    answer(o, "rssRules", true, "", rulesFx({ auto: true, set: { Debian: { enabled: false } } }))
    answer(o, "rssRulePreview", true, "", preview([]))
    compare(o.c.keyPane, "rssRuleFields")
    verify(shows(o, w.autoDlFooter), "the footer says p saves")
    typeField(o, "mustContain", "Debian 13", { ok: true, value: "Debian 13" })
    toField(o, "smartFilter")
    space(o)
    toField(o, "category")
    enter(o)
    compare(o.c.mode, "PICKER")
    down(o)
    enter(o)
    compare(sets(o), 1, "commits change only the draft")
    compare(rr(o).flags.rssRuleDirty, true)
    compare(calls(o.svc, "rssRulePreview").length, 1, "no preview per commit")
    key(o.c, "p")
    compare(sets(o), 2)
    compare(last(o.svc, "rssRuleSet").args, ["Debian", { mustContain: "Debian 13", smartFilter: true, category: "anime" },
      { mustContain: "", smartFilter: false, category: "", enabled: false }, "keep"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(rr(o).flags.rssRuleDirty, false)
    compare(calls(o.svc, "rssRulePreview").length, 2, "p previews after the save")
    answer(o, "rssRulePreview", true, "", preview(["Debian 13"]))
    // Turning on: the only on is rssRuleSet(name, {}, {}, "on") after its confirm.
    key(o.c, "e")
    answer(o, "rssRulePreview", true, "", preview(["Debian 13"]))
    compare(confirmText(o), fill(w.confirmRuleOn, { name: "Debian", n: 1 }))
    compare(sets(o), 2)
    key(o.c, "y")
    compare(sets(o), 3)
    compare(last(o.svc, "rssRuleSet").args, ["Debian", {}, {}, "on"])
    var on = calls(o.svc, "rssRuleSet").filter(function(c) { return c.args[3] === "on" })
    compare(on.length, 1)
  }

  function test_auto_download_on_a_second_p_while_the_save_runs_sends_nothing() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    key(o.c, "p")
    key(o.c, "p")
    key(o.c, "e")
    compare(sets(o), 1, "one save per rule at a time")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(rr(o).flags.rssRuleDirty, false)
    answer(o, "rssRulePreview", true, "", preview([]))
    var previews = calls(o.svc, "rssRulePreview").length
    key(o.c, "p")
    compare(sets(o), 1, "a clean draft previews without a save")
    verify(calls(o.svc, "rssRulePreview").length > previews)
  }

  function test_auto_download_on_leaving_a_dirty_draft_asks_y_saves_n_stays() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    compare(sets(o), 0)
    key(o.c, "h")
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmLeave, { name: "Arch ISO" }))
    key(o.c, "n")
    compare(o.c.keyPane, "rssRuleFields", "n keeps editing")
    compare(rr(o).flags.rssRuleDirty, true)
    compare(sets(o), 0)
    // Every leaving key asks: Tab, Esc, h.
    tab(o)
    compare(confirmText(o), fill(w.confirmLeave, { name: "Arch ISO" }))
    key(o.c, "n")
    esc(o)
    compare(confirmText(o), fill(w.confirmLeave, { name: "Arch ISO" }))
    key(o.c, "y")
    compare(sets(o), 1)
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { mustContain: "Arch 1" }, { mustContain: "Arch", enabled: false }, "keep"])
    compare(o.c.keyPane, "rssRuleFields", "the action waits for the save")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(o.c.keyPane, "rssRules", "then runs as if pressed again")
    compare(rr(o).flags.rssRuleDirty, false)
  }

  function test_ruling_a_refused_save_in_the_leave_confirm_runs_nothing_and_stays_dirty() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    key(o.c, "h")
    key(o.c, "y")
    finishCall(o, "rssRuleSet", false, fill(s.ruleChanged, { name: "Arch ISO" }))
    compare(statusText(o), fill(s.ruleChanged, { name: "Arch ISO" }))
    compare(o.c.keyPane, "rssRuleFields", "the leave didn't run")
    compare(rr(o).flags.rssRuleDirty, true, "the draft stays dirty")
  }

  function test_auto_download_on_D_and_r_discard_after_a_confirm() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    shifted(o, "D")
    compare(statusText(o), w.reasonRuleDirty)
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    shifted(o, "D")
    compare(confirmText(o), fill(w.confirmDiscard, { name: "Arch ISO" }))
    key(o.c, "y")
    compare(rr(o).flags.rssRuleDirty, false)
    compare(rr(o).flags.rssField.value, "Arch")
    typeField(o, "mustContain", "Arch 2", { ok: true, value: "Arch 2" })
    var reads = calls(o.svc, "rssRules").length
    key(o.c, "r")
    compare(confirmText(o), fill(w.confirmDiscard, { name: "Arch ISO" }))
    key(o.c, "y")
    compare(calls(o.svc, "rssRules").length, reads + 1, "then reloads")
    compare(rr(o).flags.rssRuleDirty, false)
    compare(sets(o), 0)
  }

  // ---- e: turning on and off ---------------------------------------------------------------------

  function test_e_turns_a_rule_on_after_the_preview_and_its_confirm_and_off_at_once() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    key(o.c, "e")
    compare(sets(o), 0)
    compare(last(o.svc, "rssRulePreview").args, ["Arch ISO"])
    answer(o, "rssRulePreview", true, "", preview(["a", "b", "c"], [], ["old"]))
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmRuleOn, { name: "Arch ISO", n: 3 }))
    key(o.c, "y")
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", {}, {}, "on"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(statusText(o), fill(w.noteOn, { name: "Arch ISO" }))
    answer(o, "rssRules", true, "", rulesFx({ auto: true, set: { "Arch ISO": { enabled: true } } }))
    // Off: at once, no confirm.
    key(o.c, "e")
    compare(o.c.mode, "NORMAL")
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", {}, {}, "off"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(statusText(o), fill(w.noteOff, { name: "Arch ISO" }))
    answer(o, "rssRules", true, "", rulesFx({ auto: true }))
    // n = 0, and auto-download off.
    key(o.c, "e")
    answer(o, "rssRulePreview", true, "", preview([]))
    compare(confirmText(o), fill(w.confirmRuleOnNone, { name: "Arch ISO" }))
    key(o.c, "n")
    key(o.c, "r")
    answer(o, "rssRules", true, "", rulesFx())
    key(o.c, "e")
    answer(o, "rssRulePreview", true, "", preview(["a"]))
    compare(confirmText(o), fill(w.confirmRuleOnAutoOff, { name: "Arch ISO" }))
    key(o.c, "n")
    compare(calls(o.svc, "rssRuleSet").filter(function(c) { return c.args[3] === "on" }).length, 1)
  }

  function test_e_with_articles_without_a_torrent_link_refuses_with_no_confirm() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    key(o.c, "e")
    answer(o, "rssRulePreview", true, "", preview(["a"], ["news 1", "news 2"]))
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), fill(s.noTorrentBlock, { m: 2 }))
    compare(sets(o), 0)
    // qbt's own refusal (noTorrent grew between the preview and y) speaks.
    key(o.c, "e")
    answer(o, "rssRulePreview", true, "", preview(["a"]))
    key(o.c, "y")
    finishCall(o, "rssRuleSet", false, fill(s.noTorrentBlock, { m: 1 }))
    compare(statusText(o), fill(s.noTorrentBlock, { m: 1 }))
  }

  function test_e_with_a_dirty_draft_saves_first_and_a_refused_save_turns_nothing_on() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    var previews = calls(o.svc, "rssRulePreview").length
    key(o.c, "e")
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { mustContain: "Arch 1" }, { mustContain: "Arch", enabled: false }, "keep"])
    compare(calls(o.svc, "rssRulePreview").length, previews, "no preview before the save")
    finishCall(o, "rssRuleSet", false, s.badRegex)
    compare(statusText(o), s.badRegex)
    compare(calls(o.svc, "rssRulePreview").length, previews, "a refused save previews nothing")
    compare(o.c.mode, "NORMAL")
    compare(rr(o).flags.rssRuleDirty, true)
    // Saved: then the preview, then the confirm, then on; the fields end.
    key(o.c, "e")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(rr(o).flags.rssRuleDirty, false)
    answer(o, "rssRulePreview", true, "", preview(["Arch 1"]))
    compare(confirmText(o), fill(w.confirmRuleOn, { name: "Arch ISO", n: 1 }))
    key(o.c, "y")
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", {}, {}, "on"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(o.c.keyPane, "rssRules", "an enabled rule isn't edited: back to the list")
    // Space on Enabled is e.
    answer(o, "rssRules", true, "", rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    toField(o, "enabled")
    space(o)
    compare(last(o.svc, "rssRulePreview").args, ["Arch ISO"])
    answer(o, "rssRulePreview", true, "", preview([]))
    compare(confirmText(o), fill(w.confirmRuleOnNone, { name: "Arch ISO" }))
  }

  // ---- pickers --------------------------------------------------------------------------------------

  function test_the_feeds_picker_toggles_with_space_applies_with_enter_and_shows_gone_urls() {
    var o = make()
    openRules(o)
    editRule(o, 2, preview([]))
    toField(o, "affectedFeeds")
    verify(showsIn(o, "rssRuleFieldsPane", "Distros\\Arch, " + fill(w.feedGone, { url: goneUrl })))
    enter(o)
    compare(o.c.mode, "PICKER")
    var pk = rr(o).picker
    verify(pk !== null && pk.multi)
    compare(pk.rows.map(function(r) { return r.title }), ["Distros\\Arch", "Distros\\Debian", "News", fill(w.feedGone, { url: goneUrl })])
    compare(pk.rows.map(function(r) { return r.prefix }), ["[x]", "[ ]", "[ ]", "[x]"])
    // Esc discards.
    down(o)
    space(o)
    compare(rr(o).picker.rows[1].prefix, "[x]")
    esc(o)
    compare(o.c.mode, "NORMAL")
    compare(sets(o), 0)
    enter(o)
    compare(rr(o).picker.rows[1].prefix, "[ ]", "a new picker starts from the draft")
    verify(rp(o).togglePicker() === true, "RssPane.togglePicker hands Space to the multi picker")
    compare(rr(o).picker.rows[0].prefix, "[ ]")
    down(o)
    down(o)
    down(o)
    space(o)
    up(o)
    space(o)
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(last(o.svc, "rssRuleSet").args, ["Zed", { affectedFeeds: [newsUrl] }, { affectedFeeds: [archUrl, goneUrl], enabled: false }, "keep"])
  }

  function test_the_category_and_add_stopped_pickers_are_single_choice() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    toField(o, "category")
    enter(o)
    compare(o.c.mode, "PICKER")
    compare(rr(o).picker.multi, false)
    compare(rr(o).picker.rows.map(function(r) { return r.title }), [w.categoryNone, "anime", "tv"])
    verify(rp(o).togglePicker() === false, "a single picker never toggles")
    down(o)
    down(o)
    enter(o)
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { category: "tv" }, { category: "", enabled: false }, "keep"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    toField(o, "addStopped")
    enter(o)
    compare(rr(o).picker.rows.map(function(r) { return r.title }), [w.addStoppedDefault, w.addStoppedYes, w.addStoppedNo])
    down(o)
    down(o)
    enter(o)
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { addStopped: "no" }, { addStopped: "default", enabled: false }, "keep"])
  }

  function test_number_path_and_episode_inserts_take_qbts_reply() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    typeField(o, "ignoreDays", "400", { ok: false, error: s.badDays })
    compare(o.c.mode, "INSERT")
    compare(statusText(o), s.badDays)
    line(o).setInput(" 007 ")
    enter(o)
    answer(o, "rssRuleCheck", true, "", { ok: true, value: 7 })
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { ignoreDays: 7 }, { ignoreDays: 0, enabled: false }, "keep"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    typeField(o, "savePath", "media/tv", { ok: false, error: s.badSavePath })
    compare(statusText(o), s.badSavePath)
    line(o).setInput("/media/tv/")
    enter(o)
    answer(o, "rssRuleCheck", true, "", { ok: true, value: "/media/tv" })
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { savePath: "/media/tv" }, { savePath: "", useAutoTmm: true, enabled: false }, "keep"])
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    typeField(o, "savePath", "", { ok: true, value: "" })
    compare(last(o.svc, "rssRuleSet").args, ["Arch ISO", { savePath: "" }, { savePath: "/media/tv", useAutoTmm: true, enabled: false }, "keep"],
      "useAutoTmm stays the value from when the fields were entered")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    typeField(o, "episodeFilter", "1x2", { ok: false, error: s.badEpisode })
    compare(statusText(o), s.badEpisode)
  }

  // ---- n, x --------------------------------------------------------------------------------------------

  function test_n_renames_with_a_clash_sentence_and_x_removes_after_its_confirm() {
    var o = make()
    openRules(o)
    key(o.c, "n")
    compare(o.c.inputPurpose, "rssRuleRename")
    compare(line(o).inputValue(), "Arch ISO", "prefilled with the name")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "rssRuleRename").length, 0, "an unchanged name calls nothing")
    key(o.c, "n")
    line(o).setInput("Zed")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(statusText(o), fill(s.ruleExists, { name: "Zed" }))
    line(o).setInput("Arch")
    enter(o)
    compare(last(o.svc, "rssRuleRename").args, ["Arch ISO", "Arch"])
    finishCall(o, "rssRuleRename", false, fill(s.ruleExists, { name: "Arch" }))
    compare(statusText(o), fill(s.ruleExists, { name: "Arch" }), "qbt's clash sentence")
    answer(o, "rssRules", true, "", rulesFx())
    key(o.c, "x")
    compare(confirmText(o), fill(w.confirmRemove, { name: "Arch ISO" }))
    key(o.c, "n")
    compare(calls(o.svc, "rssRuleRemove").length, 0)
    key(o.c, "x")
    key(o.c, "y")
    compare(last(o.svc, "rssRuleRemove").args, ["Arch ISO"])
    finishCall(o, "rssRuleRemove", true, "", { ok: true })
    compare(statusText(o), fill(w.noteRemoved, { name: "Arch ISO" }))
    answer(o, "rssRules", true, "", rulesFx({ drop: ["Arch ISO"] }))
    compare(rr(o).flags.rssRule.name, "Debian", "the cursor clamps")
  }

  // ---- the preview column (Review Focus 4) --------------------------------------------------------

  function test_the_preview_column_shows_each_group_dup_and_unpreviewable_as_text() {
    var o = make()
    openRules(o)
    editRule(o, 0, undefined)
    verify(showsIn(o, "rssRulePreviewPane", w.previewTitle))
    var p = preview([{ feedPath: "Distros\\Arch", guid: "1", title: "Arch news", dup: 3 }, "Arch ISO"], ["page only"], ["old one"],
      [{ name: "Show", feedPaths: ["A\\Show", "B\\Show"] }])
    answer(o, "rssRulePreview", true, "", p)
    var want = [fill(w.previewWill, { n: 2 }), "Arch news " + fill(w.previewDup, { k: 3 }), "Arch ISO", fill(w.previewNoTorrent, { m: 1 }), "page only",
      fill(w.previewRead, { k: 1 }), "old one", fill(w.previewUnpreviewable, { name: "Show" })]
    for (var i = 0; i < want.length; i++) verify(showsIn(o, "rssRulePreviewPane", want[i]), want[i])
    typeField(o, "mustContain", "zzz", { ok: true, value: "zzz" })
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    answer(o, "rssRulePreview", true, "", preview([]))
    verify(showsIn(o, "rssRulePreviewPane", w.previewEmpty))
  }

  // ---- narrow -----------------------------------------------------------------------------------------

  function test_narrow_one_column_the_rule_chip_tab_list_and_p_preview() {
    var o = make(700)
    openRules(o)
    verify(rr(o).narrow)
    verify(paneShown(o, "rssRuleListPane"))
    verify(!paneShown(o, "rssRuleFieldsPane"))
    verify(!paneShown(o, "rssRulePreviewPane"))
    editRule(o, 0, preview(["Arch old"]))
    verify(!paneShown(o, "rssRuleListPane"), "one column at a time")
    verify(paneShown(o, "rssRuleFieldsPane"))
    verify(shows(o, "Arch ISO ▾"), "the rule chip")
    tab(o)
    compare(o.c.keyPane, "rssRuleList")
    verify(findName(content(o), "rssRuleOverlay") !== null)
    esc(o)
    compare(o.c.keyPane, "rssRuleFields")
    tab(o)
    j(o, 2)
    enter(o)
    compare(o.c.keyPane, "rssRuleFields")
    compare(rr(o).flags.rssRule.name, "Zed")
    answer(o, "rssRulePreview", true, "", preview(["Zed one"]))
    key(o.c, "p")
    compare(o.c.keyPane, "rssRulePreview")
    verify(paneShown(o, "rssRulePreviewPane"), "the preview full width")
    verify(!paneShown(o, "rssRuleFieldsPane"))
    answer(o, "rssRulePreview", true, "", preview(["Zed two"]))
    verify(showsIn(o, "rssRulePreviewPane", "Zed two"))
    esc(o)
    compare(o.c.keyPane, "rssRuleFields")
    key(o.c, "h")
    compare(o.c.keyPane, "rssRules")
  }

  function test_widening_gives_the_narrow_only_panes_back_to_the_fields() {
    var o = make(700)
    openRules(o)
    editRule(o, 0, preview([]))
    key(o.c, "p")
    compare(o.c.keyPane, "rssRulePreview")
    winOf(o.c).width = 1400
    tryVerify(function() { return !rr(o).narrow }, 2000)
    compare(o.c.keyPane, "rssRuleFields")
    verify(paneShown(o, "rssRuleListPane"))
    verify(paneShown(o, "rssRuleFieldsPane"))
    verify(paneShown(o, "rssRulePreviewPane"), "three columns")
  }

  function test_narrow_a_pick_in_the_rule_list_leaves_a_dirty_draft_only_after_its_confirm() {
    var o = make(700)
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    tab(o)
    compare(o.c.keyPane, "rssRuleList", "opening the list doesn't leave")
    j(o, 2)
    enter(o)
    compare(confirmText(o), fill(w.confirmLeave, { name: "Arch ISO" }))
    key(o.c, "y")
    finishCall(o, "rssRuleSet", true, "", { ok: true })
    compare(o.c.keyPane, "rssRuleFields")
    compare(rr(o).flags.rssRule.name, "Zed")
  }

  // ---- PlainText --------------------------------------------------------------------------------------

  function test_every_rules_text_is_plain_text() {
    function richTexts(o) {
      var rich = []
      var walk = function(obj) {
        if (!obj) return
        if (typeof obj.text === "string" && obj.font !== undefined && obj.textFormat !== undefined && obj.textFormat !== Text.PlainText
          && obj.cursorPosition === undefined && !(obj.parent && obj.parent.cursorPosition !== undefined)) rich.push(String(obj) + ": " + obj.text)
        var kids = obj.children || []
        for (var i = 0; i < kids.length; i++) walk(kids[i])
      }
      walk(rr(o))
      walk(line(o))
      return rich
    }
    var evil = "<b>Evil</b>‮"
    var data = rulesFx({ set: { "Arch ISO": { mustContain: "<i>x</i>", category: "<u>c</u>", savePath: "/<s>p</s>" } } })
    data.rules.push({ name: evil, enabled: false, fields: fields({ affectedFeeds: ["<a href=x>u</a>"] }), raw: {} })
    var o = make()
    openRules(o, data)
    editRule(o, 0, preview([{ feedPath: "Distros\\Arch", guid: "1", title: "<img src=x>", dup: 2 }], [], [], [{ name: "<b>S</b>", feedPaths: ["a", "b"] }]))
    wait(30)
    compare(richTexts(o).length, 0, JSON.stringify(richTexts(o)))
    verify(showsIn(o, "rssRuleFieldsPane", "<i>x</i>"))
    verify(showsIn(o, "rssRulePreviewPane", "<img src=x> " + fill(w.previewDup, { k: 2 })))
    key(o.c, "h")
    j(o, 3)
    verify(showsIn(o, "rssRuleListPane", "<b>Evil</b>"), "shown as text, the bidi override stripped")
    key(o.c, "x")
    verify(confirmText(o).indexOf("‮") === -1)
    wait(30)
    compare(richTexts(o).length, 0, JSON.stringify(richTexts(o)))
    key(o.c, "n")
    enter(o)
    answer(o, "rssRulePreview", true, "", preview([]))
    toField(o, "affectedFeeds")
    enter(o)
    wait(30)
    compare(richTexts(o).length, 0, JSON.stringify(richTexts(o)))
    esc(o)
    // Narrow, with the rule list up.
    var n = make(700)
    openRules(n, data)
    editRule(n, 3, preview([]))
    tab(n)
    wait(30)
    compare(richTexts(n).length, 0, JSON.stringify(richTexts(n)))
  }

  // ---- closing ------------------------------------------------------------------------------------------

  function test_closing_the_window_drops_a_dirty_draft_with_no_write_and_a_rules_confirm() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    key(o.c, "h")
    compare(o.c.mode, "CONFIRM")
    var area = rr(o)
    o.c.close()
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null)
    compare(sets(o), 0, "no write")
    compare(area.flags.rssRuleDirty, false, "the draft is gone")
    compare(area.draft, null)
  }

  function test_a_forced_leave_keeps_the_dirty_draft_and_the_leave_confirm_still_guards_it() {
    var o = make()
    openRules(o, rulesFx({ auto: true }))
    editRule(o, 0, preview([]))
    typeField(o, "mustContain", "Arch 1", { ok: true, value: "Arch 1" })
    // The Client closes RSS itself (a torrent row from the palette).
    o.c.leaveView()
    compare(o.c.activeView, "torrents")
    compare(sets(o), 0)
    shifted(o, "N")
    answer(o, "rssItems", true, "", items())
    shifted(o, "R")
    answer(o, "rssRules", true, "", rulesFx({ auto: true }))
    compare(o.c.keyPane, "rssRuleFields", "the draft is there when the rules reopen")
    compare(rr(o).flags.rssRuleDirty, true)
    compare(rr(o).flags.rssField.value, "Arch 1")
    key(o.c, "h")
    compare(confirmText(o), fill(w.confirmLeave, { name: "Arch ISO" }))
    compare(sets(o), 0)
  }

  function test_a_rule_gone_under_the_fields_goes_back_to_the_list() {
    var o = make()
    openRules(o)
    editRule(o, 0, preview([]))
    key(o.c, "r")
    answer(o, "rssRules", true, "", rulesFx({ drop: ["Arch ISO"] }))
    compare(o.c.keyPane, "rssRules")
    compare(statusText(o), s.ruleGone)
  }
}

// ---- Service: the rules calls on the one `qbt rss` lane ------------------------------------------

TestCase {
  id: svcTc
  name: "ServiceRssRules"

  Component { id: realService; Service {} }

  function lane(svc) {
    for (var i = 0; i < svc.data.length; i++) {
      var o = svc.data[i]
      if (o && o.rssLane === "rss") return o
    }
    return null
  }
  function finish(p, code, out, err) {
    p.stdout.text = out || ""
    p.stderr.text = err || ""
    p.running = false
    p.exited(code, 0)
  }

  function test_every_rules_call_puts_its_values_on_stdin_never_argv() {
    var svc = createTemporaryObject(realService, svcTc)
    var p = lane(svc)
    verify(p !== null)
    var h = svc.helperPath
    var hostile = "a;b $(rm -rf /) \"q\" -- --flag\n("
    var cases = [
      { call: function() { return svc.rssRules(function() {}) }, argv: "rules", stdin: null },
      { call: function() { return svc.rssRuleCheck("mustContain", hostile, true, function() {}) }, argv: "rule-check", stdin: "mustContain\u0000" + hostile + "\u0000true" },
      { call: function() { return svc.rssRuleCheck("ignoreDays", "7", false, function() {}) }, argv: "rule-check", stdin: "ignoreDays\u00007\u0000false" },
      { call: function() { return svc.rssRuleCreate(" New ", "https://e.example/rss") }, argv: "rule-create", stdin: " New \u0000https://e.example/rss" },
      { call: function() { return svc.rssRuleCreate("New", "") }, argv: "rule-create", stdin: "New\u0000" },
      { call: function() { return svc.rssRuleSet("Show", { mustContain: hostile }, { mustContain: "", enabled: false }, "keep") }, argv: "rule-set",
        stdin: "Show\u0000" + JSON.stringify({ mustContain: hostile }) + "\u0000" + JSON.stringify({ mustContain: "", enabled: false }) + "\u0000keep" },
      { call: function() { return svc.rssRuleSet("Show", {}, {}, "on") }, argv: "rule-set", stdin: "Show\u0000{}\u0000{}\u0000on" },
      { call: function() { return svc.rssRulePreview(hostile, function() {}) }, argv: "rule-preview", stdin: hostile },
      { call: function() { return svc.rssRuleRename("Show", "Show 2") }, argv: "rule-rename", stdin: "Show\u0000Show 2" },
      { call: function() { return svc.rssRuleRemove(" odd ") }, argv: "rule-remove", stdin: " odd " }
    ]
    for (var i = 0; i < cases.length; i++) {
      var c = cases[i]
      p.writes = []
      var t = c.call()
      verify(t > 0, c.argv)
      compare(p.command, [h, "rss", c.argv], c.argv + ": argv holds only the subcommand")
      compare(p.stdinEnabled, c.stdin !== null, c.argv)
      p.started()
      compare(p.writes.slice(), c.stdin === null ? [] : [c.stdin], c.argv + ": the values, NUL-joined")
      finish(p, 0, "{\"ok\":true}")
    }
  }

  function test_the_reads_answer_their_callback_and_the_writes_rssFinished() {
    var svc = createTemporaryObject(realService, svcTc)
    var p = lane(svc)
    var got = []
    var finished = []
    svc.rssFinished.connect(function(t, ok, err, data) { finished.push({ t: t, ok: ok, err: err, data: data }) })
    svc.rssRules(function(ok, err, data) { got.push({ ok: ok, data: data }) })
    var t2 = svc.rssRuleRemove("Show")
    p.started()
    finish(p, 0, "{\"autoDownload\":true,\"rules\":[]}\n")
    compare(got.length, 1)
    compare(got[0].data.autoDownload, true)
    compare(p.command[2], "rule-remove", "the lane moves on")
    p.started()
    finish(p, 1, "", "That rule is gone.\n")
    compare(finished.length, 1)
    compare(finished[0].t, t2)
    compare(finished[0].ok, false)
    compare(finished[0].err, "That rule is gone.")
  }
}
}
