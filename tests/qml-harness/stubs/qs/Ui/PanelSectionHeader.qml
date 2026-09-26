import QtQuick
Text {
  property color foreground: "white"
  property string fontFamily: "monospace"
  property real fontSize: 10
  textFormat: Text.PlainText
  font.pixelSize: fontSize
  font.bold: true
}
