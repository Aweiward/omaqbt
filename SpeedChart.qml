pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons

// The inspector's chart tab (mockup row 1/2, col 5, "Chart A"): a legend
// row, a 190px Canvas line chart, a fixed time axis and Peak/Average rows.
// `series` is InspectorView.chartTab(...).series (itself
// InspectorView.chartSeries(...)'s output): {down, up, max, maxText,
// peakText, avgText, nowDlText, nowUlText, empty}. No I/O, no Date: every
// value the chart draws comes in through `series`.
Column {
  id: chart
  objectName: "speedChart"

  property var series: ({
    down: [], up: [], max: 0, maxText: "—", peakText: "—", avgText: "—",
    nowDlText: "—", nowUlText: "—", empty: true
  })

  // Bumped once per requestRepaint() call (every series change, plus the
  // initial paint) -- the harness asserts on this counter and on `series`
  // itself, never on drawn pixels.
  property int paintCount: 0

  readonly property color lineColor: Util.alpha(Color.foreground, Style.normalBorderAlpha)
  // Gridlines read fainter than the axes: the same token, half the alpha,
  // never a new colour.
  readonly property color gridColor: Util.alpha(Color.foreground, Style.normalBorderAlpha / 2)

  spacing: Style.space(10)

  function requestRepaint() {
    chart.paintCount += 1
    canvas.requestPaint()
  }
  onSeriesChanged: requestRepaint()
  Component.onCompleted: requestRepaint()

  // ---- legend row ("━ ↓ 4.1 MiB/s" accent, "━ ↑ 210 KiB/s" fg, "last 10
  // min" muted right) --------------------------------------------------
  Item {
    id: legend
    width: parent.width
    height: Style.space(16)

    Row {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(14)
      Text {
        objectName: "chartLegendDown"
        text: "━ " + chart.series.nowDlText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.accent
      }
      Text {
        objectName: "chartLegendUp"
        text: "━ " + chart.series.nowUlText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.foreground
      }
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: "last 10 min"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
  }

  // ---- the canvas itself ------------------------------------------------
  Item {
    id: plot
    width: parent.width
    height: Style.space(190)

    Canvas {
      id: canvas
      objectName: "speedChartCanvas"
      anchors.fill: parent
      renderStrategy: Canvas.Immediate
      onPaint: {
        var ctx = canvas.getContext("2d")
        ctx.reset()
        if (width <= 0 || height <= 0) return

        ctx.strokeStyle = chart.lineColor
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, 0)
        ctx.lineTo(0, height)
        ctx.lineTo(width, height)
        ctx.stroke()

        ctx.strokeStyle = chart.gridColor
        ctx.beginPath()
        ctx.moveTo(0, height / 3)
        ctx.lineTo(width, height / 3)
        ctx.moveTo(0, height * 2 / 3)
        ctx.lineTo(width, height * 2 / 3)
        ctx.stroke()

        canvas.drawLine(ctx, chart.series.up, Color.foreground, 1.2)
        canvas.drawLine(ctx, chart.series.down, Color.accent, 1.6)
      }

      // No fill, no points: a plain stroked polyline. `points` is
      // chartSeries' {x, y} pairs, both already normalized 0..1.
      function drawLine(ctx, points, strokeColor, strokeWidth) {
        if (!points || points.length === 0) return
        ctx.strokeStyle = strokeColor
        ctx.lineWidth = strokeWidth
        ctx.beginPath()
        for (var i = 0; i < points.length; i++) {
          var px = points[i].x * width
          var py = height - points[i].y * height
          if (i === 0) ctx.moveTo(px, py)
          else ctx.lineTo(px, py)
        }
        ctx.stroke()
      }
    }

    Text {
      objectName: "chartMaxText"
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(4)
      text: chart.series.maxText
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
  }

  // ---- time axis ("−10m −5m now") ---------------------------------------
  Item {
    width: parent.width
    height: Style.space(14)
    Text {
      anchors.left: parent.left
      text: "−10m"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "−5m"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
    Text {
      anchors.right: parent.right
      text: "now"
      textFormat: Text.PlainText
      font.family: Style.fontFamily
      font.pixelSize: Style.font.bodySmall
      color: Color.muted
    }
  }

  // ---- Peak / Average, or the idle sentence ------------------------------
  Column {
    visible: !chart.series.empty
    width: parent.width
    spacing: Style.space(10)
    Row {
      width: parent.width
      Text {
        width: Style.space(96)
        text: "Peak"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
      }
      Text {
        objectName: "chartPeakText"
        text: chart.series.peakText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.foreground
      }
    }
    Row {
      width: parent.width
      Text {
        width: Style.space(96)
        text: "Average"
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.muted
      }
      Text {
        objectName: "chartAvgText"
        text: chart.series.avgText
        textFormat: Text.PlainText
        font.family: Style.fontFamily
        font.pixelSize: Style.font.body
        color: Color.foreground
      }
    }
  }

  Text {
    objectName: "chartIdleText"
    visible: chart.series.empty
    width: parent.width
    text: "No traffic in the last 10 minutes."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    font.family: Style.fontFamily
    font.pixelSize: Style.font.body
    color: Color.muted
  }
}
