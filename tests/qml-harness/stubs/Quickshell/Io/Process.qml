import QtQuick
// Runs nothing. A test ends a "run" by setting the collectors' text,
// running = false, then emitting exited(code, 0).
QtObject {
  property bool running: false
  property var command: []
  property bool stdinEnabled: false
  property QtObject stdout: null
  property QtObject stderr: null
  signal exited(int exitCode, int exitStatus)
  function write(s) {}
}
