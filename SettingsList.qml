pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons

// The list editor's column (slice 4b): the lines of a list setting
// (SettingsView.listItems: banned IPs, add_trackers, excluded_file_names),
// one 28 px row each, the cursor row highlighted. add_trackers' tier
// breaks show as muted "— next tier —" rows and an empty pattern as a
// muted "(empty line)". An empty list shows its empty-state line
// (SettingsView.listEmptyText). The keys arrive as registry commands (pane
// settingsList) through SettingsCommands; this item only draws and
// scrolls. Every line is PlainText.
Item {
  id: listView
  objectName: "settingsList"

  // [{index, value, tierBreak, text}] and the cursor's position in them.
  property var items: []
  property int cursor: 0
  property bool focused: false
  property string emptyText: ""
  // A write of this list is running: its lines are about to change.
  property bool saving: false
  signal rowClicked(int index)

  readonly property int rowHeight: Style.space(28)
  readonly property color dim: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  // Scrolls the cursor row into view (after a j/k or a click).
  function reveal() {
    var it = rowRep.itemAt(cursor)
    if (!it) return
    if (it.y < flick.contentY) flick.contentY = it.y
    else if (it.y + it.height > flick.contentY + flick.height) flick.contentY = it.y + it.height - flick.height
  }

  onCursorChanged: Qt.callLater(listView.reveal)

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: listColumn.height + Style.space(8)
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: listColumn
      width: flick.width
      topPadding: Style.space(4)

      Repeater {
        id: rowRep
        model: listView.items
        delegate: Item {
          id: lineItem
          objectName: "settingsListRow"
          required property var modelData
          required property int index
          readonly property bool current: index === listView.cursor
          readonly property bool quiet: modelData.tierBreak === true || modelData.value === ""
          width: listColumn.width
          height: listView.rowHeight

          Rectangle {
            visible: lineItem.current
            anchors.fill: parent
            color: Style.selectedAccentFill
          }
          Rectangle {
            visible: lineItem.current && listView.focused
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            color: Color.accent
          }
          Text {
            objectName: "settingsListText"
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideMiddle
            horizontalAlignment: lineItem.modelData.tierBreak === true ? Text.AlignHCenter : Text.AlignLeft
            text: String(lineItem.modelData.text)
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: listView.saving ? Color.muted : (lineItem.quiet ? listView.dim : Color.foreground)
          }
          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            onClicked: listView.rowClicked(lineItem.index)
          }
        }
      }

      Text {
        objectName: "settingsListEmpty"
        visible: listView.items.length === 0
        width: listColumn.width
        leftPadding: Style.space(12)
        rightPadding: Style.space(12)
        topPadding: Style.space(12)
        wrapMode: Text.Wrap
        text: listView.emptyText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
      }
    }
  }
}
