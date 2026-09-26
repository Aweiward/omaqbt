pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import "Model.js" as Model
import "ClientView.js" as View

// The torrents pane body: a column header and a ListView over a ListModel
// that is patched in place with Model.diffRows ops (set / insert / remove /
// move, or a full rebuild on reset), so a status tick never resets scroll
// or rebuilds delegates. The cursor is a hash, painted by each delegate;
// ListView.currentIndex is not used, so a row moving under a new sort
// never drags the view along with it.
//
// When there are no rows to show, the same area shows the state copy
// (daemon down, Qt open, empty library, no match, ...) from ClientView.js.
Item {
  id: table

  property string cursorHash: ""
  property string sortMode: "added"
  property bool sortDesc: true
  // One of View.tableState's values.
  property string tableState: "rows"
  // View.stateCopy(...) for tableState, or an empty object.
  property var stateCopy: ({})
  // The loading line appears only after a short grace, so a fast first
  // status never flashes it.
  property bool showLoadingText: false

  signal rowClicked(string hash)

  // The rows currently in rowModel, as plain JS objects, in order.
  property var lastRows: []

  readonly property int rowHeight: Style.spacing.popupRowHeight
  readonly property int headerHeight: Style.space(30)
  readonly property int padX: Style.space(10)
  readonly property int glyphWidth: Style.space(26)
  readonly property int sizeWidth: Style.space(84)
  readonly property int progressWidth: Style.space(150)
  readonly property int dlWidth: Style.space(96)
  readonly property int ulWidth: Style.space(90)
  readonly property int etaWidth: Style.space(70)
  readonly property int ratioWidth: Style.space(62)
  readonly property int fixedWidth: glyphWidth + sizeWidth + progressWidth + dlWidth + ulWidth + etaWidth + ratioWidth
  readonly property int nameWidth: Math.max(Style.space(80), width - fixedWidth)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property string sortedColumn: View.sortColumn(sortMode)
  readonly property bool showRows: tableState === "rows"

  function toneColor(tone) {
    if (tone === "accent") return Color.accent
    if (tone === "muted") return Color.muted
    if (tone === "urgent") return Color.urgent
    return Color.foreground
  }

  function valueColor(text) {
    return text === "—" || text === "∞" ? Color.muted : Color.foreground
  }

  function headerLabel(column, label) {
    if (column !== "" && column === sortedColumn) return label + " " + View.sortMarker(sortDesc)
    return label
  }

  // Applies rows to rowModel with the same semantics as Model.applyOps:
  // every index means "the model at the moment this op runs", in order.
  function setRows(rows) {
    var next = rows || []
    var ops = Model.diffRows(lastRows, next, View.DISPLAY_FIELDS)
    if (!Array.isArray(ops)) {
      rowModel.clear()
      for (var i = 0; i < next.length; i++) rowModel.append(next[i])
    } else {
      for (var j = 0; j < ops.length; j++) {
        var op = ops[j]
        if (op.op === "set") rowModel.set(op.index, op.row)
        else if (op.op === "insert") rowModel.insert(op.index, op.row)
        else if (op.op === "remove") rowModel.remove(op.index, 1)
        else if (op.op === "move") rowModel.move(op.from, op.to, 1)
      }
    }
    lastRows = next.slice()
  }

  // Scrolls just enough to show the row; used on user cursor moves only.
  function positionAt(index) {
    if (index >= 0 && index < rowModel.count) list.positionViewAtIndex(index, ListView.Contain)
  }

  ListModel { id: rowModel }

  // Inline components can't see this file's ids, so they size themselves
  // from Style directly (the same values as rowHeight / padX above).
  component Cell: Text {
    height: Style.spacing.popupRowHeight
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.subtitle
    color: Color.foreground
  }

  component HeaderCell: Text {
    property string column: ""
    property bool sorted: false
    height: Style.space(30)
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Style.font.bodySmall * 0.08
    color: sorted ? Color.foreground : Color.muted
  }

  Item {
    id: header
    visible: table.showRows
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: table.headerHeight

    Row {
      anchors.fill: parent
      HeaderCell { width: table.glyphWidth; text: "" }
      HeaderCell { width: table.nameWidth; column: "name"; sorted: table.sortedColumn === "name"; horizontalAlignment: Text.AlignLeft; text: table.headerLabel(column, "Name") }
      HeaderCell { width: table.sizeWidth; column: "size"; sorted: table.sortedColumn === "size"; text: table.headerLabel(column, "Size") }
      HeaderCell { width: table.progressWidth; column: "progress"; sorted: table.sortedColumn === "progress"; horizontalAlignment: Text.AlignLeft; text: table.headerLabel(column, "Progress") }
      HeaderCell { width: table.dlWidth; column: "dl"; sorted: table.sortedColumn === "dl"; text: table.headerLabel(column, "↓") }
      HeaderCell { width: table.ulWidth; column: "ul"; sorted: table.sortedColumn === "ul"; text: table.headerLabel(column, "↑") }
      HeaderCell { width: table.etaWidth; column: "eta"; sorted: table.sortedColumn === "eta"; text: table.headerLabel(column, "ETA") }
      HeaderCell { width: table.ratioWidth; column: "ratio"; sorted: table.sortedColumn === "ratio"; text: table.headerLabel(column, "Ratio") }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: table.lineColor
    }
  }

  ListView {
    id: list
    visible: table.showRows
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: header.bottom
    anchors.bottom: parent.bottom
    clip: true
    model: rowModel
    boundsBehavior: Flickable.StopAtBounds
    keyNavigationEnabled: false
    highlightFollowsCurrentItem: false
    currentIndex: -1
    reuseItems: true
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    delegate: Item {
      id: rowItem
      required property int index
      required property string hash
      required property string name
      required property string glyph
      required property string glyphTone
      required property string sizeText
      required property string bar
      required property string barTone
      required property string progressText
      required property string progressTone
      required property string dlText
      required property string ulText
      required property string etaText
      required property string ratioText
      readonly property bool isCursor: hash === table.cursorHash

      width: list.width
      height: table.rowHeight

      Rectangle {
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
        anchors.fill: parent
        Cell {
          width: table.glyphWidth
          rightPadding: 0
          horizontalAlignment: Text.AlignLeft
          text: rowItem.glyph
          color: table.toneColor(rowItem.glyphTone)
        }
        Cell {
          width: table.nameWidth
          horizontalAlignment: Text.AlignLeft
          text: rowItem.name
        }
        Cell { width: table.sizeWidth; text: rowItem.sizeText }
        Item {
          width: table.progressWidth
          height: table.rowHeight
          Row {
            anchors.left: parent.left
            anchors.leftMargin: table.padX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Text {
              visible: rowItem.bar !== ""
              text: rowItem.bar
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.subtitle
              font.letterSpacing: -1
              color: table.toneColor(rowItem.barTone)
            }
            Text {
              text: rowItem.progressText
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.subtitle
              color: table.toneColor(rowItem.progressTone)
            }
          }
        }
        Cell { width: table.dlWidth; text: rowItem.dlText; color: table.valueColor(text) }
        Cell { width: table.ulWidth; text: rowItem.ulText; color: table.valueColor(text) }
        Cell { width: table.etaWidth; text: rowItem.etaText; color: table.valueColor(text) }
        Cell { width: table.ratioWidth; text: rowItem.ratioText }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: table.rowClicked(rowItem.hash)
      }
    }
  }

  // The loading line: blank for the first moments, then centered.
  Text {
    visible: table.tableState === "loading" && table.showLoadingText
    anchors.centerIn: parent
    text: table.stateCopy.title || ""
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: Color.muted
  }

  // Every other non-row state: a title, a paragraph and its keys.
  Column {
    visible: !table.showRows && table.tableState !== "loading"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(40)
    anchors.rightMargin: Style.space(40)
    spacing: Style.space(14)

    Text {
      width: Math.min(parent.width, Style.space(560))
      text: table.stateCopy.title || ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      font.family: Style.fontFamily
      font.pixelSize: Style.font.heading
      color: table.toneColor(table.stateCopy.tone || "fg")
    }

    Text {
      visible: text !== ""
      width: Math.min(parent.width, Style.space(560))
      text: table.stateCopy.body || ""
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      lineHeight: 1.4
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }

    Column {
      spacing: Style.space(8)
      Repeater {
        model: table.stateCopy.keys || []
        delegate: Row {
          id: keyRow
          required property var modelData
          Text {
            width: Style.space(74)
            text: keyRow.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.accent
          }
          Text {
            text: keyRow.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.foreground
          }
        }
      }
    }
  }
}
