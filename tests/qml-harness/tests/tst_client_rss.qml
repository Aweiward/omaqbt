import QtQuick
import QtTest
import "../../.."
import "../../../ClientView.js" as View
import "../../../RssView.js" as R
import "../../../LinkRules.js" as Links

// Slice 5b1 (Task 3): the RSS view through the Client, against a stub
// Service that serves scripted `qbt rss items` answers (a test answers each
// read's callback) and records every write (a test ends each with
// rssFinished). Keys only, as a user would press them; a few reads of
// RssPane's state where the screen can't say it more directly. Every
// sentence is the case file's, through RssView's WINDOW and SENTENCES
// (tests/rss-view.test.js checks those against the case file).
TestCase {
  id: tc
  name: "ClientRss"
  when: windowShown

  readonly property var w: R.WINDOW
  readonly property var s: R.SENTENCES
  function fill(t, v) { return Links.fill(t, v) }

  function hh(c) { var x = ""; for (var i = 0; i < 40; i++) x += c; return x }
  function tt(hash, name) {
    return { hash: hash, name: name, state: "downloading", progress: 0.5, dlSpeed: 0, upSpeed: 0, eta: 60, ratio: 0, size: 1024, addedOn: 1,
      category: "", tags: [], tracker: "", savePath: "/dl" }
  }
  function magnet(c) { return "magnet:?xt=urn:btih:" + hh(c) + "&dn=x" }

  // The scripted library: a folder with two feeds, and a feed at the root.
  // Feeds rows: 0 Unread, 1 All articles, 2 Distros, 3 Arch, 4 Debian, 5 News.
  // All articles, newest first: d1, a1, d2, n1, n2.
  function feedObj(path, url, unread, total, extra) {
    var segs = path.split("\\")
    var f = { path: path, name: segs[segs.length - 1], depth: segs.length - 1, folder: false, url: url, title: "", isLoading: false, hasError: false,
      unread: unread, total: total }
    for (var k in extra || {}) f[k] = extra[k]
    return f
  }
  function fx(opts) {
    var o = opts || {}
    var items = {
      processing: o.processing !== undefined ? o.processing : true,
      refreshInterval: 30,
      feeds: [
        { path: "Distros", name: "Distros", depth: 0, folder: true, unread: 3, total: 3, feeds: 2 },
        feedObj("Distros\\Arch", "https://archlinux.org/feeds/news/", 1, 1, o.arch),
        feedObj("Distros\\Debian", "https://www.debian.org/News/news", 2, 2, o.debian),
        feedObj("News", "https://news.example/rss", 1, 2, o.news)
      ],
      articles: [
        { feedPath: "Distros\\Arch", guid: "a1", title: "Arch news", date: 450, isRead: false, torrentURL: "https://archlinux.org/news/a1",
          link: "https://archlinux.org/news/a1", hasTorrent: false, host: "archlinux.org" },
        { feedPath: "Distros\\Debian", guid: "d1", title: "Debian 13 released", date: 500, isRead: false, torrentURL: magnet("c"),
          link: "https://www.debian.org/News/2026/d1", hasTorrent: true, host: "www.debian.org" },
        { feedPath: "Distros\\Debian", guid: "d2", title: "Debian 13 DVD", date: 400, isRead: false, torrentURL: "https://cdimage.debian.org/debian-13.torrent",
          link: "https://www.debian.org/News/2026/d2", hasTorrent: true, host: "www.debian.org" },
        { feedPath: "News", guid: "n1", title: "Alpha again", date: 300, isRead: false, torrentURL: magnet("a"),
          link: "https://news.example/n1", hasTorrent: true, host: "news.example" },
        { feedPath: "News", guid: "n2", title: "Bücher", date: null, isRead: true, torrentURL: "https://bücher.example/p",
          link: "https://bücher.example/p", hasTorrent: false, host: "xn--bcher-kva.example" }
      ]
    }
    if (o.dropNews) {
      items.feeds = items.feeds.slice(0, 3)
      items.articles = items.articles.filter(function(a) { return a.feedPath !== "News" })
    }
    return items
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
      // ticket -> a read's callback (answered by the test).
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
      function startHash(h, o) { return rec("start", [h, o]) }
      function stopHash(h, o) { return rec("stop", [h, o]) }
      function toggleHash(h, o) { return rec("toggle", [h, o]) }
      function deleteHash(h, f, o) { return rec("delete", [h, f, o]) }
      function recheckHash(h, o) { return rec("recheck", [h, o]) }
      function toggleAll(o) { return rec("toggleAll", [o]) }
      function toggleTurtle(o) { return rec("turtle", [o]) }
      function addTarget(t, s, p, o) { return rec("addTarget", [t]) }
      function openPath(p, o) { return rec("openPath", [p]) }
      function copyText(t, o) { return rec("copyText", [t]) }
      function openUrl(u) { rec("openUrl", [u]); return true }
      function setPref(k, v, o) { return rec("setPref", [k, v]) }
      function readPrefs(cb) { rec("readPrefs", []) }
      function rssItems(cb) { return read("rssItems", [], cb) }
      function rssArticle(p, g, cb) { return read("rssArticle", [p, g], cb) }
      function rssError(u, cb) { return read("rssError", [u], cb) }
      function rssAddFeed(u, p) { return rec("rssAddFeed", [u, p]) }
      function rssAddFolder(p) { return rec("rssAddFolder", [p]) }
      function rssRename(f, t) { return rec("rssRename", [f, t]) }
      function rssRemove(p) { return rec("rssRemove", [p]) }
      function rssRefresh(p) { return rec("rssRefresh", [p]) }
      function rssMarkRead(p, g, e) { return rec("rssMarkRead", [p, g, e]) }
      function rssAdd(t, l) { return rec("rssAdd", [t, l]) }
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
  function paneShown(o, name) { var p = findName(content(o), name); return !!p && p.visible }
  function calls(svc, name) { return svc.calls.filter(function(x) { return x.name === name }) }
  function last(svc, name) { var l = calls(svc, name); return l.length > 0 ? l[l.length - 1] : null }
  function finishCall(o, name, ok, err, data) {
    var c = last(o.svc, name)
    verify(c !== null, name + " was called")
    o.svc.rssFinished(c.ticket, ok, err || "", data === undefined ? null : data)
  }
  // Answers the last read of that name through its callback.
  function answer(o, name, ok, err, data, same) {
    var c = last(o.svc, name)
    verify(c !== null, name + " was called")
    var cb = o.svc.cbs[String(c.ticket)]
    verify(typeof cb === "function", name + " has a callback")
    delete o.svc.cbs[String(c.ticket)]
    cb(ok, err || "", data === undefined ? null : data, same === true)
  }
  // Answers one given read (not necessarily the last) through its callback.
  function answerCall(o, c, ok, err, data) {
    var cb = o.svc.cbs[String(c.ticket)]
    verify(typeof cb === "function", c.name + " has a callback")
    delete o.svc.cbs[String(c.ticket)]
    cb(ok, err || "", data === undefined ? null : data, false)
  }
  function items(o, data) { answer(o, "rssItems", true, "", data === undefined ? fx() : data) }
  // Every read still waiting is answered with data (a poll's).
  function answerWaiting(o, data) {
    var n = 0
    for (var t in o.svc.cbs) {
      var c = o.svc.calls.filter(function(x) { return String(x.ticket) === t })[0]
      if (!c || c.name !== "rssItems") continue
      var cb = o.svc.cbs[t]
      delete o.svc.cbs[t]
      cb(true, "", data, false)
      n++
    }
    return n
  }
  function statusText(o) { return o.c.statusMessage.text }
  function confirmText(o) { var p = View.confirmLine(o.c.confirm); return p.lead + p.strong + p.tail }

  function make(width) {
    var svc = createTemporaryObject(serviceComp, tc)
    var sh = createTemporaryObject(shellComp, tc)
    var c = createTemporaryObject(clientComp, tc)
    sh.target = c
    c.shell = sh
    c.service = svc
    svc.torrents = [tt(hh("a"), "alpha"), tt(hh("b"), "beta")]
    var o = { c: c, svc: svc, sh: sh }
    if (width) {
      winOf(c).width = width
      tryVerify(function() { return winOf(c).contentItem.width === width }, 2000)
    }
    return o
  }
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
  // N, and the items' answer.
  function openRss(o, data) {
    shifted(o, "N")
    compare(o.c.activeView, "rss")
    items(o, data)
  }
  // The All articles row, then its articles (cursor on d1).
  function toAll(o) {
    j(o)
    key(o.c, "l")
    compare(o.c.keyPane, "rssArticles")
  }
  function current(o) { var a = rp(o).currentArticle; return a ? a.guid : "" }

  // ---- open, the banner, O --------------------------------------------------------------------

  function test_open_renders_the_feeds_and_the_banner_and_O_turns_processing_on() {
    var o = make()
    openRss(o, fx({ processing: false }))
    compare(calls(o.svc, "rssItems").length, 1, "openView reads the items")
    compare(o.c.keyPane, "rssFeeds")
    var names = [w.unreadRow, w.allRow, "Distros", "Arch", "Debian", "News"]
    for (var i = 0; i < names.length; i++) verify(showsIn(o, "rssFeedsPane", names[i]), names[i])
    verify(shows(o, w.banner))
    // The Unread row's articles: every unread one, newest first.
    compare(rp(o).articleKeys(), ["Distros\\Debian\nd1", "Distros\\Arch\na1", "Distros\\Debian\nd2", "News\nn1"])
    shifted(o, "O")
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmOn, { n: 30 }))
    key(o.c, "y")
    compare(last(o.svc, "setPref").args, ["rss_processing_enabled", "true"])
    var reads = calls(o.svc, "rssItems").length
    o.svc.actionFinished(last(o.svc, "setPref").ticket, true, "", "window", [])
    compare(calls(o.svc, "rssItems").length, reads + 1, "the write is read back")
    items(o, fx({ processing: true }))
    verify(!shows(o, w.banner), "the banner goes")
    shifted(o, "O")
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), w.reasonProcessingOn)
  }

  // ---- a, N, n, x ---------------------------------------------------------------------------------

  function test_a_adds_a_feed_in_the_folder_under_the_cursor() {
    var o = make()
    openRss(o)
    j(o, 4)
    compare(rp(o).currentFeed.path, "Distros\\Debian")
    key(o.c, "a")
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "rssFeedUrl")
    line(o).setInput("ftp://e.example/rss")
    enter(o)
    compare(o.c.mode, "INSERT", "a refused URL stays in INSERT")
    compare(statusText(o), s.feedUrlScheme)
    line(o).setInput("https://Bücher.example:8443/rss")
    enter(o)
    compare(o.c.mode, "INSERT")
    compare(o.c.inputPurpose, "rssFeedName")
    compare(line(o).inputValue(), "xn--bcher-kva.example", "OV4: prefilled with the URL's host")
    line(o).setInput("a\\b")
    enter(o)
    compare(o.c.inputPurpose, "rssFeedName")
    compare(statusText(o), s.nameBackslash)
    line(o).setInput("  Books ")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(last(o.svc, "rssAddFeed").args, ["https://Bücher.example:8443/rss", "Distros\\Books"], "the URL as given, the name trimmed, in the feed's folder")
    finishCall(o, "rssAddFeed", true, "", { ok: true, path: "Distros\\Books" })
    var data = fx()
    data.feeds.splice(2, 0, feedObj("Distros\\Books", "https://Bücher.example:8443/rss", 0, 0))
    items(o, data)
    compare(rp(o).currentFeed.path, "Distros\\Books", "the cursor follows the new feed")
    // From Unread: the root.
    for (var k = 0; k < 4; k++) key(o.c, "k")
    compare(rp(o).currentFeed.kind, "unread")
    key(o.c, "a")
    line(o).setInput("http://127.0.0.1:9117/torznab")
    enter(o)
    enter(o)
    compare(last(o.svc, "rssAddFeed").args, ["http://127.0.0.1:9117/torznab", "127.0.0.1"])
    // A refusal from qbt shows its sentence and re-reads.
    var reads = calls(o.svc, "rssItems").length
    finishCall(o, "rssAddFeed", false, s.feedDup)
    compare(statusText(o), s.feedDup)
    compare(calls(o.svc, "rssItems").length, reads + 1)
  }

  function test_N_adds_a_folder_and_n_renames_with_the_cursor_following() {
    var o = make()
    openRss(o)
    j(o, 2)
    shifted(o, "N")
    compare(o.c.inputPurpose, "rssFolderName")
    line(o).setInput("Sub")
    enter(o)
    compare(last(o.svc, "rssAddFolder").args, ["Distros\\Sub"])
    finishCall(o, "rssAddFolder", true, "", { ok: true, path: "Distros\\Sub" })
    items(o)
    j(o, 3)
    compare(rp(o).currentFeed.path, "News")
    key(o.c, "n")
    compare(o.c.inputPurpose, "rssRename")
    compare(line(o).inputValue(), "News", "prefilled with the current name")
    line(o).setInput(" News　")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "rssRename").length, 0, "an unchanged rename never calls qbt")
    key(o.c, "n")
    line(o).setInput("Old news")
    enter(o)
    compare(last(o.svc, "rssRename").args, ["News", "Old news"])
    finishCall(o, "rssRename", true, "", { ok: true, path: "Old news" })
    var data = fx({ dropNews: true })
    data.feeds.push(feedObj("Old news", "https://news.example/rss", 1, 2))
    items(o, data)
    compare(rp(o).currentFeed.path, "Old news", "the cursor follows the new path")
    key(o.c, "k")
    compare(rp(o).currentFeed.path, "Distros\\Debian")
    key(o.c, "n")
    line(o).setInput("Deb")
    enter(o)
    compare(last(o.svc, "rssRename").args, ["Distros\\Debian", "Distros\\Deb"], "renamed in its own folder")
  }

  function test_x_on_a_folder_names_its_feed_count_and_unread_and_all_are_blocked() {
    var o = make()
    openRss(o)
    key(o.c, "x")
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), w.reasonItem)
    key(o.c, "n")
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), w.reasonItem)
    j(o)
    key(o.c, "x")
    compare(statusText(o), w.reasonItem, "All too (OV5)")
    j(o)
    key(o.c, "x")
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmRemoveFolder, { name: "Distros", n: 2 }))
    key(o.c, "n")
    compare(calls(o.svc, "rssRemove").length, 0)
    j(o)
    key(o.c, "x")
    compare(confirmText(o), fill(w.confirmRemoveFeed, { name: "Arch" }))
    key(o.c, "y")
    compare(last(o.svc, "rssRemove").args, ["Distros\\Arch"])
  }

  // ---- r and the polls ---------------------------------------------------------------------------

  function test_r_polls_every_2s_while_loading_and_says_still_refreshing_after_60s() {
    var o = make()
    rp(o).fastPollMs = 80
    rp(o).refreshCapMs = 700
    openRss(o)
    key(o.c, "r")
    compare(last(o.svc, "rssRefresh").args, [""], "Unread: everything")
    finishCall(o, "rssRefresh", true, "", { ok: true })
    var loading = fx({ debian: { isLoading: true } })
    answerWaiting(o, loading)
    verify(showsIn(o, "rssFeedsPane", w.rowRefreshing))
    var start = calls(o.svc, "rssItems").length
    // Each poll's answer: still loading.
    for (var i = 0; i < 12; i++) { wait(50); answerWaiting(o, loading) }
    verify(calls(o.svc, "rssItems").length >= start + 3, "polled while loading: " + (calls(o.svc, "rssItems").length - start))
    tryVerify(function() { answerWaiting(o, loading); return shows(o, w.stillRefreshing) }, 3000)
    var capped = calls(o.svc, "rssItems").length
    wait(300)
    answerWaiting(o, loading)
    compare(calls(o.svc, "rssItems").length, capped, "the fast poll stops at the cap")
    // r again: the cap starts over, and the load ends.
    j(o, 4)
    key(o.c, "r")
    compare(last(o.svc, "rssRefresh").args, ["Distros\\Debian"])
    finishCall(o, "rssRefresh", true, "", { ok: true })
    answerWaiting(o, fx())
    verify(!shows(o, w.stillRefreshing))
    var after = calls(o.svc, "rssItems").length
    wait(250)
    compare(calls(o.svc, "rssItems").length, after, "no fast poll once nothing loads")
  }

  function test_the_slow_poll_reads_while_open_and_stops_on_leave() {
    var o = make()
    rp(o).slowPollMs = 100
    openRss(o)
    tryVerify(function() { return calls(o.svc, "rssItems").length >= 2 }, 2000)
    answerWaiting(o, fx())
    esc(o)
    compare(o.c.activeView, "torrents")
    var n = calls(o.svc, "rssItems").length
    wait(300)
    compare(calls(o.svc, "rssItems").length, n, "closeView stops the polls")
  }

  // ---- Space, A ----------------------------------------------------------------------------------

  function test_space_marks_an_article_read_and_a_read_one_says_it_cant_be_unread() {
    var o = make()
    openRss(o)
    toAll(o)
    compare(current(o), "d1")
    space(o)
    compare(last(o.svc, "rssMarkRead").args, ["Distros\\Debian", "d1", 0])
    finishCall(o, "rssMarkRead", true, "", { ok: true })
    j(o, 4)
    compare(current(o), "n2")
    var n = calls(o.svc, "rssMarkRead").length
    space(o)
    compare(statusText(o), w.cantUnread)
    compare(calls(o.svc, "rssMarkRead").length, n)
  }

  function test_A_confirms_the_count_and_more_arrived_asks_again() {
    var o = make()
    openRss(o)
    shifted(o, "A")
    compare(confirmText(o), fill(w.confirmMarkAll, { n: 4 }))
    key(o.c, "y")
    compare(last(o.svc, "rssMarkRead").args, ["", "", 4])
    finishCall(o, "rssMarkRead", true, "", { ok: false, unread: 6 })
    compare(o.c.mode, "CONFIRM", "OV11: asks again")
    compare(confirmText(o), fill(w.moreArrived, { n: 6 }))
    key(o.c, "y")
    compare(last(o.svc, "rssMarkRead").args, ["", "", 6])
    var reads = calls(o.svc, "rssItems").length
    finishCall(o, "rssMarkRead", true, "", { ok: true })
    compare(calls(o.svc, "rssItems").length, reads + 1)
    items(o)
    j(o, 4)
    shifted(o, "A")
    compare(confirmText(o), fill(w.confirmMarkRead, { n: 2, name: "Debian" }))
    key(o.c, "y")
    compare(last(o.svc, "rssMarkRead").args, ["Distros\\Debian", "", 2])
  }

  // ---- Enter, d -------------------------------------------------------------------------------------

  function test_enter_on_a_magnet_confirms_adds_and_marks_it_read_once_in_the_library() {
    var o = make()
    openRss(o)
    toAll(o)
    enter(o)
    compare(o.c.mode, "CONFIRM")
    compare(confirmText(o), fill(w.confirmAdd, { title: "Debian 13 released", host: "www.debian.org" }))
    key(o.c, "y")
    compare(last(o.svc, "rssAdd").args, [magnet("c"), "https://www.debian.org/News/2026/d1"])
    finishCall(o, "rssAdd", true, "", { ok: true, via: "magnet" })
    verify(statusText(o).indexOf("Added") === -1, "not before the hash is in the library")
    compare(calls(o.svc, "rssMarkRead").length, 0)
    o.svc.torrents = o.svc.torrents.concat([tt(hh("c"), "debian")])
    compare(statusText(o), fill(w.added, { name: "Debian 13 released" }))
    compare(last(o.svc, "rssMarkRead").args, ["Distros\\Debian", "d1", 0], "then that article is marked read")
  }

  function test_enter_on_an_http_enclosure_says_sent_and_leaves_it_unread() {
    var o = make()
    openRss(o)
    toAll(o)
    j(o, 2)
    compare(current(o), "d2")
    enter(o)
    compare(confirmText(o), fill(w.confirmAdd, { title: "Debian 13 DVD", host: "www.debian.org" }))
    key(o.c, "y")
    finishCall(o, "rssAdd", true, "", { ok: true, via: "url" })
    compare(statusText(o), w.sent)
    wait(100)
    compare(calls(o.svc, "rssMarkRead").length, 0, "OV2: the user marks it")
  }

  function test_enter_on_news_says_no_torrent_link_and_asks_nothing() {
    var o = make()
    openRss(o)
    toAll(o)
    j(o)
    compare(current(o), "a1")
    verify(showsIn(o, "rssArticlePane", w.hasTorrentNo))
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), s.noTorrent)
    compare(calls(o.svc, "rssAdd").length, 0)
  }

  function test_enter_on_an_article_in_the_library_says_so() {
    var o = make()
    openRss(o)
    toAll(o)
    j(o, 3)
    compare(current(o), "n1")
    verify(showsIn(o, "rssArticlesPane", w.rowInLibrary))
    verify(showsIn(o, "rssArticlePane", w.hasTorrentYes))
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(statusText(o), w.alreadyInLibrary)
    compare(calls(o.svc, "rssAdd").length, 0)
  }

  function test_d_confirms_the_punycode_host_then_opens_detached() {
    var o = make()
    openRss(o)
    toAll(o)
    j(o, 4)
    compare(current(o), "n2")
    key(o.c, "d")
    compare(confirmText(o), fill(w.confirmOpen, { host: "xn--bcher-kva.example" }))
    key(o.c, "n")
    compare(calls(o.svc, "openUrl").length, 0)
    key(o.c, "d")
    key(o.c, "y")
    compare(last(o.svc, "openUrl").args, ["https://bücher.example/p"])
  }

  // ---- the error reason and the description -----------------------------------------------------------

  function test_a_failing_feed_reads_its_reason_once_per_url() {
    var o = make()
    var bad = fx({ arch: { hasError: true } })
    openRss(o, bad)
    compare(calls(o.svc, "rssError").length, 0, "only for the feed under the cursor")
    j(o, 3)
    verify(showsIn(o, "rssFeedsPane", w.rowError))
    compare(calls(o.svc, "rssError").length, 1)
    compare(last(o.svc, "rssError").args, ["https://archlinux.org/feeds/news/"])
    answer(o, "rssError", true, "", { reason: "HTTP 404" })
    verify(showsIn(o, "rssArticlesPane", fill(w.errorReason, { reason: "HTTP 404" })))
    key(o.c, "k"); j(o)
    rp(o).cmds.readItems()
    items(o, bad)
    compare(calls(o.svc, "rssError").length, 1, "cached while hasError holds")
    verify(showsIn(o, "rssArticlesPane", fill(w.errorReason, { reason: "HTTP 404" })))
    rp(o).cmds.readItems()
    items(o, fx())
    verify(!showsIn(o, "rssArticlesPane", fill(w.errorReason, { reason: "HTTP 404" })), "the error cleared")
    rp(o).cmds.readItems()
    items(o, bad)
    compare(calls(o.svc, "rssError").length, 2, "read again once it failed again")
    answer(o, "rssError", true, "", { reason: null })
    verify(showsIn(o, "rssArticlesPane", w.errorNoReason))
    key(o.c, "r")
    finishCall(o, "rssRefresh", true, "", { ok: true })
    answerWaiting(o, bad)
    compare(calls(o.svc, "rssError").length, 3, "a refresh reads it again")
  }

  function test_the_description_loads_on_settle_cached_and_plain() {
    var o = make()
    openRss(o)
    toAll(o)
    compare(calls(o.svc, "rssArticle").length, 0, "not before the cursor settles")
    tryVerify(function() { return calls(o.svc, "rssArticle").length === 1 }, 1000)
    compare(last(o.svc, "rssArticle").args, ["Distros\\Debian", "d1"])
    var text = []
    for (var i = 0; i < 20; i++) text.push("<b>line " + i + "</b>‮")
    answer(o, "rssArticle", true, "", { text: text.join("\n"), truncated: false })
    var d = findName(content(o), "rssDescription")
    tryVerify(function() { return d.text !== "" })
    compare(d.textFormat, Text.PlainText)
    compare(d.text.split("\n").length, 12, "the first 12 lines")
    compare(d.text.split("\n")[0], "<b>line 0</b>", "markup as text, bidi stripped")
    // Quick moves never ask; the settled one does; a cached one never again.
    j(o); j(o)
    wait(300)
    compare(calls(o.svc, "rssArticle").length, 2)
    compare(last(o.svc, "rssArticle").args, ["Distros\\Debian", "d2"])
    answer(o, "rssArticle", true, "", { text: "dvd", truncated: false })
    key(o.c, "k"); key(o.c, "k")
    wait(300)
    compare(calls(o.svc, "rssArticle").length, 2, "cached per (feed url, guid)")
    tryVerify(function() { return findName(content(o), "rssDescription").text === d.text })
  }

  // ---- narrow -----------------------------------------------------------------------------------------

  function test_narrow_one_column_the_chip_and_tab_overlay_and_the_wide_article() {
    var o = make(700)
    openRss(o)
    verify(rp(o).narrow)
    verify(paneShown(o, "rssFeedsPane"))
    verify(!paneShown(o, "rssArticlesPane"), "one column at a time")
    verify(!paneShown(o, "rssArticlePane"))
    key(o.c, "l")
    compare(o.c.keyPane, "rssArticles")
    verify(!paneShown(o, "rssFeedsPane"))
    verify(paneShown(o, "rssArticlesPane"))
    verify(shows(o, w.unreadRow + " ▾"), "the feed chip")
    tab(o)
    compare(o.c.keyPane, "rssFeedList")
    verify(findName(content(o), "rssFeedOverlay") !== null)
    j(o, 2)
    enter(o)
    compare(o.c.keyPane, "rssArticles")
    compare(rp(o).currentFeed.path, "Distros")
    verify(shows(o, "Distros ▾"))
    key(o.c, "l")
    verify(rp(o).wide)
    verify(paneShown(o, "rssArticlePane"), "the article full width")
    verify(!paneShown(o, "rssArticlesPane"))
    key(o.c, "h")
    verify(!rp(o).wide)
    verify(paneShown(o, "rssArticlesPane"))
    tab(o)
    esc(o)
    compare(o.c.keyPane, "rssArticles", "Esc closes the overlay")
    compare(o.c.activeView, "rss")
  }

  // ---- Review Focus 1: hostile content is plain text ---------------------------------------------------

  function test_rf1_every_text_is_plain_text() {
    function richTexts(o) {
      var rich = []
      var walk = function(obj) {
        if (!obj) return
        if (typeof obj.text === "string" && obj.font !== undefined && obj.textFormat !== undefined && obj.textFormat !== Text.PlainText
          && obj.cursorPosition === undefined && !(obj.parent && obj.parent.cursorPosition !== undefined)) rich.push(String(obj) + ": " + obj.text)
        var kids = obj.children || []
        for (var i = 0; i < kids.length; i++) walk(kids[i])
      }
      walk(rp(o))
      walk(line(o))
      return rich
    }
    var data = fx({ arch: { hasError: true, name: "<b>Arch</b>‮" }, processing: false })
    data.articles[0].title = "<a href='x'>evil</a>‮"
    data.articles[1].title = "<img src=x onerror=alert(1)>" + "x".repeat(10000)
    data.articles[1].host = "<i>h</i>"
    var o = make()
    openRss(o, data)
    j(o, 3)
    answer(o, "rssError", true, "", { reason: "<b>reason</b>" })
    key(o.c, "l")
    tryVerify(function() { return calls(o.svc, "rssArticle").length === 1 }, 1000)
    answer(o, "rssArticle", true, "", { text: "<script>alert(1)</script>&amp;<b>x</b>", truncated: false })
    wait(30)
    compare(richTexts(o).length, 0, JSON.stringify(richTexts(o)))
    verify(shows(o, "<a href='x'>evil</a>"), "shown as text, the bidi override stripped")
    verify(showsIn(o, "rssFeedsPane", "<b>Arch</b>"))
    // With a CONFIRM naming hostile text up.
    key(o.c, "h"); key(o.c, "k"); key(o.c, "k"); key(o.c, "l"); key(o.c, "k")
    compare(current(o), "d1")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    verify(confirmText(o).indexOf("‮") === -1)
    wait(30)
    compare(richTexts(o).length, 0, JSON.stringify(richTexts(o)))
    key(o.c, "n")
    // Narrow, with the feeds overlay up.
    var n = make(700)
    openRss(n, data)
    key(n.c, "l")
    tab(n)
    wait(30)
    compare(richTexts(n).length, 0, JSON.stringify(richTexts(n)))
  }

  // ---- Review Focus 2: a feed removed elsewhere ----------------------------------------------------------

  function test_rf2_a_feed_gone_between_reads_clamps_the_cursor_and_a_write_says_gone() {
    var o = make()
    openRss(o)
    j(o, 5)
    compare(rp(o).currentFeed.path, "News")
    key(o.c, "x")
    compare(confirmText(o), fill(w.confirmRemoveFeed, { name: "News" }))
    // The WebUI removes it; the next read no longer has it.
    key(o.c, "y")
    compare(last(o.svc, "rssRemove").args, ["News"], "the write names the feed frozen at key time")
    var reads = calls(o.svc, "rssItems").length
    finishCall(o, "rssRemove", false, s.feedGone)
    compare(statusText(o), s.feedGone)
    compare(calls(o.svc, "rssItems").length, reads + 1, "a refused write re-reads")
    items(o, fx({ dropNews: true }))
    verify(!showsIn(o, "rssFeedsPane", "News"), "the row disappears")
    compare(rp(o).currentFeed.path, "Distros\\Debian", "the cursor clamps to a neighbour")
    // A feed vanishing under a poll: the Articles cursor clamps too.
    key(o.c, "k"); key(o.c, "k"); key(o.c, "k")
    compare(rp(o).currentFeed.kind, "all")
    key(o.c, "l")
    compare(current(o), "a1", "the Articles cursor keeps its article across scopes")
    key(o.c, "k")
    compare(current(o), "d1")
    rp(o).cmds.readItems()
    var data = fx()
    data.articles = data.articles.filter(function(a) { return a.guid !== "d1" })
    items(o, data)
    compare(current(o), "a1", "the article cursor clamps to its neighbour")
    space(o)
    compare(last(o.svc, "rssMarkRead").args, ["Distros\\Arch", "a1", 0], "no write lands on another article")
  }

  // ---- Review Focus 3: qBittorrent down -------------------------------------------------------------------

  function test_rf3_down_shows_the_down_screen_drops_a_confirm_and_keeps_the_cursors() {
    var o = make()
    rp(o).slowPollMs = 100
    openRss(o)
    j(o, 4)
    key(o.c, "l")
    j(o)
    compare(current(o), "d2")
    enter(o)
    compare(o.c.mode, "CONFIRM")
    o.svc.api = false
    wait(50)
    verify(paneShown(o, "rssDown"), "the api-down screen")
    compare(o.c.mode, "NORMAL", "the RSS CONFIRM is dropped")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null)
    answerWaiting(o, fx())
    var n = calls(o.svc, "rssItems").length
    wait(300)
    compare(calls(o.svc, "rssItems").length, n, "the polls stop while down")
    key(o.c, "a")
    compare(statusText(o), w.reasonDown)
    key(o.c, "y")
    compare(calls(o.svc, "rssAdd").length, 0)
    o.svc.api = true
    wait(50)
    verify(!paneShown(o, "rssDown"))
    compare(calls(o.svc, "rssItems").length, n + 1, "read again on return")
    items(o)
    compare(rp(o).currentFeed.path, "Distros\\Debian", "the feeds cursor came back")
    compare(current(o), "d2", "and the selected article")
    compare(o.c.keyPane, "rssArticles")
  }

  // ---- Review Focus 4: a large library ------------------------------------------------------------------

  function test_rf4_the_cursor_stays_on_its_article_across_a_read_that_inserts_50_above() {
    var o = make()
    openRss(o)
    toAll(o)
    j(o, 3)
    compare(current(o), "n1")
    compare(rp(o).cursorIndex, 3)
    var data = fx()
    for (var i = 0; i < 50; i++) data.articles.push({ feedPath: "News", guid: "new" + i, title: "new " + i, date: 1000 + i, isRead: false,
      torrentURL: "", link: "", hasTorrent: false, host: "" })
    rp(o).cmds.readItems()
    items(o, data)
    compare(current(o), "n1", "the cursor stays on its article")
    compare(rp(o).cursorIndex, 53)
    compare(rp(o).articleKeys().length, 55)
    compare(rp(o).articleKeys()[0], "News\nnew49", "newest first")
    // The same stdout again: nothing is applied.
    var applied = rp(o).applyCount
    rp(o).cmds.readItems()
    answer(o, "rssItems", true, "", data, true)
    compare(rp(o).applyCount, applied, "Service's `same`: skipped")
  }

  // ---- Review Focus 5: an add that never shows up --------------------------------------------------------

  function test_rf5_a_magnet_that_never_appears_is_reported_and_stays_unread() {
    var o = make()
    rp(o).addConfirmMs = 300
    openRss(o)
    toAll(o)
    enter(o)
    key(o.c, "y")
    finishCall(o, "rssAdd", true, "", { ok: true, via: "magnet" })
    tryVerify(function() { return statusText(o) === fill(s.unconfirmedAdd, { name: "Debian 13 released" }) }, 3000, statusText(o))
    compare(calls(o.svc, "rssMarkRead").length, 0, "the article stays unread")
    o.svc.torrents = o.svc.torrents.concat([tt(hh("c"), "late")])
    wait(50)
    verify(statusText(o).indexOf("Added") === -1, "reported once")
  }

  // ---- the window closing ---------------------------------------------------------------------------------

  function test_closing_the_window_drops_an_rss_confirm_and_stops_the_polls() {
    var o = make()
    rp(o).slowPollMs = 100
    openRss(o)
    toAll(o)
    enter(o)
    compare(o.c.mode, "CONFIRM")
    var pane = rp(o)
    o.c.close()
    compare(o.c.mode, "NORMAL")
    compare(o.c.confirm, null)
    compare(o.c.regState.pending, null)
    compare(calls(o.svc, "rssAdd").length, 0, "the question was never answered")
    verify(!pane.pollsRunning)
    answerWaiting(o, fx())
    var n = calls(o.svc, "rssItems").length
    wait(300)
    compare(calls(o.svc, "rssItems").length, n)
  }

  function test_a_rebuilt_window_applies_an_unchanged_read() {
    var o = make()
    openRss(o)
    esc(o)
    reopen(o)
    shifted(o, "N")
    answer(o, "rssItems", true, "", fx(), true)
    verify(showsIn(o, "rssFeedsPane", "Debian"), "`same`, but this window had nothing")
    compare(rp(o).articleKeys().length, 4)
  }

  // ---- fix round 1 ------------------------------------------------------------------------------------

  function test_fix1_the_refresh_cap_survives_esc_then_N_and_never_runs_closed() {
    var o = make()
    rp(o).fastPollMs = 80
    rp(o).refreshCapMs = 600
    var loading = fx({ debian: { isLoading: true } })
    openRss(o)
    esc(o)
    // A read landing after closeView, now loading: nothing starts while closed.
    rp(o).cmds.readItems()
    items(o, loading)
    verify(rp(o).loading)
    verify(!rp(o).pollsRunning, "no timer runs while RSS is closed")
    shifted(o, "N")
    answerWaiting(o, loading)
    var start = calls(o.svc, "rssItems").length
    for (var i = 0; i < 8; i++) { wait(50); answerWaiting(o, loading) }
    verify(calls(o.svc, "rssItems").length >= start + 2, "the fast poll runs while loading")
    tryVerify(function() { answerWaiting(o, loading); return shows(o, w.stillRefreshing) }, 3000)
    var capped = calls(o.svc, "rssItems").length
    wait(300)
    answerWaiting(o, loading)
    compare(calls(o.svc, "rssItems").length, capped, "the fast poll stops at the cap after a reopen")
    // Esc and N again while still loading: a fresh cap, never unbounded.
    esc(o)
    shifted(o, "N")
    answerWaiting(o, loading)
    tryVerify(function() { answerWaiting(o, loading); return shows(o, w.stillRefreshing) }, 3000)
    // qBittorrent down: the cap timer stops with the polls.
    o.svc.api = false
    wait(50)
    verify(!rp(o).pollsRunning)
  }

  function test_fix2_the_feeds_column_scrolls_to_its_cursor_and_keeps_it_after_a_read() {
    var o = make()
    winOf(o.c).width = 1200
    winOf(o.c).height = 700
    tryVerify(function() { return winOf(o.c).contentItem.height === 700 }, 2000)
    var data = { processing: true, refreshInterval: 30, feeds: [], articles: [] }
    for (var i = 0; i < 86; i++) data.feeds.push(feedObj("Feed " + (i < 10 ? "0" : "") + i, "https://f" + i + ".example/rss", 0, 0))
    openRss(o, data)
    j(o, 70)
    compare(rp(o).feedIndex, 70)
    var list = findName(content(o), "rssFeedList")
    var h = rp(o).rowHeight
    function inView() { return 70 * h >= list.contentY - 0.5 && 71 * h <= list.contentY + list.height + 0.5 }
    verify(list.height < 70 * h, "the list is shorter than its rows")
    tryVerify(inView, 1000, "row 70 is in the viewport: contentY " + list.contentY + ", height " + list.height)
    rp(o).cmds.readItems()
    items(o, data)
    wait(30)
    compare(list.currentIndex, 70, "currentIndex kept after the model swap")
    tryVerify(inView, 1000, "still in view after a re-read: contentY " + list.contentY)
  }

  function test_fix_enter_on_the_prefill_of_an_untrimmed_name_renames_nothing() {
    var o = make()
    var data = fx()
    data.feeds[3] = feedObj(" News ", "https://news.example/rss", 1, 2)
    openRss(o, data)
    j(o, 5)
    compare(rp(o).currentFeed.path, " News ")
    key(o.c, "n")
    compare(line(o).inputValue(), " News ")
    enter(o)
    compare(o.c.mode, "NORMAL")
    compare(calls(o.svc, "rssRename").length, 0, "qbt's own name, untrimmed: skipped")
  }

  function test_fix_an_error_reason_asked_before_r_is_ignored_after_it() {
    var o = make()
    var bad = fx({ arch: { hasError: true } })
    openRss(o, bad)
    j(o, 3)
    var first = last(o.svc, "rssError")
    key(o.c, "r")
    finishCall(o, "rssRefresh", true, "", { ok: true })
    answerWaiting(o, bad)
    compare(calls(o.svc, "rssError").length, 2, "r reads it again")
    answerCall(o, first, true, "", { reason: "old" })
    verify(!showsIn(o, "rssArticlesPane", fill(w.errorReason, { reason: "old" })), "the answer from before r is dropped")
    answer(o, "rssError", true, "", { reason: "new" })
    verify(showsIn(o, "rssArticlesPane", fill(w.errorReason, { reason: "new" })))
  }

  function test_fix_a_failed_error_read_shows_no_reason_and_is_not_retried() {
    var o = make()
    var bad = fx({ arch: { hasError: true } })
    openRss(o, bad)
    j(o, 3)
    answer(o, "rssError", false, "Could not run the qbt helper")
    verify(showsIn(o, "rssArticlesPane", w.errorNoReason))
    rp(o).cmds.readItems()
    items(o, bad)
    compare(calls(o.svc, "rssError").length, 1, "cached until hasError changes or r")
  }

  function test_fix_a_repeated_failure_is_posted_once_until_a_read_succeeds() {
    var o = make()
    openRss(o)
    var err = "qBittorrent refused it (HTTP 500)"
    rp(o).cmds.readItems()
    answer(o, "rssItems", false, err)
    compare(statusText(o), err)
    key(o.c, "j")
    verify(statusText(o) !== err, "a key clears it")
    rp(o).cmds.readItems()
    answer(o, "rssItems", false, err)
    verify(statusText(o) !== err, "the same failure again isn't posted")
    rp(o).cmds.readItems()
    items(o)
    rp(o).cmds.readItems()
    answer(o, "rssItems", false, err)
    compare(statusText(o), err, "posted again after a read succeeded")
  }

  function test_fix_a_failed_first_read_is_retried_until_one_succeeds() {
    var o = make()
    rp(o).fastPollMs = 80
    shifted(o, "N")
    answer(o, "rssItems", false, "qBittorrent refused it (HTTP 500)")
    compare(rp(o).flagsNow().rssUp, false)
    tryVerify(function() { return calls(o.svc, "rssItems").length >= 2 }, 2000, "read again")
    answer(o, "rssItems", false, "qBittorrent refused it (HTTP 500)")
    tryVerify(function() { return calls(o.svc, "rssItems").length >= 3 }, 2000, "and again")
    items(o)
    compare(rp(o).flagsNow().rssUp, true)
    var n = calls(o.svc, "rssItems").length
    wait(300)
    compare(calls(o.svc, "rssItems").length, n, "no retry once a read succeeded")
  }
}
