import QtQuick
import QtTest
import qs.Ui
import "../../../PopupKeys.js" as PopupKeys

// Discoverability Task 1: the popup's key plumbing against a copy of Omarchy's
// real PanelKeyCatcher (stubs/qs/Ui/PanelKeyCatcher.qml). Panel.qml itself
// needs the whole bar (Panel, KeyboardPanel's PanelWindow, Service), so this
// mirrors its catcher wiring: a focused keySpy child that records the key,
// then the catcher's signals. The window row and `w` are pinned by
// tests/popup-keys.test.js.
TestCase {
  id: tc
  name: "PopupKeys"
  when: windowShown
  width: 200
  height: 200

  property string lastKeyText: ""
  property var deletes: []
  property int activates: 0
  property bool enterPending: false
  property var activateKeys: []
  property var texts: []
  property int sameWindowShortcuts: 0
  property bool sameWindowShortcutOn: false

  // Panel.qml's wiring: deleteRequested() carries no key, so the spy's
  // record tells x from X.
  PanelKeyCatcher {
    id: catcher
    anchors.fill: parent
    onActiveFocusChanged: if (activeFocus) spy.forceActiveFocus()
    onDeleteRequested: {
      tc.deletes.push(tc.lastKeyText)
      tc.lastKeyText = ""
    }
    // Panel.qml's Enter/Space split: returnRequested fires just before
    // activateRequested for Enter only.
    onReturnRequested: tc.enterPending = true
    onActivateRequested: {
      tc.activates++
      tc.activateKeys.push(tc.enterPending ? "enter" : "space")
      tc.enterPending = false
    }
    onTextKey: function(t) { tc.texts.push(t) }

    Item {
      id: spy
      Keys.onPressed: function(event) {
        var del = PopupKeys.deleteKey(event.text, (event.modifiers & Qt.ShiftModifier) !== 0)
        tc.lastKeyText = del !== "" ? del : event.text
      }
    }
  }

  // A Space Shortcut in the popup's own (focused) window. Panel.qml's Space
  // Shortcut is not this: it sits in the bar widget's item tree, so its
  // window is the bar, while the keys go to the popup (KeyboardPanel's own
  // PanelWindow). Shortcut matching follows the focus window, which the
  // offscreen platform does not model reliably, so that case is not pinned
  // here (see .superpowers/sdd/discoverability/task-1-report.md).
  Shortcut {
    sequences: ["Space"]
    enabled: tc.sameWindowShortcutOn
    onActivated: tc.sameWindowShortcuts++
  }

  function init() {
    lastKeyText = ""
    deletes = []
    activates = 0
    enterPending = false
    activateKeys = []
    texts = []
    sameWindowShortcuts = 0
    sameWindowShortcutOn = false
    catcher.forceActiveFocus()
  }

  function test_focus_on_the_catcher_moves_to_the_spy() {
    verify(spy.activeFocus, "the spy holds focus inside the catcher")
  }

  function test_x_and_X_reach_deleteRequested_with_their_case() {
    keyClick("x")
    keyClick("X")
    keyClick(Qt.Key_X, Qt.ShiftModifier)
    compare(deletes, ["x", "X", "X"], "one deleteRequested per press, each with the key's case")
  }

  function test_space_reaches_activateRequested_once_with_no_shortcut_in_the_way() {
    keyClick(Qt.Key_Space)
    compare(activates, 1, "Space reaches activateRequested once")
    compare(lastKeyText, " ", "the spy saw Space first")
  }

  function test_a_same_window_shortcut_would_swallow_space() {
    sameWindowShortcutOn = true
    keyClick(Qt.Key_Space)
    compare(sameWindowShortcuts, 1, "the focused window's Shortcut fires")
    compare(activates, 0, "and the catcher never sees Space: no double fire either way")
  }

  function test_enter_and_space_are_told_apart_by_returnRequested() {
    keyClick(Qt.Key_Return)
    keyClick(Qt.Key_Space)
    keyClick(Qt.Key_Enter)
    keyClick(Qt.Key_Space)
    compare(activateKeys, ["enter", "space", "enter", "space"])
  }

  function test_backspace_arrives_as_a_text_key() {
    keyClick(Qt.Key_Backspace)
    compare(texts, ["\b"], "the catcher emits textKey(\"\\b\") for Backspace")
  }
}
