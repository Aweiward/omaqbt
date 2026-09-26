pragma Singleton
import QtQuick
QtObject {
  id: s
  property string fontFamily: "monospace"
  property int fontBaseSize: 12
  property real normalBorderAlpha: 0.4
  property color selectedAccentFill: "#33898efa"
  property color selectionFill: "#596a55d6"
  property int cornerRadius: 0
  function space(n) { return Math.round(n) }
  function selectionFillFor(a, b) { return "#59000000" }
  function controlFill(a, b, c, d) { return "transparent" }
  property QtObject spacing: QtObject { property int popupRowHeight: 28; property int controlPaddingX: 10; property int inputPaddingY: 7 }
  property QtObject font: QtObject { property string family: "monospace"; property int caption: 10; property int bodySmall: 11; property int body: 12; property int subtitle: 13; property int title: 14; property int heading: 16 }
}
