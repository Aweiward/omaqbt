pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import "ClientView.js" as View
import "SearchView.js" as SearchView
import "Model.js" as Model
import "CommandRegistry.js" as Registry

// The Search view (slice 5a). Task 1 left the mount point and this
// interface; Task 3 (the window lane) filled it in. Client.qml,
// ClientCommands.qml and ClientView.js call the properties, signals and
// functions below with the meaning given here. See
// tests/fixtures/search-contract.md for qbt's and the sidecar's side, and
// SearchCommands.qml for the behaviour behind each key.
//
// `F` or ":Search" makes it the active view (Client.activeView "search"):
// it replaces the three torrent panes, like Settings, and the status line
// stays. Esc stops a running search first, then leaves; the last search,
// its results and the cursor survive leaving (design D7). Closing the
// window deletes qBittorrent's job (eng A5/OV14): windowClosed().
//
// The layout (mockup panels 1-3, 7's caption): the query bar (the query,
// the plugins and category chips, and the run state with a thin accent bar
// while it runs), the Plugins column (All results, each plugin with its
// count, the "other" bucket, then Recent), and the results (Name, Size,
// Seeds, Peers, Plugin, Published; "in library" on a result already there)
// with the cursor row's help line. Narrow, the Plugins column is a chip in
// the query bar and an overlay while it has the keys, and Published and
// Peers hide first, then Plugin. `P` shows the plugins overlay (a
// ListOverlay without its field: the keys stay NORMAL). qBittorrent down
// shows the torrent view's down screen, except that one missed status line
// during a plugin update doesn't (OV4). Every string from a plugin or a
// site is PlainText, cleaned by SearchView first.
//
// Given by the Client:
//   service      Service (the sidecar's search replies, qbt search*).
//   client       the Client: note(text, tone), track(...), messages,
//                regState/confirm/confirmHashes (a CONFIRM the view raises
//                with Registry.raiseConfirm, as SettingsCommands does),
//                opts(hashes), leaveView(), tableState, service.
//   commands     ClientCommands: startInput(purpose, initial), endInput(),
//                stayInInsert(), setMode(mode), inputLine.
//   tableState   the torrent view's View.tableState (the down screens).
//   narrow       below the breakpoint (View.settingsNarrow): the Plugins
//                column is a chip, and Tab/h/Shift-Tab open it as an
//                overlay (pane searchPlugins while it shows).
//   open         bound to Client.activeView === "search".
//
// Slice 5b0: this is Search's view host (the view host contract,
// docs/plans/slice-5b0.md; SettingsHost.qml is Settings'): the Client and
// ClientCommands find it by `name` (Client.viewHost) and loop over the
// hosts, so every member below is part of that contract.
//
// Read by the Client:
//   name         "search", the view's name in Registry.VIEWS.
//   inputPurposes  the INSERT purposes this view owns
//                (View.VIEW_INPUT_PURPOSES_BY_VIEW.search: "searchQuery",
//                "pluginInstall"); ClientCommands hands their commit and
//                cancel here, and Client the field's edits.
//   column       the pane keys dispatch in while Search shows (Client.keyPane):
//                "searchResults", "searchPlugins" or "searchPluginList".
//   flags        the dispatch flags (View.dispatchState's `search`, and the
//                footer's View.searchFooterKeys), always an object:
//                  narrow         as above;
//                  result         the result under the results cursor, a
//                                 plain object (Registry freezes a copy
//                                 into args.result), or null;
//                  plugin         the plugin under the overlay's cursor
//                                 ({name, fullName, version, enabled, url}),
//                                 or null;
//                  plugins        how many plugins are installed;
//                  enabledPlugins how many are on (`/` needs one, OV8);
//                  pluginsBusy    a plugin install, uninstall, on/off or
//                                 update still running (Space, x, i, U wait);
//                  running        a search is running (Esc stops it first);
//                  category       the chosen category id ("all" by default).
//   category     the category the next `qbt search start --category` gets:
//                "all", or a category an enabled plugin supports (Ruling FB).
//   pickerOpen, picker  `c`'s category picker (Ruling FB): true while it's
//                open, and its ListOverlay (keyMode "PICKER", single choice)
//                or null. ClientCommands' picker.* commands drive it through
//                these, as they drive Settings' choice picker: up/down move
//                picker, Enter calls acceptPicker(), Esc and a scrim click
//                call commands.closePicker(), which calls dropPicker(). The
//                view opens it on search.category (commands.setMode("PICKER")
//                and picker.focusField()). Rows: "all" first, then each
//                category an enabled plugin lists, in qBittorrent's order
//                (tests/fixtures/search-contract.md).
//   leaveRequested()  asks the Client to leave Search (Esc with nothing to
//                stop). The view never hides itself.
//
// Called by the Client:
//   openView()   Search just became the active view (the plugins are read).
//   closeView()  Search just stopped being the active view (Esc, a magnet's
//                CONFIRM, a torrent row from the palette, closing the
//                window). The job and its results are kept.
//   windowClosed()  the window is closing: delete the job (qbt search delete),
//                and drop a Search CONFIRM still up (kinds View.SEARCH_ACCEPT:
//                mode back to NORMAL, no pending, client.confirm null), as
//                SettingsCommands.dropConfirm does for Settings'. Client.close
//                already closed an open picker (commands.closePicker).
//   acceptPicker()  Enter (or a click) on the category picker: take the row,
//                close the picker (commands.closePicker).
//   dropPicker()  ClientCommands.closePicker's hook: nothing of the picker stays.
//   owns(commandId) -> whether Client.run hands this command here: every
//                search.* and plugin.* row except search.open.
//   run(commandId, args)  one of those commands, resolved by
//                CommandRegistry (args.result / args.plugin captured at key
//                time; args.confirmed after the view's own CONFIRM's y).
//   commitInput(purpose, text)  Enter in the status-line INSERT for
//                "searchQuery" (`/`) or "pluginInstall" (`i`); the view
//                ends it (commands.endInput) or keeps it open with a reason
//                (client.note + commands.stayInInsert).
//   cancelInput(purpose)  Esc (or a click) ended that INSERT.
//   inputEdited(purpose, text)  the field changed while it's open.
//   flagsNow()   -> `flags` while Search is the active view (open), else
//                null: View.dispatchState's `search` (Client.searchFlags).
//   togglePicker() -> false: the category picker is single choice, so
//                Space/Tab never toggle in it (ClientCommands.togglePicker
//                goes on to C/T's).
Item {
  id: search
  objectName: "searchView"

  property var service: null
  property var client: null
  property var commands: null
  property string tableState: "rows"
  property bool narrow: false
  property bool open: false

  property string column: "searchResults"
  property string category: "all"
  // Slice 5b0: the view host contract (the header).
  readonly property string name: "search"
  readonly property var inputPurposes: View.VIEW_INPUT_PURPOSES_BY_VIEW.search
  property bool pickerOpen: false
  readonly property var picker: pickerLoader.item
  // The column `P` was pressed in, which the overlay's Esc returns to.
  property string overlayFrom: "searchResults"

  // ---- plugins ---------------------------------------------------------------------
  // `qbt search-plugin list`, as qbt printed it (qBittorrent's order).
  property var pluginList: []
  property bool pluginsLoaded: false
  property bool pluginsReading: false
  // The plugin change running: "install", "uninstall", "toggle", "update" or
  // "". Service's searchPluginChange, so a window rebuilt while a change
  // runs still shows it and waits (localBusy: a Service without it).
  property string localBusy: ""
  readonly property string busyKind: service && typeof service.searchPluginChange === "string" ? service.searchPluginChange : localBusy
  readonly property bool pluginsBusy: busyKind !== ""
  // A change ended (in this window or before it was rebuilt): the list again.
  onPluginsBusyChanged: if (!pluginsBusy) cmds.loadPlugins()
  readonly property int plugins: pluginList.length
  readonly property int enabledPlugins: SearchView.enabledCount(pluginList)
  property int pluginListIndex: 0
  readonly property var cursorPlugin: pluginList.length > 0 ? pluginList[Math.max(0, Math.min(pluginListIndex, pluginList.length - 1))] : null

  // ---- the job -----------------------------------------------------------------------
  // "none" (no search yet), "starting" (qbt search start runs), "running",
  // "done", "stopped" (after Esc, or the window closed), "gone" (qBittorrent
  // lost it) or "failed" (the start was refused).
  property string jobState: "none"
  property int jobId: 0
  property int startTicket: 0
  property bool stopWanted: false
  property string query: ""
  // The raw rows received (the offset the window owns, OV7), qBittorrent's
  // total, and whether it's past the sidecar's 2000 (OV15).
  property int held: 0
  property int total: 0
  property bool capped: false
  readonly property bool running: jobState === "starting" || jobState === "running"
  // Recent (the last 8 queries): Service keeps them so a rebuilt window
  // still has them; never on disk.
  property var localRecent: []
  readonly property var recent: service && service.searchRecent !== undefined ? service.searchRecent : localRecent
  function setRecent(list) {
    if (service && service.searchRecent !== undefined) service.searchRecent = list
    else localRecent = list
  }

  // ---- results -------------------------------------------------------------------
  // Every merged row (SearchView.mergeResults), the model shows those under
  // the Plugins column's filter: appended as they stream in, re-sorted only
  // on s/S or when the search finishes (eng P1).
  property var allRows: []
  property var rowByKey: ({})
  property var shownKeys: []
  property string sortMode: "seeds"
  property bool sortDesc: true
  // The Plugins column's filter: an engine name ("" is other), or null.
  property var pluginFilter: null
  property int columnIndex: 0
  property string cursorKey: ""
  readonly property int cursorIndex: shownKeys.indexOf(cursorKey)
  property var currentResult: null
  readonly property var counts: SearchView.pluginCounts(allRows)
  // The Plugins column: All results, the plugins, then Recent (Ruling FF:
  // cursor rows; Enter on one searches it again).
  readonly property var columnRows: SearchView.pluginColumn(pluginList, counts, allRows.length, recent)
  // j/k in the column move at once; the filter follows after a short pause
  // so holding j doesn't rebuild the results on every row (review 7).
  property var pendingFilter: null
  // How long a magnet has to show up in the library before "Couldn't
  // confirm <name> was added." (Ruling FD; tests shorten it).
  property int addConfirmMs: 30000
  // The sidecar streams the results; while it isn't up nothing arrives.
  readonly property bool sidecarUp: !service || service.sidecarState === undefined || service.sidecarState === "up"
  // Ruling FD: only while Running with the sidecar down (it gave up), never
  // on a quiet search or while it starts.
  readonly property bool stalled: jobState === "running" && !!service && service.sidecarState === "down"
  // The library's ids (SearchView.librarySet), for "in library" (OV11).
  property var libSet: ({})

  // Over the down screen no result, plugin or search key acts (Esc still
  // leaves; run() refuses the rest).
  readonly property var flags: ({ narrow: search.narrow, result: search.downShown ? null : search.currentResult,
    plugin: search.downShown ? null : search.cursorPlugin, plugins: search.plugins, enabledPlugins: search.downShown ? 0 : search.enabledPlugins,
    pluginsBusy: search.pluginsBusy, running: search.running, category: search.category, down: search.downShown })

  // ---- the down screen (OV4) ----------------------------------------------------------
  readonly property bool downNow: ["gui", "notInstalled", "daemon", "api"].indexOf(tableState) !== -1
  property bool downHold: false
  readonly property bool downShown: downNow && !downHold
  onDownNowChanged: {
    if (downNow && busyKind === "update") {
      downHold = true
      downHoldTimer.restart()
    } else if (!downNow) {
      downHold = false
      downHoldTimer.stop()
      if (open && !pluginsLoaded && !pluginsReading) cmds.loadPlugins()
    }
  }

  readonly property int padX: Style.space(12)
  readonly property int rowHeight: Style.space(28)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property color dimColor: Util.alpha(Color.foreground, 0.4)

  signal leaveRequested()

  visible: open

  // ---- the Client's calls ---------------------------------------------------------------

  function openView() {
    column = "searchResults"
    syncLibrary()
    cmds.loadPlugins()
  }

  function closeView() {
    column = "searchResults"
  }

  function windowClosed() {
    dropConfirm()
    cmds.closeJob()
    cmds.awaiter.clear()
  }

  function dropConfirm() {
    var c = client
    if (!c || c.mode !== "CONFIRM" || !c.confirm || View.SEARCH_ACCEPT[c.confirm.kind] === undefined) return
    var st = ({})
    for (var k in c.regState) st[k] = c.regState[k]
    st.mode = "NORMAL"
    st.pending = null
    c.regState = st
    c.confirm = null
  }

  function owns(commandId) {
    var id = String(commandId || "")
    return id !== "search.open" && (id.indexOf("search.") === 0 || id.indexOf("plugin.") === 0)
  }

  // ev: the key event when a key ran it (the Client passes it), else
  // undefined (the palette).
  function run(commandId, args, ev) {
    if (!open) return
    // The down screen (W2): only the ways out.
    if (downShown && ["search.back", "plugin.close", "search.pluginsClose"].indexOf(commandId) === -1) return
    var a = args || ({})
    switch (commandId) {
    case "search.back":
      if (!cmds.stopSearch()) leaveRequested()
      return
    case "search.focusPlugins":
    case "search.pluginsOverlay": column = "searchPlugins"; return
    case "search.focusResults":
      // Enter on a Recent row searches it again (Ruling FF).
      if (column === "searchPlugins" && ev && (ev.key === 0x01000004 || ev.key === 0x01000005) && columnRows[columnIndex] && columnRows[columnIndex].kind === "recent") {
        var q = columnRows[columnIndex].query
        column = "searchResults"
        cmds.rerun(q)
        return
      }
      column = "searchResults"
      return
    case "search.pluginsClose": column = "searchResults"; return
    case "search.plugins": overlayFrom = column; column = "searchPluginList"; return
    case "plugin.close": column = overlayFrom; return
    case "search.category": openPicker(); return
    case "search.down": move(1); return
    case "search.up": move(-1); return
    case "search.new": if (commands) commands.startInput("searchQuery", query); return
    case "search.sort": {
      var n = SearchView.nextSort(sortMode)
      sortMode = n.sort
      sortDesc = n.desc
      rebuild()
      return
    }
    case "search.sortReverse": sortDesc = !sortDesc; rebuild(); return
    case "search.add": cmds.addResult(a.result, a.confirmed === true); return
    case "search.copyLink": cmds.copyLink(a.result); return
    case "search.openPage": cmds.openPage(a.result, a.confirmed === true); return
    case "plugin.down": movePlugin(1); return
    case "plugin.up": movePlugin(-1); return
    case "plugin.toggle": cmds.togglePlugin(a.plugin); return
    case "plugin.uninstall": cmds.uninstallPlugin(a.plugin, a.confirmed === true); return
    case "plugin.install":
      if (a.confirmed === true) cmds.installPlugin(a)
      else if (commands && !pluginsBusy) commands.startInput("pluginInstall", "")
      return
    case "plugin.updateAll": cmds.updatePlugins(); return
    case "plugin.copyListUrl":
      if (service && typeof service.copyText === "function") client.track(service.copyText(Registry.SEARCH_PLUGIN_LIST_URL, client.opts([])), "copyText", [])
      return
    default: return
    }
  }

  function commitInput(purpose, text) {
    if (purpose === "searchQuery") cmds.commitQuery(text)
    else if (purpose === "pluginInstall") cmds.commitInstall(text)
    else if (commands) commands.endInput()
  }

  function cancelInput(purpose) {
  }

  function inputEdited(purpose, text) {
  }

  function flagsNow() {
    return open ? flags : null
  }

  function togglePicker() {
    return false
  }

  // ---- the category picker (Ruling FB) -------------------------------------------------

  function openPicker() {
    var rows = SearchView.categoryRows(pluginList)
    var cur = SearchView.effectiveCategory(category, pluginList)
    pickerOpen = true
    picker.prompt = "Category"
    picker.setQuery("")
    var out = []
    var at = 0
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].id === cur) at = i
      out.push({ kind: "choice", id: rows[i].id, value: rows[i].id, title: rows[i].name, indices: [], enabled: true, reason: "", keys: rows[i].id === cur ? "current" : "" })
    }
    picker.rows = out
    picker.cursor = at
    commands.setMode("PICKER")
    picker.focusField()
  }

  function acceptPicker() {
    var row = picker ? picker.currentRow() : null
    commands.closePicker()
    if (row) category = String(row.value)
  }

  function dropPicker() {
    pickerOpen = false
  }

  // ---- plugins -----------------------------------------------------------------------

  function setPlugins(list) {
    var out = []
    for (var i = 0; i < list.length; i++) if (list[i] && typeof list[i] === "object" && typeof list[i].name === "string") out.push(list[i])
    pluginList = out
    pluginsLoaded = true
    pluginListIndex = Math.max(0, Math.min(pluginListIndex, out.length - 1))
    category = SearchView.effectiveCategory(category, out)
    // Rows that came before the list: their plugin again (Ruling FF).
    if (allRows.length > 0) {
      var rows = SearchView.remapEngines(allRows, out)
      var byKey = ({})
      for (var r = 0; r < rows.length; r++) byKey[rows[r].key] = rows[r]
      allRows = rows
      rowByKey = byKey
      syncCurrent()
    }
    syncColumn()
    if (pluginFilter !== null) rebuild()
    else refreshLabels()
  }

  function movePlugin(delta) {
    if (pluginList.length === 0) return
    pluginListIndex = Math.max(0, Math.min(pluginList.length - 1, pluginListIndex + delta))
  }

  function pluginRows() {
    var out = []
    for (var i = 0; i < pluginList.length; i++) {
      var p = pluginList[i]
      var full = SearchView.cleanName(p.fullName)
      var ver = SearchView.cleanName(p.version)
      var title = (full !== SearchView.EMPTY ? full : SearchView.cleanName(p.name)) + (ver !== SearchView.EMPTY ? " v" + ver : "")
      out.push({ kind: "plugin", title: title, indices: [], enabled: p.enabled === true, reason: "", keys: p.enabled === true ? "on" : "off" })
    }
    return out
  }

  function footerText(keys) {
    var parts = []
    for (var i = 0; i < keys.length; i++) parts.push(keys[i].key + " " + keys[i].label)
    return parts.join(" · ")
  }

  readonly property string busyText: busyKind === "install" ? SearchView.WINDOW.installing : busyKind === "update" ? SearchView.WINDOW.updating
    : busyKind === "uninstall" ? SearchView.WINDOW.uninstalling : busyKind === "toggle" ? SearchView.WINDOW.saving : ""

  // ---- results -----------------------------------------------------------------------

  function resetResults() {
    allRows = []
    rowByKey = ({})
    shownKeys = []
    held = 0
    total = 0
    capped = false
    cursorKey = ""
    pluginFilter = null
    pendingFilter = null
    filterTimer.stop()
    columnIndex = 0
    resultModel.clear()
    syncCurrent()
  }

  function modelRow(r) {
    return {
      key: r.key,
      name: r.name,
      size: typeof r.size === "number" ? Model.formatSize(r.size) : SearchView.EMPTY,
      seeds: String(r.seeds),
      peers: String(r.peers),
      plugin: pluginText(r),
      published: typeof r.published === "number" ? Qt.formatDateTime(new Date(r.published * 1000), "yyyy-MM-dd") : SearchView.EMPTY,
      v1: r.v1 || "",
      v2: r.v2 || ""
    }
  }

  function pluginText(r) {
    var labels = []
    var e = r.engines || [r.engine]
    for (var i = 0; i < e.length; i++) labels.push(SearchView.pluginLabel(e[i], pluginList))
    return labels.join(", ")
  }

  // New raw rows from a reply (already checked against the offset):
  // merged, and those that are new and pass the filter are appended.
  function appendRaw(raws) {
    var m = SearchView.mergeResults(allRows, raws, held, pluginList)
    held = held + raws.length
    var byKey = ({})
    for (var k in rowByKey) byKey[k] = rowByKey[k]
    var keys = shownKeys.slice()
    for (var u = 0; u < m.updated.length; u++) {
      var row = null
      for (var j = 0; j < m.rows.length; j++) if (m.rows[j].key === m.updated[u]) { row = m.rows[j]; break }
      byKey[m.updated[u]] = row
      if (!row) continue
      var at = keys.indexOf(m.updated[u])
      if (at >= 0) resultModel.setProperty(at, "plugin", pluginText(row))
      // A held row that gained the filtered plugin shows now (W3).
      else if (SearchView.matchesPlugin(row, pluginFilter)) { keys.push(row.key); resultModel.append(modelRow(row)) }
    }
    for (var i = 0; i < m.added.length; i++) {
      var r = m.added[i]
      byKey[r.key] = r
      if (!SearchView.matchesPlugin(r, pluginFilter)) continue
      keys.push(r.key)
      resultModel.append(modelRow(r))
    }
    rowByKey = byKey
    allRows = m.rows
    shownKeys = keys
    if (cursorKey === "" && keys.length > 0) cursorKey = keys[0]
    syncCurrent()
  }

  // Sorts and filters every row again (s, S, a filter, the search's end),
  // keeping the cursor on its row.
  function rebuild() {
    var sorted = SearchView.sortResults(allRows, sortMode, sortDesc, pluginList)
    var keys = []
    resultModel.clear()
    for (var i = 0; i < sorted.length; i++) {
      if (!SearchView.matchesPlugin(sorted[i], pluginFilter)) continue
      keys.push(sorted[i].key)
      resultModel.append(modelRow(sorted[i]))
    }
    shownKeys = keys
    if (keys.indexOf(cursorKey) === -1) cursorKey = keys.length > 0 ? keys[0] : ""
    syncCurrent()
    if (cursorIndex >= 0) resultList.positionViewAtIndex(cursorIndex, ListView.Contain)
  }

  // Plugin labels changed (the list was read again).
  function refreshLabels() {
    for (var i = 0; i < shownKeys.length; i++) {
      var r = rowByKey[shownKeys[i]]
      if (r) resultModel.setProperty(i, "plugin", pluginText(r))
    }
  }

  function syncCurrent() {
    var r = cursorKey !== "" ? rowByKey[cursorKey] : null
    currentResult = r ? { key: r.key, name: r.name, size: r.size, fileUrl: r.fileUrl, descrLink: r.descrLink, siteUrl: r.siteUrl,
      engine: r.engine, v1: r.v1, v2: r.v2 } : null
  }

  function move(delta) {
    if (column === "searchPlugins") {
      var n = columnRows.length
      if (n === 0) return
      columnIndex = Math.max(0, Math.min(n - 1, columnIndex + delta))
      var row = columnRows[columnIndex]
      // A Recent row keeps the filter as it is.
      if (row.kind === "recent") { filterTimer.stop(); return }
      pendingFilter = row.engine
      filterTimer.restart()
      return
    }
    if (shownKeys.length === 0) return
    var at = Math.max(0, Math.min(shownKeys.length - 1, (cursorIndex < 0 ? 0 : cursorIndex) + delta))
    cursorKey = shownKeys[at]
    syncCurrent()
    resultList.positionViewAtIndex(at, ListView.Contain)
  }

  // The column's cursor follows the filter when the rows move under it.
  function syncColumn() {
    var cur = columnRows[columnIndex]
    if (cur && cur.kind === "recent") return
    for (var i = 0; i < columnRows.length; i++) if (columnRows[i].kind !== "recent" && columnRows[i].engine === pluginFilter) { columnIndex = i; return }
    columnIndex = 0
    if (pluginFilter !== null) { pluginFilter = null; rebuild() }
  }

  function syncLibrary() {
    libSet = SearchView.librarySet(service ? service.torrents : [])
    cmds.awaiter.check()
  }

  onColumnRowsChanged: {
    var cur = columnRows[columnIndex]
    if (cur && cur.kind === "recent") return
    if (filterTimer.running) return
    for (var i = 0; i < columnRows.length; i++) if (columnRows[i].kind !== "recent" && columnRows[i].engine === pluginFilter) { columnIndex = i; return }
  }

  function applyFilter() {
    if (pendingFilter === pluginFilter) return
    pluginFilter = pendingFilter
    rebuild()
  }
  onServiceChanged: syncLibrary()

  SearchCommands {
    id: cmds
    view: search
  }

  Connections {
    target: search.service
    ignoreUnknownSignals: true
    function onTorrentsChanged() { search.syncLibrary() }
  }

  Timer {
    id: filterTimer
    interval: 150
    repeat: false
    onTriggered: search.applyFilter()
  }

  Timer {
    id: downHoldTimer
    interval: 2500
    repeat: false
    onTriggered: search.downHold = false
  }

  ListModel { id: resultModel }

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

  // ---- the query bar -------------------------------------------------------------------

  Item {
    id: queryBar
    objectName: "searchQueryBar"
    visible: !search.downShown
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(40)

    Text {
      id: queryLabel
      anchors.left: parent.left
      anchors.leftMargin: search.padX
      anchors.verticalCenter: parent.verticalCenter
      text: "Search"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }

    Rectangle {
      id: queryBox
      anchors.left: queryLabel.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(Style.space(300), Math.max(Style.space(80), queryBar.width * 0.3))
      height: Style.space(26)
      color: "transparent"
      border.width: 1
      border.color: Color.accent
      Text {
        objectName: "searchQueryText"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: search.query !== "" ? search.query : "/ to search"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: search.query !== "" ? Color.foreground : Color.muted
      }
    }

    Row {
      id: chips
      anchors.left: queryBox.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      // Wide: "plugins All (3)"; narrow: the Plugins column's chip.
      Rectangle {
        objectName: "searchPluginsChip"
        width: pluginsChipText.implicitWidth + Style.space(14)
        height: Style.space(22)
        color: "transparent"
        border.width: 1
        border.color: search.lineColor
        Text {
          id: pluginsChipText
          anchors.centerIn: parent
          text: search.narrow ? (search.pluginFilter === null ? "All results" : SearchView.pluginLabel(search.pluginFilter, search.pluginList)) + " ▾"
            : "plugins " + (search.plugins === 0 ? "none" : (search.pluginFilter === null ? "All" : SearchView.pluginLabel(search.pluginFilter, search.pluginList))
              + " (" + search.enabledPlugins + ")")
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Color.accent
        }
        MouseArea {
          anchors.fill: parent
          enabled: search.narrow
          onClicked: search.column = "searchPlugins"
        }
      }

      Rectangle {
        objectName: "searchCategoryChip"
        visible: search.plugins > 0
        width: categoryChipText.implicitWidth + Style.space(14)
        height: Style.space(22)
        color: "transparent"
        border.width: 1
        border.color: search.lineColor
        Text {
          id: categoryChipText
          anchors.centerIn: parent
          text: "category " + SearchView.categoryName(SearchView.effectiveCategory(search.category, search.pluginList), search.pluginList)
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: Color.accent
        }
      }
    }

    Text {
      objectName: "searchRunText"
      anchors.left: chips.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: search.padX
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      text: SearchView.runText(search.jobState, search.allRows.length)
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: search.running ? Color.accent : Color.muted
    }

    // The thin accent bar while a search runs.
    Rectangle {
      objectName: "searchRunBar"
      visible: search.running
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(2)
      color: Color.accent
    }
    Rectangle {
      visible: !search.running
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: search.lineColor
    }
  }

  // ---- the Plugins column --------------------------------------------------------------

  ClientPane {
    id: pluginsPane
    objectName: "searchPluginsPane"
    anchors.left: parent.left
    anchors.top: queryBar.bottom
    anchors.bottom: parent.bottom
    width: Style.space(210)
    title: "Plugins"
    focusedPane: search.column === "searchPlugins"
    collapsed: search.narrow
    swappedOut: search.downShown

    Flickable {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: pluginsFooter.top
      clip: true
      contentWidth: width
      contentHeight: pluginColumn.height + Style.space(8)
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: pluginColumn
        width: parent.width
        topPadding: Style.space(4)

        Repeater {
          model: search.columnRows
          delegate: Item {
            id: colItem
            required property var modelData
            required property int index
            readonly property bool current: index === search.columnIndex
            readonly property bool isRecent: modelData.kind === "recent"
            // The first Recent row carries the "Recent" heading above it.
            readonly property bool heads: isRecent && (index === 0 || search.columnRows[index - 1].kind !== "recent")
            width: pluginColumn.width
            height: search.rowHeight + (heads ? recentHead.implicitHeight + Style.space(12) : 0)

            Text {
              id: recentHead
              visible: colItem.heads
              x: search.padX
              y: Style.space(8)
              text: "Recent"
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.caption
              font.capitalization: Font.AllUppercase
              color: Color.muted
            }
            Item {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: search.rowHeight

              Rectangle {
                visible: colItem.current
                anchors.fill: parent
                color: Style.selectedAccentFill
              }
              Rectangle {
                visible: colItem.current && pluginsPane.focusedPane
                width: Style.space(3)
                height: parent.height
                color: Color.accent
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: search.padX
                anchors.right: colCount.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: colItem.modelData.label
                textFormat: Text.PlainText
                font.family: Style.fontFamily
                font.pixelSize: Style.font.body
                color: colItem.current ? Color.accent : (colItem.isRecent ? search.dimColor : Color.foreground)
              }
              Text {
                id: colCount
                visible: !colItem.isRecent
                anchors.right: parent.right
                anchors.rightMargin: search.padX
                anchors.verticalCenter: parent.verticalCenter
                text: colItem.isRecent ? "" : String(colItem.modelData.count)
                textFormat: Text.PlainText
                font.family: Style.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: Color.muted
              }
              MouseArea {
                anchors.fill: parent
                onClicked: {
                  search.column = "searchPlugins"
                  search.move(colItem.index - search.columnIndex)
                }
              }
            }
          }
        }
      }
    }

    KeyFooter {
      id: pluginsFooter
      keys: View.searchFooterKeys("searchPlugins", search.flags)
    }
  }

  // ---- the results ------------------------------------------------------------------------

  ClientPane {
    id: resultsPane
    objectName: "searchResultsPane"
    anchors.left: search.narrow ? parent.left : pluginsPane.right
    anchors.right: parent.right
    anchors.top: queryBar.bottom
    anchors.bottom: parent.bottom
    title: "Results"
    titleRight: search.allRows.length === 0 ? "" : SearchView.sortTitle(search.sortMode, search.sortDesc) + " · " + search.shownKeys.length
      + (search.capped ? " · " + SearchView.cappedText(true, search.total) : "")
    focusedPane: search.column === "searchResults"
    rightLine: false
    swappedOut: search.downShown

    // Narrow (the design's Responsive): Published and Peers hide first,
    // then Plugin.
    readonly property bool hidePublished: search.narrow
    readonly property bool hidePeers: search.narrow
    // Plugin hides below ClientView's LAYOUT_NARROW (700 px of window,
    // the width the torrent table drops its columns at): 640-699 px, which
    // the 640 px minimum window reaches.
    readonly property bool hidePlugin: search.narrow && search.width > 0 && search.width < 700
    readonly property int numWidth: Style.space(64)
    readonly property int sizeWidth: Style.space(84)
    readonly property int pluginWidth: Style.space(140)
    readonly property int dateWidth: Style.space(96)
    readonly property int nameWidth: Math.max(0, width - 2 * search.padX - sizeWidth - numWidth - (hidePeers ? 0 : numWidth)
      - (hidePlugin ? 0 : pluginWidth) - (hidePublished ? 0 : dateWidth))

    // Ruling FD: a Running search while the sidecar isn't up.
    Text {
      id: stalledLine
      objectName: "searchStalled"
      visible: search.stalled
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: visible ? Style.space(30) : 0
      leftPadding: search.padX
      rightPadding: search.padX
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      text: SearchView.WINDOW.stalled
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.urgent
    }

    Item {
      id: header
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: stalledLine.bottom
      height: Style.space(26)
      visible: resultModel.count > 0

      Row {
        anchors.fill: parent
        anchors.leftMargin: search.padX
        anchors.rightMargin: search.padX
        component HeadText: Text {
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.caption
          font.capitalization: Font.AllUppercase
          color: Color.muted
          height: parent.height
          verticalAlignment: Text.AlignVCenter
        }
        HeadText { text: "Name"; width: resultsPane.nameWidth }
        HeadText { text: "Size"; width: resultsPane.sizeWidth; horizontalAlignment: Text.AlignRight }
        HeadText { text: "Seeds"; width: resultsPane.numWidth; horizontalAlignment: Text.AlignRight }
        HeadText { text: "Peers"; width: resultsPane.numWidth; horizontalAlignment: Text.AlignRight; visible: !resultsPane.hidePeers }
        HeadText { text: "Plugin"; width: resultsPane.pluginWidth; leftPadding: Style.space(12); visible: !resultsPane.hidePlugin }
        HeadText { text: "Published"; width: resultsPane.dateWidth; horizontalAlignment: Text.AlignRight; visible: !resultsPane.hidePublished }
      }
    }

    ListView {
      id: resultList
      objectName: "searchResultList"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: header.bottom
      anchors.bottom: helpLine.top
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: resultModel
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Item {
        id: resultRow
        required property int index
        required property string key
        required property string name
        required property string size
        required property string seeds
        required property string peers
        required property string plugin
        required property string published
        required property string v1
        required property string v2
        readonly property bool current: key === search.cursorKey
        readonly property bool inLib: SearchView.inLibrary(v1, v2, search.libSet)
        width: resultList.width
        height: search.rowHeight

        Rectangle {
          visible: resultRow.current
          anchors.fill: parent
          color: Style.selectedAccentFill
        }
        Rectangle {
          visible: resultRow.current && resultsPane.focusedPane
          width: Style.space(3)
          height: parent.height
          color: Color.accent
        }
        Row {
          anchors.fill: parent
          anchors.leftMargin: search.padX
          anchors.rightMargin: search.padX
          component CellText: Text {
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.foreground
            height: parent.height
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }
          Item {
            width: resultsPane.nameWidth
            height: parent.height
            CellText {
              id: nameText
              objectName: "searchResultName"
              width: Math.min(implicitWidth, parent.width - (libTag.visible ? libTag.width + Style.space(8) : 0) - Style.space(8))
              text: resultRow.name
              color: resultRow.current ? Color.accent : Color.foreground
            }
            Rectangle {
              id: libTag
              visible: resultRow.inLib
              anchors.left: nameText.right
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: libText.implicitWidth + Style.space(10)
              height: libText.implicitHeight + Style.space(2)
              color: "transparent"
              border.width: 1
              border.color: search.lineColor
              Text {
                id: libText
                anchors.centerIn: parent
                text: "in library"
                textFormat: Text.PlainText
                font.family: Style.fontFamily
                font.pixelSize: Style.font.caption
                color: Color.muted
              }
            }
          }
          CellText { text: resultRow.size; width: resultsPane.sizeWidth; horizontalAlignment: Text.AlignRight }
          CellText { text: resultRow.seeds; width: resultsPane.numWidth; horizontalAlignment: Text.AlignRight }
          CellText { text: resultRow.peers; width: resultsPane.numWidth; horizontalAlignment: Text.AlignRight; visible: !resultsPane.hidePeers }
          CellText { text: resultRow.plugin; width: resultsPane.pluginWidth; leftPadding: Style.space(12); color: Color.muted; visible: !resultsPane.hidePlugin }
          CellText { text: resultRow.published; width: resultsPane.dateWidth; horizontalAlignment: Text.AlignRight; color: Color.muted; visible: !resultsPane.hidePublished }
        }
        MouseArea {
          anchors.fill: parent
          onClicked: {
            search.column = "searchResults"
            search.cursorKey = resultRow.key
            search.syncCurrent()
          }
        }
      }
    }

    // The empty states (the design's States table, as OV1/OV8 amend it).
    Text {
      id: emptyLine
      objectName: "searchEmpty"
      visible: text !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: stalledLine.bottom
      anchors.topMargin: Style.space(24)
      leftPadding: Style.space(16)
      rightPadding: Style.space(16)
      wrapMode: Text.Wrap
      text: SearchView.emptyText({ pluginsLoaded: search.pluginsLoaded, pluginCount: search.plugins, state: search.jobState,
        query: search.query, rows: search.allRows.length, visible: search.shownKeys.length,
        filter: search.pluginFilter === null ? "" : SearchView.pluginLabel(search.pluginFilter, search.pluginList) })
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.subtitle
      color: text === SearchView.WINDOW.noPlugins ? Color.accent : Color.muted
    }

    // Ruling FD: what plugins are, under "No search plugins yet".
    Text {
      objectName: "searchNoPluginsHelp"
      visible: emptyLine.text === SearchView.WINDOW.noPlugins
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: emptyLine.bottom
      anchors.topMargin: Style.space(10)
      leftPadding: Style.space(16)
      rightPadding: Style.space(16)
      wrapMode: Text.Wrap
      text: SearchView.WINDOW.noPluginsHelp
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }

    // The cursor row's help line: name · host · size · plugin.
    Item {
      id: helpLine
      visible: search.currentResult !== null
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: resultsFooter.top
      height: visible ? helpText.implicitHeight + Style.space(16) : 0
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: search.lineColor
      }
      Text {
        id: helpText
        objectName: "searchHelp"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: search.padX
        anchors.rightMargin: search.padX
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: search.currentResult ? [search.currentResult.name, SearchView.resultHost(search.currentResult),
          cmds.sizeText(search.currentResult.size), SearchView.pluginLabel(search.currentResult.engine, search.pluginList)].join(" · ") : ""
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }

    KeyFooter {
      id: resultsFooter
      keys: View.searchFooterKeys("searchResults", search.flags)
    }
  }

  // ---- the down screen: the torrent view's own, reused -----------------------------------

  ClientPane {
    objectName: "searchDown"
    anchors.fill: parent
    title: "Search"
    focusedPane: true
    rightLine: false
    swappedOut: !search.downShown

    TorrentTable {
      anchors.fill: parent
      tableState: "api"
      stateCopy: View.settingsDownCopy(search.tableState)
    }
  }

  // ---- the plugins overlay (P): ListOverlay without its field ---------------------------
  // Loaded only while it shows, so the window's palette stays the first
  // ListOverlay a search of the tree finds.

  Loader {
    id: overlayLoader
    anchors.fill: parent
    active: search.open && search.column === "searchPluginList"
    sourceComponent: Component {
      ListOverlay {
        id: pluginOverlay
        objectName: "searchPluginOverlay"
        keyMode: "PICKER"
        prompt: "Plugins"
        counterText: search.pluginsBusy ? search.busyText : SearchView.pluginsTitle(search.pluginList)
        emptyText: SearchView.WINDOW.noPlugins
        rows: search.pluginRows()
        cursor: search.pluginList.length > 0 ? search.pluginListIndex : -1
        footerHint: search.footerText(View.searchFooterKeys("searchPluginList", search.flags))
        onDismissed: search.run("plugin.close", ({}))
        onActivated: function(row) { search.pluginListIndex = pluginOverlay.cursor }
        Component.onCompleted: {
          pluginOverlay.inputField.visible = false
          pluginOverlay.inputField.enabled = false
        }
      }
    }
  }

  Loader {
    id: pickerLoader
    anchors.fill: parent
    active: search.open && search.pickerOpen
    sourceComponent: Component {
      ListOverlay {
        objectName: "searchCategoryPicker"
        keyMode: "PICKER"
        multi: false
        placeholder: " type to find"
        footerHint: "↑↓ / Ctrl-n Ctrl-p move · Enter choose · Esc cancel"
        onKeyForwarded: function(event) { if (search.client) search.client.handleKey(event) }
        onActivated: function(row) { search.commands.setMode("NORMAL"); search.acceptPicker() }
        onDismissed: search.commands.closePicker()
      }
    }
  }
}
