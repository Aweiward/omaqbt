import QtQuick
import QtTest
import "../../.."
// The controller switches this to LinkRules.js at merge time.
import "../../../SearchView.js" as Links

TestCase {
  name: "AddAwaiter"
  AddAwaiter { id: aw; confirmMs: 50 }
  SignalSpy { id: ok; target: aw; signalName: "confirmed" }
  SignalSpy { id: late; target: aw; signalName: "unconfirmed" }
  function init() { aw.clear(); aw.libSet = ({}); ok.clear(); late.clear() }
  function test_confirmed_when_hash_arrives() {
    aw.add("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", "", "debian")
    compare(ok.count, 0)
    aw.libSet = Links.librarySet([{ hash: "c12fe1c06bba254a9dc9f519b335aa7c1367a88a", infohash_v1: "c12fe1c06bba254a9dc9f519b335aa7c1367a88a", infohash_v2: "" }])
    aw.check()
    compare(ok.count, 1); compare(ok.signalArguments[0][0], "debian"); compare(aw.pending.length, 0)
  }
  function test_unconfirmed_after_timeout() {
    aw.add("0000000000000000000000000000000000000000", "", "ghost")
    wait(80); aw.check()
    compare(late.count, 1); compare(late.signalArguments[0][0], "ghost"); compare(aw.pending.length, 0)
  }
  function test_clear_drops_everything() {
    aw.add("0000000000000000000000000000000000000000", "", "x"); aw.clear()
    wait(80); aw.check(); compare(late.count, 0)
  }
}
