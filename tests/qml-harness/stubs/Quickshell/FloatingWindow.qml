import QtQuick
import QtQuick.Window
Window {
  id: w
  property size minimumSize
  property int implicitWidth: 1600
  property int implicitHeight: 900
  property var _backingWindow: w
  property int activateCalls: 0
  signal windowConnected()
  function requestActivate() { activateCalls++ }
  visible: true
  width: 1600; height: 900
}
