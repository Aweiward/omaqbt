import QtQuick
import QtTest
import qs.Commons as Commons
import "../../.."

// Qt 6.12 also exports a Color type from QtQuick. These components must
// continue to bind to Omarchy's palette singleton rather than that type.
TestCase {
  name: "Palette"
  when: windowShown

  ClientPane { id: pane }
  PiecesBar { id: pieces }
  TorrentTable { id: table }

  function test_theme_colors_reach_components() {
    compare(pane.lineColor, Commons.Util.alpha(Commons.Color.foreground, Commons.Style.normalBorderAlpha))
    compare(pieces.accentColor, Commons.Color.accent)
    compare(table.toneColor("accent"), Commons.Color.accent)
    compare(table.valueColor("—"), Commons.Color.muted)
  }
}
