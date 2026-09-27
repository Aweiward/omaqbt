pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The Peers tab: header, InspectorList, cursor detail (ip:port, client,
// flags, country) and footer. Extracted out of InspectorPane.qml (slice
// 2b, Task 1: pure refactor, no behaviour change).
Item {
  id: root

  // InspectorView.listTab(...): {state, rows, summary, title, copy}.
  property var peers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  property int peerIndex: 0
  property bool focusedPane: false

  signal rowClicked(int index)

  function positionAt(index) {
    peerList.positionAt(index)
  }

  readonly property var peerColumns: [
    { role: "country", label: "", width: Style.space(22), tone: "muted" },
    { role: "client", label: "Client", width: 0, tone: "fg" },
    { role: "has", label: "Has", width: Style.space(44), align: "right", tone: "fg" },
    { role: "downText", label: "↓", width: Style.space(62), align: "right", tone: "fg" },
    { role: "upText", label: "↑", width: Style.space(62), align: "right", tone: "fg" }
  ]

  // One line of the cursor row's detail block (muted unless `tone`).
  component DetailText: Text {
    property string tone: "muted"
    textFormat: Text.PlainText
    elide: Text.ElideRight
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: View.toneColor(tone, Color)
  }

  Component {
    id: peerDetailComp
    Column {
      id: pd
      property var row: null
      readonly property var d: InspectorView.peerDetail(row)
      readonly property int textWidth: Math.max(0, width - leftPadding - rightPadding)
      leftPadding: Style.space(29)
      rightPadding: Style.space(12)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(2)
      Row {
        DetailText { id: ipText; text: pd.d.ip; tone: "fg" }
        DetailText { width: Math.max(0, pd.textWidth - ipText.width); text: pd.d.rest }
      }
      Row {
        DetailText { id: flagsLead; text: "flags " }
        DetailText { id: flagsText; text: pd.d.flags; tone: "fg" }
        DetailText {
          width: Math.max(0, pd.textWidth - flagsLead.width - flagsText.width)
          text: " · " + pd.d.flagsDesc
        }
      }
    }
  }

  InspectorTabMessage {
    anchors.fill: parent
    tabState: root.peers.state
    error: root.peers.error || ""
    noun: "peers"
    copy: root.peers.copy
  }

  InspectorList {
    id: peerList
    visible: root.peers.state === "rows"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: peerFoot.top
    header: true
    rows: root.peers.rows
    columns: root.peerColumns
    cursor: root.peerIndex
    focusedPane: root.focusedPane
    detail: peerDetailComp
    onRowClicked: function(index) { root.rowClicked(index) }
  }

  InspectorFooter {
    id: peerFoot
    visible: root.peers.state === "rows"
    text: "j k move · y copy ip:port · b ban · sorted by ↓ then ↑"
  }
}
