// Slice 5b2 (Task 1): the RSS rules contract's own consistency. The lanes
// test their code against tests/fixtures/rss-autorules-cases.json; this pins
// that file's shape, the brief's exact sentences and copy, the rows the
// brief and the controller asked for, and that rss-rules-contract.md quotes
// only the case file's lines (so neither can drift from the other). 5b1's
// rss-rules-cases.json and its tests stay as they were.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");
const Registry = require("../CommandRegistry.js");

const FIX = path.join(__dirname, "fixtures");
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), "utf8"));
const data = fixture("rss-autorules-cases.json");
const RSS5B1 = fixture("rss-rules-cases.json");
const contract = fs.readFileSync(path.join(FIX, "rss-rules-contract.md"), "utf8");

function load(name, deps, values) {
  const file = path.join(__dirname, "..", name);
  const src = fs.readFileSync(file, "utf8").split("\n").map((l) => (/^\s*\.(import|pragma)\b/.test(l) ? "" : l)).join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"].concat(deps || []), { filename: file })(mod, ...(values || []));
  return mod.exports;
}
const Links = load("LinkRules.js");
const View = load("ClientView.js", ["Model", "Registry"], [require("../Model.js"), Registry]);

const KINDS = ["ruleName", "regex", "episode", "ignoreDays", "savePath", "fields", "patch", "previewJoin"];
const ALWAYS_OK = ["fields", "previewJoin"];

