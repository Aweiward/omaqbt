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

function sortTorrents(list, mode) {
  var rows = (list || []).slice();
  if (mode === "speed") {
    rows.sort(function(a, b) {
      return (Number(b.dlSpeed || 0) + Number(b.upSpeed || 0)) - (Number(a.dlSpeed || 0) + Number(a.upSpeed || 0));
    });
  } else if (mode === "eta") {
    rows.sort(function(a, b) {
      var ea = Number(a.eta || 0);
      var eb = Number(b.eta || 0);
      if (ea <= 0 || ea >= 8640000) ea = Infinity;
      if (eb <= 0 || eb >= 8640000) eb = Infinity;
      if (ea === eb) return 0;
      return ea < eb ? -1 : 1;
    });
  } else if (mode === "added") {
    rows.sort(function(a, b) {
      return Number(b.addedOn || 0) - Number(a.addedOn || 0);
    });
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
      contentPath: String(row.contentPath || ""),
      numSeeds: Number(row.numSeeds || 0),
      numLeechs: Number(row.numLeechs || 0),
      addedOn: Number(row.addedOn || 0),
      dlLimit: Number(row.dlLimit || 0),
      upLimit: Number(row.upLimit || 0),
      seqDl: row.seqDl === true,
      ratioLimit: row.ratioLimit == null ? -2 : Number(row.ratioLimit),
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

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    classifyState: classifyState,
    filterTorrents: filterTorrents,
    torrentId: torrentId,
    anyActive: anyActive,
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
    installCommand: installCommand
  };
}

