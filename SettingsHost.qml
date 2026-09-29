import QtQuick
import "ClientView.js" as View

// The Settings view's host (slice 5b0, eng D9): the view host contract
// (docs/plans/slice-5b0.md) over SettingsPane and SettingsCommands, so the
// Client and ClientCommands treat Settings like every other view.
QtObject {
  required property var pane       // SettingsPane
  required property var cmds       // SettingsCommands
  readonly property string name: "settings"
  readonly property string column: pane.column
  readonly property var inputPurposes: View.VIEW_INPUT_PURPOSES_BY_VIEW.settings
  readonly property bool pickerOpen: cmds.pickerOpen
  readonly property var picker: cmds.picker
  // SettingsCommands.flags(), whether or not Settings is open (as 5a).
  function flagsNow() { return cmds.flags() }
  function openView() { pane.openView() }
  function closeView() { pane.closeView() }
  function windowClosed() { cmds.dropConfirm() }
  function owns(id) { return cmds.owns(id) }
  function run(id, args, ev) { cmds.run(id, args) }
  // The Settings search is never an add target or a torrent filter; a
  // setting's edit is SettingsCommands', which ends or keeps the INSERT.
  function commitInput(purpose, text) {
    if (purpose === "settingsSearch") { pane.commitSearch(text); cmds.commands.endInput(); return }
    cmds.commitInput(text)
  }
  // ClientCommands.cancelInput drops SettingsCommands.input itself, for
  // every purpose.
  function cancelInput(purpose) { if (purpose === "settingsSearch") pane.clearSearch() }
  function inputEdited(purpose, text) { if (purpose === "settingsSearch") pane.setSearch(text) }
  function acceptPicker() { cmds.acceptPicker() }
  function dropPicker() { cmds.dropPicker() }
  // The choice picker is single-choice: Space/Tab don't toggle there.
  function togglePicker() { return false }
}