// The brief's sentences, exactly, plus ruleUsage and the two 5b1 read-back
// lines the rule commands reuse (see the report).
const SENTENCES = {
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

// The brief's window copy, the controller's confirmAutoDlUncounted, and the
// labels, help lines, prompts, value words and notes the window lane needs.
const WINDOW = {
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

// RULE_FIELDS: key, the window's label key, kind (the contract's table).
const RULE_FIELDS = [
  ["enabled", "labelEnabled", "toggle"],
  ["mustContain", "labelMustContain", "regexText"],
  ["mustNotContain", "labelMustNotContain", "regexText"],
  ["useRegex", "labelUseRegex", "toggle"],
  ["episodeFilter", "labelEpisodeFilter", "episode"],
  ["smartFilter", "labelSmartFilter", "toggle"],
  ["affectedFeeds", "labelAffectedFeeds", "feeds"],
  ["category", "labelCategory", "category"],
  ["savePath", "labelSavePath", "path"],
  ["addStopped", "labelAddStopped", "triBool"],
  ["ignoreDays", "labelIgnoreDays", "number"]
];
const FIELD_KEYS = RULE_FIELDS.map((f) => f[0]);
const EDIT_KEYS = FIELD_KEYS.filter((k) => k !== "enabled");

const of = (kind) => data.cases.filter((c) => c.kind === kind);
const has = (kind, pred, why) => assert.ok(of(kind).some(pred), kind + ": " + why);

test("rules cases: every case has the documented shape", () => {
  assert.equal(typeof data._doc, "string");
  assert.deepEqual(Object.keys(data).sort(), ["_doc", "cases", "sentences", "window"]);
  assert.ok(Array.isArray(data.cases) && data.cases.length > 120);
  const messages = Object.values(data.sentences);
  const filled = (m) => messages.some((s) => new RegExp("^" + s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/<[a-z]+>/g, ".+") + "$").test(m));
  for (const c of data.cases) {
    const label = c.kind + " " + c.why;
    assert.ok(KINDS.includes(c.kind), label);
    assert.ok("input" in c, label);
    assert.equal(typeof c.ok, "boolean", label);
    assert.equal(typeof c.why, "string", label);
    for (const k of Object.keys(c)) assert.ok(["kind", "input", "ok", "normalised", "message", "why"].includes(k), label + " " + k);
    assert.equal("message" in c, c.ok === false, label + ": a message exactly when refused");
    assert.equal("normalised" in c, c.ok === true, label + ": normalised exactly when ok");
    if ("message" in c) {
      assert.ok(filled(c.message), label + ": the message is one of `sentences`");
      assert.ok(!/<[a-z]+>/.test(c.message), label + ": a case message is filled");
    }
  }
  for (const kind of KINDS) {
    assert.ok(of(kind).some((c) => c.ok), kind + " has an ok case");
    if (ALWAYS_OK.includes(kind)) assert.ok(of(kind).every((c) => c.ok), kind + " is never refused");
    else assert.ok(of(kind).some((c) => !c.ok), kind + " has a refused case");
  }
  assert.ok(data._doc.includes('u"^(^\\\\d{1,4}x(\\\\d{1,4}(-(\\\\d{1,4})?)?;){1,}){1,1}"_s'), "the GUI's episode regex is quoted exactly");
});

test("rules cases: the input shapes per kind", () => {
  for (const c of data.cases) {
    const label = c.kind + " " + c.why;
    if (["ruleName", "episode", "ignoreDays", "savePath"].includes(c.kind)) assert.equal(typeof c.input, "string", label);
    if (c.kind === "regex") {
      assert.deepEqual(Object.keys(c.input).sort(), ["useRegex", "value"], label);
      assert.equal(typeof c.input.useRegex, "boolean", label);
      if (c.ok) assert.equal(c.normalised, c.input.value, label + ": a pattern is never changed");
    }
    if (c.kind === "ignoreDays" && c.ok) assert.ok(Number.isInteger(c.normalised) && c.normalised >= 0 && c.normalised <= 365, label);
    if (c.kind === "fields") assert.deepEqual(Object.keys(c.normalised), FIELD_KEYS, label);
    if (c.kind === "patch") {
      assert.deepEqual(Object.keys(c.input).sort(), ["changes", "current", "enable", "name", "snapshot"], label);
      assert.ok(["keep", "off", "on"].includes(c.input.enable), label);
      for (const k of Object.keys(c.input.changes)) assert.ok(EDIT_KEYS.includes(k), label + " " + k);
      const changed = Object.keys(c.input.changes);
      const want = changed.concat(changed.length > 0 ? ["enabled"] : [], "savePath" in c.input.changes ? ["useAutoTmm"] : []).sort();
      const usage = c.message === data.sentences.ruleUsage;
      if (!usage) assert.deepEqual(Object.keys(c.input.snapshot).sort(), want, label + ": the snapshot holds the changed keys, enabled, and useAutoTmm with savePath");
      if (!usage && c.input.enable === "on") assert.deepEqual([changed.length, Object.keys(c.input.snapshot).length], [0, 0], label + ": on never carries changes");
      if (c.ok) assert.equal(typeof c.normalised.enabled, "boolean", label + ": enabled is always written");
    }
    if (c.kind === "previewJoin") {
      assert.deepEqual(Object.keys(c.input).sort(), ["items", "matching", "rule"], label);
      assert.deepEqual(Object.keys(c.normalised), ["will", "read", "noTorrent", "unpreviewable", "gone"], label);
      for (const g of ["will", "read", "noTorrent"]) for (const e of c.normalised[g]) assert.deepEqual(Object.keys(e), ["feedPath", "guid", "title", "dup"], label);
    }
  }
});

test("rules cases: the rows the brief and the controller asked for are there", () => {
  const S = data.sentences;
  const rx = (value, useRegex) => (c) => c.input.value === value && c.input.useRegex === useRegex;
  // regex: real pcre2 behaviour.
  has("regex", (c) => rx("(", true)(c) && c.message === S.badRegex, "( refused");
  has("regex", (c) => rx("(?<=a+)b", true)(c) && c.message === S.badRegex, "(?<=a+)b refused");
  has("regex", (c) => rx("\\K", true)(c) && c.ok, "\\K accepted");
  has("regex", (c) => rx("a++b", true)(c) && c.ok, "a++b accepted");
  has("regex", (c) => rx("", true)(c) && c.ok && c.normalised === "", "empty is no condition");
  has("regex", (c) => /\n/.test(c.input.value) && c.input.useRegex && c.message === S.multiLine, "a multi-line value");
  has("regex", (c) => /\n/.test(c.input.value) && !c.input.useRegex && c.message === S.multiLine, "multi-line in wildcard mode");
  has("regex", (c) => c.input.value.length === 10000 && c.input.useRegex && c.message === S.regexUnchecked, "a 10000-character pattern");
  has("regex", (c) => c.input.value.length === 10000 && !c.input.useRegex && c.ok, "a 10000-character wildcard");
  has("regex", (c) => rx("(", false)(c) && c.ok, "wildcard mode never checks a regex");
  has("regex", (c) => !c.input.useRegex && c.input.value.includes("|") && c.ok, "| alternatives in wildcard mode");
  // episode.
  has("episode", (c) => c.input === "1x2;8-15;5;30-;" && c.ok, "the GUI example");
  has("episode", (c) => c.input === "1x2; 3;" && c.message === S.badEpisode, "OV13's odd value refused when typed");
  has("episode", (c) => c.input === "1x2;junk" && c.message === S.badEpisode, "trailing junk (the end anchor)");
  has("episode", (c) => c.input === "" && c.ok && c.normalised === "", "empty");
  // patch: read-patch-write.
  const P = of("patch");
  const full = (c) => c.input.current.torrentParams && c.input.current.torrentParams.tags && c.input.current.torrentParams.tags.length > 0 &&
    "content_layout" in c.input.current.torrentParams && c.input.current.torrentParams.download_limit > 0 && "use_auto_tmm" in c.input.current.torrentParams &&
    c.input.current.priority === 2 && c.input.current.lastMatch && c.input.current.previouslyMatchedEpisodes.length === 6;
  const rf1 = P.find((c) => full(c) && c.ok && JSON.stringify(Object.keys(c.input.changes)) === '["mustContain"]');
  assert.ok(rf1, "Review Focus 1: a fully populated rule with only mustContain changed");
  assert.deepEqual(Object.assign({}, rf1.normalised, { mustContain: rf1.input.current.mustContain }), rf1.input.current, "only mustContain changes");
  has("patch", (c) => c.ok && c.input.changes.savePath && c.normalised.torrentParams.use_auto_tmm === false && c.normalised.torrentParams.save_path === c.normalised.savePath, "a path sets use_auto_tmm false");
  for (const prior of [true, false, null]) {
    has("patch", (c) => c.ok && c.input.changes.savePath === "" && c.input.snapshot.useAutoTmm === prior && c.normalised.torrentParams &&
      !("save_path" in c.normalised.torrentParams) && (prior === null ? !("use_auto_tmm" in c.normalised.torrentParams) : c.normalised.torrentParams.use_auto_tmm === prior),
      "clearing the path restores use_auto_tmm " + prior);
  }
  for (const [v, stopped, paused] of [["yes", true, true], ["no", false, false], ["default", undefined, null]]) {
    has("patch", (c) => c.ok && c.input.changes.addStopped === v && c.normalised.torrentParams && c.normalised.torrentParams.stopped === stopped && c.normalised.addPaused === paused, "stopped " + v);
  }
  has("patch", (c) => !c.ok && c.message === S.ruleChanged.replace("<name>", c.input.name), "a snapshot conflict");
  for (const [e, before, after] of [["on", false, true], ["off", true, false], ["keep", false, false]]) {
    has("patch", (c) => c.ok && c.input.enable === e && c.input.current.enabled === before && c.normalised.enabled === after, "enable " + e + " from " + before);
  }
  has("patch", (c) => c.ok && !("enabled" in c.input.current) && c.normalised.enabled === true, "enabled written explicitly when absent");
  // Final fix wave: OV15, a keep save only touches a disabled rule.
  has("patch", (c) => c.input.enable === "keep" && c.input.snapshot.enabled === true && c.message === S.ruleUsage, "keep with snapshot.enabled true is a usage refusal");
  has("fields", (c) => c.input.torrentParams && c.input.torrentParams.stopped === null && c.normalised.addStopped === "default", "a null torrentParams.stopped is default");
  has("fields", (c) => c.input.torrentParams && ![true, false, null, undefined].includes(c.input.torrentParams.stopped) && c.normalised.addStopped === "no", "a non-bool torrentParams.stopped is no");
  // Fix round 1: on never carries changes; a save's snapshot holds enabled.
  has("patch", (c) => c.input.enable === "on" && Object.keys(c.input.changes).length > 0 && c.message === S.ruleUsage, "on with changes is a usage refusal");
  has("patch", (c) => c.ok && c.input.enable === "on" && Object.keys(c.input.changes).length === 0 && c.normalised.enabled === true, "on with empty changes");
  has("patch", (c) => c.input.enable === "keep" && c.input.snapshot.enabled !== c.input.current.enabled && c.message === S.ruleChanged.replace("<name>", c.input.name),
    "a keep save refuses when enabled changed elsewhere");
  has("patch", (c) => c.ok && c.input.current.torrentParams === null && c.normalised.torrentParams && typeof c.normalised.torrentParams === "object",
    "a present non-object torrentParams still wins");
  has("fields", (c) => c.input.torrentParams === null && c.normalised.category === "", "a null torrentParams still hides the flat keys");
  has("ruleName", (c) => /^[\u001c-\u001f]|[\u001c-\u001f]$/.test(c.input) && c.message === S.ruleNameControl, "U+001C-U+001F at the ends are controls");
  has("patch", (c) => c.ok && !("torrentParams" in c.input.current) && !("torrentParams" in c.normalised) && c.input.changes.savePath, "a legacy rule gets no torrentParams");
  has("patch", (c) => c.ok && c.input.current.episodeFilter === "1x2; 3;" && c.normalised.episodeFilter === "1x2; 3;", "OV13: an untouched odd value round-trips");
  has("patch", (c) => c.ok && c.input.current.previouslyMatchedEpisodes && c.input.current.previouslyMatchedEpisodes.length === 7 &&
    JSON.stringify(c.normalised.previouslyMatchedEpisodes) === JSON.stringify(c.input.current.previouslyMatchedEpisodes), "the current rule's episode memory is kept");
  // previewJoin: D4, OV4, OV5.
  const J = of("previewJoin");
  assert.ok(J.some((c) => c.normalised.will.length > 0 && c.normalised.read.length > 0 && c.normalised.noTorrent.length > 0), "will, read and noTorrent");
  assert.ok(J.some((c) => c.normalised.unpreviewable.length > 0 && c.normalised.will.length === 0), "same-named feeds are unpreviewable");
  assert.ok(J.some((c) => c.normalised.will.some((e) => e.dup > 1)), "duplicate titles counted with dup");
  assert.ok(J.some((c) => c.normalised.gone.length > 0), "a gone URL");
  assert.ok(J.some((c) => c.normalised.noTorrent.some((e) => {
    const a = c.input.items.articles.find((x) => x.guid === e.guid && x.feedPath === e.feedPath);
    return a.torrentURL === "" && a.link !== "";
  })), "noTorrent uses the link when torrentURL is empty");
  // hasTorrent is 5b1's rule: every article's flag is consistent with its links.
  for (const c of J) {
    for (const a of c.input.items.articles) {
      const row = RSS5B1.cases.find((r) => r.kind === "hasTorrent" && r.input.torrentURL === a.torrentURL && r.input.link === a.link);
      if (row) assert.equal(a.hasTorrent, row.ok, a.guid);
    }
  }
});

test("rules cases: the window's pre-checks agree with Qt's trim and the anchored GUI episode format", () => {
  for (const c of of("ruleName")) {
    const t = Links.qtTrim(c.input);
    if (c.ok) assert.equal(c.normalised, t, c.why);
    else if (c.message === data.sentences.ruleNameEmpty) assert.equal(t, "", c.why);
    else assert.ok(Links.CONTROL.test(t), c.why);
  }
  const EP = /^(\d{1,4}x(\d{1,4}(-(\d{1,4})?)?;){1,})$/i;
  for (const c of of("episode")) {
    const t = Links.qtTrim(c.input);
    assert.equal(c.ok, t === "" || (EP.test(t) && !/\n/.test(t)), c.why);
    if (c.ok) assert.equal(c.normalised, t, c.why);
  }
});

const PCRE = spawnSync("pcre2grep", ["--version"]).status === 0;
test("rules cases: every regex row with useRegex is what pcre2grep says", { skip: !PCRE && "pcre2grep isn't installed" }, () => {
  for (const c of of("regex").filter((x) => x.input.useRegex && x.input.value !== "" && !/[\r\n]/.test(x.input.value))) {
    const r = spawnSync("bash", ["-c", 'pcre2grep -u -i -f <(printf "%s\\n" "$1") /dev/null', "_", c.input.value], { encoding: "utf8" });
    const got = r.status === 0 || r.status === 1 ? "ok" : (r.status === 2 && /Error in regex/.test(r.stderr) ? data.sentences.badRegex : data.sentences.regexUnchecked);
    assert.equal(got, c.ok ? "ok" : c.message, c.why);
  }
});

test("rules cases: the sentences and the window's copy are exactly these", () => {
  assert.deepEqual(data.sentences, SENTENCES);
  assert.deepEqual(data.window, WINDOW);
  // Reused 5b1 lines keep 5b1's text.
  for (const k of ["unconfirmedAdd", "unconfirmedRename", "unconfirmedRemove"]) assert.equal(data.sentences[k], RSS5B1.sentences[k], k);
});

test("rules cases: every placeholder is one the _doc lists, and it lists only used ones", () => {
  const listed = data._doc.match(/Placeholders: ([^.]*)filled in by the caller/);
  assert.ok(listed, "_doc lists the placeholders");
  const allowed = new Set(listed[1].match(/<[a-z]+>/g));
  assert.deepEqual(Array.from(allowed).sort(), ["<k>", "<m>", "<n>", "<name>", "<r>", "<url>"]);
  const used = new Set();
  for (const group of ["sentences", "window"]) {
    for (const [k, s] of Object.entries(data[group])) {
      for (const m of s.match(/<[^<>]*>/g) || []) { assert.ok(allowed.has(m), group + "." + k + ": " + m); used.add(m); }
    }
  }
  assert.deepEqual(Array.from(used).sort(), Array.from(allowed).sort(), "every listed placeholder is used");
});

test("rules cases: the registry's reasons, the confirms and the INSERT prompts are the case file's", () => {
  const W = data.window;
  const sentence = (r) => (/^(RSS|qBittorrent|Space)/.test(r) ? r : r.charAt(0).toUpperCase() + r.slice(1)) + ".";
  const up = { rssUp: true, rssRule: { name: "Show", enabled: false } };
  assert.equal(sentence(Registry.needsReason("rssRule", { rssUp: true })), W.reasonRule);
  assert.equal(sentence(Registry.needsReason("rssFieldEditable", up)), W.reasonFieldEditable);
  assert.equal(sentence(Registry.needsReason("rssFieldToggle", up)), W.reasonFieldToggle);
  assert.equal(sentence(Registry.needsReason("rssRuleDirty", up)), W.reasonRuleDirty);
  for (const need of ["rssRule", "rssFieldEditable", "rssFieldToggle", "rssRuleDirty"]) assert.equal(sentence(Registry.needsReason(need, {})), RSS5B1.window.reasonDown, need);
  for (const [kind, word] of [["rssRuleRemove", "remove"], ["rssRuleOn", "turn on"], ["rssRuleEditOff", "turn off and edit"], ["rssRuleLeave", "save"],
    ["rssRuleDiscard", "discard"]]) assert.equal(View.RSS_ACCEPT[kind], word, kind);
  // Fix round 1: Settings' auto-download confirm is Settings', so RssPane.dropConfirm can't drop it.
  assert.equal(View.RSS_ACCEPT.rssAutoDlOn, undefined);
  assert.deepEqual(View.SETTINGS_ACCEPT, { rssAutoDlOn: "turn on" });
  assert.equal(View.rssRulesFooterNote("rssRuleFields", { rssUp: true, rssAutoDl: true }), W.autoDlFooter);
  assert.deepEqual(View.inputPrompt("rssRuleName"), { prompt: W.promptRuleName, placeholder: "" });
  assert.deepEqual(View.inputPrompt("rssRuleRename", "Show"), { prompt: W.promptRuleRename, placeholder: "Show" });
  assert.deepEqual(View.inputPrompt("rssRuleField"), { prompt: W.promptRuleField, placeholder: "" });
});

test("rules contract: every sentence and window line is quoted, and it quotes no other sentence", () => {
  for (const group of ["sentences", "window"]) {
    for (const [k, s] of Object.entries(data[group])) assert.ok(contract.includes('"' + s + '"'), group + "." + k + ": " + s);
  }
  const known = new Set(Object.values(data.sentences).concat(Object.values(data.window)));
  const quoted = Array.from(contract.matchAll(/"([^"\n]+)"/g)).map((m) => m[1]).filter((q) => /^[A-Za-z]/.test(q) && /[.?]$/.test(q));
  assert.ok(quoted.length > 40, "the contract quotes its sentences");
  for (const q of quoted) assert.ok(known.has(q), "rss-rules-contract.md quotes a sentence the case file doesn't hold: " + q);
});

test("rules contract: RULE_FIELDS is the table, in order, with the case file's labels", () => {
  const rows = Array.from(contract.matchAll(/^\| `([a-zA-Z]+)` \| "([^"]+)" \| ([a-zA-Z]+) \|/gm)).map((m) => [m[1], m[2], m[3]]);
  assert.deepEqual(rows, RULE_FIELDS.map(([k, label, kind]) => [k, data.window[label], kind]));
  for (const [k] of RULE_FIELDS) {
    const cap = k.charAt(0).toUpperCase() + k.slice(1);
    assert.equal(typeof data.window["label" + cap], "string", k);
    assert.equal(typeof data.window["help" + cap], "string", k);
  }
});

test("rules contract: the qbt shapes the lanes build against are written down", () => {
  for (const s of [
    "### `qbt rss rules`", "### `qbt rss rule-check`", "### `qbt rss rule-create`", "### `qbt rss rule-set`", "### `qbt rss rule-preview`",
    "### `qbt rss rules-preview-enabled`", "### `qbt rss rule-rename`", "### `qbt rss rule-remove`",
    "`{\"autoDownload\": bool, \"rules\": [{\"name\", \"enabled\", \"fields\", \"raw\"}]}`",
    "stdin `key\\0value\\0useRegex`",
    "`{\"ok\": true, \"value\": normalised}`",
    "stdin `name\\0feedUrl`",
    "`{\"enabled\": false, \"affectedFeeds\": [feedUrl]}`",
    "stdin `name\\0changesJson\\0snapshotJson\\0enable`",
    "`{\"will\": [{\"feedPath\", \"guid\", \"title\", \"dup\"}], \"read\": [...], \"noTorrent\": [...], \"unpreviewable\": [{\"name\", \"feedPaths\"}], \"gone\": [url]}`",
    "`{\"rules\": r, \"will\": n, \"noTorrent\": m}`",
    "stdin `from\\0to`",
    "`pcre2grep -u -i -f <(printf '%s\\n' \"$pattern\") /dev/null`",
    "each command takes exactly K fields: `rules` and `rules-preview-enabled` read no stdin; `rule-preview` and `rule-remove` take 1; `rule-create` and `rule-rename` take 2; `rule-check` takes 3; `rule-set` takes 4;",
    "A bare `qbt rss` or an unknown subcommand still prints 5b1's usage line",
    "previews the saved rule as `rule-preview` does before any write",
    "union_episodes",
    "Service.rssAutoPreview(cb)",
    "rssRules(cb)", "rssRuleCheck(key, value, useRegex, cb)", "rssRuleCreate(name, feedUrl)", "rssRuleSet(name, changes, snapshot, enable)",
    "rssRulePreview(name, cb)", "rssRuleRename(from, to)", "rssRuleRemove(name)",
    "RssRules.js pins its `WINDOW` and `SENTENCES` to rss-autorules-cases.json",
    "\"confirmVia\": \"rssAutoDl\"",
    // Fix round 1.
    "`rssRuleSet(name, {}, {}, \"on\")`",
    "With `on`, `changesJson` and `snapshotJson` must both be `{}`",
    "having written nothing",
    "After any successful save the draft is clean and its snapshot becomes the written values",
    "Every action that leaves a dirty draft's rule raises CONFIRM `rssRuleLeave` first",
    "`View.SETTINGS_ACCEPT`",
    "`SettingsCommands.dropConfirm`",
    "`View.rssRulesFooterNote(pane, flags)`",
    "the effective URL: torrentURL, or link when torrentURL is empty",
    "any value, even one that isn't an object"
  ]) assert.ok(contract.includes(s), s);
});
