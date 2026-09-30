.pragma library
.import "LinkRules.js" as Links

// The RSS rules area's pure rules (slice 5b2, Task 3). No I/O, no Date, no
// Qt objects: tests/rss-rules.test.js runs it in node against
// tests/fixtures/rss-autorules-cases.json. It imports LinkRules.js (5b0's
// text rules: cleanName, qtTrim, fill).
//
// The `.pragma library` line above is QML-only; the node test strips it.
//
// What lives here (tests/fixtures/rss-rules-contract.md is the contract):
// - RULE_FIELDS, the editor's fields in the contract table's order, and
//   fieldRows, the rows the fields column draws (label, value words, help);
// - draftDiff, the changes and snapshot `qbt rss rule-set` takes from the
//   draft (only the changed keys, their start values, enabled, and
//   useAutoTmm exactly when the path changed);
// - previewGroups, the preview column's lines from `qbt rss rule-preview`;
// - confirmLine, the rules' CONFIRM lines; checkRuleName, a's and n's
//   INSERT pre-check (qbt checks again); sentence, every other line.
// The window never pre-checks a regex, an episode filter, a path or a day
// count: `qbt rss rule-check` is the check.

// The case file's `window` (tests/rss-rules.test.js checks it deep-equal).
var WINDOW = {
  rulesTitle: "Rules",
  rulesEmpty: "No rules. a creates one that downloads matching articles automatically.",
  stateOn: "on",
  stateOff: "off",
  previewTitle: "Preview",
  previewEmpty: "Nothing in your feeds matches yet.",
  previewUpdating: "updating…",
  previewFailed: "Couldn't update the preview.",
  previewWill: "Would download (<n>)",
  previewNoTorrent: "No torrent link (<m>)",
  previewRead: "Already read (<k>)",
  previewDup: "(same title ×<k>)",
  previewUnpreviewable: "can't preview: two feeds are called <name>; rename one",
  feedGone: "(gone) <url>",
  labelEnabled: "Enabled",
  labelMustContain: "Must contain",
  labelMustNotContain: "Must not contain",
  labelUseRegex: "Use regular expressions",
  labelEpisodeFilter: "Episode filter",
  labelSmartFilter: "Smart episode filter",
  labelAffectedFeeds: "Feeds",
  labelCategory: "Category",
  labelSavePath: "Save to",
  labelAddStopped: "Add stopped",
  labelIgnoreDays: "Ignore for (days)",
  helpEnabled: "While it's on and auto-download is on, qBittorrent adds every unread article it matches. e turns it on or off.",
  helpMustContain: "Titles must match this. Wildcards: * and ?; words separated by spaces must all appear; | separates alternatives. Empty matches every title.",
  helpMustNotContain: "Titles that match this are skipped, with the same syntax as Must contain. Empty skips nothing.",
  helpUseRegex: "Read both patterns as Perl-compatible regular expressions, ignoring case.",
  helpEpisodeFilter: "Episodes to take, such as 1x2;8-15;5;30-; for season 1's episodes 2, 5, 8 to 15 and 30 on. Empty takes every episode.",
  helpSmartFilter: "Take each episode once, using qBittorrent's memory of matched episodes and its smart filter settings.",
  helpAffectedFeeds: "The feeds this rule reads.",
  helpCategory: "The category matching torrents are added to.",
  helpSavePath: "Where matching torrents are saved. Empty uses the category's folder or qBittorrent's default.",
  helpAddStopped: "Add matching torrents stopped, started, or as qBittorrent's own setting says.",
  helpIgnoreDays: "After a match, skip this rule's matches for this many days. 0 never skips.",
  valueEmpty: "(empty)",
  categoryNone: "(none)",
  savePathDefault: "(default)",
  addStoppedDefault: "default",
  addStoppedYes: "yes",
  addStoppedNo: "no",
  promptRuleName: "Rule name",
  promptRuleRename: "Rename rule",
  promptRuleField: "New value",
  reasonRule: "No rule here.",
  reasonFieldEditable: "This field can't be edited here.",
  reasonFieldToggle: "Space toggles on/off fields.",
  reasonRuleDirty: "Nothing to discard.",
  confirmRuleOn: "Turn on <name>? Up to <n> unread articles download now.",
  confirmRuleOnNone: "Turn on <name>? Nothing in your feeds matches yet.",
  confirmRuleOnAutoOff: "Turn on <name>? Auto-download is off, so nothing downloads until you turn it on in Settings → RSS.",
  confirmEditOff: "Editing turns <name> off until you turn it back on.",
  confirmLeave: "Save changes to <name>? y save · n keep editing",
  confirmDiscard: "Discard your changes to <name>?",
  confirmRemove: "Remove rule <name>? This can't be undone.",
  confirmAutoDl: "Turn on auto-download? <r> rules are on; up to <n> unread articles download now.",
  confirmAutoDlNone: "No rules are on yet; nothing downloads until you turn one on.",
  confirmAutoDlUncounted: "Turn on auto-download? Couldn't count what would download.",
  autoDlNoTorrent: "<m> matching articles have no torrent link, and qBittorrent would retry them forever. Tighten or turn off the rules that match them first.",
  autoDlFooter: "auto-download is on: p saves and previews",
  noteCreated: "Created <name>; it stays off until you turn it on.",
  noteOn: "<name> is on.",
  noteOff: "<name> is off.",
  noteRemoved: "Removed rule <name>."
};

