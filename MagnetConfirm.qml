pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View

// The window's browser-magnet confirm (spec D3): the row pinned at the top
// of the Torrents pane while a magnet waits (an accent ↓, the name, or
// "Fetching name…" until it is known, and the size), plus the wiring
// behind it. sync() raises and ends the MAGNET CONFIRM on the Client and
// asks for the window's attention when a magnet arrives (View.magnetSync);
// act() runs magnet.start / magnet.cancel (View.magnetAction).
//
// The magnet stays queued until the next snapshot after the window acts on
// it, so the item acted on is remembered (handledKey) and never offered, or
// acted on, twice.
Item {
  id: magnetRow

  // The Client whose regState, service and helpers this drives.
  required property var client

  // View.magnetSync's memory between calls.
  property var seenKeys: []
  property string handledKey: ""
  property bool focusDue: false

  readonly property var ms: client.magnetState
  readonly property bool shown: View.magnetShown(ms, handledKey)
  // View.magnetLine(...) while the MAGNET CONFIRM is up, else null.
  readonly property var lineParts: View.isMagnetConfirm(client.regState) ? View.magnetLine(ms) : null

  visible: shown
  height: shown ? Style.spacing.popupRowHeight : 0

  // Reads client.magnetState, not `ms`: Client calls this from its own
  // onMagnetStateChanged, which can run before `ms` has caught up.
  function sync() {
    var c = client
    var svc = c.service
    var r = View.magnetSync({ seen: seenKeys, handled: handledKey, focusDue: focusDue }, c.regState, c.magnetState,
      View.magnetKeys(svc ? svc.magnetPending : [], svc ? svc.magnetInbox : []),
      { blocked: c.helpOpen || View.overlayPane(c.layout, c.pane) !== "", opened: c.opened })
    seenKeys = r.mem.seen
    handledKey = r.mem.handled
    focusDue = r.mem.focusDue
    if (r.regState) c.regState = r.regState
    if (r.focus) c.requestWmFocus()
  }

  function act(commandId) {
    var c = client
    var s = c.magnetState
    var a = View.magnetAction(s, commandId)
    if (a.note !== "") c.note(a.note, "muted")
    if (a.call === "") return
    var hashes = s.hash !== "" ? [s.hash] : []
    var ticket
    if (a.call === "start") ticket = c.service.startPending(s.hash, c.opts(hashes))
    else if (a.call === "cancel") ticket = c.service.cancelPending(s.hash, c.opts(hashes))
    else ticket = c.service.dropInboxCurrent(c.opts(hashes))
    c.track(ticket, a.kind, hashes)
    handledKey = View.magnetItemKey(s.pending || s.inbox)
    sync()
  }

  Rectangle {
    anchors.fill: parent
    color: Style.selectedAccentFill
  }

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(3)
    color: Color.accent
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: 1
    color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  }

  Text {
    id: glyph
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(16)
    text: "↓"
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.subtitle
    color: Color.accent
  }

  Text {
    anchors.left: glyph.right
    anchors.right: size.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    elide: Text.ElideRight
    text: magnetRow.ms.isError ? magnetRow.ms.error : magnetRow.ms.title
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.subtitle
    color: magnetRow.ms.isError ? Color.urgent : Color.foreground
  }

  Text {
    id: size
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    text: magnetRow.ms.sizeText
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.subtitle
    color: Color.muted
  }
}
