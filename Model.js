function normalizeState(state) {
  return String(state || "").toLowerCase();
}

function classifyState(state, progress) {
  var s = normalizeState(state);
  var p = Number(progress);
  if (!isFinite(p)) p = 0;
  if (s === "error" || s === "missingfiles" || s === "unknown") return "error";
  if (
    s === "uploading" || s === "stalledup" || s === "queuedup" ||
    s === "forcedup" || s === "checkingup"
  ) return "seeding";
  if (
    s === "downloading" || s === "metadl" || s === "stalleddl" ||
    s === "queueddl" || s === "forceddl" || s === "allocating" || s === "checkingdl"
  ) return "downloading";
  if (
    s === "pauseddl" || s === "pausedup" || s === "stoppeddl" || s === "stoppedup"
  ) return p >= 1 ? "completed" : "paused";
  return "other";
}

function filterTorrents(list, mode) {
  var rows = list || [];
  var want = mode || "active";
  if (want === "all") return rows.slice();
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    var bucket = classifyState(rows[i].state, rows[i].progress);
    if (want === "active" && (bucket === "downloading" || bucket === "seeding")) out.push(rows[i]);
    else if (want === "paused" && bucket === "paused") out.push(rows[i]);
    else if (want === "completed" && bucket === "completed") out.push(rows[i]);
  }
  return out;
}

function torrentId(row) {
  var r = row || {};
  var hash = String(r.hash || "");
  if (hash !== "") return hash;
  var v1 = String(r.infohash_v1 || "");
  if (v1 !== "") return v1;
  return String(r.infohash_v2 || "");
}

function magnetUriFor(row) {
  var uri = String((row && row.magnetUri) || "").trim();
  if (uri.indexOf("magnet:") === 0) return uri;
  var hash = torrentId(row || {});
  if (!hash) return "";
  return "magnet:?xt=urn:btih:" + hash;
}

function anyActive(list, pending) {
  return filterTorrents(excludePending(list, pending), "active").length > 0;
}

function isRealName(name, hash) {
  var n = String(name || "").trim();
  var h = String(hash || "").trim().toLowerCase();
  if (n === "") return false;
  if (h !== "" && n.toLowerCase() === h) return false;
  return true;
}

function pendingIdSet(pending) {
  var hashes = {};
  var p = pending || [];
  for (var i = 0; i < p.length; i++) {
    var id = typeof p[i] === "string" ? p[i] : torrentId(p[i]);
    if (!id && p[i] && typeof p[i] === "object") id = String(p[i].hash || "");
    if (id) hashes[String(id).toLowerCase()] = true;
  }
  return hashes;
}

function rowIsPending(row, hashes) {
  var ids = [
    torrentId(row),
    row && row.hash,
    row && row.infohash_v1,
    row && row.infohash_v2
  ];
  for (var i = 0; i < ids.length; i++) {
    var id = String(ids[i] || "").toLowerCase();
    if (id && hashes[id]) return true;
  }
  return false;
}

function excludePending(list, pending) {
  var hashes = pendingIdSet(pending);
  var rows = list || [];
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    if (!rowIsPending(rows[i], hashes)) out.push(rows[i]);
  }
  return out;
}

function pendingNeedsStop(state) {
  var bucket = classifyState(state, 0);
  return bucket === "downloading" || bucket === "seeding";
}

function magnetMoreWaiting(pendingLen, inboxLen) {
  var n = Number(pendingLen || 0) + Number(inboxLen || 0);
  if (!isFinite(n) || n <= 1) return 0;
  return n - 1;
}

function enqueueAction(queue, item) {
  return (queue || []).concat([item]);
}

// A queued action. origin is "window" only when asked for exactly; everything
// else is the bar widget, which keeps its actionStatus/lastError behaviour.
function makeActionItem(ticket, cmd, statusText, opts) {
  var o = opts || {};
  var hashes = [];
  if (Array.isArray(o.hashes)) {
    for (var i = 0; i < o.hashes.length; i++) if (o.hashes[i]) hashes.push(String(o.hashes[i]));
  }
  return {
    cmd: cmd,
    status: statusText || "",
    ticket: ticket,
    origin: o.origin === "window" ? "window" : "widget",
    hashes: hashes
  };
}

function shiftAction(queue) {
  var q = queue || [];
  if (q.length === 0) return { item: null, rest: [] };
  return { item: q[0], rest: q.slice(1) };
}

