pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The Trackers tab: the DHT/PeX/LSD summary line, header, InspectorList,
// cursor detail (redacted URL, never its path or query, so a passkey is
// never on screen) and footer. Extracted out of InspectorPane.qml (slice
// 2b, Task 1: pure refactor, no behaviour change).
Item {
  id: root

  // InspectorView.listTab(...): {state, rows, summary, title, copy}.
  property var trackers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  property int trackerIndex: 0
  property bool focusedPane: false
  property int padX: 0
  property color lineColor: "transparent"

  signal rowClicked(int index)

  function positionAt(index) {
    trackerList.positionAt(index)
  }

  readonly property string summaryJson: JSON.stringify(InspectorView.trackerSummaryParts(root.trackers.summary))

  readonly property var trackerColumns: [
    { role: "glyph", label: "", width: Style.space(14), tone: function(r) { return r.tone } },
    { role: "host", label: "Tracker", width: 0, tone: "fg" },
    { role: "seeds", label: "Seeds", width: Style.space(44), align: "right", tone: function(r) { return r.seeds === "—" ? "muted" : "fg" } },
    { role: "peers", label: "Peers", width: Style.space(44), align: "right", tone: function(r) { return r.peers === "—" ? "muted" : "fg" } }
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
    id: trackerDetailComp
    Column {
      id: td
      property var row: null
      readonly property var d: InspectorView.trackerDetail(row)
      readonly property int textWidth: Math.max(0, width - leftPadding - rightPadding)
      leftPadding: Style.space(29)
      rightPadding: Style.space(12)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(2)
      Row {
        DetailText { id: statusWord; text: td.d.status.text; tone: td.d.status.tone }
        DetailText {
          visible: td.d.message !== ""
          width: Math.max(0, td.textWidth - statusWord.width)
          text: " · " + td.d.message
        }
      }
      DetailText { width: td.textWidth; elide: Text.ElideMiddle; text: td.d.url }
      DetailText { width: td.textWidth; text: td.d.tier }
    }
  }

  // M3: the summary line ("DHT on · PeX on · LSD on · N seeds · N peers")
  // still shows with no real trackers -- it's the only place DHT/PeX/LSD
  // state is visible, and "No trackers" alone would hide it. The
  // empty-state message is anchored below it instead of centered over the
  // whole tab, so the two never overlap.
  InspectorTabMessage {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: root.trackers.state === "empty" ? summaryLine.bottom : parent.top
    anchors.bottom: parent.bottom
    tabState: root.trackers.state
    error: root.trackers.error || ""
    noun: "trackers"
    copy: root.trackers.copy
  }

  Item {
    id: summaryLine
    visible: root.trackers.state === "rows" || root.trackers.state === "empty"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(30)
    Row {
      anchors.left: parent.left
      anchors.leftMargin: root.padX
      anchors.verticalCenter: parent.verticalCenter
      Repeater {
        // Through a string, which only notifies when the text changes,
        // so the per-second refresh doesn't rebuild these delegates.
        model: JSON.parse(root.summaryJson)
        delegate: Text {
          required property var modelData
          text: modelData.text
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.bodySmall
          color: View.toneColor(modelData.tone, Color)
        }
      }
    }
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: root.lineColor
    }
  }

  InspectorList {
    id: trackerList
    visible: root.trackers.state === "rows"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: summaryLine.bottom
    anchors.bottom: trackerFoot.top
    header: true
    rows: root.trackers.rows
    columns: root.trackerColumns
    cursor: root.trackerIndex
    focusedPane: root.focusedPane
    detail: trackerDetailComp
    onRowClicked: function(index) { root.rowClicked(index) }
  }

  InspectorFooter {
    id: trackerFoot
    visible: root.trackers.state === "rows"
    text: "j k move · a add · c change · x remove · y copy · R reannounce"
  }
}
