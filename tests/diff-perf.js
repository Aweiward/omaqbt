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
//   3. rss    -- slice 5b1's Articles column (Review Focus 4): 10,000 article
//      rows (200 feeds x 50), keyed like RssView.keyOf ("<feedPath>\n<guid>"),
//      newest first; one feed's 50 rows are replaced (a feed re-read while it
//      refreshes). It must stay a keyed diff of 50 removes and 50 inserts,
//      never a reset (the cursor stays on its article, no flicker).
//
// Prints one JSON object to stdout: { tick: {...}, reset: {...}, rss: {...} }.

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

function opBreakdown(ops) {
  var counts = { set: 0, insert: 0, remove: 0, move: 0 };
  for (var i = 0; i < ops.length; i++) {
    var op = ops[i].op;
    if (counts[op] !== undefined) counts[op]++;
  }
  return counts;
}

function describeDiffResult(result) {
  if (result && result.reset === true) {
    return { reset: true, ops: null, byType: null };
  }
  return { reset: false, ops: result.length, byType: opBreakdown(result) };
}

// `count` distinct indices into [0, n), via a partial Fisher-Yates shuffle
// (picking indices with replacement, as a naive rng()*n loop would, can and
// did repeat an index -- 50 picks landed on only 49 distinct rows once).
function distinctIndices(rng, n, count) {
  var pool = [];
  for (var i = 0; i < n; i++) pool.push(i);
  for (var i = 0; i < count; i++) {
    var j = i + Math.floor(rng() * (n - i));
    var tmp = pool[i];
    pool[i] = pool[j];
    pool[j] = tmp;
  }
  return pool.slice(0, count);
}

function isSortedByDlDescending(rows) {
  for (var i = 1; i < rows.length; i++) {
    if (rows[i - 1].dlSpeed < rows[i].dlSpeed) return false;
  }
  return true;
}

function main() {
  var rng = mulberry32(20260926);
  var baseRows = buildRows(rng, ROW_COUNT);

  var sortTick = timeMs(function() { return Model.sortTorrents(baseRows, "dl", true); });
  var oldRows = sortTick.result;
  if (!isSortedByDlDescending(oldRows)) {
    throw new Error("diff-perf: oldRows is not sorted by dl descending -- sortTorrents(desc:true) regressed");
  }

  // Case 1: a tick where 50 distinct rows change speed, then the list is
  // re-sorted by dl, descending (fastest first).
  var mutated = oldRows.map(function(row) { return Object.assign({}, row); });
  var changedIndexes = distinctIndices(rng, mutated.length, CHANGED_COUNT);
  for (var i = 0; i < changedIndexes.length; i++) {
    var idx = changedIndexes[i];
    mutated[idx] = Object.assign({}, mutated[idx], {
      dlSpeed: Math.floor(rng() * 5000000),
      upSpeed: Math.floor(rng() * 1000000)
    });
  }
  var resortTiming = timeMs(function() { return Model.sortTorrents(mutated, "dl", true); });
  var newRowsTick = resortTiming.result;
  if (!isSortedByDlDescending(newRowsTick)) {
    throw new Error("diff-perf: newRowsTick is not sorted by dl descending -- sortTorrents(desc:true) regressed");
  }

  var diffTickTiming = timeMs(function() { return Model.diffRows(oldRows, newRowsTick, DIFF_FIELDS); });
  var tickSummary = describeDiffResult(diffTickTiming.result);
  tickSummary.rows = ROW_COUNT;
  tickSummary.changedRows = CHANGED_COUNT;
  tickSummary.distinctChanged = changedIndexes.length;
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

  // Case 3: RSS, 200 feeds x 50 articles; feed 117's 50 articles replaced.
  var RSS_FEEDS = 200, RSS_PER_FEED = 50, RSS_FIELDS = ["title", "dateText", "isRead", "inLibrary", "hasTorrent"];
  function rssRow(feed, guid, date) {
    return { hash: "Feeds\\feed " + feed + "\n" + guid, title: "article " + guid, dateText: String(date), isRead: false, inLibrary: false, hasTorrent: true, date: date };
  }
  var rssOld = [];
  for (var f = 0; f < RSS_FEEDS; f++) for (var a = 0; a < RSS_PER_FEED; a++) rssOld.push(rssRow(f, "g" + a, 1700000000 + a * RSS_FEEDS + f));
  rssOld.sort(function(x, y) { return y.date - x.date; });
  var rssNew = rssOld.map(function(row) {
    if (row.hash.indexOf("Feeds\\feed 117\n") !== 0) return row;
    return rssRow(117, "new-" + row.hash.split("\n")[1], row.date);
  });
  var rssTiming = timeMs(function() { return Model.diffRows(rssOld, rssNew, RSS_FIELDS); });
  var rssSummary = describeDiffResult(rssTiming.result);
  if (rssSummary.reset || rssSummary.byType.remove !== RSS_PER_FEED || rssSummary.byType.insert !== RSS_PER_FEED || rssSummary.ops !== 2 * RSS_PER_FEED) {
    throw new Error("diff-perf: the RSS re-read must be 50 removes and 50 inserts, got " + JSON.stringify(rssSummary));
  }
  if (Model.applyOps(rssOld, rssTiming.result).map(function(r) { return r.hash; }).join("|") !== rssNew.map(function(r) { return r.hash; }).join("|")) {
    throw new Error("diff-perf: the RSS ops don't rebuild the new rows");
  }
  rssSummary.rows = rssOld.length;
  rssSummary.ms = Number(rssTiming.ms.toFixed(3));

  var output = { tick: tickSummary, reset: resetSummary, rss: rssSummary };
  console.log(JSON.stringify(output));
}

main();
