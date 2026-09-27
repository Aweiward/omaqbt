pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "CommandRegistry.js" as Registry
import "ClientView.js" as View

// The `:` command palette (spec D7): ListOverlay in "COMMAND" keyMode, with
// the palette's own row computation (fuzzy match, MRU, group order) and its
// "N of M" counts and footer hint. ListOverlay owns the overlay, scrim,
// field, row list and cursor; this file is the palette's config plus the
// row-refresh logic View.paletteRows/paletteMove/... implement.
//
// The keys COMMAND mode resolves (Esc, Enter, Up/Down, Ctrl-n/Ctrl-p, Tab)
// go back to the window through keyForwarded, so they run through
// CommandRegistry.dispatch like every other key; ClientCommands then calls
// open/move/complete/currentRow here.
ListOverlay {
  id: pal

  keyMode: "COMMAND"
  prompt: ":"
  footerHint: "↑↓ / Ctrl-n Ctrl-p move · Enter run · Tab complete · Esc close"
  counterText: matchCount + " of " + totalCount
  emptyText: View.paletteEmptyText(pal.query)

  // The recently used command ids (Client.paletteMru).
  property var mru: []
  // View.paletteState(...): the state rows are enabled or disabled by.
  property var evalState: ({})

  readonly property int matchCount: View.paletteCommandCount(rows)
  readonly property int totalCount: View.paletteCommandCount(View.paletteRows("", Registry.commands, [], evalState))

  // Starts empty, with the cursor on the first row, and takes the keys.
  function open() {
    setQuery("")
    refresh(false)
    focusField()
  }

  // Tab: the query becomes the cursor row's title.
  function complete() {
    var row = currentRow()
    if (!row || row.kind !== "command") return
    setQuery(row.title)
    inputField.cursorPosition = String(inputField.text).length
  }

  // keep: the rows changed under the cursor (a tick, the MRU), so it stays
  // on its command if it can; a new query starts from the top.
  function refresh(keep) {
    var row = keep ? currentRow() : null
    var next = View.paletteRows(query, Registry.commands, mru, evalState)
    rows = next
    cursor = row ? View.paletteCursorFor(next, row.id) : View.paletteFirst(next)
  }

  onQueryChanged: refresh(false)
  onEvalStateChanged: refresh(true)
  onMruChanged: refresh(true)
}
