import QtQuick
import Quickshell
import Quickshell.Io

// Thin wrapper around the long-lived `qbt-serve` process: one JSON object per
// stdout line out, one JSON command per stdin line in. Service owns the policy
// (parsing, watchdog, backoff); this only moves bytes.
Scope {
  id: root

  property string path: ""
  readonly property bool running: proc.running

  // True from a start request until its exited signal goes out, so each
  // attempt reports exactly one exit.
  property bool attemptOpen: false

  signal line(string text)
  signal exited(int code)
  // Slice 5a: a search watch's reply ({"type":"search", ...}, parsed),
  // routed here because Model.parseServeLine knows only the older line
  // types. Every other line still goes out as `line`.
  signal searchLine(var data)

  // route(text): a search reply goes to searchLine, anything else to line.
  function route(text) {
    var t = String(text)
    if (t.indexOf("\"search\"") !== -1) {
      var obj = null
      try { obj = JSON.parse(t) } catch (e) { obj = null }
      if (obj && typeof obj === "object" && !Array.isArray(obj) && obj.type === "search") {
        root.searchLine(obj)
        return
      }
    }
    root.line(t)
  }

  function start() {
    if (proc.running || root.path === "") return
    root.attemptOpen = true
    proc.command = [root.path]
    proc.running = true
    // A failed exec may never reach running; catch that too. If this runs
    // before a slow start reaches running, onRunningChanged re-opens it.
    Qt.callLater(root.checkLost)
  }

  function finishAttempt(code) {
    if (!root.attemptOpen) return
    root.attemptOpen = false
    root.exited(code)
  }

  // Quickshell's FailedToStart path clears running without emitting exited.
  // Checked a turn later so a normal exit, which clears the attempt first,
  // is never reported twice.
  function checkLost() {
    if (root.attemptOpen && !proc.running) root.finishAttempt(-1)
  }

  function stop() {
    if (proc.running) proc.running = false
  }

  function send(obj) {
    if (!proc.running) return false
    proc.write(JSON.stringify(obj) + "\n")
    return true
  }

  Process {
    id: proc
    running: false
    command: []
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(data) { root.route(String(data)) }
    }
    // Drained line by line and dropped, so a chatty child never grows a
    // buffer for the shell's lifetime; the fatal line on stdout carries
    // the reason.
    stderr: SplitParser {
      onRead: function(data) { console.debug("OmaqBT qbt-serve stderr: " + data) }
    }
    onExited: function(exitCode) { root.finishAttempt(exitCode) }
    // A process that comes up re-opens its attempt, so a checkLost that ran
    // before `running` went true can't leave a live child whose exit is
    // never reported.
    onRunningChanged: {
      if (proc.running) root.attemptOpen = true
      else Qt.callLater(root.checkLost)
    }
  }
}
