.pragma library

// Pure rules for per-torrent limits (slice 3b): the input parsers, the Info
// tab's six Limits rows, the effective share limits and action, the D8
// share-limit confirm and the done notes. No I/O, no Date, no Qt objects:
// everything comes in through arguments, so tests/limits-view.test.js can
// run it in node. It imports nothing.
//
// The `.pragma library` line above is QML-only. The node test strips it
// and runs this file in a vm context (see the test's loader), because node
// can't parse it and QML can't `require`.
//
// Input rules (D5, D12). Every parser takes the text exactly as typed: no
// trimming, ASCII digits only, no signs other than a literal -2/-1, no
// leading zeros ("01"), no exponents. Letters are case-insensitive.
// - Speed: a number with an optional K (KiB/s) or M (MiB/s); a bare number
//   is KiB/s. Up to 2 decimals ("1.5M", "0.5K"), rounded to the nearest
//   whole byte; more decimals get "Use at most 2 decimals.", as for the
//   ratio. "0" (in any unit) or "u" is 0, unlimited. At most exactly
//   2047 MiB/s (2146435072 bytes/s), as the message says, which stays under
//   qBittorrent's INT_MAX bytes/s; "2047.01M" is refused.
// - Ratio: 0-9998 with at most 2 decimals; "g" (or -2) is default, "n" (or
//   -1) is none. The accepted non-letter forms are exactly qbt's wire forms
//   (tests/fixtures/validation-cases.json), so String(ratio) is sendable.
// - Seed time: a whole number with an optional m, h or d; a bare number is
//   minutes, as on the wire. At most 525600 minutes (365d). "g"/"n" as for
//   the ratio. No decimals and no compound forms ("2h30m").
// - For both the ratio and the seed time, the literal text "-2" and "-1"
//   is accepted too, as the same -2 (default) and -1 (none) as "g"/"n";
//   no other signed text is.
//
// Effective values. -2 (a limit) and "Default" (the action) resolve like
// qBittorrent 5.2.3 and qbt's share-limits jq: the torrent's own value, else
// its category, else each parent category ("a/b/c" -> "a/b" -> "a"), else
// status.shareDefaults. A category missing from status.categoryLimits
// defers to its parent. The chain stops at the first non-default value,
// including -1 and 0 (both real). Where qbt fails closed on a malformed
// value (a non-number limit, a non-string action) this module treats it as
// "default" and moves on, and a missing shareDefaults reads as none/Stop;
// qbt's fresh read stays the real gate (Ruling CE).
//
// Display vs prediction. For DISPLAY (limitRows), a deferred value shows
// the row's maxRatio/maxSeedingTime, qBittorrent's own resolved values, and
// uses the chain only when those are missing. For PREDICTION (shareConfirm)
// both limits, the changed one and the kept one, resolve through the chain
// from status, which is exactly what qbt's guard reads, so the window's
// confirm and qbt's refusal agree.
//
// Readiness (Ruling CG): shareConfirm never throws on a status without
// categoryLimits or shareDefaults, but its answer is only as good as
// those; the caller gates share-limit edits on LibraryView.libraryReady.

// --- Small helpers (private) -------------------------------------------------

// A list from a JS array or an array-like (a QML sequence can fail
// Array.isArray); anything else is empty.
function listOf(list) {
  if (Array.isArray(list)) return list;
  if (list && typeof list === "object" && typeof list.length === "number") return Array.prototype.slice.call(list);
  return [];
}