// The case file's `sentences`: every line `qbt rss rule-*` prints.
var SENTENCES = {
  ruleUsage: "usage: qbt rss rules|rules-preview-enabled|rule-check|rule-create|rule-set|rule-preview|rule-rename|rule-remove",
  ruleExists: "There's already a rule called <name>.",
  ruleGone: "That rule is gone.",
  ruleChanged: "<name> changed elsewhere; press r to reload it.",
  ruleNameEmpty: "Enter a rule name.",
  ruleNameControl: "Rule names can't contain control characters.",
  badRegex: "That isn't a valid regular expression.",
  regexUnchecked: "Couldn't check the regular expression.",
  noPcre: "Checking regular expressions needs pcre2grep.",
  badEpisode: "Use an episode filter such as 1x2;8-15;",
  badDays: "Ignore for a whole number of days, 0 to 365.",
  badSavePath: "Enter an absolute path, or leave it empty.",
  multiLine: "Patterns go on one line.",
  noTorrentBlock: "<m> matching articles have no torrent link, and qBittorrent would retry them forever. Tighten the rule first.",
  unconfirmedSave: "Couldn't confirm the save.",
  unconfirmedAdd: "Couldn't confirm <name> was added.",
  unconfirmedRename: "Couldn't confirm the rename.",
  unconfirmedRemove: "Couldn't confirm <name> was removed."
};

var EMPTY = Links.EMPTY;

function fill(template, vars) { return Links.fill(template, vars); }

// sentence(key, vars) -> the window's copy, or qbt's sentence, of that key,
// with <name>, <n>, <m>, <k>, <r> and <url> filled in; "" for no such key.
function sentence(key, vars) {
  var t = Object.prototype.hasOwnProperty.call(WINDOW, key) ? WINDOW[key] : SENTENCES[key];
  return t === undefined ? "" : fill(t, vars);
}

// displayName(name) -> a rule name, pattern, title or path as a row or a
// confirm shows it (5b0's row rule: bidi controls removed, controls a
// space, trimmed, capped at 300 code points; nothing is "—").
function displayName(name) { return Links.cleanName(name); }

// ---- RULE_FIELDS ------------------------------------------------------------------------

function field(key, kind) {
  var cap = key.charAt(0).toUpperCase() + key.slice(1);
  return { key: key, kind: kind, label: WINDOW["label" + cap], help: WINDOW["help" + cap] };
}

var RULE_FIELDS = [
  field("enabled", "toggle"),
  field("mustContain", "regexText"),
  field("mustNotContain", "regexText"),
  field("useRegex", "toggle"),
  field("episodeFilter", "episode"),
  field("smartFilter", "toggle"),
  field("affectedFeeds", "feeds"),
  field("category", "category"),
  field("savePath", "path"),
  field("addStopped", "triBool"),
  field("ignoreDays", "number")
];

// The kinds: Space toggles; Enter opens an INSERT (checked by `qbt rss
// rule-check` before it commits) or a ListOverlay picker.
function isToggle(kind) { return kind === "toggle"; }
function isInsert(kind) { return kind === "regexText" || kind === "episode" || kind === "number" || kind === "path"; }
function isPicker(kind) { return kind === "feeds" || kind === "category" || kind === "triBool"; }

function fieldOf(key) {
  for (var i = 0; i < RULE_FIELDS.length; i++) if (RULE_FIELDS[i].key === key) return RULE_FIELDS[i];
  return null;
}

var ADD_STOPPED = { "default": "addStoppedDefault", yes: "addStoppedYes", no: "addStoppedNo" };

function feedsText(urls, feeds) {
  var list = Array.isArray(urls) ? urls : [];
  if (list.length === 0) return { text: WINDOW.valueEmpty, muted: true };
  var byUrl = {};
  var all = Array.isArray(feeds) ? feeds : [];
  for (var i = 0; i < all.length; i++) {
    var f = all[i];
    if (f && f.folder !== true && typeof f.url === "string" && typeof f.path === "string" && byUrl[f.url] === undefined) byUrl[f.url] = f.path;
  }
  var parts = [];
  for (var j = 0; j < list.length; j++) {
    var u = String(list[j]);
    parts.push(byUrl[u] !== undefined ? displayName(byUrl[u]) : fill(WINDOW.feedGone, { url: displayName(u) }));
  }
  return { text: parts.join(", "), muted: false };
}

