pragma ComponentBehavior: Bound

import QtQuick
import "CommandRegistry.js" as Registry
import "ClientView.js" as View
import "RssView.js" as RssView
import "LinkRules.js" as Links

// The RSS view's commands (slice 5b1, Task 3): what RssPane.run hands
// here, the four INSERTs (a's URL then name, N, n), the reads (`qbt rss
// items`, `article`, `error`, through Service's callbacks) and the ends of
// the writes (Service.rssFinished). RssPane holds the state and draws it;
// this holds the behaviour, the way SearchCommands sits beside SearchPane.
//
// - Every write reads the items back once it ends, ok or not: a refusal
//   ("That feed is gone.") shows qbt's sentence, and the re-read drops the
//   row and clamps the cursor (Review Focus 2). A write names the path
//   frozen at key time (args.item), never the cursor as it stands.
// - a: the feedUrl rule in INSERT, then the name prompt prefilled with the
//   URL's host (OV4), in the folder under the Feeds cursor. N: a folder
//   there. n: the name rule, an unchanged name ends with no qbt call, and
//   the cursor follows qbt's new path.
// - x, A, Enter, d and O raise the view's own CONFIRMs (View.RSS_ACCEPT);
//   `y` comes back as the same command with args.confirmed. A's
//   {"ok":false,"unread":M} asks again with the moreArrived line (OV11),
//   or, when the user is already in another mode, notes the count.
// - Enter: in the library says so; no torrent link says the rule's
//   sentence; a magnet is awaited in the library (AddAwaiter, tagged with
//   its article) and marked read once it's there, or reported after
//   addConfirmMs; an http(s) enclosure says "Sent …" and stays unread (OV2).
// - The failing feed's reason (`qbt rss error`) is read once per URL while
//   its hasError holds (cleared by the error ending or `r`); an article's
//   description (`qbt rss article`) once per (feed url, guid).
// Every sentence is RssView's (the case file's); qbt's own show as they are.
QtObject {
  id: cmds

  required property var view

  readonly property var client: view.client
  readonly property var service: view.service

  // ticket -> {kind, ...}: this window's `qbt rss` writes still going.
  property var tickets: ({})
  // An items read is running; another asked for meanwhile runs after it.
  property bool reading: false
  property bool readAgain: false
  // The last items read failed (RssPane retries while nothing is loaded).
  property bool itemsFailed: false
  // The items-read failure last posted (pollFail): an identical one isn't
  // posted again until a read succeeds. Write failures never check it.
  property string lastFail: ""
  // Each `qbt rss error` read's token: an answer for an entry that was
  // dropped (the error cleared, or `r`) or replaced meanwhile is ignored.
  property int errorToken: 0
  // The INSERT a, N or n opened: {folder, url} or {item} (frozen then).
  property var input: null
  // O's setPref ticket (Service.actionFinished ends it).
  property int processingTicket: 0
  // url -> {loading} | {reason}: `qbt rss error`'s answers (OV13).
  property var errorCache: ({})
  property int errorVersion: 0
  // "<feed url>\n<guid>" -> {loading} | {text}: `qbt rss article`'s.
  property var descCache: ({})
  property int descVersion: 0

  // Magnets added whose hash isn't in the library yet: "Added <name>." and
  // the article marked read once it is, "Couldn't confirm <name> was
  // added." once view.addConfirmMs passes (OV2).
  property AddAwaiter awaiter: AddAwaiter {
    libSet: cmds.view.libSet
    confirmMs: cmds.view.addConfirmMs
    onConfirmed: (name, tag) => cmds.addConfirmed(name, tag)
    onUnconfirmed: (name, tag) => cmds.note(RssView.sentence("unconfirmedAdd", { name: name }), "urgent")
  }

  function svcHas(name) {
    return !!service && typeof service[name] === "function"
  }

  function remember(ticket, entry) {
    if (!(Number(ticket) > 0)) {
      note(View.BUSY_NOTE, "muted")
      return false
    }
    var n = ({})
    for (var t in tickets) n[t] = tickets[t]
    n[String(ticket)] = entry
    tickets = n
    return true
  }

  function take(ticket) {
    var k = String(ticket)
    var e = tickets[k]
    if (!e) return null
    var n = ({})
    for (var t in tickets) if (t !== k) n[t] = tickets[t]
    tickets = n
    return e
  }

  function note(text, tone) {
    if (client) client.note(text, tone || "muted")
  }

  // Every write failure speaks.
  function fail(text) {
    if (client) client.messages = View.msgError(client.messages, String(text || ""), [])
  }

  // An items read (the polls) failing: an identical failure is posted once
  // until a read succeeds, so a poll failing every 2 s or 5 min says it once.
  function pollFail(text) {
    var t = String(text || "")
    if (t === lastFail) return
    lastFail = t
    fail(t)
  }

  // Raises one of RSS's CONFIRMs (View.RSS_ACCEPT's kinds): `y` comes back
  // as commandId with args plus confirmed.
  function raise(commandId, kind, args, line) {
    var c = client
    var r = Registry.raiseConfirm(c.regState, commandId, kind, args)
    var cf = ({})
    for (var f in r.confirm) cf[f] = r.confirm[f]
    cf.line = line
    c.regState = r.state
    c.confirmHashes = []
    c.confirm = cf
  }

  // ---- the reads ---------------------------------------------------------------------

  function readItems() {
    if (!svcHas("rssItems")) return
    if (reading) { readAgain = true; return }
    var t = service.rssItems(function(ok, error, data, same) { cmds.itemsRead(ok, error, data, same) })
    reading = Number(t) > 0
  }

  function itemsRead(ok, error, data, same) {
    var v = view
    reading = false
    itemsFailed = !ok
    if (ok) lastFail = ""
    if (!ok) {
      if (v.tableState === "rows" || v.tableState === "empty") pollFail(error)
    } else if (data && typeof data === "object" && Array.isArray(data.feeds) && Array.isArray(data.articles)) {
      // Service's `same`: the stdout didn't change, so nothing is applied,
      // unless this window has nothing yet (it was rebuilt).
      if (!(same === true && v.loaded)) v.applyItems(data)
    }
    if (readAgain) {
      readAgain = false
      readItems()
    }
  }

  // After every applied read: reasons whose feed no longer fails go
  // (OV13), and the feed under the cursor gets its reason.
  function itemsApplied() {
    var failing = ({})
    var rows = view.feedRowsList
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "feed" && rows[i].hasError) failing[rows[i].url] = true
    var n = ({})
    var dropped = false
    for (var u in errorCache) {
      if (failing[u] === true) n[u] = errorCache[u]
      else dropped = true
    }
    if (dropped) {
      errorCache = n
      errorVersion++
    }
    checkError()
  }

  // The feed under the Feeds cursor fails: its reason, once per URL. Not
  // while it refreshes: qBittorrent keeps the old hasError (and the log its
  // old line) until the refresh ends, so asking then caches a stale reason.
  function checkError() {
    var f = view.currentFeed
    if (!f || f.kind !== "feed" || !f.hasError || f.isLoading || f.url === "" || view.downShown) return
    if (errorCache[f.url] !== undefined || !svcHas("rssError")) return
    var url = f.url
    errorToken++
    var token = errorToken
    setError(url, { loading: true, token: token })
    // A failed read is kept as no reason (errorNoReason) until the error
    // clears or `r`, never re-asked on every applied read.
    var t = service.rssError(url, function(ok, error, data) {
      var e = cmds.errorCache[url]
      if (!e || e.token !== token) return
      cmds.setError(url, { reason: ok && data && typeof data === "object" ? data.reason : null })
    })
    if (!(Number(t) > 0)) setError(url, undefined)
  }

  function setError(url, entry) {
    var n = ({})
    for (var u in errorCache) if (u !== url) n[u] = errorCache[u]
    if (entry !== undefined) n[url] = entry
    errorCache = n
    errorVersion++
  }

  // The failing feed's line: its reason, or errorNoReason; "" while it's
  // read or when the feed doesn't fail.
  function errorLine(feed) {
    if (!feed || feed.kind !== "feed" || !feed.hasError) return ""
    var e = errorCache[feed.url]
    if (!e || e.loading === true) return ""
    return RssView.errorText(e.reason)
  }

  function descKey(article) {
    return article ? view.feedUrl(article.feedPath) + "\n" + article.guid : ""
  }

  // The Articles cursor settled (150 ms): the description, once per
  // (feed url, guid).
  function loadDescription() {
    var a = view.currentArticle
    if (!a || view.downShown || !svcHas("rssArticle")) return
    var k = descKey(a)
    if (descCache[k] !== undefined) return
    setDesc(k, { loading: true })
    var t = service.rssArticle(a.feedPath, a.guid, function(ok, error, data) {
      if (ok && data && typeof data === "object") cmds.setDesc(k, { text: RssView.descriptionText(data.text) })
      else cmds.setDesc(k, undefined)
    })
    if (!(Number(t) > 0)) setDesc(k, undefined)
  }

  function setDesc(k, entry) {
    var n = ({})
    for (var d in descCache) if (d !== k) n[d] = descCache[d]
    if (entry !== undefined) n[k] = entry
    descCache = n
    descVersion++
  }

  function description(article) {
    var e = article ? descCache[descKey(article)] : undefined
    return e && typeof e.text === "string" ? e.text : ""
  }

  // ---- the INSERTs (a, N, n) ---------------------------------------------------------

  function addFeed(item) {
    input = { folder: RssView.folderPath(item) }
    view.commands.startInput("rssFeedUrl", "")
  }

  function addFolder(item) {
    input = { folder: RssView.folderPath(item) }
    view.commands.startInput("rssFolderName", "")
  }

  function rename(item) {
    if (!item) return
    input = { item: item }
    view.commands.startInput("rssRename", item.name)
  }

  function stay(message) {
    note(message, "urgent")
    view.commands.stayInInsert()
  }

  function commitInput(purpose, text) {
    var c = view.commands
    var inp = input
    if (!inp) { c.endInput(); return }
    if (purpose === "rssFeedUrl") {
      var u = RssView.checkFeedUrl(text)
      if (!u.ok) { stay(u.message); return }
      input = { folder: inp.folder, url: String(text) }
      c.startInput("rssFeedName", u.normalised)
      return
    }
    // Enter on the rename's prefill, qbt's name exactly (an untrimmed
    // channel title included): nothing changes, no qbt call.
    if (purpose === "rssRename" && String(text) === inp.item.name) {
      input = null
      c.endInput()
      return
    }
    var r = RssView.checkName(text)
    if (!r.ok) { stay(r.message); return }
    input = null
    c.endInput()
    if (purpose === "rssFeedName") {
      var p = RssView.joinPath(inp.folder, r.normalised)
      if (svcHas("rssAddFeed")) remember(service.rssAddFeed(inp.url, p), { kind: "follow", path: p })
    } else if (purpose === "rssFolderName") {
      var fp = RssView.joinPath(inp.folder, r.normalised)
      if (svcHas("rssAddFolder")) remember(service.rssAddFolder(fp), { kind: "follow", path: fp })
    } else if (purpose === "rssRename") {
      var it = inp.item
      if (r.normalised === it.name) return
      var to = RssView.joinPath(RssView.parentPath(it.path), r.normalised)
      if (svcHas("rssRename")) remember(service.rssRename(it.path, to), { kind: "follow", path: to })
    }
  }

  function cancelInput() {
    input = null
  }

  // ---- the writes --------------------------------------------------------------------

  function remove(item, confirmed) {
    if (!item) return
    if (confirmed !== true) {
      raise("rss.remove", "rssRemove", { item: item }, RssView.confirmLine("rssRemove", { name: RssView.cleanName(item.name), folder: item.folder === true, n: item.feeds }))
      return
    }
    if (svcHas("rssRemove")) remember(service.rssRemove(item.path), { kind: "write" })
  }

  function refresh(item) {
    view.refreshStarted()
    errorCache = ({})
    errorVersion++
    if (svcHas("rssRefresh")) remember(service.rssRefresh(item ? item.path : ""), { kind: "write" })
  }

  // A (and OV11's second ask): the count the confirm names is qbt's
  // `expect`; item null means everything (Unread and All).
  // more: qbt found more unread than the confirm named, so it asks again.
  function markAllRead(item, unread, confirmed, more) {
    var n = Number(unread) || 0
    if (n <= 0) return
    if (confirmed !== true) {
      raise("rss.markAllRead", "rssMarkRead", { item: item, unread: n },
        RssView.confirmLine("rssMarkRead", { all: !item, name: item ? RssView.cleanName(item.name) : "", n: n, more: more === true }))
      return
    }
    if (svcHas("rssMarkRead")) remember(service.rssMarkRead(item ? item.path : "", "", n), { kind: "markAll", item: item })
  }

  function markRead(article) {
    if (!article) return
    if (article.isRead === true) { note(RssView.WINDOW.cantUnread, "muted"); return }
    if (svcHas("rssMarkRead")) remember(service.rssMarkRead(article.feedPath, article.guid, 0), { kind: "write" })
  }

  // The confirm's <host>: where the torrent comes from. An http(s)
  // enclosure (torrentURL ≠ link) names its own host (punycode, as
  // checkPageLink gives it); a magnet or an enclosure-less .torrent link
  // names the page's (qbt's), else the torrent URL's, else "—".
  function addHost(article, via) {
    var t = Links.checkPageLink(article.torrentURL)
    if (via === "url" && article.torrentURL !== article.link && t.ok) return t.host
    if (article.host !== "") return article.host
    return t.ok ? t.host : RssView.EMPTY
  }

  function add(article, confirmed) {
    if (!article) return
    if (article.inLibrary === true) { note(RssView.WINDOW.alreadyInLibrary, "muted"); return }
    var r = RssView.checkHasTorrent({ torrentURL: article.torrentURL, link: article.link })
    if (!r.ok) { note(r.message, "urgent"); return }
    if (confirmed !== true) {
      raise("rss.add", "rssAdd", { article: article }, RssView.confirmLine("rssAdd", { title: article.title, host: addHost(article, r.normalised) }))
      return
    }
    if (!svcHas("rssAdd")) return
    var h = Links.magnetHash(article.torrentURL)
    remember(service.rssAdd(article.torrentURL, article.link), { kind: "add", via: r.normalised, title: article.title,
      feedPath: article.feedPath, guid: article.guid, v1: h && h.v1 ? h.v1 : "", v2: h && h.v2 ? h.v2 : "" })
  }

  function addConfirmed(name, tag) {
    note(RssView.sentence("added", { name: name }), "muted")
    if (tag && typeof tag === "object" && svcHas("rssMarkRead")) remember(service.rssMarkRead(tag.feedPath, tag.guid, 0), { kind: "write" })
  }

  function openPage(article, confirmed) {
    if (!article) return
    var r = Links.checkPageLink(article.link)
    if (!r.ok) { note(r.message, "urgent"); return }
    if (confirmed !== true) {
      raise("rss.openPage", "rssOpenPage", { article: article }, RssView.confirmLine("rssOpenPage", { host: r.host }))
      return
    }
    if (svcHas("openUrl") && !service.openUrl(article.link)) note(View.BUSY_NOTE, "muted")
  }

  function processingOn(confirmed) {
    if (confirmed !== true) {
      var items = view.items || ({})
      raise("rss.processingOn", "rssProcessingOn", ({}), RssView.confirmLine("rssProcessingOn", { n: items.refreshInterval }))
      return
    }
    if (!svcHas("setPref")) return
    var t = Number(service.setPref("rss_processing_enabled", "true", client.opts([]))) || 0
    if (t > 0) processingTicket = t
    else note(View.BUSY_NOTE, "muted")
  }

  // ---- the ends of the writes ---------------------------------------------------------

  function finished(ticket, ok, error, data) {
    var e = take(ticket)
    if (!e) return
    if (e.kind === "add") {
      if (!ok) { fail(error); return }
      var via = data && typeof data === "object" && (data.via === "magnet" || data.via === "url") ? data.via : e.via
      if (via === "magnet") awaiter.add(e.v1, e.v2, e.title, { feedPath: e.feedPath, guid: e.guid })
      else note(RssView.WINDOW.sent, "muted")
      return
    }
    if (!ok) {
      fail(error)
      readItems()
      return
    }
    if (e.kind === "follow") view.pendingFollow = data && typeof data === "object" && typeof data.path === "string" ? data.path : e.path
    if (e.kind === "markAll" && data && typeof data === "object" && data.ok === false && typeof data.unread === "number") {
      // OV11: nothing was marked; the new count is asked about while RSS
      // shows in NORMAL. Anything else up (an INSERT, another CONFIRM) is
      // never replaced: the count is a note and the column is read again.
      if (view.open && !view.downShown && client && client.mode === "NORMAL") {
        markAllRead(e.item, data.unread, false, true)
        return
      }
      note(RssView.sentence("moreArrivedNote", { n: data.unread }), "muted")
      readItems()
      return
    }
    readItems()
  }

  function actionFinished(ticket, ok, error) {
    if (processingTicket === 0 || Number(ticket) !== processingTicket) return
    processingTicket = 0
    if (!ok) fail(error)
    readItems()
  }

  property Connections serviceLink: Connections {
    target: cmds.service
    ignoreUnknownSignals: true
    function onRssFinished(ticket, ok, error, data) { cmds.finished(ticket, ok, error, data) }
    function onActionFinished(ticket, ok, error, origin, hashes) { cmds.actionFinished(ticket, ok, error) }
  }
}
