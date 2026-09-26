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

  signal line(string text)
  signal exited(int code)

  function start() {
    if (proc.running || root.path === "") return
    proc.command = [root.path]
    proc.running = true
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
    onExited: function(exitCode) { root.exited(exitCode) }
  }
}