function formatSize(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n < 0) n = 0;
  var units = ["B", "KiB", "MiB", "GiB", "TiB"];
  var i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n = n / 1024;
    i++;
  }
  if (i === 0) return Math.round(n) + " B";
  return n.toFixed(1) + " " + units[i];
}

function formatRate(bytesPerSec) {
  return formatSize(bytesPerSec) + "/s";
}

function formatCompactRate(bytesPerSec) {
  var n = Number(bytesPerSec);
  if (!isFinite(n) || n < 0) n = 0;
  var units = ["K", "M", "G"];
  var v = n / 1024;
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v = v / 1024;
    i++;
  }
  var text = i === 0 || v >= 10 ? String(Math.round(v)) : v.toFixed(1);
  return text + units[i];
}

function barSpeedText(dlSpeed, upSpeed, active) {
  if (!active) return "";
  return "↓" + formatCompactRate(dlSpeed) + " ↑" + formatCompactRate(upSpeed);
}

function newlyCompleted(prevList, nextList) {
  var prev = prevList || [];
  var progressById = {};
  for (var i = 0; i < prev.length; i++) {
    progressById[torrentId(prev[i])] = Number(prev[i].progress || 0);
  }
  var names = [];
  var next = nextList || [];
  for (var j = 0; j < next.length; j++) {
    var id = torrentId(next[j]);
    if (Number(next[j].progress || 0) < 1) continue;
    if (!(id in progressById) || progressById[id] >= 1) continue;
    names.push(String(next[j].name || ""));
  }
  return names;
}

function completionText(names) {
  var list = names || [];
  if (list.length === 0) return "";
  if (list.length === 1) return plainText(list[0]) + " finished downloading";
  return list.length + " torrents finished downloading";
}

var SORT_ORDER = ["default", "speed", "eta", "added"];
var SORT_LABELS = { default: "", speed: "by speed", eta: "by eta", added: "by added" };

// Every field mode's natural (desc=false) direction. true means the mode's
// default order is largest/newest-first; false means smallest/soonest-first.
// T7 draws the sorted column's ▾/▴ from this plus the caller's `desc`.
var SORT_FIELD_DESC_DEFAULT = {
  added: true,
  name: false,
  size: true,
  progress: false,
  dl: true,
  ul: true,
  eta: false,
  ratio: true
};

var SORT_FIELD_MODES = {
  added: true, name: true, size: true, progress: true,
  dl: true, ul: true, eta: true, ratio: true
};

// Every mode tie-breaks on hash ascending (never flipped by desc), so the
// result is deterministic even when rows share a value.
function hashAsc(a, b) {
  var ha = String((a && a.hash) || "");
  var hb = String((b && b.hash) || "");
  if (ha === hb) return 0;
  return ha < hb ? -1 : 1;
}

function etaSortValue(row) {
  var e = Number((row && row.eta) || 0);
  if (!isFinite(e) || e <= 0 || e >= 8640000) return Infinity;
  return e;
}

function sortFieldValue(mode, row) {
  var r = row || {};
  if (mode === "added") return Number(r.addedOn || 0);
  if (mode === "size") return Number(r.size || 0);
  if (mode === "progress") {
    var p = Number(r.progress);
    return isFinite(p) ? p : 0;
  }
  if (mode === "dl") return Number(r.dlSpeed || 0);
  if (mode === "ul") return Number(r.upSpeed || 0);
  if (mode === "ratio") return Number(r.ratio || 0);
  if (mode === "eta") return etaSortValue(r);
  return 0;
}

function nameAsc(a, b) {
  var na = String((a && a.name) || "").toLowerCase();
  var nb = String((b && b.name) || "").toLowerCase();
  // Codepoint compare, not localeCompare: Node's ICU and QML's V4 can order
  // the same strings differently, and this must be deterministic everywhere.
  if (na === nb) return 0;
  return na < nb ? -1 : 1;
}

function fieldSortComparator(mode, desc) {
  var naturalDesc = SORT_FIELD_DESC_DEFAULT[mode] === true;
  return function(a, b) {
    var diff;
    if (mode === "name") {
      diff = nameAsc(a, b);
    } else {
      var va = sortFieldValue(mode, a);
      var vb = sortFieldValue(mode, b);
      diff = va === vb ? 0 : (va < vb ? -1 : 1);
    }
    if (naturalDesc) diff = -diff;
    if (desc) diff = -diff;
    if (diff === 0) return hashAsc(a, b);
    return diff;
  };
}

