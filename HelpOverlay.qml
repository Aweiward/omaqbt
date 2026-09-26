pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons

// The `?` overlay: the keys for the current mode and pane, generated from
// CommandRegistry.helpFor through View.helpRows, so it can never drift
// from what dispatch() does. Same frame as the palette in the spec (D7):
// 640 px wide, 90 px from the top, over a scrim of the background. Any
// key closes it (Client.qml handles that); a click on the scrim does too.
Item {
  id: overlay

  // View.helpRows(...): [{group, items: [{keys, title}]}]
  property var groups: []
  property string mode: "NORMAL"
  property string paneName: "table"

  signal dismissed()

  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Qt.darker(Color.background, 1.6), 0.55)
    MouseArea {
      anchors.fill: parent
      onClicked: overlay.dismissed()
    }
  }

  Rectangle {
    id: box
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.min(Style.space(90), Math.round(overlay.height / 6))
    width: Math.min(Style.space(640), overlay.width - Style.space(32))
    height: Math.max(0, Math.min(head.height + flick.contentHeight + foot.height, overlay.height - y - Style.space(24)))
    color: Color.background
    border.width: 1
    border.color: Color.accent

    // Swallow clicks so they don't reach the scrim.
    MouseArea { anchors.fill: parent }

    Item {
      id: head
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Style.space(40)

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: "Keys"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.title
        color: Color.accent
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: overlay.mode + " · " + overlay.paneName
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: overlay.lineColor
      }
    }

    Flickable {
      id: flick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: head.bottom
      anchors.bottom: foot.top
      clip: true
      contentWidth: width
      contentHeight: groupColumn.height + Style.space(10)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: groupColumn
        width: flick.width
        topPadding: Style.space(6)

        Repeater {
          model: overlay.groups
          delegate: Column {
            id: grp
            required property var modelData
            width: groupColumn.width
            topPadding: Style.space(8)

            Text {
              leftPadding: Style.space(14)
              bottomPadding: Style.space(4)
              text: grp.modelData.group
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.caption
              font.capitalization: Font.AllUppercase
              font.letterSpacing: Style.font.caption * 0.12
              color: Color.muted
            }

            Repeater {
              model: grp.modelData.items
              delegate: Item {
                id: row
                required property var modelData
                width: grp.width
                height: Style.space(26)

                Text {
                  id: keyText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(150)
                  elide: Text.ElideRight
                  text: row.modelData.keys
                  textFormat: Text.PlainText
                  font.family: Style.fontFamily
                  font.pixelSize: Style.font.body
                  color: Color.accent
                }

                Text {
                  anchors.left: keyText.right
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: row.modelData.title
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
    }

    Item {
      id: foot
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.space(28)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: overlay.lineColor
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: "Any key closes"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }
  }
}
