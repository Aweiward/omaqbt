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

function anyActive(list) {
  return filterTorrents(list, "active").length > 0;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    classifyState: classifyState,
    filterTorrents: filterTorrents,
    torrentId: torrentId,
    anyActive: anyActive
  };
}
