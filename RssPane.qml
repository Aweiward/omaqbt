pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import "ClientView.js" as View
import "RssView.js" as RssView
import "LinkRules.js" as Links
import "Model.js" as Model


// The RSS view (slice 5b1). Task 1 wrote the view host contract below;
// Task 3 (the window lane) filled it in, keeping that interface, with
// RssCommands.qml for the behaviour behind each key and RssView.js for the
// pure rules and the copy. Client.qml, ClientCommands.qml
// and ClientView.js call the properties, signals and functions below with
// the meaning given here. See tests/fixtures/rss-contract.md for qbt's side
// (`qbt rss …`, every value on stdin) and tests/fixtures/rss-rules-cases.json
// for the rules and every sentence (`sentences`, `window`), which the view
// reads, never retypes.
//
// `N` or ":RSS" makes it the active view (Client.activeView "rss"): it
// replaces the three torrent panes, like Search, and the status line stays.
// Three columns: Feeds (Unread, All articles, then the folders and their
// feeds, indented, with unread counts), Articles, and the Article pane (the
// article under the cursor: title, date, host, "Torrent link" or "No torrent
// link", and the description as PlainText, first 12 lines; the description
// comes from `qbt rss article` once the cursor settles for 150 ms, cached per
// (feed url, guid)). Narrow, one
// column at a time: a feed chip, Tab opens the feeds overlay (pane
// rssFeedList, a ListOverlay without its field: the keys stay NORMAL), and
// `l` shows the Article pane full width (`h` back). Every string from a feed
// or an article is PlainText. qBittorrent down shows the torrent view's
// down screen.
//
// Given by the Client:
//   service      Service (the rss lane: rssItems, rssArticle, rssError,
//                rssAddFeed, rssAddFolder, rssRename, rssRemove, rssRefresh,
//                rssMarkRead, rssAdd, rssFinished; setPref for O).
//   client       the Client: note(text, tone), track(...), messages,
//                regState/confirm (a CONFIRM the view raises with
//                Registry.raiseConfirm, as SearchPane does), leaveView(),
//                tableState, service.
//   commands     ClientCommands: startInput(purpose, initial), endInput(),
//                stayInInsert(), setMode(mode), inputLine.
//   tableState   the torrent view's View.tableState (the down screens).
//   narrow       below the breakpoint (View.settingsNarrow).
//   open         bound to Client.activeView === "rss".
//
// The view host contract (docs/plans/slice-5b0.md; SettingsHost.qml and
// SearchPane.qml are the other hosts): the Client and ClientCommands find it
// by `name` (Client.viewHost) and loop over the hosts.
//
// Read by the Client:
//   name         "rss", the view's name in Registry.VIEWS.
//   inputPurposes  the INSERT purposes this view owns
//                (View.VIEW_INPUT_PURPOSES_BY_VIEW.rss): "rssFeedUrl" (a's
//                URL, then) "rssFeedName" (prefilled with the URL's host,
//                OV4), "rssFolderName" (N) and "rssRename" (n, prefilled
//                with the current name). ClientCommands hands their commit
//                and cancel here, and Client the field's edits. Prompts and
//                hints: View.inputPrompt / View.modeHints. The name and
//                rename placeholders never show (ClientCommands.inputShown
//                has no host route); the prefill carries the host or name.
//                An unchanged rename ends the INSERT with no qbt call.
//   column       the pane keys dispatch in while RSS shows (Client.keyPane):
//                "rssFeeds", "rssArticles" or "rssFeedList" (narrow overlay).
//   flags        the dispatch flags (View.VIEW_FLAG_STATE.rss writes them into
//                the dispatch state every time; View.rssFooterKeys reads them
//                for the footer, through the Client's `rss` footer field),
//                always an object:
//                  rssItem          {path, name, folder, feeds} of the real
//                                   feed or folder under the Feeds cursor
//                                   (feeds: the folder's feed count, 0 for a
//                                   feed), or null (Unread, All, none);
//                                   dispatch state rssItem;
//                  rssFeedRow       any Feeds row is under the cursor,
//                                   Unread and All included;
//                  rssArticle       {feedPath, guid, title, isRead,
//                                   hasTorrent, inLibrary, link, torrentURL,
//                                   host} under the Articles cursor, or null;
//                  rssUnread        the unread count in the Feeds cursor's
//                                   scope (a number);
//                  rssProcessingOff RSS processing is off in qBittorrent;
//                  rssUp            qBittorrent is reachable (false over the
//                                   down screen: every need but rssFeedRow
//                                   then says "qBittorrent isn't reachable");
//                                   also false until the first `qbt rss
//                                   items` answer arrives;
//                  narrow           as above;
//                  wide             the Article pane is full width (narrow
//                                   only); dispatch state rssWide.
//   pickerOpen, picker  false and null: RSS has no picker (5b2's feeds
//                picker will).
//   leaveRequested()  asks the Client to leave RSS (Esc). The view never
//                hides itself.
//
// Called by the Client:
//   openView()   RSS just became the active view (read the items; start the
//                polls: every 2 s while any feed isLoading, else 5 min).
//   closeView()  RSS just stopped being the active view (Esc, a magnet's
//                CONFIRM, a torrent row from the palette, closing the
//                window): stop the polls; the cursors are kept.
//   windowClosed()  the window is closing: drop an RSS CONFIRM still up
//                (kinds View.RSS_ACCEPT: mode back to NORMAL, no pending,
//                client.confirm null), as SearchPane.dropConfirm does.
//   acceptPicker(), dropPicker()  no-ops (no picker).
//   togglePicker() -> false.
//   owns(commandId) -> whether Client.run hands this command here: every
//                rss.* row except rss.open.
//   run(commandId, args, ev)  one of those commands, resolved by
//                CommandRegistry. args (frozen copies taken at key time):
//                  args.item     rssItem (rss.addFeed, rss.addFolder,
//                                rss.rename, rss.remove, rss.refresh,
//                                rss.markAllRead; null means everything, or
//                                the root for a new feed or folder);
//                  args.article  rssArticle (rss.markRead, rss.add,
//                                rss.openPage, rss.articleWide);
//                  args.unread   rssUnread (rss.markAllRead: the count its
//                                confirm names, qbt's mark-read `expect`);
//                  args.confirmed  true after the view's own CONFIRM's y.
//                The view raises every CONFIRM itself with
//                Registry.raiseConfirm(client.regState, commandId, kind, args)
//                and client.confirm = {..., kind, line} (View.confirmLine
//                shows `line`; `y` comes back as the same commandId with
//                args.confirmed): rss.add → rssAdd, rss.openPage →
//                rssOpenPage, rss.remove → rssRemove, rss.markAllRead →
//                rssMarkRead, rss.processingOn → rssProcessingOn. It starts
//                the INSERTs itself (commands.startInput): rss.addFeed
//                (rssFeedUrl, then rssFeedName), rss.addFolder
//                (rssFolderName), rss.rename (rssRename).
//                rss.switch: Tab between the columns; narrow, it opens the
//                feeds overlay (column "rssFeedList"). rss.toFeeds (h) while
//                `wide`: back to the articles. rss.back: leaveRequested().
//                rss.feedsPick: pick the overlay's feed and close it;
//                rss.feedsClose: close it.
//   commitInput(purpose, text)  Enter in one of this view's INSERTs; the view
//                ends it (commands.endInput) or keeps it open with a reason
//                (client.note + commands.stayInInsert).
//   cancelInput(purpose)  Esc (or a click) ended that INSERT.
//   inputEdited(purpose, text)  the field changed while it's open.
//   flagsNow()   -> `flags` while RSS is the active view (open), else null.
Item {
  id: rss
  objectName: "rssView"

  property var service: null
  property var client: null
  property var commands: null
  property string tableState: "rows"
  property bool narrow: false
  property bool open: false

  property string column: "rssFeeds"
  // The view host contract (the header).
  readonly property string name: "rss"
  readonly property var inputPurposes: View.VIEW_INPUT_PURPOSES_BY_VIEW.rss
  readonly property bool pickerOpen: false
  readonly property var picker: null

  // The behaviour behind each key (RssCommands.qml).
  readonly property var cmds: rssCmds

  // ---- the items -------------------------------------------------------------------------
  // `qbt rss items`' last applied answer ({processing, refreshInterval,
  // feeds, articles}), and whether one arrived yet.
  property var items: null
  property bool loaded: false
  // How many answers were applied (a read Service flags `same` isn't).
  property int applyCount: 0
  // A write's new path (a, N, n): the Feeds cursor goes there once read.
  property string pendingFollow: ""

  // ---- the Feeds column -------------------------------------------------------------------
  property var feedRowsList: RssView.feedRows(null)
  property int feedIndex: 0
  // The row's key ("unread", "all", "p:<path>"): the cursor stays on it
  // across reads, and clamps to a neighbour when it goes (Review Focus 2).
  property string feedKey: "unread"
  property var currentFeed: feedRowsList[0]
  // The narrow feeds overlay's own cursor (Enter picks it).
  property int overlayIndex: 0

  // ---- the Articles column ------------------------------------------------------------------
  // The rows the model holds (Model.diffRows' `hash` is keyOf), and each
  // lean row (RssView.articleRows) by key.
  property var lastRows: []
  property var articleByKey: ({})
  property string articleKey: ""
  property int cursorIndex: -1
  property var currentArticle: null
  // Narrow: the Article pane full width (l; h back).
  property bool wide: false

  // The library's ids (Links.librarySet), for "in library" (D7).
  property var libSet: ({})

  // ---- timing (tests shorten these) ------------------------------------------------------------
  property int fastPollMs: 2000
  property int slowPollMs: 300000
  property int refreshCapMs: 60000
  property int settleMs: 150
  // How long a magnet has to show up in the library (OV2).
  property int addConfirmMs: 30000

  readonly property bool loading: loaded && RssView.anyLoading(items)
  // The refresh took longer than refreshCapMs: the fast poll stops and
  // "Still refreshing; …" shows until nothing loads.
  property bool capped: false
  readonly property bool pollsRunning: fastTimer.running || slowTimer.running || capTimer.running || retryTimer.running

  readonly property bool processingOff: loaded && !!items && items.processing === false
  readonly property bool downShown: ["gui", "notInstalled", "daemon", "api"].indexOf(tableState) !== -1

  readonly property var flags: ({ rssItem: rss.downShown || !rss.currentFeed ? null : rss.currentFeed.rssItem,
    rssFeedRow: rss.currentFeed !== null && rss.currentFeed !== undefined,
    rssArticle: rss.downShown ? null : rss.currentArticle,
    rssUnread: rss.currentFeed ? rss.currentFeed.unread : 0,
    rssProcessingOff: rss.processingOff,
    rssUp: rss.loaded && !rss.downShown,
    narrow: rss.narrow,
    wide: rss.narrow && rss.wide })

  readonly property int padX: Style.space(12)
  readonly property int rowHeight: Style.space(28)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property color dimColor: Util.alpha(Color.foreground, 0.4)

  signal leaveRequested()

  visible: open

  // ---- the Client's calls ---------------------------------------------------------------

  function openView() {
    column = "rssFeeds"
    wide = false
    syncLibrary()
    rssCmds.readItems()
    // A feed still loading from before (Esc, then N): the cap starts
    // again, so the fast poll never runs unbounded.
    armCap()
    showFeedCursor()
  }

  function closeView() {
    column = "rssFeeds"
    wide = false
    capped = false
    capTimer.stop()
    settleTimer.stop()
  }

  function windowClosed() {
    dropConfirm()
    rssCmds.awaiter.clear()
    rssCmds.input = null
  }

  // An RSS CONFIRM still up goes: mode back to NORMAL, no pending.
  function dropConfirm() {
    var c = client
    if (!c || c.mode !== "CONFIRM" || !c.confirm || View.RSS_ACCEPT[c.confirm.kind] === undefined) return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
  }

  function owns(commandId) {
    var id = String(commandId || "")
    return id !== "rss.open" && id.indexOf("rss.") === 0
  }

  function run(commandId, args, ev) {
    if (!open) return
    // The down screen: only the ways out.
    if (downShown && ["rss.back", "rss.feedsClose"].indexOf(commandId) === -1) return
    var a = args || ({})
    switch (commandId) {
    case "rss.down": move(1); return
    case "rss.up": move(-1); return
    case "rss.toArticles": column = "rssArticles"; return
    case "rss.toFeeds":
      if (wide) wide = false
      else column = "rssFeeds"
      return
    case "rss.switch":
      if (narrow && column === "rssArticles") { overlayIndex = feedIndex; column = "rssFeedList" }
      else column = column === "rssFeeds" ? "rssArticles" : "rssFeeds"
      return
    case "rss.articleWide": if (narrow) wide = true; return
    case "rss.feedsPick": selectFeed(overlayIndex); column = "rssArticles"; return
    case "rss.feedsClose": column = "rssArticles"; return
    case "rss.back": leaveRequested(); return
    case "rss.addFeed": rssCmds.addFeed(a.item); return
    case "rss.addFolder": rssCmds.addFolder(a.item); return
    case "rss.rename": rssCmds.rename(a.item); return
    case "rss.remove": rssCmds.remove(a.item, a.confirmed === true); return
    case "rss.refresh": rssCmds.refresh(a.item); return
    case "rss.markAllRead": rssCmds.markAllRead(a.item, a.unread, a.confirmed === true); return
    case "rss.markRead": rssCmds.markRead(a.article); return
    case "rss.add": rssCmds.add(a.article, a.confirmed === true); return
    case "rss.openPage": rssCmds.openPage(a.article, a.confirmed === true); return
    case "rss.processingOn": rssCmds.processingOn(a.confirmed === true); return
    default: return
    }
  }

  function commitInput(purpose, text) {
    rssCmds.commitInput(purpose, text)
  }

  function cancelInput(purpose) {
    rssCmds.cancelInput()
  }

  function inputEdited(purpose, text) {
  }

  function flagsNow() {
    return open ? flags : null
  }

  function acceptPicker() {
  }

  function dropPicker() {
  }

  function togglePicker() {
    return false
  }

  // ---- the items ---------------------------------------------------------------------------

  function applyItems(data) {
    items = data
    loaded = true
    applyCount++
    var rows = RssView.feedRows(data)
    var want = pendingFollow !== "" ? "p:" + pendingFollow : feedKey
    pendingFollow = ""
    var at = -1
    for (var i = 0; i < rows.length; i++) if (rows[i].key === want) { at = i; break }
    if (at === -1) {
      for (var k = 0; k < rows.length; k++) if (rows[k].key === feedKey) { at = k; break }
    }
    if (at === -1) at = Math.max(0, Math.min(feedIndex, rows.length - 1))
    feedRowsList = rows
    feedIndex = at
    syncFeed()
    applyArticles()
    rssCmds.itemsApplied()
    showFeedCursor()
  }

  // The Feeds column scrolls to its cursor (a read swaps its model, which
  // drops the ListView's currentIndex, so it is set here, not bound).
  function showFeedCursor() {
    if (feedIndex < 0 || feedIndex >= feedRowsList.length) return
    feedList.forceLayout()
    feedList.currentIndex = feedIndex
    feedList.positionViewAtIndex(feedIndex, ListView.Contain)
  }

  function syncFeed() {
    currentFeed = feedRowsList[feedIndex] || null
    feedKey = currentFeed ? currentFeed.key : ""
  }

  function feedUrl(path) {
    for (var i = 0; i < feedRowsList.length; i++) if (feedRowsList[i].kind === "feed" && feedRowsList[i].path === path) return feedRowsList[i].url
    return ""
  }

  function selectFeed(index) {
    var n = feedRowsList.length
    if (n === 0) return
    var at = Math.max(0, Math.min(n - 1, index))
    if (at === feedIndex && currentFeed && currentFeed.key === feedKey) return
    feedIndex = at
    syncFeed()
    applyArticles()
    rssCmds.checkError()
    showFeedCursor()
  }

  function move(delta) {
    if (column === "rssFeeds") { selectFeed(feedIndex + delta); return }
    if (column === "rssFeedList") {
      overlayIndex = Math.max(0, Math.min(feedRowsList.length - 1, overlayIndex + delta))
      return
    }
    if (lastRows.length === 0) return
    var at = Math.max(0, Math.min(lastRows.length - 1, (cursorIndex < 0 ? 0 : cursorIndex) + delta))
    articleKey = lastRows[at].hash
    syncArticle()
    articleList.positionViewAtIndex(at, ListView.Contain)
  }

  // ---- the Articles column ----------------------------------------------------------------

  function dateText(d) {
    return typeof d === "number" ? Qt.formatDateTime(new Date(d * 1000), "yyyy-MM-dd HH:mm") : RssView.EMPTY
  }

  // The model's lean row: one fixed type per role.
  function modelRow(r) {
    return { hash: r.key, title: r.title, dateText: dateText(r.date), isRead: r.isRead === true, inLibrary: r.inLibrary === true,
      hasTorrent: r.hasTorrent === true }
  }

  // The Articles column again, from the items, the Feeds cursor's scope
  // and the library: patched in place with Model.diffRows (the torrent
  // table's keyed diff), the cursor kept on its article by key.
  function applyArticles() {
    var rows = RssView.articleRows(items, RssView.scopeOf(currentFeed), libSet)
    var byKey = ({})
    var next = []
    for (var i = 0; i < rows.length; i++) {
      byKey[rows[i].key] = rows[i]
      next.push(modelRow(rows[i]))
    }
    var ops = Model.diffRows(lastRows, next, ["title", "dateText", "isRead", "inLibrary", "hasTorrent"])
    if (!Array.isArray(ops)) {
      articleModel.clear()
      for (var r = 0; r < next.length; r++) articleModel.append(next[r])
    } else {
      for (var j = 0; j < ops.length; j++) {
        var op = ops[j]
        if (op.op === "set") articleModel.set(op.index, op.row)
        else if (op.op === "insert") articleModel.insert(op.index, op.row)
        else if (op.op === "remove") articleModel.remove(op.index, 1)
        else if (op.op === "move") articleModel.move(op.from, op.to, 1)
      }
    }
    var before = cursorIndex
    lastRows = next
    articleByKey = byKey
    if (byKey[articleKey] === undefined) {
      var at = Math.max(0, Math.min(before < 0 ? 0 : before, next.length - 1))
      articleKey = next.length > 0 ? next[at].hash : ""
    }
    syncArticle()
  }

  function syncArticle() {
    var r = articleKey !== "" ? articleByKey[articleKey] : undefined
    var idx = -1
    if (r) for (var i = 0; i < lastRows.length; i++) if (lastRows[i].hash === articleKey) { idx = i; break }
    cursorIndex = idx
    var was = currentArticle ? RssView.keyOf(currentArticle) : ""
    currentArticle = r ? { feedPath: r.feedPath, guid: r.guid, title: r.title, isRead: r.isRead, hasTorrent: r.hasTorrent,
      inLibrary: r.inLibrary, link: r.link, torrentURL: r.torrentURL, host: r.host, date: r.date } : null
    if (articleKey !== was) settleTimer.restart()
  }

  function articleKeys() {
    var out = []
    for (var i = 0; i < lastRows.length; i++) out.push(lastRows[i].hash)
    return out
  }

  function syncLibrary() {
    libSet = Links.librarySet(service ? service.torrents : [])
    rssCmds.awaiter.check()
    if (open && loaded) applyArticles()
  }

  // `r`: the cap starts over.
  function refreshStarted() {
    capped = false
    capTimer.stop()
    armCap()
  }

  // The 60 s cap on the fast poll runs only while RSS shows and qBittorrent
  // is up; an items read landing after closeView never starts it.
  function armCap() {
    if (open && !downShown && loading && !capped && !capTimer.running) capTimer.start()
  }

  onLoadingChanged: {
    if (loading) {
      armCap()
    } else {
      capped = false
      capTimer.stop()
    }
  }
  onDownShownChanged: {
    if (downShown) {
      dropConfirm()
      capTimer.stop()
    } else if (open) {
      rssCmds.readItems()
      armCap()
    }
  }
  onNarrowChanged: {
    if (!narrow) {
      wide = false
      if (column === "rssFeedList") column = "rssArticles"
    }
  }
  onServiceChanged: syncLibrary()

  RssCommands {
    id: rssCmds
    view: rss
  }

  Connections {
    target: rss.service
    ignoreUnknownSignals: true
    function onTorrentsChanged() { rss.syncLibrary() }
  }

  // Every 2 s while a feed refreshes (capped at refreshCapMs), every 5 min
  // otherwise; neither while RSS is closed or qBittorrent is down.
  Timer {
    id: fastTimer
    interval: rss.fastPollMs
    repeat: true
    running: rss.open && !rss.downShown && rss.loading && !rss.capped
    onTriggered: rss.cmds.readItems()
  }
  Timer {
    id: slowTimer
    interval: rss.slowPollMs
    repeat: true
    running: rss.open && !rss.downShown
    onTriggered: rss.cmds.readItems()
  }
  Timer {
    id: capTimer
    interval: rss.refreshCapMs
    repeat: false
    onTriggered: if (rss.open && !rss.downShown && rss.loading) rss.capped = true
  }
  // A failed first read: again every fastPollMs until one succeeds (rssUp
  // stays false until then).
  Timer {
    id: retryTimer
    interval: rss.fastPollMs
    repeat: true
    running: rss.open && !rss.downShown && !rss.loaded && rssCmds.itemsFailed
    onTriggered: rss.cmds.readItems()
  }
  // The Articles cursor settles: its description.
  Timer {
    id: settleTimer
    interval: rss.settleMs
    repeat: false
    onTriggered: rss.cmds.loadDescription()
  }

  ListModel { id: articleModel }

  Rectangle {
    anchors.fill: parent
    color: Color.background
  }

  // ---- the footer the columns share -----------------------------------------------------

  component KeyFooter: Item {
    id: footerItem
    property var keys: []
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: keyFlow.implicitHeight + Style.space(12)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
    }

    Flow {
      id: keyFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)
      Repeater {
        model: footerItem.keys
        delegate: Row {
          id: hint
          required property var modelData
          Text {
            text: hint.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
          }
          Text {
            text: " " + hint.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.muted
          }
        }
      }
    }
  }

  function footerText(keys) {
    var parts = []
    for (var i = 0; i < keys.length; i++) parts.push(keys[i].key + " " + keys[i].label)
    return parts.join(" · ")
  }

  // ---- the banner (processing off) ---------------------------------------------------------

  Item {
    id: banner
    objectName: "rssBanner"
    visible: rss.processingOff && !rss.downShown
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: visible ? bannerText.implicitHeight + Style.space(16) : 0

    Text {
      id: bannerText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: rss.padX
      anchors.rightMargin: rss.padX
      anchors.verticalCenter: parent.verticalCenter
      wrapMode: Text.Wrap
      text: RssView.WINDOW.banner
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.accent
    }
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: rss.lineColor
    }
  }

  // ---- the Feeds column ---------------------------------------------------------------------

  ClientPane {
    id: feedsPane
    objectName: "rssFeedsPane"
    anchors.left: parent.left
    anchors.top: banner.bottom
    anchors.bottom: parent.bottom
    width: rss.narrow ? parent.width : Style.space(250)
    title: "Feeds"
    focusedPane: rss.column === "rssFeeds"
    swappedOut: rss.downShown || (rss.narrow && rss.column !== "rssFeeds")

    ListView {
      id: feedList
      objectName: "rssFeedList"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: feedsFooter.top
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: rss.feedRowsList
      // showFeedCursor positions it at once; no animated follow.
      highlightFollowsCurrentItem: false
      // The footer re-flows (its keys follow the cursor): keep the row shown.
      onHeightChanged: if (rss.feedIndex >= 0 && rss.feedIndex < count) positionViewAtIndex(rss.feedIndex, ListView.Contain)
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Item {
        id: feedRow
        required property var modelData
        required property int index
        readonly property bool current: index === rss.feedIndex
        width: feedList.width
        height: rss.rowHeight

        Rectangle {
          visible: feedRow.current
          anchors.fill: parent
          color: Style.selectedAccentFill
        }
        Rectangle {
          visible: feedRow.current && feedsPane.focusedPane
          width: Style.space(3)
          height: parent.height
          color: Color.accent
        }
        Text {
          id: feedLabel
          anchors.left: parent.left
          anchors.leftMargin: rss.padX + feedRow.modelData.depth * Style.space(14)
          anchors.right: feedState.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: feedRow.modelData.label
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.body
          font.bold: feedRow.modelData.kind === "folder"
          color: feedRow.current ? Color.accent : Color.foreground
        }
        Text {
          id: feedState
          anchors.right: feedCount.left
          anchors.rightMargin: text !== "" ? Style.space(8) : 0
          anchors.verticalCenter: parent.verticalCenter
          text: feedRow.modelData.state
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.caption
          color: feedRow.modelData.hasError ? Color.urgent : Color.muted
        }
        Text {
          id: feedCount
          anchors.right: parent.right
          anchors.rightMargin: rss.padX
          anchors.verticalCenter: parent.verticalCenter
          text: feedRow.modelData.unread > 0 ? String(feedRow.modelData.unread) : ""
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Color.muted
        }
        MouseArea {
          anchors.fill: parent
          onClicked: {
            rss.column = "rssFeeds"
            rss.selectFeed(feedRow.index)
          }
        }
      }
    }

    KeyFooter {
      id: feedsFooter
      keys: View.rssFooterKeys("rssFeeds", rss.flags)
    }
  }

  // ---- the Articles column -------------------------------------------------------------------

  ClientPane {
    id: articlesPane
    objectName: "rssArticlesPane"
    anchors.left: rss.narrow ? parent.left : feedsPane.right
    anchors.right: rss.narrow ? parent.right : articlePane.left
    anchors.top: banner.bottom
    anchors.bottom: parent.bottom
    title: "Articles"
    titleRight: rss.lastRows.length > 0 ? String(rss.lastRows.length) : ""
    focusedPane: rss.column === "rssArticles" || rss.column === "rssFeedList"
    swappedOut: rss.downShown || (rss.narrow && (rss.column === "rssFeeds" || rss.wide))

    // Narrow: the Feeds column is this chip (Tab opens the overlay).
    Rectangle {
      id: feedChip
      objectName: "rssFeedChip"
      visible: rss.narrow
      anchors.left: parent.left
      anchors.leftMargin: rss.padX
      anchors.top: parent.top
      anchors.topMargin: Style.space(4)
      width: visible ? chipText.implicitWidth + Style.space(14) : 0
      height: visible ? Style.space(22) : 0
      color: "transparent"
      border.width: 1
      border.color: rss.lineColor
      Text {
        id: chipText
        anchors.centerIn: parent
        text: (rss.currentFeed ? rss.currentFeed.label : RssView.WINDOW.unreadRow) + " ▾"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.accent
      }
      MouseArea {
        anchors.fill: parent
        onClicked: { rss.overlayIndex = rss.feedIndex; rss.column = "rssFeedList" }
      }
    }

    // A failing feed's reason, or the refresh that doesn't end.
    Item {
      id: noticeLine
      visible: noticeText.text !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: feedChip.bottom
      anchors.topMargin: visible ? Style.space(4) : 0
      height: visible ? noticeText.implicitHeight + Style.space(8) : 0
      Text {
        id: noticeText
        objectName: "rssNotice"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        leftPadding: rss.padX
        rightPadding: rss.padX
        wrapMode: Text.Wrap
        text: {
          void rss.cmds.errorVersion
          var lines = []
          var e = rss.cmds.errorLine(rss.currentFeed)
          if (e !== "") lines.push(e)
          if (rss.capped && rss.loading) lines.push(RssView.WINDOW.stillRefreshing)
          return lines.join("\n")
        }
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.urgent
      }
    }

    ListView {
      id: articleList
      objectName: "rssArticleList"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: noticeLine.bottom
      anchors.bottom: articlesFooter.top
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: articleModel
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Item {
        id: articleRow
        required property string hash
        required property string title
        required property string dateText
        required property bool isRead
        required property bool inLibrary
        readonly property bool current: hash === rss.articleKey
        width: articleList.width
        height: rss.rowHeight

        Rectangle {
          visible: articleRow.current
          anchors.fill: parent
          color: Style.selectedAccentFill
        }
        Rectangle {
          visible: articleRow.current && articlesPane.focusedPane
          width: Style.space(3)
          height: parent.height
          color: Color.accent
        }
        Text {
          id: titleText
          anchors.left: parent.left
          anchors.leftMargin: rss.padX
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, articleRow.width - 2 * rss.padX - dateCell.width - (libTag.visible ? libTag.width + Style.space(8) : 0) - Style.space(12))
          elide: Text.ElideRight
          text: articleRow.title
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.body
          font.bold: !articleRow.isRead
          color: articleRow.current ? Color.accent : (articleRow.isRead ? rss.dimColor : Color.foreground)
        }
        Rectangle {
          id: libTag
          visible: articleRow.inLibrary
          anchors.left: titleText.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: libText.implicitWidth + Style.space(10)
          height: libText.implicitHeight + Style.space(2)
          color: "transparent"
          border.width: 1
          border.color: rss.lineColor
          Text {
            id: libText
            anchors.centerIn: parent
            text: RssView.WINDOW.rowInLibrary
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.caption
            color: Color.muted
          }
        }
        Text {
          id: dateCell
          anchors.right: parent.right
          anchors.rightMargin: rss.padX
          anchors.verticalCenter: parent.verticalCenter
          text: articleRow.dateText
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Color.muted
        }
        MouseArea {
          anchors.fill: parent
          onClicked: {
            rss.column = "rssArticles"
            rss.articleKey = articleRow.hash
            rss.syncArticle()
          }
        }
      }
    }

    // The empty states.
    Text {
      objectName: "rssEmpty"
      visible: text !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: noticeLine.bottom
      anchors.topMargin: Style.space(24)
      leftPadding: Style.space(16)
      rightPadding: Style.space(16)
      wrapMode: Text.Wrap
      text: RssView.stateText({ loaded: rss.loaded, feeds: RssView.feedCount(rss.items), scope: rss.currentFeed ? rss.currentFeed.kind : "",
        rows: rss.lastRows.length })
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.subtitle
      color: Color.muted
    }

    KeyFooter {
      id: articlesFooter
      keys: View.rssFooterKeys("rssArticles", rss.flags)
    }
  }

  // ---- the Article pane -------------------------------------------------------------------------

  ClientPane {
    id: articlePane
    objectName: "rssArticlePane"
    anchors.right: parent.right
    anchors.top: banner.bottom
    anchors.bottom: parent.bottom
    width: rss.narrow ? parent.width : Style.space(380)
    title: "Article"
    focusedPane: rss.narrow && rss.wide
    rightLine: false
    swappedOut: rss.downShown || (rss.narrow && !rss.wide)

    readonly property var meta: RssView.articleMeta(rss.currentArticle)

    Flickable {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: articleFooter.top
      clip: true
      contentWidth: width
      contentHeight: articleColumn.height + Style.space(16)
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: articleColumn
        visible: articlePane.meta !== null
        x: rss.padX
        width: parent.width - 2 * rss.padX
        topPadding: Style.space(8)
        spacing: Style.space(6)

        Text {
          objectName: "rssArticleTitle"
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: 4
          elide: Text.ElideRight
          text: articlePane.meta ? articlePane.meta.title : ""
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          color: Color.foreground
        }
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: articlePane.meta ? rss.dateText(articlePane.meta.date) + " · " + articlePane.meta.host : ""
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Color.muted
        }
        Text {
          width: parent.width
          text: articlePane.meta ? articlePane.meta.torrent : ""
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: rss.currentArticle && rss.currentArticle.hasTorrent ? Color.accent : Color.muted
        }
        Rectangle {
          width: parent.width
          height: 1
          color: rss.lineColor
        }
        // The description (`qbt rss article`), first 12 lines, as text.
        Text {
          objectName: "rssDescription"
          width: parent.width
          wrapMode: Text.Wrap
          maximumLineCount: RssView.DESCRIPTION_LINES
          elide: Text.ElideRight
          text: {
            void rss.cmds.descVersion
            return rss.cmds.description(rss.currentArticle)
          }
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.body
          color: Color.foreground
        }
      }
    }

    KeyFooter {
      id: articleFooter
      visible: rss.narrow
      keys: View.rssFooterKeys("rssArticles", rss.flags)
    }
  }

  // ---- the down screen: the torrent view's own, reused -----------------------------------

  ClientPane {
    objectName: "rssDown"
    anchors.fill: parent
    title: "RSS"
    focusedPane: true
    rightLine: false
    swappedOut: !rss.downShown

    TorrentTable {
      anchors.fill: parent
      tableState: "api"
      stateCopy: View.settingsDownCopy(rss.tableState)
    }
  }

  // ---- the feeds overlay (narrow, Tab): ListOverlay without its field ----------------------
  // Loaded only while it shows, so the window's palette stays the first
  // ListOverlay a search of the tree finds.

  function overlayRows() {
    var out = []
    for (var i = 0; i < feedRowsList.length; i++) {
      var f = feedRowsList[i]
      var indent = ""
      for (var d = 0; d < f.depth; d++) indent += "  "
      out.push({ kind: "feed", title: indent + f.label, indices: [], enabled: true, reason: "", keys: f.unread > 0 ? String(f.unread) : "" })
    }
    return out
  }

  Loader {
    id: overlayLoader
    anchors.fill: parent
    active: rss.open && rss.column === "rssFeedList"
    sourceComponent: Component {
      ListOverlay {
        id: feedOverlay
        objectName: "rssFeedOverlay"
        keyMode: "PICKER"
        prompt: "Feeds"
        rows: rss.overlayRows()
        cursor: rss.overlayIndex
        footerHint: rss.footerText(View.rssFooterKeys("rssFeedList", rss.flags))
        onDismissed: rss.run("rss.feedsClose", ({}))
        onActivated: function(row) { rss.overlayIndex = feedOverlay.cursor; rss.run("rss.feedsPick", ({})) }
        Component.onCompleted: {
          feedOverlay.inputField.visible = false
          feedOverlay.inputField.enabled = false
        }
      }
    }
  }
}
