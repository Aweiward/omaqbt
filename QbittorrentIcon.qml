import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool warning: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real stroke: Math.max(1.6, iconSize * 0.12)
  readonly property real pad: iconSize * 0.08

  onColorChanged: chevron.requestPaint()
  onStrokeChanged: chevron.requestPaint()

  Rectangle {
    id: ring
    anchors.fill: parent
    anchors.margins: root.pad
    radius: width / 2
    color: "transparent"
    border.color: root.color
    border.width: root.stroke
  }

  Rectangle {
    width: root.stroke
    height: ring.height * 0.34
    radius: width / 2
    color: root.color
    anchors.horizontalCenter: ring.horizontalCenter
    anchors.bottom: ring.verticalCenter
    anchors.bottomMargin: -root.stroke
  }

  Canvas {
    id: chevron
    anchors.fill: ring
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      ctx.strokeStyle = root.color
      ctx.lineWidth = root.stroke
      ctx.lineCap = "round"
      ctx.lineJoin = "round"
      var cx = width / 2
      var y = height * 0.58
      var w = width * 0.28
      ctx.beginPath()
      ctx.moveTo(cx - w, y - w * 0.45)
      ctx.lineTo(cx, y + w * 0.35)
      ctx.lineTo(cx + w, y - w * 0.45)
      ctx.stroke()
    }
    onVisibleChanged: requestPaint()
    Component.onCompleted: requestPaint()
  }

  BorderSurface {
    visible: root.warning
    width: Math.max(7, parent.width * 0.42)
    height: width
    radius: width / 2
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
