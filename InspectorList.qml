pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import "ClientView.js" as View

// The inspector pane's shared cursor list: today's Files ListView, generic
// enough for trackers and peers (slice 2) to reuse. A plain ListView whose
// rows and columns are entirely data-driven, with the same cursor look
// Files has always had (Style.selectedAccentFill plus a 3px accent bar),
// drawn only when `focusedPane`.
//
// Callers own their own row shape and stickiness: `rows` needs a `key`
// per row (unique, stable across a refresh) so a caller can carry the
// cursor across a reorder or a resize with InspectorView.keyedIndex; this
// component itself never reads `key` -- it only trusts `cursor` (an
// index into `rows`).
Item {
  id: list

  // rows: plain objects, each read through `columns`' `role` and `tone`.
  property var rows: []
  // The cursor row's index into `rows`, or -1 for none.
  property int cursor: -1
  property bool focusedPane: false
  // columns: [{role, width, align, tone}]. `width` 0 (or omitted) is
  // flexible -- it fills what fixed-width columns leave, and is the only
  // one elided (Text.ElideMiddle); a positive number is a fixed pixel
  // width. `align`: "left" (default) or "right". `tone`: a
  // View.toneColor name ("accent"/"muted"/"urgent"/"fg"), "dim" (today's
  // Files dim, for a skipped file's name), or a function(row) -> one of
  // those, for a per-row tone (a skipped file's name/priority; Task 5's
  // per-row tracker/peer tone).
  property var columns: []
  // true: a fixed header row (ListView.header, so it never counts toward
  // `count`) with each column's `role` as its label. Files doesn't use
  // one.
  property bool header: false
  // A Component drawn under the cursor row, inside its accent fill (the
  // fill and the row's height both grow to hold it); its root item may
  // declare `property var row` to receive the cursor row. null (Files)
  // draws nothing, and every row keeps `rowHeight`.
  property var detail: null
  property int rowHeight: Style.spacing.popupRowHeight

  signal rowClicked(int index)

  readonly property int padX: Style.space(12)
  readonly property int cellSpacing: Style.space(8)

  function positionAt(index) {
    if (index < 0 || index >= listView.count) return
    listView.positionViewAtIndex(index, ListView.Contain)
  }

  function toneColor(tone) {
    if (tone === "dim") return Util.alpha(Color.foreground, Style.normalBorderAlpha)
    return View.toneColor(tone, Color)
  }

  function toneFor(column, row) {
    return typeof column.tone === "function" ? column.tone(row) : column.tone
  }

  readonly property real fixedWidth: {
    var t = 0
    for (var i = 0; i < columns.length; i++) if (columns[i].width > 0) t += columns[i].width
    return t
  }
  readonly property int flexCount: {
    var n = 0
    for (var i = 0; i < columns.length; i++) if (!(columns[i].width > 0)) n++
    return n
  }
  readonly property real flexWidth: {
    if (flexCount <= 0) return 0
    var avail = listView.width - 2 * padX - cellSpacing * Math.max(0, columns.length - 1) - fixedWidth
    return Math.max(0, avail / flexCount)
  }

  function columnWidth(column) {
    return column.width > 0 ? column.width : list.flexWidth
  }

  ListView {
    id: listView
    anchors.fill: parent
    clip: true
    model: list.rows
    boundsBehavior: Flickable.StopAtBounds
    keyNavigationEnabled: false
    highlightFollowsCurrentItem: false
    currentIndex: -1
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    header: list.header ? headerComp : null

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index
      readonly property bool isCursor: list.focusedPane && index === list.cursor
      readonly property bool hasDetail: rowItem.isCursor && list.detail !== null

      width: listView.width
      height: list.rowHeight + (rowItem.hasDetail ? detailLoader.height : 0)

      Rectangle {
        id: fill
        anchors.fill: parent
        color: rowItem.isCursor ? Style.selectedAccentFill : "transparent"
      }

      Rectangle {
        visible: rowItem.isCursor
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(3)
        color: Color.accent
      }

      Row {
        id: cells
        x: list.padX
        anchors.top: parent.top
        spacing: list.cellSpacing
        height: list.rowHeight

        Repeater {
          model: list.columns
          delegate: Text {
            id: cell
            objectName: "cell"
            required property var modelData
            width: list.columnWidth(modelData)
            height: cells.height
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: modelData.align === "right" ? Text.AlignRight : Text.AlignLeft
            elide: modelData.width > 0 ? Text.ElideNone : Text.ElideMiddle
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            text: rowItem.modelData ? String(rowItem.modelData[cell.modelData.role]) : ""
            color: list.toneColor(list.toneFor(cell.modelData, rowItem.modelData))
          }
        }
      }

      Loader {
        id: detailLoader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: list.rowHeight
        active: rowItem.hasDetail
        sourceComponent: list.detail
        onLoaded: if (item) item.row = rowItem.modelData
      }

      MouseArea {
        anchors.fill: fill
        acceptedButtons: Qt.LeftButton
        onClicked: list.rowClicked(rowItem.index)
      }
    }
  }

  Component {
    id: headerComp
    Item {
      width: listView.width
      height: list.rowHeight

      Row {
        x: list.padX
        spacing: list.cellSpacing
        height: list.rowHeight

        Repeater {
          model: list.columns
          delegate: Text {
            required property var modelData
            width: list.columnWidth(modelData)
            height: list.rowHeight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: modelData.align === "right" ? Text.AlignRight : Text.AlignLeft
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.muted
            text: modelData.role
          }
        }
      }
    }
  }
}
