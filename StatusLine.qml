pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "ClientView.js" as View

// The window's 30 px status line: the mode badge, then either the stats
// (count · speeds · turtle · VPN bind), a progress message, the CONFIRM
// question, or the INSERT input; key hints for the mode sit on the right.
//
// The INSERT input lives here so it stays a descendant of the window's
// key-handling item: TextField keeps printable keys and lets Return and
// Escape bubble up to the one Keys.onPressed that feeds dispatch().
Rectangle {
  id: line

  property string mode: "NORMAL"
  // View.confirmLine(...) while mode is CONFIRM, else null.
  property var confirmParts: null
  property string countText: ""
  // The VISUAL range's size ("K selected", in accent); 0 hides it.
  property int selectedCount: 0
  property string speedText: ""
  property bool turtle: false
  // View.vpnPart(...) or null.
  property var vpn: null
  property bool sidecarDown: false
  property bool loading: false
  // A progress (muted) or validation (urgent) message; replaces the stats
  // while it is set, and the stats come back once it clears.
  property string message: ""
  property string messageTone: "muted"
  // [{key, label}] from View.modeHints.
  property var hints: []
  // "filter" or "move" while mode is INSERT.
  property string inputPurpose: ""

  // Every edit of the INSERT field, as the user types.
  signal inputEdited(string text)

  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  readonly property int gap: Style.space(14)
  readonly property bool badgeFilled: mode !== "NORMAL"

  function setInput(text) {
    input.text = String(text || "")
  }

  function inputValue() {
    return String(input.text || "")
  }

  function focusInput() {
    input.forceActiveFocus()
    input.cursorPosition = String(input.text || "").length
  }

  function toneColor(tone) {
    return View.toneColor(tone, Color)
  }

  // No bg-dark token exists; Panel.qml already derives shades with
  // Qt.darker, so this stays a pure function of Color.background.
  color: Qt.darker(Color.background, 1.12)
  height: Style.space(30)

  component Part: Text {
    textFormat: Text.PlainText
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: Color.foreground
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: 1
    color: line.lineColor
  }

  Rectangle {
    id: badge
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: badgeText.implicitWidth + Style.space(24)
    color: {
      if (line.mode === "CONFIRM") return Color.urgent
      if (line.badgeFilled) return Color.accent
      return "transparent"
    }

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: line.mode
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.body
      font.bold: line.badgeFilled
      font.letterSpacing: Style.font.body * 0.06
      color: line.badgeFilled ? Color.background : Color.muted
    }

    Rectangle {
      visible: !line.badgeFilled
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      color: line.lineColor
    }
  }

  Item {
    id: body
    anchors.left: badge.right
    anchors.leftMargin: line.gap
    anchors.right: hintRow.left
    anchors.rightMargin: line.gap
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    clip: true

    // CONFIRM: "Delete 2 torrents and their files from disk?"
    Row {
      visible: line.mode === "CONFIRM" && line.confirmParts !== null
      anchors.verticalCenter: parent.verticalCenter
      Part { text: line.confirmParts ? line.confirmParts.lead : ""; color: Color.urgent }
      Part { text: line.confirmParts ? line.confirmParts.strong : ""; color: Color.foreground; font.bold: true }
      Part { text: line.confirmParts ? line.confirmParts.tail : ""; color: Color.urgent }
    }

    // INSERT: a prompt and the text field.
    Row {
      visible: line.mode === "INSERT"
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)
      Part {
        text: line.inputPurpose === "move" ? "move to" : "/"
        color: Color.accent
      }
      TextField {
        id: input
        width: Math.max(Style.space(160), Math.min(Style.space(560), body.width - Style.space(120)))
        verticalPadding: Style.space(2)
        placeholderText: line.inputPurpose === "move" ? "/absolute/path" : "filter by name, or paste a magnet"
        onTextChanged: line.inputEdited(String(input.text || ""))
      }
      Part {
        visible: line.message !== ""
        text: line.message
        color: line.toneColor(line.messageTone)
      }
    }

    // NORMAL (and anything else): a message, or the stats.
    Row {
      visible: line.mode !== "CONFIRM" && line.mode !== "INSERT"
      anchors.verticalCenter: parent.verticalCenter
      spacing: line.gap

      Part {
        visible: line.message !== ""
        text: line.message
        color: line.toneColor(line.messageTone)
      }
      Part {
        visible: line.message === "" && line.loading
        text: "Connecting to qbittorrent-nox…"
        color: Color.muted
      }
      Row {
        visible: line.message === "" && !line.loading
        spacing: line.gap
        Part { text: line.countText }
        Part { visible: line.selectedCount > 0; text: "·"; color: Color.muted }
        Part { visible: line.selectedCount > 0; text: line.selectedCount + " selected"; color: Color.accent }
        Part { text: "·"; color: Color.muted }
        Part { text: line.speedText }
        Part { text: "·"; color: Color.muted }
        Part { text: line.turtle ? "turtle on" : "turtle off"; color: line.turtle ? Color.accent : Color.muted }
        Part { visible: line.vpn !== null; text: "·"; color: Color.muted }
        Part {
          visible: line.vpn !== null
          text: line.vpn ? line.vpn.text : ""
          color: line.toneColor(line.vpn ? line.vpn.tone : "fg")
        }
        Part { visible: line.sidecarDown; text: "· slow polling (qbt-serve down)"; color: Color.muted }
      }
    }
  }

  Row {
    id: hintRow
    anchors.right: parent.right
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    Repeater {
      model: line.hints
      delegate: Row {
        id: hint
        required property var modelData
        required property int index
        Part { visible: hint.index > 0; text: " · "; color: Color.muted }
        Part { text: hint.modelData.key; color: Color.foreground }
        Part { text: " " + hint.modelData.label; color: Color.muted }
      }
    }
  }
}