// sortTorrents(list, mode, desc).
//
// Modes: "added" (newest first; also the default when mode is falsy), "name",
// "size", "progress", "dl", "ul", "eta" and "ratio". `desc` flips whichever
// direction is natural for that mode. Every mode tie-breaks on hash ascending.
//
// "default" and "speed" are kept only so the widget's existing
// sortTorrents(list, "default"|"speed"|"eta"|"added") call sites keep
// producing exactly today's orders: "default" returns the list untouched
// (exempt from the hash tie-break -- it must stay a plain unsorted copy),
// and "speed" sorts on the dl+ul sum, same as before. Any other unrecognized
// mode string also falls back to an untouched copy, matching the old
// if/else chain's behavior for a mode it didn't know.
function sortTorrents(list, mode, desc) {
  var rows = (list || []).slice();
  var m = mode;
  if (!m) m = "added";
  if (m === "default") return rows;
  if (m === "speed") {
    rows.sort(function(a, b) {
      var diff = (Number(b.dlSpeed || 0) + Number(b.upSpeed || 0)) - (Number(a.dlSpeed || 0) + Number(a.upSpeed || 0));
      if (desc) diff = -diff;
      if (diff === 0) return hashAsc(a, b);
      return diff;
    });
    return rows;
  }
  if (SORT_FIELD_MODES[m] === true) {
    rows.sort(fieldSortComparator(m, desc));
    return rows;
  }
  return rows;
}

function cycleSort(mode) {
  var i = SORT_ORDER.indexOf(String(mode));
  if (i === -1) return SORT_ORDER[1];
  return SORT_ORDER[(i + 1) % SORT_ORDER.length];
}

function sortLabel(mode) {
  var label = SORT_LABELS[String(mode)];
  return label == null ? "" : label;
}

// --- Table diffing: diffRows / applyOps -------------------------------------
//
// applyOps(rows, ops) is the executable contract T7 follows against a QML
// ListModel: {op:"set",index,row} -> list.set(index,row), {op:"insert"} ->
// list.insert(index,row), {op:"remove"} -> list.remove(index), and
// {op:"move",from,to} -> list.move(from,to,1). Every index means "the array
// state at the moment this op is applied", in the order the ops appear.

function rowHash(row) {
  return String((row && row.hash) || "");
}

function applyOps(rows, ops) {
  var working = (rows || []).slice();
  var list = ops || [];
  for (var i = 0; i < list.length; i++) {
    var op = list[i] || {};
    if (op.op === "set") {
      if (op.index < 0 || op.index >= working.length) {
        throw new Error("applyOps: set index " + op.index + " out of range");
      }
      working[op.index] = op.row;
    } else if (op.op === "insert") {
      if (op.index < 0 || op.index > working.length) {
        throw new Error("applyOps: insert index " + op.index + " out of range");
      }
      working.splice(op.index, 0, op.row);
    } else if (op.op === "remove") {
      if (op.index < 0 || op.index >= working.length) {
        throw new Error("applyOps: remove index " + op.index + " out of range");
      }
      working.splice(op.index, 1);
    } else if (op.op === "move") {
      if (op.from < 0 || op.from >= working.length) {
        throw new Error("applyOps: move from " + op.from + " out of range");
      }
      var item = working.splice(op.from, 1)[0];
      if (op.to < 0 || op.to > working.length) {
        throw new Error("applyOps: move to " + op.to + " out of range");
      }
      working.splice(op.to, 0, item);
    } else {
      throw new Error("applyOps: unknown op " + JSON.stringify(op));
    }
  }
  return working;
}

function fieldsChanged(oldRow, newRow, fields) {
  var flds = fields || [];
  for (var i = 0; i < flds.length; i++) {
    var f = flds[i];
    var ov = oldRow ? oldRow[f] : undefined;
    var nv = newRow ? newRow[f] : undefined;
    if (Array.isArray(ov) || Array.isArray(nv)) {
      var oa = Array.isArray(ov) ? ov : [];
      var na = Array.isArray(nv) ? nv : [];
      if (oa.length !== na.length) return true;
      for (var j = 0; j < oa.length; j++) {
        if (oa[j] !== na[j]) return true;
      }
    } else if (ov !== nv) {
      return true;
    }
  }
  return false;
}

