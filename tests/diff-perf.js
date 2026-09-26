// Perf probe for Model.diffRows over a synthetic 5,000-row table.
//
// Two cases, matching the design doc's Open Question 4 ("measure in slice 1
// with a synthetic 5,000-row fixture"):
//   1. tick   -- 50 of 5,000 rows change speed, the list is re-sorted by
//      "dl", and we diff against the previous tick. This is the steady-state
//      cost the sidecar's cadence has to stay under.
//   2. reset  -- the whole 5,000-row set is replaced (all new hashes), which
//      must blow the op-count threshold and come back as {reset:true}
//      quickly rather than walking a doomed diff.
//
// Prints one JSON object to stdout: { tick: {...}, reset: {...} }.

var Model = require("../Model.js");

var ROW_COUNT = 5000;
var CHANGED_COUNT = 50;
var DIFF_FIELDS = ["name", "dlSpeed", "upSpeed", "progress", "eta", "ratio", "tags"];

// Small seeded PRNG so this script's output is reproducible.
function mulberry32(seed) {
  return function() {
    seed |= 0;
    seed = (seed + 0x6D2B79F5) | 0;
    var t = seed;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function buildRows(rng, count) {
  var rows = [];
  for (var i = 0; i < count; i++) {
    rows.push({
      hash: "hash-" + String(i).padStart(5, "0"),
      name: "torrent-" + i,
      state: "downloading",
      progress: rng(),
      dlSpeed: Math.floor(rng() * 5000000),
      upSpeed: Math.floor(rng() * 1000000),
      eta: Math.floor(rng() * 100000),
      ratio: rng() * 3,
      size: Math.floor(rng() * 1e10),
      addedOn: Math.floor(rng() * 1700000000),
      category: "",
      tags: [],
      tracker: "tracker" + (i % 20) + ".example"
    });
  }
  return rows;
}

function timeMs(fn) {
  var start = process.hrtime.bigint();
  var result = fn();
  var end = process.hrtime.bigint();
  return { result: result, ms: Number(end - start) / 1e6 };
}

function describeDiffResult(result) {
  if (result && result.reset === true) {
    return { reset: true, ops: null };
  }
  return { reset: false, ops: result.length };
}

function main() {
  var rng = mulberry32(20260926);
  var baseRows = buildRows(rng, ROW_COUNT);

  var sortTick = timeMs(function() { return Model.sortTorrents(baseRows, "dl", true); });
  var oldRows = sortTick.result;

  // Case 1: a tick where 50 rows change speed, then the list is re-sorted.
  var mutated = oldRows.map(function(row) { return Object.assign({}, row); });
  var changedIndexes = [];
  for (var i = 0; i < CHANGED_COUNT; i++) {
    var idx = Math.floor(rng() * mutated.length);
    changedIndexes.push(idx);
    mutated[idx] = Object.assign({}, mutated[idx], {
      dlSpeed: Math.floor(rng() * 5000000),
      upSpeed: Math.floor(rng() * 1000000)
    });
  }
  var resortTiming = timeMs(function() { return Model.sortTorrents(mutated, "dl", true); });
  var newRowsTick = resortTiming.result;

  var diffTickTiming = timeMs(function() { return Model.diffRows(oldRows, newRowsTick, DIFF_FIELDS); });
  var tickSummary = describeDiffResult(diffTickTiming.result);
  tickSummary.rows = ROW_COUNT;
  tickSummary.changedRows = CHANGED_COUNT;
  tickSummary.ms = Number(diffTickTiming.ms.toFixed(3));

  // Case 2: a full reset -- every hash replaced, so the ops count must blow
  // the max(8, newRows.length/2) threshold and diffRows must bail fast.
  var rng2 = mulberry32(99);
  var replacedRows = buildRows(rng2, ROW_COUNT).map(function(row, i) {
    return Object.assign({}, row, { hash: "reset-" + row.hash });
  });
  var diffResetTiming = timeMs(function() { return Model.diffRows(oldRows, replacedRows, DIFF_FIELDS); });
  var resetSummary = describeDiffResult(diffResetTiming.result);
  resetSummary.rows = ROW_COUNT;
  resetSummary.ms = Number(diffResetTiming.ms.toFixed(3));

  var output = { tick: tickSummary, reset: resetSummary };
  console.log(JSON.stringify(output));
}

main();
