pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "ClientView.js" as View

// The shell shared by the `:` command palette and a slice 3a PICKER
// overlay (category `C`, tag `T`): a 640 px box 90 px from the top over a
// scrim of the background at 55%, a text field the owner drives (typing
// filters; some keys are handed back to the window's dispatch instead),
// a scrollable, fuzzy-match-highlighted row list with a cursor, and a
// footer hint line.
//
// Presentation only: this component never computes rows or reacts to its
// own query. The owner (CommandPalette today; a picker in Tasks 5/6)
// supplies `rows` and recomputes them (typically on `onQueryChanged`).
// A row is {kind, title, indices, enabled, reason, keys, prefix}:
// kind "divider" draws a plain separator line; anything else is a real,
// selectable row. `title`/`indices` drive the fuzzy-match highlighting
// (View.paletteSegments); `enabled === false` dims the row and shows
// `reason`; `keys` is the right-aligned shortcut hint; `prefix` is a
// plain-text marker before the title (e.g. "[x]"/"[~]"/"[ ]" for a
// multi-select picker's rows).
//
// keyMode picks which keys the field hands back through keyForwarded
// instead of typing (View.overlayOwnsKey): "COMMAND" (default, the
// palette) or "PICKER" (a category/tag picker), where Space is a toggle
// candidate only with an empty query and Tab only when `multi` is set --
// see CommandRegistry.js's PICKER mode, which makes the same distinction
// (the two must never disagree about which keys the field gives up).
Item {
  id: overlay

  // ---- config the owner sets --------------------------------------------
  property string keyMode: "COMMAND"
  property string prompt: ":"
  property string placeholder: ""
  // Whether this instance is a multi-select list. ListOverlay itself does
  // not branch on it (a picker's Space/Tab gating lives in dispatch, not
  // here); the owner reads it back when building dispatch's `pickerMulti`
  // state flag, and may use it to choose its own placeholder/footer text.
  property bool multi: false
  property string counterText: ""
  property string emptyText: ""
  property string footerHint: ""
  property var rows: []

  // ---- state the owner reads and drives ----------------------------------
  property string query: ""
  property int cursor: -1

  // A key the window resolves (View.overlayOwnsKey).
  signal keyForwarded(var event)
  // A row was clicked.
  signal activated(var row)
  // The scrim was clicked.
  signal dismissed()

  // The query field (WmFocus hands the keys back to it).
  readonly property var inputField: field
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  function focusField() {
    field.forceActiveFocus()
  }

  // Tests (and Tab-complete) drive the query the way typing would.
  function setQuery(text) {
    field.text = String(text || "")
  }

  function currentRow() {
    return cursor >= 0 && cursor < rows.length ? rows[cursor] : null
  }

  function move(delta) {
    cursor = View.paletteMove(rows, cursor, delta)
    if (cursor >= 0) list.positionViewAtIndex(cursor, ListView.Contain)
  }

  onCursorChanged: if (cursor >= 0) list.positionViewAtIndex(cursor, ListView.Contain)

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.55)
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
    height: head.height + body.height + foot.height
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
        id: promptText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: overlay.prompt
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.title
        color: Color.accent
      }

      TextField {
        id: field
        anchors.left: promptText.right
        anchors.leftMargin: Style.space(4)
        anchors.right: countText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        verticalPadding: Style.space(2)
        font.pixelSize: Style.font.title
        placeholderText: overlay.placeholder
        onTextChanged: overlay.query = String(field.text || "")

        Keys.onPressed: function(event) {
          var ev = View.keyEvent(event.key, event.text, event.modifiers, 0)
          if (!View.overlayOwnsKey(overlay.keyMode, ev, field.text.length === 0)) return
          overlay.keyForwarded(event)
          event.accepted = true
        }
      }

      Text {
        id: countText
        visible: overlay.counterText !== ""
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: overlay.counterText
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

    Item {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: head.bottom
      height: overlay.rows.length === 0 ? Style.space(30)
        : Math.max(0, Math.min(list.contentHeight, overlay.height - box.y - head.height - foot.height - Style.space(24)))

      Text {
        visible: overlay.rows.length === 0
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: overlay.emptyText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.subtitle
        color: Color.muted
      }

      ListView {
        id: list
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: overlay.rows

        delegate: Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool isRow: modelData.kind !== "divider"
          readonly property bool isCursor: index === overlay.cursor
          readonly property bool dim: isRow && modelData.enabled === false
          width: list.width
          height: isRow ? Style.space(30) : Style.space(9)

          Rectangle {
            visible: !row.isRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: overlay.lineColor
          }

          Rectangle {
            anchors.fill: parent
            visible: row.isCursor
            color: Style.selectedAccentFill
          }

          Rectangle {
            visible: row.isCursor
            width: 3
            height: parent.height
            color: Color.accent
          }

          Row {
            visible: row.isRow
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.right: keys.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            clip: true

            Text {
              visible: !!row.modelData.prefix
              // A trailing space (not Row spacing) separates the marker
              // from the title without opening a gap between the fuzzy-
              // match segments below, which must stay flush.
              text: row.modelData.prefix ? (row.modelData.prefix + " ") : ""
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.subtitle
              color: row.dim ? Util.alpha(Color.foreground, 0.4) : Color.foreground
            }

            Repeater {
              model: row.isRow ? View.paletteSegments(row.modelData.title, row.modelData.indices) : []
              delegate: Text {
                required property var modelData
                text: modelData.text
                textFormat: Text.PlainText
                font.family: Style.fontFamily
                font.pixelSize: Style.font.subtitle
                font.underline: modelData.matched
                color: modelData.matched ? Color.accent
                  : (row.dim ? Util.alpha(Color.foreground, 0.4) : Color.foreground)
              }
            }

            Text {
              visible: row.dim
              text: "  · " + row.modelData.reason
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Util.alpha(Color.muted, 0.7)
            }
          }

          Text {
            id: keys
            visible: row.isRow && !!row.modelData.keys
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.keys || ""
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: row.dim ? Util.alpha(Color.muted, 0.7) : Color.muted
          }

          MouseArea {
            anchors.fill: parent
            enabled: row.isRow
            onClicked: {
              overlay.cursor = row.index
              overlay.activated(row.modelData)
            }
          }
        }
      }
    }

    Item {
      id: foot
      visible: overlay.footerHint !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: body.bottom
      height: overlay.footerHint !== "" ? Style.space(28) : 0

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
        text: overlay.footerHint
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }
  }
}
