pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import "ClientView.js" as View
import "InspectorView.js" as InspectorView

// The inspector pane body: tab 1 (Info), 2 (Trackers), 3 (Peers), 4
// (Files) and 5 (Chart, Task 8).
//
// Trackers and peers: InspectorView.listTab(...) from Client, drawn as a
// state line (loading, error, sidecar down, empty) or an InspectorList
// with the cursor row's detail under it. Tracker rows show host:port
// only; the detail shows the URL redacted (never its path or query), so
// a passkey is never on screen. Tracker messages, peer clients,
// countries and flags come from qBittorrent: plain text only.
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
  // The raw cursor row (Client.cursorRow), for InspectorView.emptyCopy's
  // row argument -- distinct from `info`, which is already the rendered
  // Info tab, not row-shaped.
  property var row: null
  // InspectorView.infoView(...)'s pieces bar and Transfer/Torrent groups.
  property var pieces: []
  property string piecesLegend: ""
  property bool noMeta: false
  // M2: true for a fresh Info-tab error. `noMeta` keeps its usual
  // row-size meaning (State's "waiting for metadata" and Files' "No file
  // list yet" copy must survive an unrelated info-read failure); this
  // instead gates only the Info tab's own "no metadata yet" line, so a
  // transient error blanks the pieces area without a stale line.
  property bool infoErrored: false
  property var groups: []
  // View.filesView(...): {state: "loading"|"error"|"empty"|"rows", rows}.
  property var files: ({ state: "loading", rows: [] })
  property int fileIndex: 0
  // InspectorView.listTab(...): {state, rows, summary, title, copy}.
  property var trackers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  property var peers: ({ state: "blank", rows: [], summary: {}, title: "", copy: {} })
  // InspectorView.chartTab(...): {state, series, error}.
  property var chart: ({
    state: "blank",
    series: { down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—", nowDlText: "—", nowUlText: "—", empty: true },
    error: ""
  })
  property int trackerIndex: 0
  property int peerIndex: 0
  property bool focusedPane: false
  // The pane title's right side: "8 trackers", "17 peers · 14 seeds".
  readonly property string titleRight: info === null ? ""
    : (tab === "trackers" ? trackers.title : (tab === "peers" ? peers.title : ""))

  readonly property string summaryJson: JSON.stringify(InspectorView.trackerSummaryParts(trackers.summary))

  signal tabClicked(string tab)
  signal fileClicked(int index)
  signal listRowClicked(string tab, int index)

  readonly property int padX: Style.space(12)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  function toneColor(tone) {
    return View.toneColor(tone, Color)
  }

  function positionFile(index) {
    fileList.positionAt(index)
  }

  function positionRow(tab, index) {
    (tab === "trackers" ? trackerList : peerList).positionAt(index)
  }

  readonly property var trackerColumns: [
    { role: "glyph", label: "", width: Style.space(14), tone: function(r) { return r.tone } },
    { role: "host", label: "Tracker", width: 0, tone: "fg" },
    { role: "seeds", label: "Seeds", width: Style.space(44), align: "right", tone: function(r) { return r.seeds === "—" ? "muted" : "fg" } },
    { role: "peers", label: "Peers", width: Style.space(44), align: "right", tone: function(r) { return r.peers === "—" ? "muted" : "fg" } }
  ]
  readonly property var peerColumns: [
    { role: "country", label: "", width: Style.space(22), tone: "muted" },
    { role: "client", label: "Client", width: 0, tone: "fg" },
    { role: "has", label: "Has", width: Style.space(44), align: "right", tone: "fg" },
    { role: "downText", label: "↓", width: Style.space(62), align: "right", tone: "fg" },
    { role: "upText", label: "↑", width: Style.space(62), align: "right", tone: "fg" }
  ]

  // One line of the cursor row's detail block (muted unless `tone`).
  component DetailText: Text {
    property string tone: "muted"
    textFormat: Text.PlainText
    elide: Text.ElideRight
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: View.toneColor(tone, Color)
  }

  // A tab's non-row state: nothing (blank), "Loading…", the read error
  // (its cause, then "Retrying every 5 s."), "Needs qbt-serve", or the
  // empty copy. Inline components can't see
  // this file's ids, so everything comes in as properties.
  component TabMessage: Item {
    id: msg
    property string tabState: "blank"
    property string noun: ""
    property var copy: ({})
    // The read error's (sanitized) text, for the "error" state.
    property string error: ""
    readonly property bool big: tabState === "error" || tabState === "empty"

    Column {
      visible: msg.tabState !== "blank" && msg.tabState !== "rows"
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(28)
      anchors.rightMargin: Style.space(28)
      spacing: Style.space(10)

      Text {
        width: parent.width
        horizontalAlignment: msg.big ? Text.AlignLeft : Text.AlignHCenter
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: msg.big ? Style.font.title : Style.font.body
        color: msg.tabState === "error" ? Color.urgent : (msg.tabState === "empty" ? Color.foreground : Color.muted)
        text: {
          if (msg.tabState === "loading") return "Loading " + msg.noun + "…"
          if (msg.tabState === "error") return "Couldn't read " + msg.noun
          if (msg.tabState === "sidecarDown") return "Needs qbt-serve (slow polling)"
          if (msg.tabState === "empty") return msg.copy.title || ""
          return ""
        }
      }
      Text {
        visible: msg.big
        width: parent.width
        wrapMode: Text.WordWrap
        lineHeight: 1.3
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
        text: msg.tabState === "error" ? msg.error : (msg.copy.body || "")
      }
      Text {
        visible: msg.tabState === "error"
        width: parent.width
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
        text: "Retrying every 5 s."
      }
    }
  }

  // The key hints pinned at the bottom of a list tab.
  component Footer: Item {
    id: foot
    property string text: ""
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Style.space(28)
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
    }
    Text {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: foot.text
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
  }

  Component {
    id: trackerDetailComp
    Column {
      id: td
      property var row: null
      readonly property var d: InspectorView.trackerDetail(row)
      readonly property int textWidth: Math.max(0, width - leftPadding - rightPadding)
      leftPadding: Style.space(29)
      rightPadding: Style.space(12)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(2)
      Row {
        DetailText { id: statusWord; text: td.d.status.text; tone: td.d.status.tone }
        DetailText {
          visible: td.d.message !== ""
          width: Math.max(0, td.textWidth - statusWord.width)
          text: " · " + td.d.message
        }
      }
      DetailText { width: td.textWidth; elide: Text.ElideMiddle; text: td.d.url }
      DetailText { width: td.textWidth; text: td.d.tier }
    }
  }

  Component {
    id: peerDetailComp
    Column {
      id: pd
      property var row: null
      readonly property var d: InspectorView.peerDetail(row)
      readonly property int textWidth: Math.max(0, width - leftPadding - rightPadding)
      leftPadding: Style.space(29)
      rightPadding: Style.space(12)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(2)
      Row {
        DetailText { id: ipText; text: pd.d.ip; tone: "fg" }
        DetailText { width: Math.max(0, pd.textWidth - ipText.width); text: pd.d.rest }
      }
      Row {
        DetailText { id: flagsLead; text: "flags " }
        DetailText { id: flagsText; text: pd.d.flags; tone: "fg" }
        DetailText {
          width: Math.max(0, pd.textWidth - flagsLead.width - flagsText.width)
          text: " · " + pd.d.flagsDesc
        }
      }
    }
  }

  // Files' InspectorList columns: name is flexible and elides (dims when
  // the file is skipped), progress stays muted, priority is a fixed 52px
  // right-aligned column that mutes when skipped too (today's look).
  readonly property var filesColumns: [
    { role: "name", width: 0, tone: function(r) { return r.skipped ? "dim" : "fg" } },
    { role: "progressText", width: Style.space(64), align: "right", tone: "muted" },
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
        model: [{ digit: "1", tab: "info" }, { digit: "2", tab: "trackers" }, { digit: "3", tab: "peers" },
          { digit: "4", tab: "files" }, { digit: "5", tab: "chart" }]
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
    // The action keys are pinned outside the Flickable (infoFoot), so
    // scrolling the name/fields/groups to the bottom never carries them
    // off screen.
    Item {
      id: infoBody
      visible: pane.info !== null && pane.tab === "info"
      anchors.fill: parent

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

          // Hidden with no cells too: while the sidecar is down, or before
          // the first info reply arrives, InspectorView.infoView hands back
          // [] rather than a bar of all-missing glyphs and a "0 of 0" legend.
          PiecesBar {
            visible: !pane.noMeta && pane.pieces.length > 0
            x: pane.padX
            width: infoColumn.width - 2 * pane.padX
            cells: pane.pieces
            legend: pane.piecesLegend
          }

          Text {
            visible: pane.noMeta && !pane.infoErrored
            x: pane.padX
            width: infoColumn.width - 2 * pane.padX
            text: "no metadata yet · pieces and files appear once it's fetched"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.muted
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

          Repeater {
            model: pane.groups
            delegate: Column {
              id: group
              required property var modelData
              x: pane.padX
              width: infoColumn.width - 2 * pane.padX
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
                  delegate: Row {
                    id: gfield
                    required property var modelData
                    width: group.width
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
                      color: pane.toneColor(gfield.modelData.tone)
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

      Item {
        id: infoFoot
        objectName: "infoActionsFooter"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(28)
        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: 1
          color: pane.lineColor
        }
        Flow {
          anchors.left: parent.left
          anchors.leftMargin: pane.padX
          anchors.right: parent.right
          anchors.rightMargin: pane.padX
          anchors.verticalCenter: parent.verticalCenter
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

    // ---- 2 trackers ----------------------------------------------------
    Item {
      visible: pane.info !== null && pane.tab === "trackers"
      anchors.fill: parent

      // M3: the summary line ("DHT on · PeX on · LSD on · N seeds · N
      // peers") still shows with no real trackers -- it's the only place
      // DHT/PeX/LSD state is visible, and "No trackers" alone would hide
      // it. The empty-state message is anchored below it instead of
      // centered over the whole tab, so the two never overlap.
      TabMessage {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: pane.trackers.state === "empty" ? summaryLine.bottom : parent.top
        anchors.bottom: parent.bottom
        tabState: pane.trackers.state
        error: pane.trackers.error || ""
        noun: "trackers"
        copy: pane.trackers.copy
      }

      Item {
        id: summaryLine
        visible: pane.trackers.state === "rows" || pane.trackers.state === "empty"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.space(30)
        Row {
          anchors.left: parent.left
          anchors.leftMargin: pane.padX
          anchors.verticalCenter: parent.verticalCenter
          Repeater {
            // Through a string, which only notifies when the text changes,
            // so the per-second refresh doesn't rebuild these delegates.
            model: JSON.parse(pane.summaryJson)
            delegate: Text {
              required property var modelData
              text: modelData.text
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: pane.toneColor(modelData.tone)
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

      InspectorList {
        id: trackerList
        visible: pane.trackers.state === "rows"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: summaryLine.bottom
        anchors.bottom: trackerFoot.top
        header: true
        rows: pane.trackers.rows
        columns: pane.trackerColumns
        cursor: pane.trackerIndex
        focusedPane: pane.focusedPane
        detail: trackerDetailComp
        onRowClicked: function(index) { pane.listRowClicked("trackers", index) }
      }

      Footer {
        id: trackerFoot
        visible: pane.trackers.state === "rows"
        text: "j k move · y copy"
      }
    }

    // ---- 3 peers -------------------------------------------------------
    Item {
      visible: pane.info !== null && pane.tab === "peers"
      anchors.fill: parent

      TabMessage {
        anchors.fill: parent
        tabState: pane.peers.state
        error: pane.peers.error || ""
        noun: "peers"
        copy: pane.peers.copy
      }

      InspectorList {
        id: peerList
        visible: pane.peers.state === "rows"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: peerFoot.top
        header: true
        rows: pane.peers.rows
        columns: pane.peerColumns
        cursor: pane.peerIndex
        focusedPane: pane.focusedPane
        detail: peerDetailComp
        onRowClicked: function(index) { pane.listRowClicked("peers", index) }
      }

      Footer {
        id: peerFoot
        visible: pane.peers.state === "rows"
        text: "j k move · y copy ip:port · sorted by ↓ then ↑"
      }
    }

    // ---- 4 files -------------------------------------------------------
    // A no-metadata torrent's empty files list gets its own explanation
    // (emptyCopy("files", ...)) instead of the plain "No files.": qBittorrent
    // has nothing to list until the magnet resolves.
    Text {
      visible: pane.info !== null && pane.tab === "files" && pane.files.state !== "rows"
        && !(pane.files.state === "empty" && pane.noMeta)
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

    Column {
      id: filesNoMetaCopy
      visible: pane.info !== null && pane.tab === "files" && pane.files.state === "empty" && pane.noMeta
      readonly property var copy: InspectorView.emptyCopy("files", pane.row)
      anchors.left: parent.left
      anchors.leftMargin: pane.padX
      anchors.right: parent.right
      anchors.rightMargin: pane.padX
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
      // Old layout's widest gap (progress-to-priority, 10px); the column
      // model has one spacing for the whole row, so this is as close as
      // it gets without a per-gap concept (name-to-progress goes from
      // 8px to 10px too).
      cellSpacing: Style.space(10)
      onRowClicked: function(index) { pane.fileClicked(index) }
    }

    // ---- 5 chart ---------------------------------------------------------
    Item {
      visible: pane.info !== null && pane.tab === "chart"
      anchors.fill: parent

      TabMessage {
        anchors.fill: parent
        tabState: pane.chart.state
        error: pane.chart.error || ""
        noun: "chart"
      }

      SpeedChart {
        visible: pane.chart.state === "rows"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: pane.padX
        anchors.rightMargin: pane.padX
        anchors.topMargin: Style.space(10)
        series: pane.chart.series
      }
    }
  }
}
