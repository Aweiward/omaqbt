import QtQuick
import "LinkRules.js" as Links

// Magnets added from a view whose hash isn't in the library yet (slice
// 5a's `awaiting`, shared in 5b0 so RSS reuses it). The owner formats the
// sentences: confirmed(name, tag) once the hash is in libSet,
// unconfirmed(name, tag) once confirmMs passes. Checked each second while
// anything waits. tag (slice 5b1, optional) is the owner's, passed back as
// it was given (RSS marks that article read: titles can collide);
// undefined when add() had none.
QtObject {
  id: awaiter
  property var libSet: ({})
  property int confirmMs: 30000
  property var pending: []   // [{v1, v2, name, tag, until}]
  signal confirmed(string name, var tag)
  signal unconfirmed(string name, var tag)

  function add(v1, v2, name, tag) {
    pending = pending.concat([{ v1: v1, v2: v2, name: name, tag: tag, until: Date.now() + confirmMs }])
    check()
  }
  function clear() { pending = [] }
  function check() {
    if (pending.length === 0) return
    var keep = [], now = Date.now()
    for (var i = 0; i < pending.length; i++) {
      var a = pending[i]
      if (Links.inLibrary(a.v1, a.v2, libSet)) confirmed(a.name, a.tag)
      else if (now >= a.until) unconfirmed(a.name, a.tag)
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
