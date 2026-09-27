pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The Chart tab: the tab's non-row state, or the SpeedChart once a
// non-empty series arrives. Extracted out of InspectorPane.qml (slice 2b,
// Task 1: pure refactor, no behaviour change).
Item {
  id: root

  // InspectorView.chartTab(...): {state, series, error}.
  property var chart: ({
    state: "blank",
    series: { down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—", nowDlText: "—", nowUlText: "—", empty: true },
    error: ""
  })
  property int padX: 0

  InspectorTabMessage {
    anchors.fill: parent
    tabState: root.chart.state
    error: root.chart.error || ""
    noun: "chart"
  }

  SpeedChart {
    visible: root.chart.state === "rows"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: root.padX
    anchors.rightMargin: root.padX
    anchors.topMargin: Style.space(10)
    series: root.chart.series
  }
}
