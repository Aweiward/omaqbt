import QtQuick
import qs.Commons

// One settings row (28 px), lifted verbatim from SettingsPane.qml's inline
// SettingsRow (slice 5b2, Task 3) so the RSS rules' fields draw with the
// same delegate: the label (with its section in a search), the value, a
// muted "after restart" on restart keys, and the muted type tag. Locked
// rows ("OmaqBT") and dimmed dependents are painted dim; other muted
// values (sentinels, "—" while loading) in muted. SettingsPane's own copy
// is an inline component under `pragma ComponentBehavior: Bound`, which
// another file can't instantiate; switching SettingsPane over to this file
// is a one-hunk swap (the objectNames are the same).
Item {
  id: rowItem
  objectName: "settingsRow"
  property var row: ({})
  property bool current: false
  property bool focused: false
  property bool showSection: false
  property bool saving: false
  // Narrow (slice 4b, D6): no type tag or "after restart", and the value
  // keeps its width while the label truncates first.
  property bool compact: false
  signal clicked()
  readonly property color dim: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property int labelWidth: compact
    ? Math.max(Math.round(width * 0.25), Math.min(rowLabel.implicitWidth + Style.space(12) + (showSection ? rowSection.implicitWidth : 0) + Style.space(8),
      width - rowValue.implicitWidth - Style.space(32)))
    : Math.min(Style.space(300), Math.round(width * 0.45))
  readonly property int tagWidth: compact ? 0 : Style.space(78)

  Rectangle {
    visible: rowItem.current
    anchors.fill: parent
    color: Style.selectedAccentFill
  }
  Rectangle {
    visible: rowItem.current && rowItem.focused
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(3)
    color: Color.accent
  }
  Text {
    id: rowLabel
    objectName: "settingsLabel"
    x: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    width: Math.max(0, Math.min(implicitWidth, rowItem.labelWidth - Style.space(12) - (rowItem.showSection ? rowSection.implicitWidth : 0)))
    elide: Text.ElideRight
    text: String(rowItem.row.label || "")
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: rowItem.row.locked ? rowItem.dim : Color.foreground
  }
  Text {
    id: rowSection
    objectName: "settingsSection"
    visible: rowItem.showSection
    anchors.left: rowLabel.right
    anchors.verticalCenter: parent.verticalCenter
    leftPadding: Style.space(6)
    text: "· " + String(rowItem.row.section || "")
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: Color.muted
  }
  Text {
    id: rowValue
    objectName: "settingsValue"
    x: rowItem.labelWidth + Style.space(8)
    anchors.right: rowRestart.visible ? rowRestart.left : (rowTag.visible ? rowTag.left : parent.right)
    anchors.rightMargin: rowTag.visible ? Style.space(8) : Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    elide: Text.ElideRight
    text: rowItem.saving ? "saving…" : String(rowItem.row.text === undefined ? "" : rowItem.row.text)
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: rowItem.saving ? Color.muted : (rowItem.row.locked || rowItem.row.dimmed ? rowItem.dim : (rowItem.row.muted ? Color.muted : Color.foreground))
  }
  Text {
    id: rowRestart
    objectName: "settingsRestart"
    visible: rowItem.row.restart === true && !rowItem.compact
    anchors.right: rowTag.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: "after restart"
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: Color.muted
  }
  Text {
    id: rowTag
    objectName: "settingsTag"
    visible: !rowItem.compact
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    width: rowItem.tagWidth
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    text: String(rowItem.row.typeTag || "")
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: rowItem.row.locked ? rowItem.dim : Color.muted
  }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    onClicked: rowItem.clicked()
  }
}
