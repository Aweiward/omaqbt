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
// Two columns, as in the mockup: the sections (220 px, with counts; RSS
// last, live since slice 5b1) and the settings of the cursor section (group
// headers, 28 px rows of label, value and a muted type tag), with a help
// line for the cursor row above a footer of the keys that apply. `/`
// searches every section (SettingsView.search); a result names its section.
//
// The keys arrive as registry commands (panes settingsSections and
// settingsKeys) through ClientCommands, which calls the functions below.
// Every value shown is SettingsView's, as PlainText.
//
// Slice 4b: a third column state, settingsList, shows one list setting's
// lines (SettingsList.qml) in place of the settings: Enter on a list row
// opens it, and the Banned IPs section's column is always its list (l or
// Enter from the sections focuses it). In a narrow window (`narrow`,
// View.settingsNarrow) the sections column is an overlay over the left edge
// while it has focus (ClientPane's collapsed overlay) and a chip ("Speed ▾")
// above the settings stands for it; type tags hide, labels truncate before
// values and the help line wraps.
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

  // Showing: bound by the Client to activeView === "settings" (slice 5a,
  // eng C1). The Client owns opening and leaving: it calls openView() and
  // closeView() as the view comes and goes, and Esc here only asks it to
  // leave (leaveRequested).
  property bool open: false
  signal leaveRequested()
  // Below the breakpoint (the Client's View.settingsNarrow).
  property bool narrow: false
  // The focused column, the registry pane keys dispatch in:
  // settingsSections, settingsKeys or settingsList.
  property string column: "settingsSections"
  // The open list's key while column is settingsList, else "".
  property string listKey: ""
  // Each list's cursor, by key (a line index into listItems).
  property var listCursors: ({})
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
  // Slice 4b (Task 4): entries in this visit's undo history (SettingsCommands
  // binds it); the footer shows "u undo" while there are any.
  property int undoCount: 0

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
  readonly property var cursorEditor: cursorRow && saving[cursorRow.key] === undefined ? SettingsView.editorFor(cursorRow.key, prefs) : ({ kind: "none" })
  readonly property string editorKind: cursorEditor.kind
  // The list the settings column shows: the open one, or the Banned IPs
  // section's (a preview while the sections have focus); "" for settings.
  // A search (typed or committed) shows its results instead: the keys act
  // on them.
  readonly property string listShown: column === "settingsList" ? listKey : (!searching && section.list ? String(section.list) : "")
  readonly property var listItems: listShown !== "" && prefs ? SettingsView.listItems(listShown, prefs[listShown]) : []
  readonly property int listIndex: View.moveIndex(listItems.length, listCursors[listShown] || 0, 0)
  // The line under the list cursor, or null.
  readonly property var listItem: column === "settingsList" && listIndex < listItems.length ? listItems[listIndex] : null
  readonly property bool listSaving: listShown !== "" && saving[listShown] !== undefined

  readonly property int padX: Style.space(12)
  readonly property int rowHeight: Style.space(28)
  readonly property color dimColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  visible: open

  // ---- open, close, read -------------------------------------------------------

  // The Client just made Settings the active view: a fresh visit.
  function openView() {
    // Narrow, the sections are a chip: the settings take the keys, or the
    // Banned IPs list once the read shows which section this is (reload).
    column = narrow ? "settingsKeys" : "settingsSections"
    listKey = ""
    query = ""
    searchIndex = 0
    reload(false)
  }

  // The Client just left Settings: drop the visit (a late read is ignored).
  function closeView() {
    pickerOpen = false
    query = ""
    searchIndex = 0
    column = "settingsSections"
    listKey = ""
    readSeq = readSeq + 1
  }

  // A resize below the breakpoint while the sections have focus hands it
  // to what they show (the 1b pattern: a collapsing pane gives focus back).
  onNarrowChanged: if (narrow && open && column === "settingsSections") showSection()

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
        settings.settleNarrow()
      } else {
        // error first: a failed read's note (SettingsCommands) reads it.
        settings.error = res && res.error ? String(res.error) : ""
        settings.failed = true
      }
    })
  }

  // qBittorrent came back while the down screen showed: read again. It went
  // down while Settings showed: the down screen, and a read in flight is
  // dropped so it can't land over it.
  onTableStateChanged: {
    if (!open) return
    if (failed && ["gui", "notInstalled", "daemon", "api", "loading"].indexOf(tableState) === -1) {
      reload(false)
    } else if (!failed && ["gui", "notInstalled", "daemon", "api"].indexOf(tableState) !== -1) {
      readSeq = readSeq + 1
      error = ""
      failed = true
    }
  }

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

  // l/Enter/Tab on a section: its settings, or the Banned IPs list. Narrow,
  // this also closes the overlay (the sections lose focus).
  function enter() {
    if (failed) return
    if (section.list) { openList(String(section.list)); return }
    listKey = ""
    column = "settingsKeys"
    Qt.callLater(settings.revealCursor)
  }

  // ---- narrow: the sections overlay (slice 4b, D13) ---------------------------

  // Tab/h/Shift-Tab from the settings: the overlay (the sections column),
  // ending a search as wide h does (leave()).
  function openSections() {
    if (failed) return
    query = ""
    searchIndex = 0
    column = "settingsSections"
  }

  // Esc on the overlay (Ruling EF): closed, back to the settings; on a list
  // section (Banned IPs, whose Esc brought you here) it leaves Settings, so
  // the list and the overlay never bounce.
  function closeSections() {
    if (section.list) leaveRequested()
    else { listKey = ""; column = "settingsKeys" }
  }

  // Narrow, the settings column has the keys on a list section (opening
  // Settings, or the down screen gone): the list takes them. Only once
  // prefs are in: sections(null) has no Other, so the index may name
  // another section until then.
  function settleNarrow() {
    if (narrow && open && column === "settingsKeys" && !searching && !failed && section.list) openList(String(section.list))
  }

  // The focus handoff when the sections collapse: to what the section
  // shows. Under the down screen a list can't open: the settings column
  // holds the keys until the read is back (onTableStateChanged).
  function showSection() {
    if (section.list && !failed) openList(String(section.list))
    else { listKey = ""; column = "settingsKeys" }
  }

  // ---- the list editor (slice 4b) --------------------------------------------------

  function openList(k) {
    if (failed || !k) return
    listKey = k
    column = "settingsList"
  }

  // Esc in a list: back to its row; the Banned IPs list (a section) back to
  // the sections -- narrow, that's the overlay.
  function closeList() {
    var k = listKey
    listKey = ""
    column = k === SettingsView.BAN_KEY ? "settingsSections" : "settingsKeys"
  }

  function setListCursor(k, index) {
    var c = {}
    for (var s in listCursors) c[s] = listCursors[s]
    c[k] = Math.max(0, Number(index) || 0)
    listCursors = c
  }

  function listMove(delta) {
    if (column !== "settingsList") return
    setListCursor(listKey, View.moveIndex(listItems.length, listIndex, delta))
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
    else leaveRequested()
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

  // ---- the sections column -------------------------------------------------------

  ClientPane {
    id: sectionsPane
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.space(220)
    title: "Settings"
    focusedPane: settings.column === "settingsSections"
    collapsed: settings.narrow
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
      keys: View.settingsFooterKeys("settingsSections", settings.searching, "none", { narrow: settings.narrow, listSection: !!settings.section.list })
    }
  }

  // ---- the settings column --------------------------------------------------------

  ClientPane {
    id: keysPane
    anchors.left: settings.narrow ? parent.left : sectionsPane.right
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    title: settings.listShown !== "" ? SettingsView.listTitle(settings.listShown) : settings.title.title
    titleRight: settings.listShown === "" ? settings.title.right
      : (settings.listSaving ? "saving…" : View.plural(settings.listItems.length, "line", "lines"))
    focusedPane: settings.column === "settingsKeys" || settings.column === "settingsList"
    rightLine: false
    swappedOut: settings.failed

    // Narrow: the sections chip ("Speed ▾"); Tab or a click opens them.
    Item {
      id: sectionChip
      objectName: "settingsChip"
      visible: settings.narrow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: visible ? chipText.implicitHeight + Style.space(12) : 0

      Text {
        id: chipText
        anchors.left: parent.left
        anchors.leftMargin: settings.padX
        anchors.right: parent.right
        anchors.rightMargin: settings.padX
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: View.settingsChip(settings.section.label)
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.accent
      }
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: settings.lineColor
      }
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        onClicked: settings.openSections()
      }
    }

    // A list setting's lines (slice 4b), in place of the settings.
    SettingsList {
      id: listColumn
      visible: settings.listShown !== ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: sectionChip.bottom
      anchors.bottom: helpPanel.top
      items: settings.listItems
      cursor: settings.listIndex
      focused: settings.column === "settingsList"
      saving: settings.listSaving
      emptyText: settings.prefs ? SettingsView.listEmptyText(settings.listShown) : SettingsView.LOADING
      onRowClicked: function(index) {
        settings.openList(settings.listShown)
        settings.setListCursor(settings.listShown, index)
      }
    }

    Flickable {
      id: keyFlick
      visible: settings.listShown === ""
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: sectionChip.bottom
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

            SettingRow {
              visible: entryItem.isRow
              anchors.fill: parent
              row: entryItem.isRow ? entryItem.modelData.row : ({})
              current: entryItem.isRow && entryItem.entryIndex === settings.keyIndex
              focused: keysPane.focusedPane
              showSection: settings.searching
              compact: settings.narrow
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
      // Narrow: the label on its own line, the help wrapping under it.
      height: settings.cursorRow === null ? 0 : (settings.narrow ? helpLabel.implicitHeight + helpText.implicitHeight + Style.space(22)
        : Math.max(helpLabel.implicitHeight, helpText.implicitHeight) + Style.space(18))

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
        width: Math.min(implicitWidth, parent.width * (settings.narrow ? 1 : 0.4) - (settings.narrow ? 2 * settings.padX : 0))
        elide: Text.ElideRight
        text: settings.cursorRow ? settings.cursorRow.label + (settings.narrow ? "" : " · ") : ""
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.foreground
      }
      Text {
        id: helpText
        objectName: "settingsHelp"
        x: settings.narrow ? settings.padX : helpLabel.x + helpLabel.width
        width: Math.max(0, parent.width - x - settings.padX)
        y: settings.narrow ? helpLabel.y + helpLabel.height + Style.space(4) : helpLabel.y
        wrapMode: Text.Wrap
        maximumLineCount: settings.narrow ? 6 : 3
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
      keys: SettingsView.withUndoKey(View.settingsFooterKeys(settings.column === "settingsList" ? "settingsList" : "settingsKeys", settings.searching, settings.editorKind,
        { narrow: settings.narrow, secretSet: settings.cursorEditor.set === true, listEditable: settings.prefs !== null && !settings.listSaving,
          listItem: settings.listItem }), settings.undoCount)
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
