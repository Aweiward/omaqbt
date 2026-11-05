import QtQuick
import QtTest
import "../../../ClientView.js" as View

// Qt 6.12 hands a `var` signal parameter's arrays over as V4Sequence objects
// (Array.isArray false), nested ones too. View.plain gives real arrays back.
TestCase {
  id: tc
  name: "SignalArrays"
  property var got
  QtObject { id: svc; signal done(var data) }
  Connections { target: svc; function onDone(data) { tc.got = View.plain(data) } }

  function test_plain_restores_arrays_through_a_signal() {
    svc.done([{ name: "a", cats: [{ id: "tv" }] }, { name: "b", cats: [] }])
    verify(Array.isArray(tc.got))
    compare(tc.got.length, 2)
    verify(Array.isArray(tc.got[0].cats))
    compare(tc.got[0].cats[0].id, "tv")
  }

  function test_plain_keeps_scalars_and_null() {
    compare(View.plain(null), null)
    compare(View.plain(undefined), undefined)
    compare(View.plain("x"), "x")
    compare(View.plain(7), 7)
  }
}
