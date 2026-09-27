pragma ComponentBehavior: Bound

import QtQuick
import "ClientView.js" as View
import "LibraryView.js" as Library

// T's tag picker (slice 3a): ListOverlay in PICKER keyMode, multi-select.
// Each tag shows [x] / [~] / [ ] for the target torrents
// (LibraryView.tagStates); Space (empty query) or Tab toggles the cursor
// row in a working copy, and Enter sends only what changed
// (LibraryView.tagAccept). Esc drops the working copy, so it changes
// nothing. Its keys go back through the window's dispatch; ClientCommands
// captured the targets when T was pressed.
ListOverlay {
  id: picker

  // The ClientCommands this picker's keys and clicks go through.
  required property var commands

  objectName: "tagPicker"
  keyMode: "PICKER"
  multi: true
  prompt: "Tags"
  placeholder: " type to find or create"
  visible: commands.client.mode === "PICKER" && commands.pickerKind === "tag"
  footerHint: "↑↓ move · Space/Tab toggle · Enter apply · Esc cancel"
  counterText: View.countText(targetCount)
  emptyText: "No tags yet; type a name to create one"

  property int targetCount: 0
  // The tags as T found them, and the working copy toggles change.
  property var original: []
  property var working: []

  function open(initial, count) {
    targetCount = count
    original = initial
    working = initial
    setQuery("")
    refresh("")
    focusField()
  }

  // Toggles `name` (a "+ New tag" row's name joins as a new tag) and keeps
  // the cursor on it.
  function toggle(name) {
    working = Library.toggleTag(working, original, name)
    refresh("t:" + name)
  }

  function refresh(id) {
    var next = Library.tagPickerRows(query, working, View.fuzzyMatch)
    rows = next
    cursor = id ? View.paletteCursorFor(next, id) : View.paletteFirst(next)
  }

  onQueryChanged: refresh("")
  onKeyForwarded: function(event) { commands.client.handleKey(event) }
  onActivated: function(row) { commands.pickerClicked() }
  onDismissed: commands.closePicker()
}
