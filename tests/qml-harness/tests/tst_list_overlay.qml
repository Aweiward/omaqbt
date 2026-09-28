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

  // Every Text's string under obj. The TestCase's own item isn't shown, so
  // this walks by structure, not by visibility.
  function allTexts(obj, out) {
    out = out || []
    if (!obj) return out
    if (typeof obj.text === "string" && obj.font !== undefined) out.push(obj.text)
    var kids = obj.children || []
    for (var i = 0; i < kids.length; i++) allTexts(kids[i], out)
    if (obj.contentItem && kids.indexOf(obj.contentItem) === -1) allTexts(obj.contentItem, out)
    return out
  }

  // Slice 3b Task 5 (Ruling CJ 4): a dimmed row with no reason (the Limits
  // rows, blocked with no note) shows no dangling " · ".
  function test_a_dimmed_row_without_a_reason_shows_no_separator() {
    var saved = overlay.rows
    overlay.rows = [
      { kind: "command", id: "a", title: "Edit limit", group: "Torrent", keys: "Enter", indices: [], enabled: false, reason: "" },
      { kind: "command", id: "b", title: "Next limit", group: "View", keys: "j", indices: [], enabled: false, reason: "focus the info tab" }
    ]
    wait(30)
    var texts = allTexts(overlay)
    verify(texts.indexOf("Edit limit") !== -1, "the rows render: " + texts.join("|"))
    var seps = texts.filter(function(t) { return t.indexOf("·") !== -1 })
    compare(seps, ["  · focus the info tab"], "no separator without a reason")
    overlay.rows = saved
  }
}