function isNumber(v) {
  return typeof v === "number" && isFinite(v);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

// "1.50" -> "1.5", "2.00" -> "2": at most 2 decimals, no trailing zeros.
function trimmed(n) {
  return String(Number(Number(n).toFixed(2)));
}

// --- Parsers -------------------------------------------------------------------

var SPEED_ERROR = "Use a number with K or M, or 0.";
var SPEED_CAP_ERROR = "Use at most 2047 MiB/s.";
var SPEED_CAP_BYTES = 2047 * 1048576;
var RATIO_ERROR = "Use a ratio like 1.5, g for default or n for none.";
var DECIMALS_ERROR = "Use at most 2 decimals.";
var RATIO_DECIMALS_ERROR = DECIMALS_ERROR;
var RATIO_CAP_ERROR = "Use at most 9998.";
var RATIO_CAP = 9998;
var SEED_ERROR = "Use a time like 90m, 2h or 3d, g for default or n for none.";
var SEED_CAP_ERROR = "Use at most 365d.";
var SEED_CAP_MINUTES = 525600;

function textOf(text) {
  return text === null || text === undefined ? "" : String(text);
}

// parseSpeed(text) -> {bytes} (0 = unlimited) or {error}.
function parseSpeed(text) {
  var s = textOf(text);
  if (s === "u" || s === "U") return { bytes: 0 };
  var m = /^(0|[1-9][0-9]*)(?:\.([0-9]+))?([kKmM])?$/.exec(s);
  if (!m) return { error: SPEED_ERROR };
  if (m[2] !== undefined && m[2].length > 2) return { error: DECIMALS_ERROR };
  var unit = m[3] === "m" || m[3] === "M" ? 1048576 : 1024;
  var frac = m[2] === undefined ? 0 : Number((m[2] + "0").slice(0, 2));
  var hundredths = Number(m[1]) * 100 + frac;
  var bytes = Math.round(hundredths * unit / 100);
  if (!(bytes <= SPEED_CAP_BYTES)) return { error: SPEED_CAP_ERROR };
  return { bytes: bytes };
}

// parseRatio(text) -> {ratio} (-2 default, -1 none) or {error}.
function parseRatio(text) {
  var s = textOf(text);
  if (s === "g" || s === "G" || s === "-2") return { ratio: -2 };
  if (s === "n" || s === "N" || s === "-1") return { ratio: -1 };
  var m = /^(0|[1-9][0-9]*)(?:\.([0-9]+))?$/.exec(s);
  if (!m) return { error: RATIO_ERROR };
  if (m[2] !== undefined && m[2].length > 2) return { error: RATIO_DECIMALS_ERROR };
  var ratio = Number(s);
  if (!(ratio <= RATIO_CAP)) return { error: RATIO_CAP_ERROR };
  return { ratio: ratio };
}

var SEED_UNITS = { "": 1, m: 1, h: 60, d: 1440 };

// parseSeedTime(text) -> {minutes} (-2 default, -1 none) or {error}.
function parseSeedTime(text) {
  var s = textOf(text);
  if (s === "g" || s === "G" || s === "-2") return { minutes: -2 };
  if (s === "n" || s === "N" || s === "-1") return { minutes: -1 };
  var m = /^(0|[1-9][0-9]*)([mMhHdD])?$/.exec(s);
  if (!m) return { error: SEED_ERROR };
  var minutes = Number(m[1]) * SEED_UNITS[(m[2] || "").toLowerCase()];
  if (!(minutes <= SEED_CAP_MINUTES)) return { error: SEED_CAP_ERROR };
  return { minutes: minutes };
}

// --- Formatting ------------------------------------------------------------------

// formatSpeed(bytes) -> "unlimited", "10 B/s", "500 KiB/s", "1.5 MiB/s".
function formatSpeed(bytes) {
  var n = Number(bytes);
  if (!isFinite(n) || n <= 0) return "unlimited";
  if (n < 1024) return Math.round(n) + " B/s";
  if (n < 1048576) return trimmed(n / 1024) + " KiB/s";
  return trimmed(n / 1048576) + " MiB/s";
}

// formatRatio(ratio) -> "2.00", or "none" for -1 (or anything not >= 0).
function formatRatio(ratio) {
  var n = Number(ratio);
  return isFinite(n) && n >= 0 ? n.toFixed(2) : "none";
}

// formatMinutes(m) -> "0m", "1h 30m", "3d", "1d 1h 1m".
function formatMinutes(minutes) {
  var n = Math.max(0, Math.floor(Number(minutes) || 0));
  if (n === 0) return "0m";
  var parts = [];
  var d = Math.floor(n / 1440);
  var h = Math.floor((n % 1440) / 60);
  var mm = n % 60;
  if (d) parts.push(d + "d");
  if (h) parts.push(h + "h");
  if (mm) parts.push(mm + "m");
  return parts.join(" ");
}

// A limit value in words for the confirm head and the done notes.
function ratioWord(ratio) {
  var n = Number(ratio);
  if (n === -2) return "default";
  if (!(n >= 0)) return "none";
  return String(n);
}

function seedWord(minutes) {
  var n = Number(minutes);
  if (n === -2) return "default";
  if (!(n >= 0)) return "none";
  return formatMinutes(n);
}

// --- Effective values ---------------------------------------------------------------

function parentCategory(name) {
  var i = name.lastIndexOf("/");
  return i === -1 ? "" : name.slice(0, i);
}

function categoryLimitsOf(status) {
  var c = status && status.categoryLimits;
  return c && typeof c === "object" && !Array.isArray(c) ? c : {};
}

function shareDefaultsOf(status) {
  var d = status && status.shareDefaults;
  return d && typeof d === "object" ? d : {};
}

// Walk the category chain for field, skipping values equal to dflt or
// failing valid, and fall back to globalValue.
function chain(category, field, dflt, valid, globalValue, status) {
  var cats = categoryLimitsOf(status);
  var c = typeof category === "string" ? category : "";
  while (c !== "") {
    var entry = hasOwn(cats, c) ? cats[c] : null;
    if (entry && typeof entry === "object") {
      var v = entry[field];
      if (valid(v) && v !== dflt) return v;
    }
    c = parentCategory(c);
  }
  return globalValue;
}

function validAction(v) {
  return typeof v === "string" && v !== "";
}

function effectiveLimit(row, status, value, field, globalField) {
  var own = value === undefined || value === null ? (row ? row[field] : undefined) : value;
  own = Number(own);
  if (isFinite(own) && own !== -2) return own;
  var g = shareDefaultsOf(status)[globalField];
  return chain(row ? row.category : "", field, -2, isNumber, isNumber(g) ? g : -1, status);
}

// effectiveRatio(row, status, value?) -> the ratio limit in force: value
// (a new own value; undefined/null keeps row.ratioLimit), resolved through
// the category chain and shareDefaults.ratio when it's -2. -1 is none.
function effectiveRatio(row, status, value) {
  return effectiveLimit(row, status, value, "ratioLimit", "ratio");
}

// effectiveSeedTime(row, status, value?) -> the seed time limit in force,
// in minutes, the same way through seedingTimeLimit and
// shareDefaults.seedingTime.
function effectiveSeedTime(row, status, value) {
  return effectiveLimit(row, status, value, "seedingTimeLimit", "seedingTime");
}

// effectiveAction(row, status) -> the torrent's own share-limit action,
// else its category chain's, else shareDefaults.action, else "Stop".
function effectiveAction(row, status) {
  var own = row ? row.shareLimitAction : undefined;
  if (validAction(own) && own !== "Default") return own;
  var g = shareDefaultsOf(status).action;
  return chain(row ? row.category : "", "shareLimitAction", "Default", validAction, validAction(g) ? g : "Stop", status);
}

// --- Finished (Ruling CC) ------------------------------------------------------------

var SEEDING_STATES = { uploading: true, stalledUP: true, queuedUP: true, stoppedUP: true, checkingUP: true };

// isFinished(row) -> whether qBittorrent applies share limits to it: not
// forcedUP, and progress 1 or a seeding state (a torrent with every file
// unwanted is finished at progress 0). The same rule as qbt's guard.
function isFinished(row) {
  if (!row || typeof row !== "object") return false;
  var state = String(row.state || "");
  if (state === "forcedUP") return false;
  return Number(row.progress) >= 1 || hasOwn(SEEDING_STATES, state);
}

// Whether the torrent is seeding at all, forcedUP included: the done
// notes' "(applies once seeding)" test.
function isSeeding(row) {
  return isFinished(row) || (!!row && typeof row === "object" && row.state === "forcedUP");
}

// --- limitRows ------------------------------------------------------------------------

function row6(key, label, value, muted, toggle) {
  return { key: key, label: label, value: value, muted: muted, toggle: toggle };
}

function speedRow(key, label, bytes) {
  var n = Number(bytes);
  return row6(key, label, formatSpeed(n), !(n > 0), false);
}

// limitRows(row, status) -> the Info tab's six Limits rows,
// [{key, label, value, muted, toggle}], keyed by the status row's own
// field names: dlLimit, upLimit, ratioLimit, seedingTimeLimit, seqDl,
// firstLast. muted marks a value that isn't the torrent's own: a deferred
// (-2) ratio or seed time, "default (…)", and an unlimited (0) speed, which
// leaves only the global speed limit in force. toggle marks the two rows
// Space flips. No row, no rows.
function limitRows(row, status) {
  if (!row || typeof row !== "object") return [];
  var ratio = Number(row.ratioLimit);
  var ratioValue;
  if (ratio === -2 || !isFinite(ratio)) {
    ratioValue = "default (" + formatRatio(isNumber(row.maxRatio) ? row.maxRatio : effectiveRatio(row, status)) + ")";
  } else {
    ratioValue = formatRatio(ratio);
  }
  var seed = Number(row.seedingTimeLimit);
  var seedValue;
  if (seed === -2 || !isFinite(seed)) {
    var eff = isNumber(row.maxSeedingTime) ? row.maxSeedingTime : effectiveSeedTime(row, status);
    seedValue = "default (" + (eff >= 0 ? formatMinutes(eff) : "none") + ")";
  } else {
    seedValue = seed >= 0 ? formatMinutes(seed) : "none";
  }
  return [
    speedRow("dlLimit", "↓ limit", row.dlLimit),
    speedRow("upLimit", "↑ limit", row.upLimit),
    row6("ratioLimit", "Ratio limit", ratioValue, ratio === -2 || !isFinite(ratio), false),
    row6("seedingTimeLimit", "Seed time", seedValue, seed === -2 || !isFinite(seed), false),
    row6("seqDl", "Sequential", row.seqDl === true ? "on" : "off", false, true),
    row6("firstLast", "First/last", row.firstLast === true ? "on" : "off", false, true)
  ];
}

// --- editText -----------------------------------------------------------------------

function speedText(bytes) {
  var b = Number(bytes);
  if (!isFinite(b) || b <= 0) return "u";
  if (b > SPEED_CAP_BYTES) b = SPEED_CAP_BYTES;
  if (b % 1048576 === 0) return (b / 1048576) + "M";
  if (b >= 1048576 && Math.round(Number(trimmed(b / 1048576)) * 1048576) === b) return trimmed(b / 1048576) + "M";
  if (b % 1024 === 0) return (b / 1024) + "K";
  // The nearest hundredth of a KiB, never 0 (which would read as
  // unlimited). The cap is a whole number of hundredths, so rounding a
  // value at or under it never passes it.
  var h = Math.max(1, Math.round(b / 10.24));
  return trimmed(h / 100) + "K";
}

function seedText(minutes) {
  var n = Number(minutes);
  if (n === -2) return "g";
  if (!(n >= 0)) return "n";
  if (n > 0 && n % 1440 === 0) return (n / 1440) + "d";
  if (n > 0 && n % 60 === 0) return (n / 60) + "h";
  if (n > 0) return n + "m";
  return "0";
}

function ratioText(ratio) {
  var n = Number(ratio);
  if (n === -2) return "g";
  if (!(n >= 0)) return "n";
  return trimmed(n);
}

// editText(key, row) -> the current value in input form, for the INSERT
// prefill: "500K", "1.5M", "u", "1.5", "g", "n", "2h", "90m". It parses
// back to the same value (a speed that isn't whole hundredths of a KiB
// comes back as the nearest one). The toggles and unknown keys give "".
function editText(key, row) {
  if (!row || typeof row !== "object") return "";
  if (key === "dlLimit" || key === "upLimit") return speedText(row[key]);
  if (key === "ratioLimit") return ratioText(row.ratioLimit);
  if (key === "seedingTimeLimit") return seedText(row.seedingTimeLimit);
  return "";
}

// --- shareConfirm (D8) ------------------------------------------------------------------

// Outcomes from worst to mildest (Ruling CI). Remove and RemoveWithContent
// share a slot: any RemoveWithContent reads "with their files", as qbt's
// refusal does.
var OUTCOME_ORDER = ["Remove", "EnableSuperSeeding", "Stop"];

function outcomeKind(action) {
  if (action === "EnableSuperSeeding") return "EnableSuperSeeding";
  if (action === "Remove" || action === "RemoveWithContent") return "Remove";
  return "Stop";
}

// "be removed with their files", "switch to super seeding", "be stopped",
// with consecutive "be" phrases sharing one "be", joined with commas and a
// final "or".
function outcomeText(kinds, files, count) {
  var parts = [];
  var prevBe = false;
  for (var i = 0; i < OUTCOME_ORDER.length; i++) {
    var k = OUTCOME_ORDER[i];
    if (!kinds[k]) continue;
    if (k === "EnableSuperSeeding") {
      parts.push("switch to super seeding");
      prevBe = false;
      continue;
    }
    var word = k === "Stop" ? "stopped" : "removed" + (files ? (count === 1 ? " with its files" : " with their files") : "");
    parts.push(prevBe ? word : "be " + word);
    prevBe = true;
  }
  if (parts.length === 1) return parts[0];
  return parts.slice(0, -1).join(", ") + " or " + parts[parts.length - 1];
}

// shareConfirm(action, rows, status) -> {line, force}.
// action is {ratio?, seedingTime?}, the canonical new values (a missing or
// null one is kept). rows are the target status rows (an array or a QML
// sequence). A target counts when it is finished (isFinished) and already
// meets one of its new effective limits: the new value for the limit being
// changed, the kept value for the other, each resolved through the chain
// (see the header). A ratio is met when ratio >= limit, or when maindata's
// ratio is -1 (above the maximum); a seed time when the whole minutes
// seeded (seedingTime is seconds) >= limit. -1 is never met.
// line is "" when no target counts, else one sentence:
//   "Set the ratio limit to 0? 3 torrents already meet it and will be stopped."
// The head names each changed value ("to 1.5", "to default", "to none",
// "to 2h"). "already meet it" becomes "already meet a share limit" when
// both limits change or a counted target meets only the kept one. The tail
// names every outcome among the counted targets, worst first: "be removed
// with their files" (or "be removed"), "switch to super seeding", "be
// stopped" (e.g. "will be removed with their files, switch to super
// seeding or be stopped").
// force is true when any counted target's effective action is Remove or
// RemoveWithContent: qbt refuses that write without --force.
function shareConfirm(action, rows, status) {
  var none = { line: "", force: false };
  if (!action || typeof action !== "object") return none;
  var hasRatio = action.ratio !== undefined && action.ratio !== null;
  var hasSeed = action.seedingTime !== undefined && action.seedingTime !== null;
  if (!hasRatio && !hasSeed) return none;
  var list = listOf(rows);
  var count = 0;
  var onlyChanged = true;
  var kinds = {};
  var files = false;
  var force = false;
  for (var i = 0; i < list.length; i++) {
    var r = list[i];
    if (!isFinished(r)) continue;
    var effRatio = effectiveRatio(r, status, hasRatio ? action.ratio : undefined);
    var effSeed = effectiveSeedTime(r, status, hasSeed ? action.seedingTime : undefined);
    var ratio = Number(r.ratio);
    var ratioMet = effRatio >= 0 && (ratio < 0 || ratio >= effRatio);
    var seedMet = effSeed >= 0 && Math.floor(Number(r.seedingTime) / 60) >= effSeed;
    if (!ratioMet && !seedMet) continue;
    count++;
    if (!((hasRatio && ratioMet) || (hasSeed && seedMet))) onlyChanged = false;
    var act = effectiveAction(r, status);
    kinds[outcomeKind(act)] = true;
    if (act === "RemoveWithContent") files = true;
    if (act === "Remove" || act === "RemoveWithContent") force = true;
  }
  if (count === 0) return none;
  var head;
  if (hasRatio && hasSeed) head = "Set the ratio limit to " + ratioWord(action.ratio) + " and the seed time limit to " + seedWord(action.seedingTime) + "?";
  else if (hasRatio) head = "Set the ratio limit to " + ratioWord(action.ratio) + "?";
  else head = "Set the seed time limit to " + seedWord(action.seedingTime) + "?";
  var what = hasRatio && hasSeed || !onlyChanged ? "a share limit" : "it";
  var line = head + " " + count + (count === 1 ? " torrent already meets " : " torrents already meet ") + what +
    " and will " + outcomeText(kinds, files, count) + ".";
  return { line: line, force: force };
}

// --- doneNote -----------------------------------------------------------------------------

// doneNote(key, value, row) -> the status note after a successful write,
// value being the canonical value sent (bytes, ratio, minutes, or the
// toggle's new boolean). Ratio and seed-time notes on a torrent that isn't
// seeding yet (isSeeding; forcedUP counts as seeding) add
// " (applies once seeding)". Unknown keys give "". The palette's bulk
// commands (Task 6) append " on N torrents" themselves.
function doneNote(key, value, row) {
  var later = row && typeof row === "object" && !isSeeding(row) ? " (applies once seeding)" : "";
  if (key === "dlLimit") return "↓ limit set to " + formatSpeed(value);
  if (key === "upLimit") return "↑ limit set to " + formatSpeed(value);
  if (key === "ratioLimit") {
    var n = Number(value);
    return "Ratio limit set to " + (n === -2 ? "default" : formatRatio(n)) + later;
  }
  if (key === "seedingTimeLimit") return "Seed time limit set to " + seedWord(value) + later;
  if (key === "seqDl") return "Sequential download " + (value ? "on" : "off");
  if (key === "firstLast") return "First and last pieces first " + (value ? "on" : "off");
  return "";
}

if (typeof module !== "undefined") {
  module.exports = {
    SPEED_ERROR: SPEED_ERROR,
    SPEED_CAP_ERROR: SPEED_CAP_ERROR,
    RATIO_ERROR: RATIO_ERROR,
    RATIO_DECIMALS_ERROR: RATIO_DECIMALS_ERROR,
    RATIO_CAP_ERROR: RATIO_CAP_ERROR,
    SEED_ERROR: SEED_ERROR,
    SEED_CAP_ERROR: SEED_CAP_ERROR,
    parseSpeed: parseSpeed,
    parseRatio: parseRatio,
    parseSeedTime: parseSeedTime,
    formatSpeed: formatSpeed,
    formatRatio: formatRatio,
    formatMinutes: formatMinutes,
    effectiveRatio: effectiveRatio,
    effectiveSeedTime: effectiveSeedTime,
    effectiveAction: effectiveAction,
    isFinished: isFinished,
    limitRows: limitRows,
    editText: editText,
    shareConfirm: shareConfirm,
    doneNote: doneNote
  };
}
