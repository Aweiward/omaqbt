pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// A titled, bordered pane. A focused pane gets a 1 px accent outline and
// an accent title; the others a normalBorderAlpha line and a muted title.
Item {
  id: paneItem
  property string title: ""
  property string titleRight: ""
  property bool focusedPane: false
  property bool rightLine: true
  default property alias content: paneBody.data
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  Item {
    id: titleBar
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(30)

    Text {
      id: titleText
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: paneItem.title
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.capitalization: Font.AllUppercase
      font.letterSpacing: Style.font.bodySmall * 0.1
      color: paneItem.focusedPane ? Color.accent : Color.muted
    }

    Text {
      anchors.left: titleText.right
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      text: paneItem.titleRight
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: paneItem.focusedPane ? Color.accent : Color.muted
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: paneItem.lineColor
    }
  }

  Item {
    id: paneBody
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: titleBar.bottom
    anchors.bottom: parent.bottom
  }

  Rectangle {
    visible: paneItem.rightLine
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: 1
    color: paneItem.lineColor
  }

  Rectangle {
    visible: paneItem.focusedPane
    anchors.fill: parent
    color: "transparent"
    border.width: 1
    border.color: Color.accent
  }
}