// valueText(key, value, feeds) -> {text, muted}: a field's value as its
// row shows it. A toggle is on or off; an empty pattern or episode filter
// "(empty)", an empty category "(none)", an empty path "(default)", each
// muted, as is addStopped's default (qBittorrent's own setting); the feeds
// by path (feeds: `qbt rss items`' feeds), a URL no feed has "(gone) <url>".
function valueText(key, value, feeds) {
  var f = fieldOf(key);
  var kind = f ? f.kind : "";
  if (kind === "toggle") return { text: value === true ? WINDOW.stateOn : WINDOW.stateOff, muted: false };
  if (kind === "feeds") return feedsText(value, feeds);
  if (kind === "triBool") {
    var w = ADD_STOPPED[value] || ADD_STOPPED["default"];
    return { text: WINDOW[w], muted: w === ADD_STOPPED["default"] };
  }
  if (kind === "number") return { text: String(typeof value === "number" ? value : 0), muted: false };
  var s = typeof value === "string" ? value : "";
  if (s === "") return { text: kind === "category" ? WINDOW.categoryNone : (kind === "path" ? WINDOW.savePathDefault : WINDOW.valueEmpty), muted: true };
  return { text: displayName(s), muted: false };
}

// fieldRows(fields, feeds) -> one row per RULE_FIELDS entry, in order:
// {key, kind, label, help, value (the raw value, an INSERT's prefill),
// text (valueText), muted}. fields: a rule's `fields` (qbt rss rules) or
// the draft.
function fieldRows(fields, feeds) {
  var v = fields && typeof fields === "object" ? fields : {};
  var out = [];
  for (var i = 0; i < RULE_FIELDS.length; i++) {
    var f = RULE_FIELDS[i];
    var t = valueText(f.key, v[f.key], feeds);
    out.push({ key: f.key, kind: f.kind, label: f.label, help: f.help, value: v[f.key], text: t.text, muted: t.muted });
  }
  return out;
}

// ---- the draft --------------------------------------------------------------------------

function copyValue(v) {
  return Array.isArray(v) ? v.slice() : v;
}

function sameValue(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }
  return a === b;
}

// draftDiff(draft, snapshot) -> {changes, snapshot}, what `qbt rss
// rule-set` takes: changes holds only the fields (RULE_FIELDS without
// enabled) whose draft value differs from the snapshot's, lists compared in
// order; snapshot holds those keys' start values, plus enabled whenever
// there are changes, plus useAutoTmm exactly when savePath changed.
// snapshot is the draft's start: the rule's fields, enabled included, and
// useAutoTmm (torrentParams.use_auto_tmm when the fields were entered:
// true, false or null). No change is {} and {}.
function draftDiff(draft, snapshot) {
  var d = draft || {};
  var s = snapshot || {};
  var changes = {};
  var snap = {};
  var any = false;
  for (var i = 0; i < RULE_FIELDS.length; i++) {
    var k = RULE_FIELDS[i].key;
    if (k === "enabled") continue;
    if (sameValue(d[k], s[k])) continue;
    changes[k] = copyValue(d[k]);
    snap[k] = copyValue(s[k]);
    any = true;
  }
  if (!any) return { changes: {}, snapshot: {} };
  if (Object.prototype.hasOwnProperty.call(changes, "savePath")) snap.useAutoTmm = s.useAutoTmm === true || s.useAutoTmm === false ? s.useAutoTmm : null;
  snap.enabled = s.enabled === true;
  return { changes: changes, snapshot: snap };
}

function isDirty(draft, snapshot) {
  return Object.keys(draftDiff(draft, snapshot).changes).length > 0;
}

// ---- the preview ------------------------------------------------------------------------

function listOf(v) { return Array.isArray(v) ? v : []; }

