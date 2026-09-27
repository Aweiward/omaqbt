pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// A tab's non-row state: nothing (blank), "Loading…", the read error (its
// cause, then "Retrying every 5 s."), "Needs qbt-serve", or the empty
// copy. Shared by the trackers, peers and chart tabs. Extracted out of
// InspectorPane.qml (slice 2b, Task 1: pure refactor, no behaviour
// change).
Item {
  id: msg
  property string tabState: "blank"
  property string noun: ""
  property var copy: ({})
  // The read error's (sanitized) text, for the "error" state.
  property string error: ""
  readonly property bool big: tabState === "error" || tabState === "empty"

  Column {
    visible: msg.tabState !== "blank" && msg.tabState !== "rows"
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(28)
    anchors.rightMargin: Style.space(28)
    spacing: Style.space(10)

    Text {
      width: parent.width
      horizontalAlignment: msg.big ? Text.AlignLeft : Text.AlignHCenter
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: msg.big ? Style.font.title : Style.font.body
      color: msg.tabState === "error" ? Color.urgent : (msg.tabState === "empty" ? Color.foreground : Color.muted)
      text: {
        if (msg.tabState === "loading") return "Loading " + msg.noun + "…"
        if (msg.tabState === "error") return "Couldn't read " + msg.noun
        if (msg.tabState === "sidecarDown") return "Needs qbt-serve (slow polling)"
        if (msg.tabState === "empty") return msg.copy.title || ""
        return ""
      }
    }
    Text {
      visible: msg.big
      width: parent.width
      wrapMode: Text.WordWrap
      lineHeight: 1.3
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
      text: msg.tabState === "error" ? msg.error : (msg.copy.body || "")
    }
    Text {
      visible: msg.tabState === "error"
      width: parent.width
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
      text: "Retrying every 5 s."
    }
  }
}
