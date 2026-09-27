pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The Info tab's pieces bar (mockup row 1, col 1): InspectorView.binPieces'
// output as one line of glyphs -- have/partial in accent, missing dim --
// and a muted 11px legend line below. One Text with StyledText markup
// (runs of the same tone merged into one <font> span) draws the whole
// line, so a pieces refresh (every ~5s, F9) never rebuilds 48 delegates
// the way a per-glyph Repeater would.
Column {
  id: bar

  // InspectorView.binPieces' output: [{glyph, tone}] ("accent" | "dim").
  property var cells: []
  property string legend: ""

  spacing: Style.space(4)

  readonly property color accentColor: Color.accent
  readonly property color dimColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)

  function toneColor(tone) {
    return tone === "accent" ? bar.accentColor : bar.dimColor
  }

  // markup(list) -> barText's StyledText source: consecutive glyphs of the
  // same tone share one <font> span (binPieces' output is a handful of
  // runs in practice, never one span per cell).
  function markup(list) {
    var out = ""
    var l = list || []
    var n = l.length
    var i = 0
    while (i < n) {
      var tone = l[i].tone
      var run = l[i].glyph
      var j = i + 1
      while (j < n && l[j].tone === tone) { run += l[j].glyph; j++ }
      out += "<font color=\"" + bar.toneColor(tone) + "\">" + run + "</font>"
      i = j
    }
    return out
  }

  Text {
    id: barText
    objectName: "piecesBarText"
    textFormat: Text.StyledText
    text: bar.markup(bar.cells)
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    id: legendText
    objectName: "piecesLegendText"
    textFormat: Text.PlainText
    text: bar.legend
    font.family: Style.fontFamily
    font.pixelSize: Style.font.bodySmall
    color: Color.muted
  }
}