// One longest increasing subsequence of `seq` (any valid LIS; not
// necessarily unique), returned as the sorted array of indices into `seq`
// that belong to it. O(n log n).
function longestIncreasingSubsequenceIndices(seq) {
  var n = seq.length;
  var predecessors = new Array(n);
  var tailsIndices = [];
  for (var i = 0; i < n; i++) {
    var v = seq[i];
    var lo = 0, hi = tailsIndices.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (seq[tailsIndices[mid]] < v) lo = mid + 1;
      else hi = mid;
    }
    predecessors[i] = lo > 0 ? tailsIndices[lo - 1] : -1;
    tailsIndices[lo] = i;
  }
  var result = [];
  var k = tailsIndices.length ? tailsIndices[tailsIndices.length - 1] : -1;
  while (k !== -1) {
    result.push(k);
    k = predecessors[k];
  }
  result.reverse();
  return result;
}

// diffRows(oldRows, newRows, fields) -> ops | {reset:true}.
//
// Rows are keyed by `hash`; `fields` are the displayed fields to compare
// (arrays, e.g. `tags`, compare element-wise). A duplicate hash in either
// list makes a keyed diff undefined, so it resets.
//
// Emits, in this order: removes (old array, back to front), moves (only the
// survivors NOT on a longest-increasing-subsequence anchor set, so a row
// that travels far doesn't drag a "move" out of every row it passes),
// inserts (new-only rows, walked left to right), then sets (changed
// fields, left to right). Bails to {reset:true} the instant the op count
// would exceed max(8, newRows.length/2).
function diffRows(oldRows, newRows, fields) {
  var old = oldRows || [];
  var next = newRows || [];
  var threshold = Math.max(8, next.length / 2);
  var ops = [];

  function overBudget() {
    return ops.length > threshold;
  }

  var oldIndexByHash = {};
  for (var i = 0; i < old.length; i++) {
    var oh = rowHash(old[i]);
    if (Object.prototype.hasOwnProperty.call(oldIndexByHash, oh)) return { reset: true };
    oldIndexByHash[oh] = i;
  }
  var newIndexByHash = {};
  for (var i = 0; i < next.length; i++) {
    var nh = rowHash(next[i]);
    if (Object.prototype.hasOwnProperty.call(newIndexByHash, nh)) return { reset: true };
    newIndexByHash[nh] = i;
  }

  // Phase 1: remove old rows that don't survive into `next`, back to front
  // against a live copy so every index is valid at the moment it's used.
  var cur = old.slice();
  for (var i = cur.length - 1; i >= 0; i--) {
    if (!Object.prototype.hasOwnProperty.call(newIndexByHash, rowHash(cur[i]))) {
      ops.push({ op: "remove", index: i });
      cur.splice(i, 1);
      if (overBudget()) return { reset: true };
    }
  }
  // cur == survivors, in old relative order.

  // Phase 2: reorder survivors to match their relative order in `next`.
  var survivorsByNewOrder = cur.slice().sort(function(a, b) {
    return newIndexByHash[rowHash(a)] - newIndexByHash[rowHash(b)];
  });
  var oldPosByHash = {};
  for (var i = 0; i < cur.length; i++) oldPosByHash[rowHash(cur[i])] = i;
  var seq = survivorsByNewOrder.map(function(row) { return oldPosByHash[rowHash(row)]; });
  var anchorIdx = longestIncreasingSubsequenceIndices(seq);
  var isAnchor = {};
  for (var i = 0; i < anchorIdx.length; i++) isAnchor[anchorIdx[i]] = true;

  for (var i = survivorsByNewOrder.length - 1; i >= 0; i--) {
    if (isAnchor[i]) continue;
    var row = survivorsByNewOrder[i];
    var h = rowHash(row);
    var from = -1;
    for (var j = 0; j < cur.length; j++) {
      if (rowHash(cur[j]) === h) { from = j; break; }
    }
    cur.splice(from, 1);
    var to;
    if (i === survivorsByNewOrder.length - 1) {
      to = cur.length;
    } else {
      var nextHash = rowHash(survivorsByNewOrder[i + 1]);
      to = -1;
      for (var k = 0; k < cur.length; k++) {
        if (rowHash(cur[k]) === nextHash) { to = k; break; }
      }
    }
    cur.splice(to, 0, row);
    ops.push({ op: "move", from: from, to: to });
    if (overBudget()) return { reset: true };
  }
  // cur now holds only the survivors, in `next`'s relative order (with
  // stale field values) -- `cur` isn't touched again; phases 3 and 4 work
  // directly off `next`'s indices, which is safe because inserting only the
  // missing (new-only) hashes at their exact target index, left to right,
  // is enough to turn a correctly-ordered subsequence into the full list.

  // Phase 3: insert new-only rows at their final index, walking `next` left
  // to right (a correctly-ordered subsequence only needs the gaps filled).
  for (var i = 0; i < next.length; i++) {
    var h2 = rowHash(next[i]);
    if (!Object.prototype.hasOwnProperty.call(oldIndexByHash, h2)) {
      ops.push({ op: "insert", index: i, row: next[i] });
      if (overBudget()) return { reset: true };
    }
  }

  // Phase 4: set changed fields on survivors.
  for (var i = 0; i < next.length; i++) {
    var h3 = rowHash(next[i]);
    if (Object.prototype.hasOwnProperty.call(oldIndexByHash, h3)) {
      var oldRow = old[oldIndexByHash[h3]];
      if (fieldsChanged(oldRow, next[i], fields)) {
        ops.push({ op: "set", index: i, row: next[i] });
        if (overBudget()) return { reset: true };
      }
    }
  }

  return ops;
}

