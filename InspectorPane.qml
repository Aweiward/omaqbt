pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The inspector pane body: tab strip, pane title, and a switch between the
// per-tab components: InspectorInfoTab (1), InspectorTrackersTab (2),
// InspectorPeersTab (3), InspectorFilesTab (4) and InspectorChartTab (5,
// Task 8). Each tab component gets what it needs through properties; every
// property, signal and function Client.qml or the test harness uses stays
// here on the pane itself (slice 2b, Task 1: pure refactor, no behaviour
// change -- the tab bodies used to live inline in this file).
Item {
  id: pane

  property string tab: "info"
  // View.inspectorInfo(...), or null when there is no cursor row.
  property var info: null
  // The raw cursor row (Client.cursorRow), for InspectorView.emptyCopy's
  // row argument -- distinct from `info`, which is already the rendered
  // Info tab, not row-shaped.
  property var row: null
  // InspectorView.infoView(...)'s pieces bar and Transfer/Torrent groups.
  property var pieces: []
  property string piecesLegend: ""
  property bool noMeta: false
  // M2: true for a fresh Info-tab error. `noMeta` keeps its usual
  // row-size meaning (State's "waiting for metadata" and Files' "No file
  // list yet" copy must survive an unrelated info-read failure); this
  // instead gates only the Info tab's own "no metadata yet" line, so a
  // transient error blanks the pieces area without a stale line.
  property bool infoErrored: false
  property var groups: []
  // LimitsView.footerKeys for the Limits cursor row ([] unless focused on
  // Info), pinned ahead of the Info footer's own keys.
  property var limitKeys: []
  // View.filesView(...): {state: "loading"|"error"|"empty"|"rows", rows}.
  property var files: ({ state: "loading", rows: [] })
  property int fileIndex: 0
  // InspectorView.listTab(...): {state, rows, summary, title, copy}.
  property var trackers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  property var peers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  // InspectorView.chartTab(...): {state, series, error}.
  property var chart: ({
    state: "blank",
    series: { down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—", nowDlText: "—", nowUlText: "—", empty: true },
    error: ""
  })
  property int trackerIndex: 0
  property int peerIndex: 0
  property bool focusedPane: false
  // The pane title's right side: "8 trackers", "17 peers · 14 seeds".
  readonly property string titleRight: info === null ? ""
    : (tab === "trackers" ? trackers.title : (tab === "peers" ? peers.title : ""))

  signal tabClicked(string tab)
  signal fileClicked(int index)
  signal listRowClicked(string tab, int index)

  readonly property int padX: Style.space(12)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  function positionFile(index) {
    filesTab.positionAt(index)
  }

  // j/k on Info: scroll so the Limits cursor row shows (Ruling CL 4).
  function positionLimit() {
    infoTab.positionLimit()
  }

  function positionRow(tab, index) {
    if (tab === "trackers") trackersTab.positionAt(index)
    else peersTab.positionAt(index)
  }

  // ---- tabs ------------------------------------------------------------
  Item {
    id: tabs
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(30)

    Row {
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      spacing: Style.space(14)

      Repeater {
        model: [{ digit: "1", tab: "info" }, { digit: "2", tab: "trackers" }, { digit: "3", tab: "peers" },
          { digit: "4", tab: "files" }, { digit: "5", tab: "chart" }]
        delegate: Item {
          id: tabItem
          required property var modelData
          readonly property bool on: pane.tab === modelData.tab
          width: tabRow.implicitWidth
          height: tabs.height

          Row {
            id: tabRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Text {
              text: tabItem.modelData.digit
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: Color.muted
            }
            Text {
              text: tabItem.modelData.tab
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: tabItem.on ? Color.foreground : Color.muted
            }
          }

          Rectangle {
            visible: tabItem.on
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(2)
            color: Color.accent
          }

          MouseArea {
            anchors.fill: parent
            onClicked: pane.tabClicked(tabItem.modelData.tab)
          }
        }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: pane.lineColor
    }
  }

  Item {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: tabs.bottom
    anchors.bottom: parent.bottom

    // No cursor row (or a blocking state): the same line on both tabs.
    Text {
      visible: pane.info === null
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.top: parent.top
      anchors.topMargin: Style.space(14)
      text: "Select a torrent"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }

    InspectorInfoTab {
      id: infoTab
      visible: pane.info !== null && pane.tab === "info"
      anchors.fill: parent
      info: pane.info
      pieces: pane.pieces
      piecesLegend: pane.piecesLegend
      noMeta: pane.noMeta
      row: pane.row
      infoErrored: pane.infoErrored
      groups: pane.groups
      limitKeys: pane.limitKeys
      padX: pane.padX
      lineColor: pane.lineColor
    }

    InspectorTrackersTab {
      id: trackersTab
      visible: pane.info !== null && pane.tab === "trackers"
      anchors.fill: parent
      trackers: pane.trackers
      trackerIndex: pane.trackerIndex
      focusedPane: pane.focusedPane
      padX: pane.padX
      lineColor: pane.lineColor
      onRowClicked: function(index) { pane.listRowClicked("trackers", index) }
    }

    InspectorPeersTab {
      id: peersTab
      visible: pane.info !== null && pane.tab === "peers"
      anchors.fill: parent
      peers: pane.peers
      peerIndex: pane.peerIndex
      focusedPane: pane.focusedPane
      onRowClicked: function(index) { pane.listRowClicked("peers", index) }
    }

    InspectorFilesTab {
      id: filesTab
      visible: pane.info !== null && pane.tab === "files"
      anchors.fill: parent
      files: pane.files
      fileIndex: pane.fileIndex
      focusedPane: pane.focusedPane
      noMeta: pane.noMeta
      row: pane.row
      padX: pane.padX
      onFileClicked: function(index) { pane.fileClicked(index) }
    }

    InspectorChartTab {
      id: chartTab
      visible: pane.info !== null && pane.tab === "chart"
      anchors.fill: parent
      chart: pane.chart
      padX: pane.padX
    }
  }
}
