import QtQuick
import QtTest
import "../../.."
import "../../../LinkRules.js" as Links

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
  // Slice 5b1: an optional tag rides along (RSS marks the right article
  // read, titles can collide); no tag is undefined, as Search adds.
  function test_the_tag_rides_along_with_each_signal() {
    aw.add("c12fe1c06bba254a9dc9f519b335aa7c1367a88a", "", "same title", { feedPath: "A", guid: "1" })
    aw.add("0000000000000000000000000000000000000000", "", "same title", { feedPath: "B", guid: "2" })
    aw.add("1111111111111111111111111111111111111111", "", "untagged")
    aw.libSet = Links.librarySet([{ hash: "c12fe1c06bba254a9dc9f519b335aa7c1367a88a", infohash_v1: "c12fe1c06bba254a9dc9f519b335aa7c1367a88a", infohash_v2: "" }])
    aw.check()
    compare(ok.count, 1)
    compare(ok.signalArguments[0][1].guid, "1")
    wait(80); aw.check()
    compare(late.count, 2)
    compare(late.signalArguments[0][1].feedPath, "B")
    compare(late.signalArguments[1][0], "untagged")
    compare(late.signalArguments[1][1], undefined)
  }
  function test_clear_drops_everything() {
    aw.add("0000000000000000000000000000000000000000", "", "x"); aw.clear()
    wait(80); aw.check(); compare(late.count, 0)
  }
}
