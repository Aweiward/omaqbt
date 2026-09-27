pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "ClientView.js" as View

// The filters pane body: Model.filterGroups flattened by
// View.filterEntries into group headers (Status, Categories, Tags,
// Trackers) and items. The active filter shows `▸`, accent text and the
// accent fill; counts are right-aligned in muted; zero-count items are
// dimmed but still selectable. While the pane is focused, the j/k cursor
// (distinct from the active filter until Enter applies it) is outlined in
// accent. Labels are untrusted (category, tag and tracker names) and are
// rendered as plain text. An empty Categories or Tags group shows a muted
// "No categories yet" / "No tags yet" note (kind "note", never a cursor
// stop), and while the pane is focused a footer lists the keys that apply
// to the cursor row (LibraryView.footerKeys).
Item {
  id: pane

  // View.filterEntries(...): [{kind: "header"|"item"|"note", group, value, label, count, zero}]
  property var entries: []
  property var activeFilter: ({ group: "status", value: "All" })
  property var cursorFilter: ({ group: "status", value: "All" })
  property bool focusedPane: false
  // [{key, label}] for the footer; empty hides it.
  property var footerKeys: []

  signal itemClicked(string group, string value)

  readonly property int padX: Style.space(12)
  readonly property int itemHeight: Style.space(26)
  readonly property color dimColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property color mutedColor: Color.muted

  // Scrolls just enough to show the entry at index.
  function positionAt(index) {
    var item = rep.itemAt(index)
    if (!item) return
    var top = item.y
    var bottom = item.y + item.height
    if (top < flick.contentY) flick.contentY = top
    else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height
  }

  Flickable {
    id: flick
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: footer.visible ? footer.top : parent.bottom
    clip: true
    contentWidth: width
    contentHeight: column.height + Style.space(10)
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: column
      width: flick.width
      topPadding: Style.space(4)

      Repeater {
        id: rep
        model: pane.entries

        delegate: Item {
          id: entry
          required property var modelData
          required property int index
          readonly property bool isHeader: modelData.kind === "header"
          readonly property bool isItem: modelData.kind === "item"
          readonly property bool isActive: isItem && View.sameFilter(modelData, pane.activeFilter)
          readonly property bool isCursor: isItem && pane.focusedPane && View.sameFilter(modelData, pane.cursorFilter)
          readonly property bool urgentCount: modelData.group === "status" && modelData.value === "Errored" && modelData.count > 0

          width: column.width
          height: isHeader ? headerText.implicitHeight + Style.space(index === 0 ? 10 : 20) : pane.itemHeight

          PanelSectionHeader {
            id: headerText
            visible: entry.isHeader
            anchors.left: parent.left
            anchors.leftMargin: pane.padX
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            text: entry.modelData.label
            color: Color.muted
            font.bold: false
            font.capitalization: Font.AllUppercase
            font.letterSpacing: Style.font.caption * 0.12
          }

          Rectangle {
            visible: entry.isItem
            anchors.fill: parent
            color: entry.isActive ? Style.selectedAccentFill : "transparent"
            border.width: entry.isCursor ? 1 : 0
            border.color: Color.accent
          }

          Text {
            visible: entry.isActive
            anchors.right: label.left
            anchors.rightMargin: Style.space(2)
            anchors.verticalCenter: parent.verticalCenter
            text: "▸"
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.accent
          }

          Text {
            id: label
            visible: !entry.isHeader
            anchors.left: parent.left
            anchors.leftMargin: pane.padX
            anchors.right: count.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: entry.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: entry.isItem ? Style.font.body : Style.font.bodySmall
            color: !entry.isItem ? Color.muted : (entry.isActive ? Color.accent : (entry.modelData.zero ? pane.dimColor : Color.foreground))
          }

          Text {
            id: count
            visible: entry.isItem
            anchors.right: parent.right
            anchors.rightMargin: pane.padX
            anchors.verticalCenter: parent.verticalCenter
            text: String(entry.modelData.count)
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: entry.urgentCount ? Color.urgent : (entry.modelData.zero ? pane.dimColor : Color.muted)
          }

          MouseArea {
            enabled: entry.isItem
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onClicked: pane.itemClicked(entry.modelData.group, entry.modelData.value)
          }
        }
      }
    }
  }

  // The keys for the cursor row ("a add · c rename · p save path · x
  // delete"), wrapping in the 210 px pane.
  Item {
    id: footer
    objectName: "filtersFooter"
    visible: pane.focusedPane && pane.footerKeys.length > 0
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: keyFlow.implicitHeight + Style.space(12)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: pane.dimColor
    }

    Flow {
      id: keyFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: pane.padX
      anchors.rightMargin: pane.padX
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)
      Repeater {
        model: pane.footerKeys
        delegate: Row {
          id: hint
          required property var modelData
          Text {
            text: hint.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
          }
          Text {
            text: " " + hint.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.muted
          }
        }
      }
    }
  }
}
