pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "InspectorView.js" as InspectorView

// The Files tab: the cursor row's files with their priority; Space (or a
// click) cycles it, the same cycle as the widget. A no-metadata torrent's
// empty files list gets its own explanation (emptyCopy) instead of the
// plain "No files.": qBittorrent has nothing to list until the magnet
// resolves. Names, paths and categories are untrusted: plain text only.
// Extracted out of InspectorPane.qml (slice 2b, Task 1: pure refactor, no
// behaviour change).
Item {
  id: root

  // View.filesView(...): {state: "loading"|"error"|"empty"|"rows", rows}.
  property var files: ({ state: "loading", rows: [] })
  property int fileIndex: 0
  property bool focusedPane: false
  property bool noMeta: false
  // The raw cursor row (Client.cursorRow), for InspectorView.emptyCopy's
  // row argument.
  property var row: null
  property int padX: 0

  signal fileClicked(int index)

  function positionAt(index) {
    fileList.positionAt(index)
  }

  // Files' InspectorList columns: name is flexible and elides (dims when
  // the file is skipped), progress stays muted, priority is a fixed 52px
  // right-aligned column that mutes when skipped too (today's look).
  readonly property var filesColumns: [
    { role: "name", width: 0, tone: function(r) { return r.skipped ? "dim" : "fg" } },
    { role: "progressText", width: Style.space(64), align: "right", tone: "muted" },
    { role: "priorityText", width: Style.space(52), align: "right", tone: function(r) { return r.skipped ? "muted" : "fg" } }
  ]

  Text {
    visible: root.files.state !== "rows" && !(root.files.state === "empty" && root.noMeta)
    anchors.left: parent.left
    anchors.leftMargin: root.padX
    anchors.top: parent.top
    anchors.topMargin: Style.space(14)
    text: {
      if (root.files.state === "error") return "Couldn't read files"
      if (root.files.state === "empty") return "No files."
      return "Loading files…"
    }
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: root.files.state === "error" ? Color.urgent : Color.muted
  }

  Column {
    id: filesNoMetaCopy
    visible: root.files.state === "empty" && root.noMeta
    readonly property var copy: InspectorView.emptyCopy("files", root.row)
    anchors.left: parent.left
    anchors.leftMargin: root.padX
    anchors.right: parent.right
    anchors.rightMargin: root.padX
    anchors.top: parent.top
    anchors.topMargin: Style.space(14)
    spacing: Style.space(6)
    Text {
      width: parent.width
      text: filesNoMetaCopy.copy.title
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.foreground
    }
    Text {
      width: parent.width
      text: filesNoMetaCopy.copy.body
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      color: Color.muted
    }
    Flow {
      width: parent.width
      spacing: Style.space(14)
      Repeater {
        model: filesNoMetaCopy.copy.keys
        delegate: Row {
          id: noMetaKey
          required property var modelData
          spacing: Style.space(6)
          Text {
            text: noMetaKey.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.foreground
          }
          Text {
            text: noMetaKey.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.body
            color: Color.muted
          }
        }
      }
    }
  }

  InspectorList {
    id: fileList
    visible: root.files.state === "rows"
    anchors.fill: parent
    anchors.topMargin: Style.space(6)
    rows: root.files.rows
    columns: root.filesColumns
    cursor: root.fileIndex
    focusedPane: root.focusedPane
    // Old layout's widest gap (progress-to-priority, 10px); the column
    // model has one spacing for the whole row, so this is as close as
    // it gets without a per-gap concept (name-to-progress goes from
    // 8px to 10px too).
    cellSpacing: Style.space(10)
    onRowClicked: function(index) { root.fileClicked(index) }
  }
}
