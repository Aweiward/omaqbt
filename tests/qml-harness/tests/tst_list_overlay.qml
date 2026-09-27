import QtQuick
import QtTest
import "../../.."

// ListOverlay's field routing (slice 3a Task 4): the one behaviour the
// window-level harness (tst_client.qml) can't exercise, since its `key()`
// helper calls Client.handleKey directly and never goes through a real,
// focused TextField's Keys.onPressed. This is the first harness test that
// delivers an actual Qt key event and lets the field itself decide
// (View.overlayOwnsKey) whether to forward it or type it.
TestCase {
  id: tc
  name: "ListOverlay"
  when: windowShown
  width: 400
  height: 300

  ListOverlay {
    id: overlay
    anchors.fill: parent
    keyMode: "PICKER"
    multi: true
  }

  function init() {
    overlay.setQuery("")
  }

  function test_space_is_forwarded_only_while_the_field_is_empty() {
    var forwarded = 0
    var onForwarded = function() { forwarded++ }
    overlay.keyForwarded.connect(onForwarded)

    overlay.focusField()
    compare(overlay.query, "", "starts empty")

    keyClick(Qt.Key_Space)
    compare(forwarded, 1, "an empty field forwards Space to dispatch")
    compare(overlay.query, "", "the field itself never sees it as text")

    overlay.setQuery("anime")
    keyClick(Qt.Key_Space)
    compare(forwarded, 1, "no further forward once the field has typed text")
    compare(overlay.query, "anime ", "Space types into a non-empty field")

    overlay.keyForwarded.disconnect(onForwarded)
  }
}
