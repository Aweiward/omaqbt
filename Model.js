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
    dlSpeed: 0,
    upSpeed: 0,
    torrents: [],
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
      bucket: classifyState(row.state, row.progress)
    });
  }
  return {
    ok: true,
    installed: parsed.installed === true,
    daemon: parsed.daemon === true,
    lockHolder: String(parsed.lockHolder || "none"),
    api: parsed.api === true,
    dlSpeed: Number(parsed.dlSpeed || 0),
    upSpeed: Number(parsed.upSpeed || 0),
    torrents: torrents,
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
    formatEta: formatEta,
    formatPercent: formatPercent,
    plainText: plainText,
    isAddableUrl: isAddableUrl,
    priorityLabel: priorityLabel,
    cyclePriority: cyclePriority,
    parseStatusJson: parseStatusJson,
    sanitizeError: sanitizeError,
    nextStatusError: nextStatusError,
    installCommand: installCommand
  };
}

