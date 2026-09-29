import QtQuick
import "ClientView.js" as View

// The RSS view (slice 5b1). Task 1 left this placeholder: every member of
// the view host contract below, with empty bodies; Task 3 (the window lane)
// replaces the file, keeping this interface. Client.qml, ClientCommands.qml
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

  // Task 1's placeholder flags: nothing under a cursor, qBittorrent not yet read.
  readonly property var flags: ({ rssItem: null, rssFeedRow: false, rssArticle: null, rssUnread: 0, rssProcessingOff: false,
    rssUp: false, narrow: rss.narrow, wide: false })

  signal leaveRequested()

  visible: open

  function openView() {
    column = "rssFeeds"
  }

  function closeView() {
    column = "rssFeeds"
  }

  function windowClosed() {
  }

  function owns(commandId) {
    var id = String(commandId || "")
    return id !== "rss.open" && id.indexOf("rss.") === 0
  }

  function run(commandId, args, ev) {
  }

  function commitInput(purpose, text) {
    if (commands) commands.endInput()
  }

  function cancelInput(purpose) {
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
}
