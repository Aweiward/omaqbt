import QtQuick
// Runs nothing. A test ends a "run" by setting the collectors' text,
// running = false, then emitting exited(code, 0).
QtObject {
  property bool running: false
  property var command: []
  property bool stdinEnabled: false
  property QtObject stdout: null
  property QtObject stderr: null
  // Every string passed to write(), in order -- lets a test see what a
  // stdin-driven Process (the sidecar) was told without a real child.
  property var writes: []
  signal exited(int exitCode, int exitStatus)
  function write(s) { var w = writes.slice(); w.push(s); writes = w }
}
