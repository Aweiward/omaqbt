pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "CommandRegistry.js" as Registry
import "ClientView.js" as View

// The `:` command palette (spec D7): a 640 px box 90 px from the top over
// a scrim of the background at 55%, a `:` prompt with an "N of M" count,
// 30 px rows with the fuzzy-matched characters in accent and underlined,
// each command's keys right-aligned in muted, and disabled rows dimmed
// with their reason. The rows come from View.paletteRows, evaluated as the
// table pane would (evalState).
//
// The text field owns typing. The keys COMMAND mode resolves (Esc, Enter,
// Up/Down, Ctrl-n/Ctrl-p, Tab) go back to the window through keyForwarded,
// so they run through CommandRegistry.dispatch like every other key;
// ClientCommands then calls open/move/complete/currentRow here.
Item {
  id: pal

  // The recently used command ids (Client.paletteMru).
  property var mru: []
  // View.paletteState(...): the state rows are enabled or disabled by.
  property var evalState: ({})

  property string query: ""
  property var rows: []
  property int cursor: -1
  readonly property int matchCount: View.paletteCommandCount(rows)
  readonly property int totalCount: View.paletteCommandCount(View.paletteRows("", Registry.commands, [], evalState))

  // A key the window resolves (see View.paletteOwnsKey).
  signal keyForwarded(var event)
  // A row was clicked.
  signal activated(var row)
  // The scrim was clicked.
  signal dismissed()

  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  // Starts empty, with the cursor on the first row, and takes the keys.
  function open() {
    field.text = ""
    query = ""
    refresh(false)
    focusField()
  }

  function focusField() {
    field.forceActiveFocus()
  }

  // Tests drive the query the way typing would.
  function setQuery(text) {
    field.text = String(text || "")
  }

  function currentRow() {
    return cursor >= 0 && cursor < rows.length ? rows[cursor] : null
  }

  function move(delta) {
    cursor = View.paletteMove(rows, cursor, delta)
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  // Tab: the query becomes the cursor row's title.
  function complete() {
    var row = currentRow()
    if (!row || row.kind !== "command") return
    setQuery(row.title)
    field.cursorPosition = String(field.text).length
  }

  // keep: the rows changed under the cursor (a tick, the MRU), so it stays
  // on its command if it can; a new query starts from the top.
  function refresh(keep) {
    var row = keep ? currentRow() : null
    var next = View.paletteRows(query, Registry.commands, mru, evalState)
    rows = next
    cursor = row ? View.paletteCursorFor(next, row.id) : View.paletteFirst(next)
    if (cursor >= 0) list.positionViewAtIndex(cursor, ListView.Contain)
  }

  onQueryChanged: refresh(false)
  onEvalStateChanged: refresh(true)
  onMruChanged: refresh(true)

  Rectangle {
    anchors.fill: parent
    color: Util.alpha(Color.background, 0.55)
    MouseArea {
      anchors.fill: parent
      onClicked: pal.dismissed()
    }
  }

  Rectangle {
    id: box
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.min(Style.space(90), Math.round(pal.height / 6))
    width: Math.min(Style.space(640), pal.width - Style.space(32))
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
        id: prompt
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: ":"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.title
        color: Color.accent
      }

      TextField {
        id: field
        anchors.left: prompt.right
        anchors.leftMargin: Style.space(4)
        anchors.right: countText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        verticalPadding: Style.space(2)
        font.pixelSize: Style.font.title
        onTextChanged: pal.query = String(field.text || "")

        Keys.onPressed: function(event) {
          if (!View.paletteOwnsKey(View.keyEvent(event.key, event.text, event.modifiers, 0))) return
          pal.keyForwarded(event)
          event.accepted = true
        }
      }

      Text {
        id: countText
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: pal.matchCount + " of " + pal.totalCount
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
        color: pal.lineColor
      }
    }

    Item {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: head.bottom
      height: pal.rows.length === 0 ? Style.space(30)
        : Math.max(0, Math.min(list.contentHeight, pal.height - box.y - head.height - foot.height - Style.space(24)))

      Text {
        visible: pal.rows.length === 0
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: View.paletteEmptyText(pal.query)
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
        model: pal.rows

        delegate: Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool isCommand: modelData.kind === "command"
          readonly property bool isCursor: index === pal.cursor
          readonly property bool dim: isCommand && !modelData.enabled
          width: list.width
          height: isCommand ? Style.space(30) : Style.space(9)

          Rectangle {
            visible: !row.isCommand
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: pal.lineColor
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
            visible: row.isCommand
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.right: keys.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            clip: true

            Repeater {
              model: row.isCommand ? View.paletteSegments(row.modelData.title, row.modelData.indices) : []
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
            visible: row.isCommand
            anchors.right: parent.right
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.keys
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: row.dim ? Util.alpha(Color.muted, 0.7) : Color.muted
          }

          MouseArea {
            anchors.fill: parent
            enabled: row.isCommand
            onClicked: {
              pal.cursor = row.index
              pal.activated(row.modelData)
            }
          }
        }
      }
    }

    Item {
      id: foot
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: body.bottom
      height: Style.space(28)

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: pal.lineColor
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.verticalCenter: parent.verticalCenter
        text: "↑↓ / Ctrl-n Ctrl-p move · Enter run · Tab complete · Esc close"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }
  }
}