// --- Filter sidebar: filterGroups / matchFilter / statusGroup ---------------
//
// statusGroup buckets a row the same way the table's state glyph does:
// downloading, seeding, stopped, errored, checking. It layers a
// checking-or-moving carve-out on top of classifyState (whose buckets fold
// checkingDL/checkingUP into downloading/seeding and checkingResumeData into
// "other") because the design's glyph table gives checking/moving states
// their own glyph, distinct from downloading/seeding.
function statusGroup(row) {
  var r = row || {};
  var s = normalizeState(r.state);
  if (s.indexOf("checking") === 0 || s === "moving") return "checking";
  var bucket = classifyState(r.state, r.progress);
  if (bucket === "error") return "errored";
  if (bucket === "downloading") return "downloading";
  if (bucket === "seeding") return "seeding";
  return "stopped"; // paused, completed, and any other unclassified state
}

var STATUS_ITEM_LABELS = ["All", "Active", "Downloading", "Seeding", "Stopped", "Errored", "Checking"];

function statusItemMatches(label, row) {
  if (label === "All") return true;
  var g = statusGroup(row);
  if (label === "Active") return g === "downloading" || g === "seeding";
  if (label === "Downloading") return g === "downloading";
  if (label === "Seeding") return g === "seeding";
  if (label === "Stopped") return g === "stopped";
  if (label === "Errored") return g === "errored";
  if (label === "Checking") return g === "checking";
  return false;
}

function makeFilterItem(group, value, label, count) {
  return { group: group, value: value, label: label, count: count, zero: count === 0 };
}

function countRows(rows, predicate) {
  var n = 0;
  for (var i = 0; i < rows.length; i++) {
    if (predicate(rows[i])) n++;
  }
  return n;
}

function caseInsensitiveAsc(a, b) {
  var la = String(a).toLowerCase();
  var lb = String(b).toLowerCase();
  if (la === lb) return 0;
  return la < lb ? -1 : 1;
}

