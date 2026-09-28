pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

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
//                  running        a search is running (Esc stops it first).
//   leaveRequested()  asks the Client to leave Search (Esc with nothing to
//                stop). The view never hides itself.
//
// Called by the Client:
//   openView()   Search just became the active view.
//   closeView()  Search just stopped being the active view (Esc, a magnet's
//                CONFIRM, a torrent row from the palette, closing the
//                window). The job and its results are kept.
//   windowClosed()  the window is closing: delete the job (qbt search delete).
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
  // The column `P` was pressed in, which the overlay's Esc returns to.
  property string overlayFrom: "searchResults"

  readonly property var flags: ({ narrow: search.narrow, result: null, plugin: null, plugins: 0, enabledPlugins: 0, pluginsBusy: false, running: false })

  signal leaveRequested()

  visible: open

  function openView() {
    column = "searchResults"
  }

  function closeView() {
    column = "searchResults"
  }

  function windowClosed() {
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
}
