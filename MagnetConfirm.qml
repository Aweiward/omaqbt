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
  // The Service ticket of the last start/cancel/drop this row ran (0 for
  // none). If it fails, the item is offered again.
  property int ticket: 0

  readonly property var ms: client.magnetState
  readonly property bool shown: View.magnetShown(ms, handledKey)
  // A shown magnet not yet in its CONFIRM: the status line says it waits.
  readonly property bool deferred: View.magnetDeferred(shown, client.regState)
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
      { blocked: c.helpOpen || View.overlayPane(c.layout, c.pane) !== "", opened: c.opened,
        now: Date.now(), lastKeyAt: c.lastKeyAt, active: c.windowActive() })
    seenKeys = r.mem.seen
    handledKey = r.mem.handled
    focusDue = r.mem.focusDue
    if (r.regState) c.regState = r.regState
    if (r.focus) c.requestWmFocus(r.focusField ? c.typingField() : null)
    // Still settling after a key: look again once it has.
    if (r.wait > 0) {
      settle.interval = r.wait
      settle.restart()
    }
  }

  function act(commandId) {
    var c = client
    var s = c.magnetState
    var a = View.magnetAction(s, commandId)
    if (a.note !== "") c.note(a.note, "muted")
    if (a.call === "") return
    var hashes = s.hash !== "" ? [s.hash] : []
    var t
    if (a.call === "start") t = c.service.startPending(s.hash, c.opts(hashes))
    else if (a.call === "cancel") t = c.service.cancelPending(s.hash, c.opts(hashes))
    else t = c.service.dropInboxCurrent(c.opts(hashes))
    // A busy refusal (0) queued nothing: track() notes "Busy, try again."
    // and the item stays offered.
    c.track(t, a.kind, hashes)
    if (!(t > 0)) return
    ticket = t
    handledKey = View.magnetItemKey(s.pending || s.inbox)
    sync()
  }

  // A failed start/cancel/drop leaves the item queued: offer it again.
  // Filtered by this row's ticket only; the pending-drop bookkeeping emits
  // extra window-origin signals carrying the same hashes.
  Connections {
    target: magnetRow.client.service
    ignoreUnknownSignals: true
    function onActionFinished(t, ok, error, origin, hashes) {
      if (magnetRow.ticket <= 0 || t !== magnetRow.ticket) return
      magnetRow.ticket = 0
      if (ok) return
      magnetRow.handledKey = ""
      magnetRow.sync()
    }
  }

  Timer {
    id: settle
    repeat: false
    onTriggered: magnetRow.sync()
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
