.pragma library

// The popup's key routing and its "Open the window" entry point. Pure, so
// tests/popup-keys.test.js pins every state x key pair; Panel.qml only
// dispatches the returned action to its existing functions.
//
// Omarchy's PanelKeyCatcher emits semantic signals: moveRequested(dx, dy)
// (h/Left is (-1, 0)), activateRequested (Enter and Space), closeRequested,
// deleteRequested() with no args for both x and X, and textKey(t) for the
// rest (Backspace arrives as textKey("\b")). Panel.qml records the last key
// press so "delete" knows the case, and passes "enter" or "space" with
// "activate" (the catcher's returnRequested fires just before it for Enter only).

var WINDOW_ID = "aweiward.omaqbt"
var ROW_LABEL = "Open the window"
var ROW_KEY = "w"
var FALLBACK_NOTE = "Open the window with: omarchy-shell shell toggle aweiward.omaqbt"

function act(action, args) {
  return { action: action, args: args || [] }
}

// The delete key's case from the last key press: "x", "X" or "" (unknown).
function deleteKey(text, shift) {
  if (text === "X") return "X"
  if (text === "x") return shift ? "X" : "x"
  return ""
}

// signal: "move" | "activate" | "delete" | "text" | "close"
// state: { view: "list"|"detail", section, blocked, magnetConfirmOpen, cursorActive }
// -> { action, args }, action one of: none, openWindow, back, remove,
//    deleteFiles, skipFile, toggle, moveCursor, activateCursor, text, close,
//    cancelMagnet, startMagnet.
// "activate" takes "enter" | "space" (null means Enter).
function route(signal, arg, state) {
  var s = state || {}
  var view = s.view === "detail" ? "detail" : "list"
  // A field has focus or the delete confirm owns the keys.
  if (s.blocked) return act("none")

  if (signal === "move") {
    var dx = arg && arg.dx ? arg.dx : 0
    var dy = arg && arg.dy ? arg.dy : 0
    if (view === "detail" && dx < 0 && dy === 0) return act("back")
    return act("moveCursor", [dx, dy])
  }

  if (signal === "activate") {
    if (s.magnetConfirmOpen) return act("startMagnet")
    // Space starts or stops the torrent under the cursor (README); Enter opens it.
    if (arg === "space" && (view === "detail" || s.section === "rows")) return act("toggle")
    if (view === "list" && s.section === "window") return act("openWindow")
    return act("activateCursor")
  }

  if (signal === "delete") {
    if (s.magnetConfirmOpen) return act("none")
    if (arg !== "x" && arg !== "X") return act("none")
    // The list acts on the torrent under the cursor only. In the detail view
    // x skips the file under the cursor on the files section, and otherwise
    // removes the detail torrent; X always asks to delete its files.
    if (view === "list" && s.section !== "rows") return act("none")
    if (arg === "X") return act("deleteFiles")
    if (view === "detail" && s.section === "files") return act("skipFile")
    return act("remove")
  }

  if (signal === "text") {
    if (arg === ROW_KEY) {
      if (view === "list" && !s.magnetConfirmOpen) return act("openWindow")
      return act("none")
    }
    if (arg === "\b") return act(view === "detail" ? "back" : "none")
    return act("text", [arg])
  }

  if (signal === "close") {
    if (s.magnetConfirmOpen) return act("cancelMagnet")
    return act("close")
  }

  return act("none")
}

// Summons the window through the bar's shell facade. beforeSummon (the popup
// close) runs first, and only when the shell can summon; otherwise the popup
// stays open and shows the note.
function openWindow(shell, beforeSummon) {
  if (!shell || typeof shell.summon !== "function") return { ok: false, note: FALLBACK_NOTE }
  if (typeof beforeSummon === "function") beforeSummon()
  try {
    shell.summon(WINDOW_ID, "")
  } catch (e) {
    return { ok: false, note: FALLBACK_NOTE }
  }
  return { ok: true, note: "" }
}

if (typeof module !== "undefined") {
  module.exports = {
    WINDOW_ID: WINDOW_ID,
    ROW_LABEL: ROW_LABEL,
    ROW_KEY: ROW_KEY,
    FALLBACK_NOTE: FALLBACK_NOTE,
    deleteKey: deleteKey,
    route: route,
    openWindow: openWindow
  }
}