// filterGroups(rows, categories, tags) -> [{group, items:[{group,value,label,count,zero}]}].
//
// `categories` and `tags` are the top-level lists from Status
// (parseStatusJson's `categories`/`tags`, both arrays of name strings) --
// the authoritative source for zero-count entries, unioned with whatever
// rows carry. Sentinel entries (Uncategorized/Untagged/Trackerless) use
// value:"" -- never the label string -- so a real category/tag/tracker
// named e.g. "Uncategorized" can't collide with the sentinel, and
// matchFilter needs no special case: value:"" already equals what an
// unset row.category/tracker/[] tags compares as.
function filterGroups(rows, categories, tags) {
  var list = rows || [];
  var i;

  var statusItems = [];
  for (i = 0; i < STATUS_ITEM_LABELS.length; i++) {
    var label = STATUS_ITEM_LABELS[i];
    var count = countRows(list, function(row) { return statusItemMatches(label, row); });
    statusItems.push(makeFilterItem("status", label, label, count));
  }

  var categoryNames = {};
  for (i = 0; i < (categories || []).length; i++) categoryNames[String(categories[i])] = true;
  for (i = 0; i < list.length; i++) {
    var c = String(list[i].category || "");
    if (c !== "") categoryNames[c] = true;
  }
  var sortedCategoryNames = Object.keys(categoryNames).sort(caseInsensitiveAsc);
  var categoryItems = [
    makeFilterItem("categories", "", "Uncategorized", countRows(list, function(row) { return String(row.category || "") === ""; }))
  ];
  for (i = 0; i < sortedCategoryNames.length; i++) {
    var catName = sortedCategoryNames[i];
    categoryItems.push(makeFilterItem("categories", catName, catName, countRows(list, function(row) { return String(row.category || "") === catName; })));
  }

  var tagNames = {};
  for (i = 0; i < (tags || []).length; i++) tagNames[String(tags[i])] = true;
  for (i = 0; i < list.length; i++) {
    var rowTags = Array.isArray(list[i].tags) ? list[i].tags : [];
    for (var j = 0; j < rowTags.length; j++) tagNames[String(rowTags[j])] = true;
  }
  var sortedTagNames = Object.keys(tagNames).sort(caseInsensitiveAsc);
  var tagItems = [
    makeFilterItem("tags", "", "Untagged", countRows(list, function(row) { return !Array.isArray(row.tags) || row.tags.length === 0; }))
  ];
  for (i = 0; i < sortedTagNames.length; i++) {
    var tagName = sortedTagNames[i];
    tagItems.push(makeFilterItem("tags", tagName, tagName, countRows(list, function(row) {
      return Array.isArray(row.tags) && row.tags.indexOf(tagName) !== -1;
    })));
  }

  var trackerNames = {};
  for (i = 0; i < list.length; i++) {
    var t = String(list[i].tracker || "");
    if (t !== "") trackerNames[t] = true;
  }
  var sortedTrackerNames = Object.keys(trackerNames).sort(caseInsensitiveAsc);
  var trackerItems = [
    makeFilterItem("trackers", "", "Trackerless", countRows(list, function(row) { return String(row.tracker || "") === ""; }))
  ];
  for (i = 0; i < sortedTrackerNames.length; i++) {
    var host = sortedTrackerNames[i];
    trackerItems.push(makeFilterItem("trackers", host, host, countRows(list, function(row) { return String(row.tracker || "") === host; })));
  }

  return [
    { group: "status", items: statusItems },
    { group: "categories", items: categoryItems },
    { group: "tags", items: tagItems },
    { group: "trackers", items: trackerItems }
  ];
}

// matchFilter(row, filter) where filter is {group, value}. A missing or
// unrecognized group fails open (matches everything), the same as the
// default "All" filter.
function matchFilter(row, filter) {
  var f = filter || {};
  var group = f.group;
  var value = f.value;
  if (group === "status") return statusItemMatches(String(value), row);
  if (group === "categories") return String((row && row.category) || "") === String(value || "");
  if (group === "tags") {
    var rowTags = Array.isArray(row && row.tags) ? row.tags : [];
    if (!value) return rowTags.length === 0;
    return rowTags.indexOf(String(value)) !== -1;
  }
  if (group === "trackers") return String((row && row.tracker) || "") === String(value || "");
  return true;
}

function filterByQuery(list, query) {
  var q = String(query || "").trim().toLowerCase();
  var rows = list || [];
  if (q === "") return rows.slice();
  var out = [];
  for (var i = 0; i < rows.length; i++) {
    if (String(rows[i].name || "").toLowerCase().indexOf(q) !== -1) out.push(rows[i]);
  }
  return out;
}

function listQuery(fieldText) {
  var s = String(fieldText || "").trim();
  if (s === "" || isAddableTarget(s)) return "";
  return s;
}

function formatDate(epochSec) {
  var n = Number(epochSec);
  if (!isFinite(n) || n <= 0) return "—";
  return new Date(n * 1000).toISOString().slice(0, 10);
}

var LIMIT_ORDER = [0, 8388608, 4194304, 1048576, 262144];

function cycleLimit(bytesPerSec) {
  var i = LIMIT_ORDER.indexOf(Number(bytesPerSec));
  if (i === -1) return Number(bytesPerSec) < 0 ? LIMIT_ORDER[1] : 0;
  return LIMIT_ORDER[(i + 1) % LIMIT_ORDER.length];
}

function limitLabel(bytesPerSec) {
  var n = Number(bytesPerSec);
  if (!isFinite(n) || n <= 0) return "∞";
  if (n >= 1048576) return (n / 1048576).toFixed(1) + "M/s";
  return Math.round(n / 1024) + "K/s";
}

var RATIO_ORDER = [-2, 1, 2, -1];

function cycleRatioLimit(ratio) {
  var i = RATIO_ORDER.indexOf(Number(ratio));
  if (i === -1) return -1;
  return RATIO_ORDER[(i + 1) % RATIO_ORDER.length];
}

function ratioLimitLabel(ratio) {
  var n = Number(ratio);
  if (n === -2) return "global";
  if (n === -1 || !isFinite(n)) return "none";
  return n.toFixed(1);
}

