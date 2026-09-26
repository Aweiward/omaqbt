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

  function start() {
    if (proc.running || root.path === "") return
    root.attemptOpen = true
    proc.command = [root.path]
    proc.running = true
    // A failed exec may never reach running; catch that too.
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
      onRead: function(data) { root.line(String(data)) }
    }
    // Kept only for debugging; the fatal line on stdout carries the reason.
    stderr: StdioCollector { id: errOut; waitForEnd: true }
    onExited: function(exitCode) { root.finishAttempt(exitCode) }
    onRunningChanged: if (!proc.running) Qt.callLater(root.checkLost)
  }
}
