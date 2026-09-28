pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "SettingsView.js" as SettingsView
import "ClientView.js" as View

// The Settings view (slice 4a): `,` or ":Settings" swaps it in for the
// three torrent panes, and Esc swaps them back. The status line stays.
//
// Two columns, as in the mockup: the sections (220 px, with counts and a
// dimmed "RSS · slice 5") and the settings of the cursor section (group
// headers, 28 px rows of label, value and a muted type tag), with a help
// line for the cursor row above a footer of the keys that apply. `/`
// searches every section (SettingsView.search); a result names its section.
//
// The keys arrive as registry commands (panes settingsSections and
// settingsKeys) through ClientCommands, which calls the functions below.
// Every value shown is SettingsView's, as PlainText.
//
// Preferences are read (Service.readPrefs) each time the view opens; rows
// show "—" until they arrive. A failed read shows the torrent view's own
// down screen (TorrentTable's state copy, View.settingsDownCopy). None of
// this is saved: view.json never remembers Settings.
Item {
  id: settings
  objectName: "settingsView"

  property var service: null
  // The torrent view's View.tableState: which down screen to show, and a
  // failed read is retried once qBittorrent is back.
  property string tableState: "rows"

  property bool open: false
  // The focused column, the registry pane keys dispatch in.
  property string column: "settingsSections"
  // `qbt prefs` output; null while loading (SettingsView shows "—").
  property var prefs: null
  // The last read failed (error: its one-line reason).
  property bool failed: false
  property string error: ""
  // Bumped by every read and by closing, so a late answer is dropped.
  property int readSeq: 0
  // Task 6 (SettingsCommands): key -> "run" while its write runs, "done"
  // until the re-read is in; those rows show "saving…". pickerOpen loads
  // the choice picker below (null otherwise), which SettingsCommands drives.
  property var saving: ({})
  property bool pickerOpen: false
  readonly property var picker: pickerLoader.item

  property int sectionIndex: 0
  // The settings cursor of each section, by section name.
  property var cursors: ({})
  // The search (live while its INSERT field is open), its cursor, and the
  // column `/` was pressed in (clearing the search goes back there).
  property string query: ""
  property int searchIndex: 0
  property string searchFrom: "settingsSections"

  readonly property var sectionList: SettingsView.sections(prefs)
  readonly property int sectionAt: View.settingsSectionStep(sectionList, sectionIndex, 0)
  readonly property var section: sectionAt < sectionList.length ? sectionList[sectionAt] : ({ name: "", label: "" })
  readonly property string sectionName: section.name
  readonly property bool searching: query.trim() !== ""
  readonly property var searchResult: SettingsView.search(query, prefs)
  readonly property var shownRows: searching ? searchResult.rows : SettingsView.rows(sectionName, prefs)
  readonly property int keyIndex: View.moveIndex(shownRows.length, searching ? searchIndex : (cursors[sectionName] || 0), 0)
  // The row under the settings cursor (Task 6 edits it), or null.
  readonly property var cursorRow: keyIndex < shownRows.length ? shownRows[keyIndex] : null
  readonly property var entries: View.settingsEntries(shownRows, searching)
  readonly property var title: View.settingsTitle(section.label, shownRows.length, query)
  // The cursor row's editor kind (Space/Enter hints), "none" while it saves.
  readonly property string editorKind: cursorRow && saving[cursorRow.key] === undefined ? SettingsView.editorFor(cursorRow.key, prefs).kind : "none"

  readonly property int padX: Style.space(12)
  readonly property int rowHeight: Style.space(28)
  readonly property color dimColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  visible: open

  // ---- open, close, read -------------------------------------------------------

  function openView() {
    open = true
    column = "settingsSections"
    query = ""
    searchIndex = 0
    reload(false)
  }

  function closeView() {
    open = false
    pickerOpen = false
    query = ""
    searchIndex = 0
    column = "settingsSections"
    readSeq = readSeq + 1
  }

  // Reads preferences again. keep: leave the current values up until the
  // answer (a re-read after a write), rather than "—".
  function reload(keep) {
    if (keep !== true) prefs = null
    failed = false
    error = ""
    readSeq = readSeq + 1
    var seq = readSeq
    if (!service || typeof service.readPrefs !== "function") {
      failed = true
      return
    }
    service.readPrefs(function(res) {
      if (seq !== settings.readSeq || !settings.open) return
      if (res && res.ok === true && res.prefs) {
        settings.prefs = res.prefs
        settings.failed = false
      } else {
        // error first: a failed read's note (SettingsCommands) reads it.
        settings.error = res && res.error ? String(res.error) : ""
        settings.failed = true
      }
    })
  }

  // qBittorrent came back while the down screen showed: read again.
  onTableStateChanged: if (open && failed && ["gui", "notInstalled", "daemon", "api", "loading"].indexOf(tableState) === -1) reload(false)

  // ---- navigation (the settings.* commands) --------------------------------------

  function move(delta) {
    if (failed) return
    if (column === "settingsSections") {
      sectionIndex = View.settingsSectionStep(sectionList, sectionAt, delta)
      Qt.callLater(settings.revealCursor)
      return
    }
    var next = View.moveIndex(shownRows.length, keyIndex, delta)
    if (searching) {
      searchIndex = next
    } else {
      var c = {}
      for (var k in cursors) c[k] = cursors[k]
      c[sectionName] = next
      cursors = c
    }
    Qt.callLater(settings.revealCursor)
  }

  function enter() {
    if (failed) return
    column = "settingsKeys"
    Qt.callLater(settings.revealCursor)
  }

  // h from the settings: back to the sections, ending a search.
  function leave() {
    query = ""
    searchIndex = 0
    column = "settingsSections"
  }

  // Esc: clears a search first, then leaves Settings.
  function back() {
    if (searching) clearSearch()
    else closeView()
  }

  // ---- search -----------------------------------------------------------------------

  function beginSearch() {
    if (!searching) searchFrom = column
  }

  function setSearch(text) {
    query = String(text || "")
    searchIndex = 0
  }

  // Enter in the field: results stay, with the cursor on them; an empty
  // query is no search.
  function commitSearch(text) {
    setSearch(text)
    column = searching ? "settingsKeys" : searchFrom
  }

  function clearSearch() {
    query = ""
    searchIndex = 0
    column = searchFrom
  }

  // ---- scrolling --------------------------------------------------------------------

  function revealIn(flick, item) {
    if (!item) return
    var top = item.y
    var bottom = item.y + item.height
    if (top < flick.contentY) flick.contentY = top
    else if (bottom > flick.contentY + flick.height) flick.contentY = bottom - flick.height
  }

  function revealCursor() {
    revealIn(sectionFlick, sectionRep.itemAt(sectionAt))
    for (var i = 0; i < entryRep.count; i++) {
      var it = entryRep.itemAt(i)
      if (it && it.entryIndex === keyIndex && it.isRow) { revealIn(keyFlick, it); return }
    }
  }

  // ---- the footer both columns share --------------------------------------------------

  component KeyFooter: Item {
    id: footerItem
    property var keys: []
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: keyFlow.implicitHeight + Style.space(12)

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: 1
      color: Util.alpha(Color.foreground, Style.normalBorderAlpha)
    }

    Flow {
      id: keyFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)
      Repeater {
        model: footerItem.keys
        delegate: Row {
          id: hint
          required property var modelData
          Text {
            text: hint.modelData.key
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.foreground
          }
          Text {
            text: " " + hint.modelData.label
            textFormat: Text.PlainText
            font.family: Style.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: Color.muted
          }
        }
      }
    }
  }

  // One settings row (28 px): the label (with its section in a search), the
  // value, a muted "after restart" on restart keys, and the muted type tag.
  // Locked rows ("OmaqBT") and dimmed dependents are painted dim; other
  // muted values (sentinels, "—" while loading) in muted. Inline
  // components can't see this file's ids, so it sizes itself from Style.
  component SettingsRow: Item {
    id: rowItem
    objectName: "settingsRow"
    property var row: ({})
    property bool current: false
    property bool focused: false
    property bool showSection: false
    property bool saving: false
    signal clicked()
    readonly property color dim: Util.alpha(Color.foreground, Style.normalBorderAlpha)
    readonly property int labelWidth: Math.min(Style.space(300), Math.round(width * 0.45))
    readonly property int tagWidth: Style.space(78)

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
      objectName: "settingsValue"
      x: rowItem.labelWidth + Style.space(8)
      anchors.right: rowRestart.visible ? rowRestart.left : rowTag.left
      anchors.rightMargin: Style.space(8)
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
      visible: rowItem.row.restart === true
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

  // ---- the sections column -------------------------------------------------------

  ClientPane {
    id: sectionsPane
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(220)
    title: "Settings"
    focusedPane: settings.column === "settingsSections"
    swappedOut: settings.failed

    Flickable {
      id: sectionFlick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: sectionsFooter.top
      clip: true
      contentWidth: width
      contentHeight: sectionColumn.height + Style.space(8)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: sectionColumn
        width: sectionFlick.width
        topPadding: Style.space(4)

        Repeater {
          id: sectionRep
          model: settings.sectionList
          delegate: Item {
            id: sectionItem
            objectName: "settingsSectionItem"
            required property var modelData
            required property int index
            readonly property bool current: index === settings.sectionAt
            readonly property bool dimmed: modelData.dimmed === true
            width: sectionColumn.width
            height: settings.rowHeight

            Rectangle {
              visible: sectionItem.current
              anchors.fill: parent
              color: Style.selectedAccentFill
            }
            Rectangle {
              visible: sectionItem.current && sectionsPane.focusedPane
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(3)
              color: Color.accent
            }
            Text {
              anchors.left: parent.left
              anchors.leftMargin: settings.padX
              anchors.right: sectionCount.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              text: sectionItem.modelData.label
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.body
              color: sectionItem.dimmed ? settings.dimColor : (sectionItem.current ? Color.accent : Color.foreground)
            }
            Text {
              id: sectionCount
              visible: !sectionItem.dimmed
              anchors.right: parent.right
              anchors.rightMargin: settings.padX
              anchors.verticalCenter: parent.verticalCenter
              text: String(sectionItem.modelData.count)
              textFormat: Text.PlainText
              font.family: Style.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: Color.muted
            }
          }
        }
      }
    }

    KeyFooter {
      id: sectionsFooter
      keys: View.settingsFooterKeys("settingsSections", false)
    }
  }

  // ---- the settings column --------------------------------------------------------

  ClientPane {
    id: keysPane
    anchors.left: sectionsPane.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    title: settings.title.title
    titleRight: settings.title.right
    focusedPane: settings.column === "settingsKeys"
    rightLine: false
    swappedOut: settings.failed

    Flickable {
      id: keyFlick
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: helpPanel.top
      clip: true
      contentWidth: width
      contentHeight: keyColumn.height + Style.space(8)
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: keyColumn
        width: keyFlick.width

        Repeater {
          id: entryRep
          model: settings.entries
          delegate: Item {
            id: entryItem
            required property var modelData
            readonly property bool isRow: modelData.kind === "row"
            readonly property int entryIndex: modelData.index
            width: keyColumn.width
            height: isRow ? settings.rowHeight : groupHeader.implicitHeight + Style.space(18)

            PanelSectionHeader {
              id: groupHeader
              visible: !entryItem.isRow
              anchors.left: parent.left
              anchors.leftMargin: settings.padX
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(6)
              text: entryItem.modelData.label
              color: Color.muted
              font.bold: false
              font.capitalization: Font.AllUppercase
              font.letterSpacing: Style.font.caption * 0.12
            }

            SettingsRow {
              visible: entryItem.isRow
              anchors.fill: parent
              row: entryItem.isRow ? entryItem.modelData.row : ({})
              current: entryItem.isRow && entryItem.entryIndex === settings.keyIndex
              focused: keysPane.focusedPane
              showSection: settings.searching
              saving: entryItem.isRow && settings.saving[entryItem.modelData.row.key] !== undefined
              onClicked: {
                settings.column = "settingsKeys"
                settings.searchIndex = entryItem.entryIndex
                if (!settings.searching) {
                  var c = {}
                  for (var k in settings.cursors) c[k] = settings.cursors[k]
                  c[settings.sectionName] = entryItem.entryIndex
                  settings.cursors = c
                }
              }
            }
          }
        }

        // No search match: SettingsView.noMatch's line.
        Text {
          visible: settings.searching && settings.shownRows.length === 0
          width: keyColumn.width
          leftPadding: settings.padX
          rightPadding: settings.padX
          topPadding: Style.space(12)
          wrapMode: Text.Wrap
          text: settings.searchResult.message
          textFormat: Text.PlainText
          font.family: Style.fontFamily
          font.pixelSize: Style.font.body
          color: Color.muted
        }
      }
    }

    // The cursor row's help: its label, then the schema's help text.
    Item {
      id: helpPanel
      visible: settings.cursorRow !== null
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: keysFooter.top
      height: settings.cursorRow !== null ? Math.max(helpLabel.implicitHeight, helpText.implicitHeight) + Style.space(18) : 0

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: settings.lineColor
      }
      Text {
        id: helpLabel
        anchors.left: parent.left
        anchors.leftMargin: settings.padX
        anchors.top: parent.top
        anchors.topMargin: Style.space(9)
        width: Math.min(implicitWidth, parent.width * 0.4)
        elide: Text.ElideRight
        text: settings.cursorRow ? settings.cursorRow.label + " · " : ""
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.foreground
      }
      Text {
        id: helpText
        objectName: "settingsHelp"
        anchors.left: helpLabel.right
        anchors.right: parent.right
        anchors.rightMargin: settings.padX
        anchors.top: helpLabel.top
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        text: settings.cursorRow ? settings.cursorRow.help : ""
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.muted
      }
    }

    KeyFooter {
      id: keysFooter
      keys: View.settingsFooterKeys("settingsKeys", settings.searching, settings.editorKind)
    }
  }

  // ---- the down screen: the torrent view's own, reused ------------------------------

  ClientPane {
    anchors.fill: parent
    title: "Settings"
    focusedPane: true
    rightLine: false
    swappedOut: !settings.failed

    TorrentTable {
      anchors.fill: parent
      tableState: "api"
      stateCopy: View.settingsDownCopy(settings.tableState)
    }
  }

  // ---- the choice picker (Task 6): 3a's ListOverlay in PICKER mode ----------------
  // Loaded only while open, so the window's palette (a ListOverlay later in
  // the tree) stays the first one a search of the tree finds.

  Loader {
    id: pickerLoader
    anchors.fill: parent
    active: settings.open && settings.pickerOpen
    sourceComponent: Component {
      ListOverlay {
        objectName: "settingPicker"
        keyMode: "PICKER"
        multi: false
        placeholder: " type to find"
        footerHint: "↑↓ / Ctrl-n Ctrl-p move · Enter set · Esc cancel"
      }
    }
  }
}