function vpnUnbound(status) {
  var s = status || {};
  if (s.daemon !== true || s.api !== true) return false;
  var vpn = String(s.vpnIface || "");
  if (vpn === "") return false;
  return String(s.bindIface || "") !== vpn;
}

function formatEta(seconds) {
  var n = Number(seconds);
  if (!isFinite(n) || n < 0 || n >= 8640000) return "—";
  if (n < 60) return Math.round(n) + "s";
  if (n < 3600) return Math.round(n / 60) + "m";
  if (n < 86400) return Math.round(n / 3600) + "h";
  return Math.round(n / 86400) + "d";
}

function formatPercent(progress) {
  var n = Number(progress);
  if (!isFinite(n)) n = 0;
  return Math.round(n * 100) + "%";
}

function plainText(text) {
  // PanelHero renders its title with Text.AutoText, which promotes any string
  // containing markup to rich text (so <img src=…> would trigger a network
  // fetch). Torrent names are attacker-controlled, so strip the angle brackets
  // that Qt's rich-text heuristic keys on before the name reaches the hero.
  return String(text || "").replace(/[<>]/g, "");
}

function isAddableUrl(text) {
  var s = String(text || "").trim();
  if (s.indexOf("magnet:") === 0) return true;
  if (!/^https?:\/\//i.test(s)) return false;
  var path = s.split("?")[0].split("#")[0];
  return /\.torrent$/i.test(path);
}

function isAddableFile(text) {
  var s = String(text || "").trim();
  if (s.indexOf("file://") === 0) s = s.substring(7);
  if (!/\.torrent$/i.test(s)) return false;
  return s.indexOf("/") === 0 || s.indexOf("~/") === 0;
}

function isAddableTarget(text) {
  return isAddableUrl(text) || isAddableFile(text);
}

var PRIORITY_ORDER = [0, 1, 6, 7];
var PRIORITY_LABELS = { 0: "Skip", 1: "Low", 6: "Normal", 7: "High" };

function priorityLabel(value) {
  var n = parseInt(String(value), 10);
  return PRIORITY_LABELS[n] || "Low";
}

function cyclePriority(value) {
  var n = parseInt(String(value), 10);
  var i = PRIORITY_ORDER.indexOf(n);
  if (i === -1) return 1;
  return PRIORITY_ORDER[(i + 1) % PRIORITY_ORDER.length];
}

function emptyStatus() {
  return {
    ok: false,
    installed: false,
    daemon: false,
    lockHolder: "none",
    api: false,
    altSpeed: false,
    dlSpeed: 0,
    upSpeed: 0,
    torrents: [],
    vpnIface: "",
    bindIface: "",
    categories: [],
    tags: [],
    error: ""
  };
}

function parseStatusJson(raw) {
  var parsed;
  try {
    parsed = JSON.parse(String(raw || ""));
  } catch (e) {
    return emptyStatus();
  }
  if (!parsed || typeof parsed !== "object") return emptyStatus();
  var rows = parsed.torrents || [];
  var torrents = [];
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {};
    var id = torrentId(row);
    torrents.push({
      hash: id,
      name: String(row.name || ""),
      state: String(row.state || ""),
      progress: Number(row.progress || 0),
      dlSpeed: Number(row.dlSpeed || 0),
      upSpeed: Number(row.upSpeed || 0),
      eta: Number(row.eta || 0),
      ratio: Number(row.ratio || 0),
      size: Number(row.size || 0),
      savePath: String(row.savePath || ""),
      magnetUri: String(row.magnetUri || ""),
      contentPath: String(row.contentPath || ""),
      numSeeds: Number(row.numSeeds || 0),
      numLeechs: Number(row.numLeechs || 0),
      addedOn: Number(row.addedOn || 0),
      dlLimit: Number(row.dlLimit || 0),
      upLimit: Number(row.upLimit || 0),
      seqDl: row.seqDl === true,
      ratioLimit: row.ratioLimit == null ? -2 : Number(row.ratioLimit),
      category: String(row.category || ""),
      tags: Array.isArray(row.tags) ? row.tags : [],
      tracker: String(row.tracker || ""),
      bucket: classifyState(row.state, row.progress)
    });
  }
  return {
    ok: true,
    installed: parsed.installed === true,
    daemon: parsed.daemon === true,
    lockHolder: String(parsed.lockHolder || "none"),
    api: parsed.api === true,
    altSpeed: parsed.altSpeed === true,
    dlSpeed: Number(parsed.dlSpeed || 0),
    upSpeed: Number(parsed.upSpeed || 0),
    torrents: torrents,
    vpnIface: String(parsed.vpnIface || ""),
    bindIface: String(parsed.bindIface || ""),
    categories: Array.isArray(parsed.categories) ? parsed.categories : [],
    tags: Array.isArray(parsed.tags) ? parsed.tags : [],
    error: String(parsed.error || "")
  };
}

