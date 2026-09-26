pragma Singleton
import QtQuick
QtObject {
  property QtObject toplevels: QtObject { property var values: [] }
  property var activeToplevel: null
  property bool usingLua: true
  property var dispatched: []
  function refreshToplevels() {}
  function dispatch(r) { dispatched.push(r) }
}
