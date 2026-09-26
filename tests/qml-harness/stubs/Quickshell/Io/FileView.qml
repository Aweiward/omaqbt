import QtQuick
// No disk I/O at all.
QtObject {
  property string path: ""
  property bool printErrors: true
  property bool atomicWrites: false
  signal loaded()
  signal loadFailed(int error)
  signal saveFailed(int error)
  function setText(t) {}
  function text() { return "" }
}
