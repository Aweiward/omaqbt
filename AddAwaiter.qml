import QtQuick
// The controller switches this to LinkRules.js at merge time; SearchView.js
// keeps inLibrary and librarySet as aliases until then.
import "SearchView.js" as Links

// Magnets added from a view whose hash isn't in the library yet (slice
// 5a's `awaiting`, shared in 5b0 so RSS reuses it). The owner formats the
// sentences: confirmed(name) once the hash is in libSet, unconfirmed(name)
// once confirmMs passes. Checked each second while anything waits.
QtObject {
  id: awaiter
  property var libSet: ({})
  property int confirmMs: 30000
  property var pending: []   // [{v1, v2, name, until}]
  signal confirmed(string name)
  signal unconfirmed(string name)

  function add(v1, v2, name) {
    pending = pending.concat([{ v1: v1, v2: v2, name: name, until: Date.now() + confirmMs }])
    check()
  }
  function clear() { pending = [] }
  function check() {
    if (pending.length === 0) return
    var keep = [], now = Date.now()
    for (var i = 0; i < pending.length; i++) {
      var a = pending[i]
      if (Links.inLibrary(a.v1, a.v2, libSet)) confirmed(a.name)
      else if (now >= a.until) unconfirmed(a.name)
      else keep.push(a)
    }
    pending = keep
  }
  property Timer timer: Timer {
    interval: 1000; repeat: true
    running: awaiter.pending.length > 0
    onTriggered: awaiter.check()
  }
}