// previewGroups(preview) -> the preview column, from `qbt rss
// rule-preview`'s {will, read, noTorrent, unpreviewable, gone}: {n, m, k
// (will's, noTorrent's and read's counts), empty (nothing at all), gone,
// lines: [{text, muted, head}]}. Lines: "Would download (<n>)" and its
// titles, then the muted "No torrent link (<m>)" and "Already read (<k>)"
// with theirs, a title with dup > 1 followed by "(same title ×<k>)", then
// one muted "can't preview" line per same-named pair (OV4); nothing at all
// is the one line "Nothing in your feeds matches yet.". An article of an
// unpreviewable feed counts nowhere (qbt never puts one in a group; this
// holds even if it did).
function previewGroups(preview) {
  var p = preview && typeof preview === "object" ? preview : {};
  var unp = listOf(p.unpreviewable);
  var hidden = {};
  for (var i = 0; i < unp.length; i++) {
    var paths = unp[i] && Array.isArray(unp[i].feedPaths) ? unp[i].feedPaths : [];
    for (var j = 0; j < paths.length; j++) hidden[String(paths[j])] = true;
  }
  function keep(list) {
    return listOf(list).filter(function(a) { return a && typeof a === "object" && hidden[String(a.feedPath)] !== true; });
  }
  var will = keep(p.will), noTorrent = keep(p.noTorrent), read = keep(p.read);
  var out = { n: will.length, m: noTorrent.length, k: read.length, empty: false, gone: listOf(p.gone).slice(), lines: [] };
  if (will.length + noTorrent.length + read.length === 0 && unp.length === 0) {
    out.empty = true;
    out.lines.push({ text: WINDOW.previewEmpty, muted: true, head: false });
    return out;
  }
  function titles(list, muted) {
    for (var t = 0; t < list.length; t++) {
      var a = list[t];
      var dup = typeof a.dup === "number" && a.dup > 1 ? " " + fill(WINDOW.previewDup, { k: a.dup }) : "";
      out.lines.push({ text: displayName(a.title) + dup, muted: muted, head: false });
    }
  }
  out.lines.push({ text: fill(WINDOW.previewWill, { n: will.length }), muted: false, head: true });
  titles(will, false);
  out.lines.push({ text: fill(WINDOW.previewNoTorrent, { m: noTorrent.length }), muted: true, head: true });
  titles(noTorrent, true);
  out.lines.push({ text: fill(WINDOW.previewRead, { k: read.length }), muted: true, head: true });
  titles(read, true);
  for (var u = 0; u < unp.length; u++) out.lines.push({ text: fill(WINDOW.previewUnpreviewable, { name: displayName(unp[u] ? unp[u].name : "") }), muted: true, head: false });
  return out;
}

// ---- confirms and names -----------------------------------------------------------------

// confirmLine(kind, vars) -> the line of one of the rules' CONFIRMs
// (View.RSS_ACCEPT's rule kinds), the name sanitised. vars: {name} for
// each; rssRuleOn also {n (the preview's), autoDl}: auto-download off says
// so whatever n is, else n = 0 is confirmRuleOnNone.
function confirmLine(kind, vars) {
  var v = vars || {};
  var name = displayName(v.name);
  switch (kind) {
  case "rssRuleRemove": return fill(WINDOW.confirmRemove, { name: name });
  case "rssRuleEditOff": return fill(WINDOW.confirmEditOff, { name: name });
  case "rssRuleLeave": return fill(WINDOW.confirmLeave, { name: name });
  case "rssRuleDiscard": return fill(WINDOW.confirmDiscard, { name: name });
  case "rssRuleOn":
    if (v.autoDl !== true) return fill(WINDOW.confirmRuleOnAutoOff, { name: name });
    var n = Number(v.n) || 0;
    return n > 0 ? fill(WINDOW.confirmRuleOn, { name: name, n: n }) : fill(WINDOW.confirmRuleOnNone, { name: name });
  default: return "";
  }
}

var CONTROL = /[\u0000-\u001f\u007f-\u009f]/;

// checkRuleName(text) -> {ok, normalised (trimmed)} or {ok:false, message}:
// the case file's ruleName rule, a's and n's INSERT pre-check (qbt's
// rule-create and rule-rename check again).
function checkRuleName(text) {
  var s = Links.qtTrim(typeof text === "string" ? text : "");
  if (s === "") return { ok: false, message: SENTENCES.ruleNameEmpty };
  if (CONTROL.test(s)) return { ok: false, message: SENTENCES.ruleNameControl };
  return { ok: true, normalised: s };
}

// ruleExists(rules, name) -> qbt's rule list has exactly that name.
function ruleExists(rules, name) {
  var list = Array.isArray(rules) ? rules : [];
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].name === name) return true;
  return false;
}

if (typeof module !== "undefined") {
  module.exports = {
    WINDOW: WINDOW, SENTENCES: SENTENCES, RULE_FIELDS: RULE_FIELDS,
    sentence: sentence, displayName: displayName, isToggle: isToggle, isInsert: isInsert, isPicker: isPicker, fieldOf: fieldOf,
    valueText: valueText, fieldRows: fieldRows, draftDiff: draftDiff, isDirty: isDirty, sameValue: sameValue,
    previewGroups: previewGroups, confirmLine: confirmLine, checkRuleName: checkRuleName, ruleExists: ruleExists
  };
}
