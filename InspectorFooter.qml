import QtQuick
import qs.Commons

// The key hints pinned at the bottom of a list tab. Extracted out of
// InspectorPane.qml (slice 2b, Task 1: pure refactor, no behaviour
// change).
Item {
  id: foot
  property string text: ""
  anchors.left: parent.left
  anchors.right: parent.right
  anchors.bottom: parent.bottom
  height: Style.space(28)
  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  }
  Text {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    text: foot.text
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: Color.muted
  }
}
