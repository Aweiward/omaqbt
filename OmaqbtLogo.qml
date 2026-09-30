import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// Square q. The window does not close; the right wall is the download.
// One color, sharp miters. Recolor tailColor while a transfer is running.
Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color tailColor: color
  property color badgeColor: Color.urgent
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  Item {
    width: 48
    height: 48
    scale: root.iconSize / 48
    transformOrigin: Item.TopLeft

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.color
        strokeColor: "transparent"
        strokeWidth: 0
        PathSvg { path: "M 8 5 H 34 V 37 H 27 V 12 H 15 V 24 H 22 V 31 H 8 Z" }
      }
      ShapePath {
        fillColor: root.tailColor
        strokeColor: "transparent"
        strokeWidth: 0
        PathSvg { path: "M 22.5 34 L 30.5 42 L 38.5 34 Z" }
      }
    }
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.38)
    height: width
    radius: 0
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    borderSpec: Border.flat(Color.popups.background, 1)
    Text {
      anchors.centerIn: parent
      text: "!"
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.72)
      font.bold: true
    }
  }
}
