pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View

// The inspector pane body. Slice 1 ships tab 1 (Info) and tab 4 (Files);
// 2, 3 and 5 are reserved for trackers, peers and chart (slice 2).
//
// Info: the cursor row's full name (wrapped), label/value pairs
// (View.inspectorInfo) and the action keys. Files: the cursor row's files
// with their priority; Space (or a click) cycles it, the same cycle as the
// widget. Names, paths and categories are untrusted: plain text only.
Item {
  id: pane

  property string tab: "info"
  // View.inspectorInfo(...), or null when there is no cursor row.
  property var info: null
  // View.filesView(...): {state: "loading"|"error"|"empty"|"rows", rows}.
  property var files: ({ state: "loading", rows: [] })
  property int fileIndex: 0
  property bool focusedPane: false

  signal tabClicked(string tab)
  signal fileClicked(int index)

  readonly property int padX: Style.space(12)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  function toneColor(tone) {
    return View.toneColor(tone, Color)
  }

  function positionFile(index) {
    fileList.positionAt(index)
  }

  // Files' InspectorList columns: name is flexible and elides (dims when
  // the file is skipped), progress stays muted, priority is a fixed 52px
  // right-aligned column that mutes when skipped too (today's look).
  readonly property var filesColumns: [
    { role: "name", width: 0, tone: function(r) { return r.skipped ? "dim" : "fg" } },
    { role: "progressText", width: Style.space(64), tone: "muted" },
    { role: "priorityText", width: Style.space(52), align: "right", tone: function(r) { return r.skipped ? "muted" : "fg" } }
  ]

  // ---- tabs ------------------------------------------------------------
  Item {
    id: tabs
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: Style.space(30)

    Row {
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      spacing: Style.space(14)

      Repeater {
        model: [{ digit: "1", tab: "info" }, { digit: "4", tab: "files" }]
        delegate: Item {
          id: tabItem
          required property var modelData
          readonly property bool on: pane.tab === modelData.tab
          width: tabRow.implicitWidth
          height: tabs.height

          Row {
            id: tabRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            Text {
              text: tabItem.modelData.digit
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: Color.muted
            }
            Text {
              text: tabItem.modelData.tab
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: tabItem.on ? Color.foreground : Color.muted
            }
          }

          Rectangle {
            visible: tabItem.on
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(2)
            color: Color.accent
          }

          MouseArea {
            anchors.fill: parent
            onClicked: pane.tabClicked(tabItem.modelData.tab)
          }
        }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: pane.lineColor
    }
  }

  Item {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: tabs.bottom
    anchors.bottom: parent.bottom

    // No cursor row (or a blocking state): the same line on both tabs.
    Text {
      visible: pane.info === null
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.top: parent.top
      anchors.topMargin: Style.space(14)
      text: "Select a torrent"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }

    // ---- 1 info --------------------------------------------------------
    Flickable {
      id: infoFlick
      visible: pane.info !== null && pane.tab === "info"
      anchors.fill: parent
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
          x: pane.padX
          width: infoColumn.width - 2 * pane.padX
          text: pane.info ? pane.info.name : ""
          textFormat: Text.PlainText
          wrapMode: Text.WrapAnywhere
          lineHeight: 1.2
          font.family: Style.fontFamily
          font.pixelSize: Style.font.title
          color: Color.foreground
        }

        Column {
          x: pane.padX
          width: infoColumn.width - 2 * pane.padX
          spacing: Style.space(10)

          Repeater {
            model: pane.info ? pane.info.fields : []
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
                color: pane.toneColor(field.modelData.tone)
              }
            }
          }
        }

        Flow {
          x: pane.padX
          width: infoColumn.width - 2 * pane.padX
          spacing: Style.space(14)
          Repeater {
            model: pane.info ? pane.info.keys : []
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

    // ---- 4 files -------------------------------------------------------
    Text {
      visible: pane.info !== null && pane.tab === "files" && pane.files.state !== "rows"
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.top: parent.top
      anchors.topMargin: Style.space(14)
      text: {
        if (pane.files.state === "error") return "Couldn't read files"
        if (pane.files.state === "empty") return "No files."
        return "Loading files…"
      }
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: pane.files.state === "error" ? Color.urgent : Color.muted
    }

    InspectorList {
      id: fileList
      visible: pane.info !== null && pane.tab === "files" && pane.files.state === "rows"
      anchors.fill: parent
      anchors.topMargin: Style.space(6)
      rows: pane.files.rows
      columns: pane.filesColumns
      cursor: pane.fileIndex
      focusedPane: pane.focusedPane
      onRowClicked: function(index) { pane.fileClicked(index) }
    }
  }
}
