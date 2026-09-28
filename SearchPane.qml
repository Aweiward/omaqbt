pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View

// The Search view (slice 5a). PLACEHOLDER from Task 1: the mount point and
// the contract the Client codes against. Task 3 (the window lane) owns this
// file and replaces its body; it must keep every property, signal and
// function below with the meaning given here, because Client.qml,
// ClientCommands.qml and ClientView.js (which Task 3 doesn't edit) call
// them. See tests/fixtures/search-contract.md for qbt's and the sidecar's
// side.
//
// `F` or ":Search" makes it the active view (Client.activeView "search"):
// it replaces the three torrent panes, like Settings, and the status line
// stays. Esc stops a running search first, then leaves; the last search,
// its results and the cursor survive leaving (design D7). Closing the
// window deletes qBittorrent's job (eng A5/OV14): windowClosed().
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
// Read by the Client:
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
//   openView()   Search just became the active view.
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
  // Placeholder inputs for the flags (Task 3 derives them from the plugins).
  property int plugins: 0
  property int enabledPlugins: 0
  property string category: "all"
  property bool pickerOpen: false
  readonly property var picker: pickerLoader.item
  // The column `P` was pressed in, which the overlay's Esc returns to.
  property string overlayFrom: "searchResults"

  readonly property var flags: ({ narrow: search.narrow, result: null, plugin: null, plugins: search.plugins, enabledPlugins: search.enabledPlugins,
    pluginsBusy: false, running: false, category: search.category })

  signal leaveRequested()

  visible: open

  function openView() {
    column = "searchResults"
  }

  function closeView() {
    column = "searchResults"
  }

  function windowClosed() {
    dropConfirm()
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

  // ---- the category picker (placeholder: "all" only) -----------------------------

  function openPicker() {
    pickerOpen = true
    picker.prompt = "Category"
    picker.setQuery("")
    picker.rows = [{ kind: "choice", id: "all", value: "all", title: "All categories", indices: [], enabled: true, reason: "", keys: category === "all" ? "current" : "" }]
    picker.cursor = 0
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

  function owns(commandId) {
    var id = String(commandId || "")
    return id !== "search.open" && (id.indexOf("search.") === 0 || id.indexOf("plugin.") === 0)
  }

  // Task 3 fills in every command; the placeholder only moves between the
  // panes and leaves, so the Client's keys can be tested end to end.
  function run(commandId, args) {
    if (!open) return
    switch (commandId) {
    case "search.back": leaveRequested(); return
    case "search.focusPlugins":
    case "search.pluginsOverlay": column = "searchPlugins"; return
    case "search.focusResults":
    case "search.pluginsClose": column = "searchResults"; return
    case "search.plugins": overlayFrom = column; column = "searchPluginList"; return
    case "plugin.close": column = overlayFrom; return
    case "search.category": openPicker(); return
    default: return
    }
  }

  function commitInput(purpose, text) {
    if (commands) commands.endInput()
  }

  function cancelInput(purpose) {
  }

  function inputEdited(purpose, text) {
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background
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
