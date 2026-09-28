pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The Info tab: the cursor row's full name (wrapped), PiecesBar or the
// no-metadata line, the slice-1 field block, the Transfer/Limits/Torrent groups
// (with the Comment 3-line cap) and the pinned action-keys footer sized to
// its wrapped keys. Extracted out of InspectorPane.qml (slice 2b, Task 1:
// pure refactor, no behaviour change).
Item {
  id: root

  // View.inspectorInfo(...), or null when there is no cursor row.
  property var info: null
  // InspectorView.infoView(...)'s pieces bar and Transfer/Torrent groups.
  property var pieces: []
  property string piecesLegend: ""
  property bool noMeta: false
  // The raw cursor row (Client.cursorRow), for the no-metadata keys.
  property var row: null
  // M2: true for a fresh Info-tab error -- see InspectorPane.qml's own
  // `infoErrored` property doc.
  property bool infoErrored: false
  // Transfer, Limits (slice 3b, InspectorView.withLimits) and Torrent. A
  // Limits field carries `cursor` on the row under the Limits cursor.
  property var groups: []
  // LimitsView.footerKeys for that row, ahead of the tab's own keys.
  property var limitKeys: []
  property int padX: 0
  property color lineColor: "transparent"

  function toneColor(tone) {
    return View.toneColor(tone, Color)
  }

  Flickable {
    id: infoFlick
    objectName: "infoFlick"
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: infoFoot.top
    clip: true
    contentWidth: width
    contentHeight: infoColumn.height + Style.space(14)
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: infoColumn
      width: infoFlick.width
      topPadding: Style.space(14)
      spacing: Style.space(14)

      Text {
        x: root.padX
        width: infoColumn.width - 2 * root.padX
        text: root.info ? root.info.name : ""
        textFormat: Text.PlainText
        wrapMode: Text.WrapAnywhere
        lineHeight: 1.2
        font.family: Style.fontFamily
        font.pixelSize: Style.font.title
        color: Color.foreground
      }

      // Hidden with no cells too: while the sidecar is down, or before
      // the first info reply arrives, InspectorView.infoView hands back
      // [] rather than a bar of all-missing glyphs and a "0 of 0" legend.
      PiecesBar {
        visible: !root.noMeta && root.pieces.length > 0
        x: root.padX
        width: infoColumn.width - 2 * root.padX
        cells: root.pieces
        legend: root.piecesLegend
      }

      Text {
        visible: root.noMeta && !root.infoErrored
        x: root.padX
        width: infoColumn.width - 2 * root.padX
        text: "no metadata yet · pieces and files appear once it's fetched"
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }

      Column {
        x: root.padX
        width: infoColumn.width - 2 * root.padX
        spacing: Style.space(10)

        Repeater {
          model: root.info ? root.info.fields : []
          delegate: Row {
            id: field
            required property var modelData
            width: parent.width
            Text {
              width: Style.space(96)
              text: field.modelData.label
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: Color.muted
            }
            Text {
              width: field.width - Style.space(96)
              text: field.modelData.value
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: root.toneColor(field.modelData.tone)
            }
          }
        }
      }

      Repeater {
        model: root.groups
        delegate: Column {
          id: group
          required property var modelData
          x: root.padX
          width: infoColumn.width - 2 * root.padX
          spacing: Style.space(8)

          Text {
            text: group.modelData.title
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.caption
            font.capitalization: Font.AllUppercase
            font.bold: false
            font.letterSpacing: Style.font.caption * 0.12
            color: Color.muted
          }

          Column {
            width: group.width
            spacing: Style.space(10)

            Repeater {
              model: group.modelData.fields
              // The value wraps (Comment is untrusted, arbitrary-length
              // qBittorrent text); the note (Downloaded's short "· N
              // this session" suffix, the only field that carries one)
              // sits after it in its own muted tone, so the value's
              // width leaves room for it instead of always wrapping.
              delegate: Item {
                id: gfield
                required property var modelData
                width: group.width
                height: gfieldRow.height

                // The Limits cursor: InspectorList's fill and accent bar,
                // pane-wide.
                Rectangle {
                  objectName: "limitCursor"
                  visible: gfield.modelData.cursor === true
                  x: -root.padX
                  y: -Style.space(4)
                  width: infoColumn.width
                  height: gfield.height + Style.space(8)
                  color: Style.selectedAccentFill
                  Rectangle {
                    width: Style.space(3)
                    height: parent.height
                    color: Color.accent
                  }
                }

                Row {
                  id: gfieldRow
                  width: gfield.width
                  Text {
                    width: Style.space(96)
                    text: gfield.modelData.label
                    textFormat: Text.PlainText
                    font.family: Style.fontFamily
                    font.pixelSize: Style.font.body
                    color: Color.muted
                  }
                  Text {
                    id: gvalue
                    objectName: "groupValue_" + gfield.modelData.label
                    width: gfield.width - Style.space(96) - (gnote.visible ? gnote.implicitWidth : 0)
                    text: gfield.modelData.value
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    // Comment is the one field the spec caps: at most 3
                    // lines, then "…" (a save path or a long hash still
                    // wraps in full).
                    maximumLineCount: gfield.modelData.label === "Comment" ? 3 : 0
                    elide: gfield.modelData.label === "Comment" ? Text.ElideRight : Text.ElideNone
                    font.family: Style.fontFamily
                    font.pixelSize: Style.font.body
                    color: root.toneColor(gfield.modelData.tone)
                  }
                  Text {
                    id: gnote
                    visible: !!gfield.modelData.note
                    text: " " + gfield.modelData.note
                    textFormat: Text.PlainText
                    font.family: Style.fontFamily
                    font.pixelSize: Style.font.body
                    color: Color.muted
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  Item {
    id: infoFoot
    objectName: "infoActionsFooter"
    // Sized to the key Flow's content, not a fixed height: at the real
    // pane width the four keys wrap to two lines, and a fixed height
    // used to clip the second line under the divider.
    readonly property int vPad: Style.space(7)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: keyFlow.implicitHeight + 2 * vPad
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: root.lineColor
    }
    Flow {
      id: keyFlow
      objectName: "infoKeyFlow"
      anchors.left: parent.left
      anchors.leftMargin: root.padX
      anchors.right: parent.right
      anchors.rightMargin: root.padX
      anchors.top: parent.top
      anchors.topMargin: infoFoot.vPad
      spacing: Style.space(14)
      Repeater {
        // No metadata: the pinned keys become Space and f (the states
        // table). The Limits cursor's keys come first, and claim Space on
        // a toggle row (Ruling CJ).
        model: !root.info ? [] : InspectorView.infoFooterKeys(root.limitKeys,
          root.noMeta ? InspectorView.emptyCopy("info", root.row).keys : root.info.keys)
        delegate: Row {
          id: act
          required property var modelData
          spacing: Style.space(6)
          Text {
            text: act.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.foreground
          }
          Text {
            text: act.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.muted
          }
        }
      }
    }
  }
}