function sanitizeError(raw) {
  return String(raw || "")
    .replace(/SID=[^;\s]*/gi, "")
    .replace(/password=[^;\s]*/gi, "")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
}

function nextStatusError(parsed, current) {
  var status = parsed || {};
  if (status.error) return String(status.error);
  if (status.ok && status.installed && status.daemon && status.api) return "";
  return String(current || "");
}

function installCommand(stdinIsTty) {
  if (stdinIsTty) return ["omarchy", "pkg", "add", "qbittorrent-nox"];
  return ["pkexec", "omarchy", "pkg", "add", "qbittorrent-nox"];
}

function parseServeLine(line) {
  var raw = String(line || "");
  var data = null;
  var type = "invalid";

  try {
    var parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { type: "invalid", raw: raw, data: null };
    }

    var t = String(parsed.type || "");
    if (t === "status" || t === "files" || t === "heartbeat" || t === "fatal" || t === "error") {
      type = t;
      data = parsed;
    }
    // else type stays "invalid" and data stays null
  } catch (e) {
    // JSON parse failed, type stays "invalid"
  }

  return { type: type, raw: raw, data: data };
}

function cadenceMs(magnetWatching, refreshIntervalSec) {
  if (magnetWatching) return 250;

  var n = parseInt(String(refreshIntervalSec), 10);
  if (!isFinite(n)) n = 5;
  if (n < 5) n = 5;
  if (n > 3600) n = 3600;

  return n * 1000;
}

function heartbeatExpired(lastBeatMs, nowMs, intervalMs) {
  var interval = intervalMs || 5000;
  return nowMs - lastBeatMs > 2 * interval;
}

function nextBackoffMs(failures) {
  var f = Number(failures);
  if (!isFinite(f) || f <= 0) return 0;
  return Math.min(1000 * Math.pow(2, f - 1), 30000);
}

function sidecarGaveUp(failures) {
  return Number(failures) >= 5;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    classifyState: classifyState,
    filterTorrents: filterTorrents,
    torrentId: torrentId,
    magnetUriFor: magnetUriFor,
    anyActive: anyActive,
    isRealName: isRealName,
    excludePending: excludePending,
    pendingNeedsStop: pendingNeedsStop,
    magnetMoreWaiting: magnetMoreWaiting,
    enqueueAction: enqueueAction,
    makeActionItem: makeActionItem,
    shiftAction: shiftAction,
    formatSize: formatSize,
    formatRate: formatRate,
    formatCompactRate: formatCompactRate,
    barSpeedText: barSpeedText,
    newlyCompleted: newlyCompleted,
    completionText: completionText,
    vpnUnbound: vpnUnbound,
    sortTorrents: sortTorrents,
    cycleSort: cycleSort,
    sortLabel: sortLabel,
    SORT_FIELD_DESC_DEFAULT: SORT_FIELD_DESC_DEFAULT,
    applyOps: applyOps,
    diffRows: diffRows,
    statusGroup: statusGroup,
    filterGroups: filterGroups,
    matchFilter: matchFilter,
    filterByQuery: filterByQuery,
    listQuery: listQuery,
    formatDate: formatDate,
    cycleLimit: cycleLimit,
    limitLabel: limitLabel,
    cycleRatioLimit: cycleRatioLimit,
    ratioLimitLabel: ratioLimitLabel,
    formatEta: formatEta,
    formatPercent: formatPercent,
    plainText: plainText,
    isAddableUrl: isAddableUrl,
    isAddableFile: isAddableFile,
    isAddableTarget: isAddableTarget,
    priorityLabel: priorityLabel,
    cyclePriority: cyclePriority,
    parseStatusJson: parseStatusJson,
    sanitizeError: sanitizeError,
    nextStatusError: nextStatusError,
    installCommand: installCommand,
    parseServeLine: parseServeLine,
    cadenceMs: cadenceMs,
    heartbeatExpired: heartbeatExpired,
    nextBackoffMs: nextBackoffMs,
    sidecarGaveUp: sidecarGaveUp
  };
}

