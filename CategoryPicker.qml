pragma ComponentBehavior: Bound

import QtQuick
import "ClientView.js" as View
import "LibraryView.js" as Library

// C's category picker (slice 3a): ListOverlay in PICKER keyMode, single
// choice. Rows come from LibraryView.categoryPickerRows: "(no category)",
// every category with "N of M now" for the target torrents, and "+ New
// category "<query>"". Its keys go back through the window's dispatch
// (Enter, Esc, Up/Down); ClientCommands decides what Enter does
// (LibraryView.categoryAccept) and captured the targets when C was pressed.
ListOverlay {
  id: picker

  // The ClientCommands this picker's keys and clicks go through.
  required property var commands

  objectName: "categoryPicker"
  keyMode: "PICKER"
  multi: false
  prompt: "Category"
  placeholder: " type to find or create"
  visible: commands.client.mode === "PICKER" && commands.pickerKind === "category"
  footerHint: "↑↓ / Ctrl-n Ctrl-p move · Enter set · Esc cancel"
  counterText: View.countText(targetRows.length)

  // The target torrents' rows as C found them (for "N of M now").
  property var targetRows: []
  readonly property var categories: commands.client.service ? commands.client.service.categories : []

  function open(rows) {
    targetRows = rows
    setQuery("")
    refresh(false)
    focusField()
  }

  // keep: the categories changed under the cursor (a status tick), so it
  // stays on its row if it can; a new query starts from the top.
  function refresh(keep) {
    var row = keep ? currentRow() : null
    var next = Library.categoryPickerRows(query, categories, targetRows, View.fuzzyMatch)
    rows = next
    cursor = row ? View.paletteCursorFor(next, row.id) : View.paletteFirst(next)
  }

  onQueryChanged: refresh(false)
  // Not while the API is down, nor when the list empties (an API-down
  // tick): rebuilding then would put the cursor on "+ New category" and
  // keep it there after recovery (ruling BS).
  onCategoriesChanged: if (visible && commands.client.service && commands.client.service.api && categories.length > 0) refresh(true)
  onKeyForwarded: function(event) { commands.client.handleKey(event) }
  onActivated: function(row) { commands.pickerClicked() }
  onDismissed: commands.closePicker()
}
