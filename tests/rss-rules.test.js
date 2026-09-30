// Slice 5b2 (Task 3): RssRules.js, the rules area's pure rules, against
// tests/fixtures/rss-autorules-cases.json: its `window` and `sentences`
// copy, the RULE_FIELDS table of tests/fixtures/rss-rules-contract.md, the
// `fields` rows (what fieldRows draws), the `patch` rows (the exact
// changes and snapshot rule-set takes, which draftDiff builds), the
// `previewJoin` rows (what previewGroups draws) and the `ruleName` rows
// (a's and n's INSERT pre-check).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// RssRules.js imports LinkRules.js as Links (tests/rss-view.test.js's loader).
function load(name, params, args) {
  const file = path.join(__dirname, "..", name);
  const src = fs.readFileSync(file, "utf8")
    .split("\n")
    .map((line) => (/^\s*\.(import|pragma)\b/.test(line) ? "" : line))
    .join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"].concat(params), { filename: file })(mod, ...args);
  return mod.exports;
}

const Links = load("LinkRules.js", [], []);
const R = load("RssRules.js", ["Links"], [Links]);
const DATA = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "rss-autorules-cases.json"), "utf8"));
const MD = fs.readFileSync(path.join(__dirname, "fixtures", "rss-rules-contract.md"), "utf8");
const W = DATA.window;
const S = DATA.sentences;
const fill = (t, v) => Links.fill(t, v);
const rows = (kind) => DATA.cases.filter((c) => c.kind === kind);

// ---- the copy -----------------------------------------------------------------------------

test("WINDOW and SENTENCES are the case file's, and sentence() fills them", () => {
  assert.deepEqual(R.WINDOW, W);
  assert.deepEqual(R.SENTENCES, S);
  for (const k of Object.keys(W)) assert.equal(R.sentence(k, {}), W[k], k);
  for (const k of Object.keys(S)) assert.equal(R.sentence(k, {}), S[k], k);
  assert.equal(R.sentence("noteCreated", { name: "Show" }), fill(W.noteCreated, { name: "Show" }));
  assert.equal(R.sentence("noTorrentBlock", { m: 2 }), fill(S.noTorrentBlock, { m: 2 }));
  assert.equal(R.sentence("nope", {}), "");
});

// ---- RULE_FIELDS ----------------------------------------------------------------------------

test("RULE_FIELDS: the contract table's order, labels, kinds, and the help lines", () => {
  const table = [];
  const re = /^\| `([a-zA-Z]+)` \| "([^"]+)" \| ([a-zA-Z]+) \|/gm;
  let m;
  while ((m = re.exec(MD)) !== null) table.push({ key: m[1], label: m[2], kind: m[3] });
  assert.equal(table.length, 11);
  assert.deepEqual(R.RULE_FIELDS.map((f) => ({ key: f.key, label: f.label, kind: f.kind })), table);
  for (const f of R.RULE_FIELDS) {
    const cap = f.key.charAt(0).toUpperCase() + f.key.slice(1);
    assert.equal(f.label, W["label" + cap], f.key);
    assert.equal(f.help, W["help" + cap], f.key);
  }
  // Every key fields_of gives, in the same order.
  assert.deepEqual(R.RULE_FIELDS.map((f) => f.key), Object.keys(rows("fields")[0].normalised));
});

test("field kinds: which INSERT, picker or toggle each opens, and which qbt checks", () => {
  assert.deepEqual(R.RULE_FIELDS.filter((f) => R.isToggle(f.kind)).map((f) => f.key), ["enabled", "useRegex", "smartFilter"]);
  assert.deepEqual(R.RULE_FIELDS.filter((f) => R.isInsert(f.kind)).map((f) => f.key), ["mustContain", "mustNotContain", "episodeFilter", "savePath", "ignoreDays"]);
  assert.deepEqual(R.RULE_FIELDS.filter((f) => R.isPicker(f.kind)).map((f) => f.key), ["affectedFeeds", "category", "addStopped"]);
  // rule-check's keys are exactly the INSERT fields.
  for (const f of R.RULE_FIELDS) assert.equal(R.isInsert(f.kind), ["mustContain", "mustNotContain", "episodeFilter", "ignoreDays", "savePath"].indexOf(f.key) !== -1, f.key);
  assert.equal(R.fieldOf("savePath").kind, "path");
  assert.equal(R.fieldOf("nope"), null);
});

// ---- fieldRows ------------------------------------------------------------------------------

test("fieldRows: every fields row, drawn with the case file's value words", () => {
  for (const c of rows("fields")) {
    const f = c.normalised;
    const got = R.fieldRows(f, []);
    assert.deepEqual(got.map((r) => r.key), R.RULE_FIELDS.map((x) => x.key), c.why);
    for (const r of got) {
      const v = f[r.key];
      assert.deepEqual(r.value, v, c.why + " " + r.key);
      let want;
      if (typeof v === "boolean") want = v ? W.stateOn : W.stateOff;
      else if (r.key === "category") want = v === "" ? W.categoryNone : Links.cleanName(v);
      else if (r.key === "savePath") want = v === "" ? W.savePathDefault : Links.cleanName(v);
      else if (r.key === "addStopped") want = { default: W.addStoppedDefault, yes: W.addStoppedYes, no: W.addStoppedNo }[v];
      else if (r.key === "ignoreDays") want = String(v);
      else if (r.key === "affectedFeeds") want = v.length === 0 ? W.valueEmpty : v.map((u) => fill(W.feedGone, { url: Links.cleanName(u) })).join(", ");
      else want = v === "" ? W.valueEmpty : Links.cleanName(v);
      assert.equal(r.text, want, c.why + " " + r.key);
      assert.equal(r.label, R.fieldOf(r.key).label);
      assert.equal(r.help, R.fieldOf(r.key).help);
    }
  }
});

test("fieldRows: feeds by path, a URL no feed has as (gone), placeholders muted, hostile text sanitised", () => {
  const feeds = [
    { path: "Linux", name: "Linux", folder: true },
    { path: "Linux\\Arch", name: "Arch", folder: false, url: "https://archlinux.org/feeds/news/" },
    { path: "<b>Evil</b>‮", name: "x", folder: false, url: "https://e.example/rss" }
  ];
  const f = Object.assign({}, rows("fields")[2].normalised, {
    affectedFeeds: ["https://archlinux.org/feeds/news/", "https://gone.example/rss", "https://e.example/rss"],
    mustContain: "<i>Show</i>‮\u0007x",
    category: "",
    savePath: ""
  });
  const got = R.fieldRows(f, feeds);
  const by = (k) => got.filter((r) => r.key === k)[0];
  assert.equal(by("affectedFeeds").text, "Linux\\Arch, " + fill(W.feedGone, { url: "https://gone.example/rss" }) + ", <b>Evil</b>");
  assert.equal(by("mustContain").text, "<i>Show</i> x", "bidi stripped, a control a space");
  assert.equal(by("mustContain").value, "<i>Show</i>‮\u0007x", "the value stays raw (the INSERT's prefill)");
  assert.equal(by("mustNotContain").text, W.valueEmpty);
  assert.equal(by("mustNotContain").muted, true);
  assert.equal(by("category").muted, true);
  assert.equal(by("savePath").muted, true);
  assert.equal(by("addStopped").muted, true, "default is qBittorrent's own");
  assert.equal(by("mustContain").muted, false);
  assert.equal(by("enabled").muted, false);
  // A 400-character pattern is capped for the row, not for the value.
  const long = "a".repeat(400);
  const r2 = R.fieldRows(Object.assign({}, f, { mustContain: long }), feeds).filter((r) => r.key === "mustContain")[0];
  assert.equal(Array.from(r2.text).length, 300);
  assert.equal(r2.value, long);
});

// ---- draftDiff ------------------------------------------------------------------------------

// The draft's start: fields_of values plus enabled and useAutoTmm.
function startFrom(snap) {
  const base = Object.assign({}, rows("fields")[2].normalised, { useAutoTmm: true });
  return Object.assign(base, snap);
}

test("draftDiff: every well-shaped keep or off patch row's changes and snapshot, exactly", () => {
  let n = 0;
  for (const c of rows("patch")) {
    const ch = c.input.changes;
    const snap = c.input.snapshot;
    if (Object.keys(ch).length === 0 || !Object.prototype.hasOwnProperty.call(snap, "enabled") || c.input.enable === "on") continue;
    const start = startFrom(snap);
    const draft = Object.assign({}, start, ch);
    delete draft.useAutoTmm;
    assert.deepEqual(R.draftDiff(draft, start), { changes: ch, snapshot: snap }, c.why);
    n++;
  }
  assert.ok(n >= 25, "rows checked: " + n);
});

test("draftDiff: no change is {} and {}; lists compare in order; useAutoTmm only with savePath", () => {
  const start = startFrom({ affectedFeeds: ["a", "b"], enabled: false, useAutoTmm: null });
  assert.deepEqual(R.draftDiff(Object.assign({}, start), start), { changes: {}, snapshot: {} });
  const d = Object.assign({}, start, { affectedFeeds: ["b", "a"] });
  assert.deepEqual(R.draftDiff(d, start), { changes: { affectedFeeds: ["b", "a"] }, snapshot: { affectedFeeds: ["a", "b"], enabled: false } });
  const p = Object.assign({}, start, { savePath: "/x" });
  assert.deepEqual(R.draftDiff(p, start), { changes: { savePath: "/x" }, snapshot: { savePath: "", useAutoTmm: null, enabled: false } });
  // enabled in the draft is never a change (only e turns a rule on or off).
  const e = Object.assign({}, start, { enabled: true });
  assert.deepEqual(R.draftDiff(e, start), { changes: {}, snapshot: {} });
  // The results are copies: editing them never reaches the draft.
  const r = R.draftDiff(d, start);
  r.changes.affectedFeeds.push("z");
  assert.deepEqual(d.affectedFeeds, ["b", "a"]);
  assert.equal(R.isDirty(d, start), true);
  assert.equal(R.isDirty(Object.assign({}, start), start), false);
});

// ---- previewGroups --------------------------------------------------------------------------

test("previewGroups: every previewJoin row, n m k from the groups, dup and unpreviewable as text", () => {
  for (const c of rows("previewJoin")) {
    const p = c.normalised;
    const g = R.previewGroups(p);
    assert.equal(g.n, p.will.length, c.why);
    assert.equal(g.m, p.noTorrent.length, c.why);
    assert.equal(g.k, p.read.length, c.why);
    const texts = g.lines.map((l) => l.text);
    const nothing = p.will.length + p.read.length + p.noTorrent.length === 0 && p.unpreviewable.length === 0;
    assert.equal(g.empty, nothing, c.why);
    if (nothing) { assert.deepEqual(texts, [W.previewEmpty], c.why); continue; }
    const want = [fill(W.previewWill, { n: p.will.length })];
    const row = (a) => Links.cleanName(a.title) + (a.dup > 1 ? " " + fill(W.previewDup, { k: a.dup }) : "");
    p.will.forEach((a) => want.push(row(a)));
    want.push(fill(W.previewNoTorrent, { m: p.noTorrent.length }));
    p.noTorrent.forEach((a) => want.push(row(a)));
    want.push(fill(W.previewRead, { k: p.read.length }));
    p.read.forEach((a) => want.push(row(a)));
    p.unpreviewable.forEach((u) => want.push(fill(W.previewUnpreviewable, { name: Links.cleanName(u.name) })));
    assert.deepEqual(texts, want, c.why);
    // The heads: Would download plain, the other two muted.
    assert.equal(g.lines[0].muted, false);
    assert.equal(g.lines.filter((l) => l.text === fill(W.previewNoTorrent, { m: p.noTorrent.length }))[0].muted, true);
    assert.equal(g.lines.filter((l) => l.text === fill(W.previewRead, { k: p.read.length }))[0].muted, true);
  }
  // Review Focus 4: the all-at-once row has the pair, dup 3 and a gone URL.
  const all = rows("previewJoin").filter((c) => /all at once/.test(c.why))[0].normalised;
  const g = R.previewGroups(all);
  assert.ok(g.lines.some((l) => l.text === "Arch news " + fill(W.previewDup, { k: 3 })));
  assert.ok(g.lines.some((l) => l.text === fill(W.previewUnpreviewable, { name: "Show" })));
  assert.deepEqual(g.gone, all.gone);
});

test("previewGroups: n never counts an unpreviewable feed's articles, and hostile titles are sanitised", () => {
  const p = {
    will: [{ feedPath: "A\\Show", guid: "1", title: "x", dup: 1 }, { feedPath: "B\\Show", guid: "2", title: "y", dup: 1 },
      { feedPath: "Linux\\Arch", guid: "3", title: "<b>z</b>‮\u0000q", dup: 2 }],
    read: [{ feedPath: "A\\Show", guid: "4", title: "r", dup: 1 }],
    noTorrent: [{ feedPath: "B\\Show", guid: "5", title: "n", dup: 1 }],
    unpreviewable: [{ name: "Sh‮ow", feedPaths: ["A\\Show", "B\\Show"] }],
    gone: []
  };
  const g = R.previewGroups(p);
  assert.equal(g.n, 1);
  assert.equal(g.m, 0);
  assert.equal(g.k, 0);
  assert.equal(g.lines[1].text, "<b>z</b> q " + fill(W.previewDup, { k: 2 }));
  assert.equal(g.lines[g.lines.length - 1].text, fill(W.previewUnpreviewable, { name: "Show" }));
  // Anything that isn't a preview is nothing at all.
  for (const bad of [null, undefined, 3, "x", {}]) {
    const e = R.previewGroups(bad);
    assert.equal(e.empty, true);
    assert.equal(e.n, 0);
    assert.deepEqual(e.lines.map((l) => l.text), [W.previewEmpty]);
  }
});

// ---- confirms and names ---------------------------------------------------------------------

test("confirmLine: every rules confirm, the name sanitised, turn-on by n and auto-download", () => {
  const name = "Show‮\u0007";
  const clean = "Show";
  assert.equal(R.confirmLine("rssRuleRemove", { name }), fill(W.confirmRemove, { name: clean }));
  assert.equal(R.confirmLine("rssRuleEditOff", { name }), fill(W.confirmEditOff, { name: clean }));
  assert.equal(R.confirmLine("rssRuleLeave", { name }), fill(W.confirmLeave, { name: clean }));
  assert.equal(R.confirmLine("rssRuleDiscard", { name }), fill(W.confirmDiscard, { name: clean }));
  assert.equal(R.confirmLine("rssRuleOn", { name, n: 3, autoDl: true }), fill(W.confirmRuleOn, { name: clean, n: 3 }));
  assert.equal(R.confirmLine("rssRuleOn", { name, n: 0, autoDl: true }), fill(W.confirmRuleOnNone, { name: clean }));
  assert.equal(R.confirmLine("rssRuleOn", { name, n: 3, autoDl: false }), fill(W.confirmRuleOnAutoOff, { name: clean }));
  assert.equal(R.confirmLine("rssRuleOn", { name, n: 0, autoDl: false }), fill(W.confirmRuleOnAutoOff, { name: clean }));
  assert.equal(R.confirmLine("nope", { name }), "");
  assert.equal(R.displayName(""), Links.EMPTY);
});

test("checkRuleName: every ruleName row (a's and n's INSERT; qbt checks again)", () => {
  const rs = rows("ruleName");
  assert.ok(rs.length > 10);
  for (const c of rs) {
    const got = R.checkRuleName(c.input);
    assert.equal(got.ok, c.ok, c.why);
    if (c.ok) assert.equal(got.normalised, c.normalised, c.why);
    else assert.equal(got.message, c.message, c.why);
  }
  assert.equal(R.checkRuleName(undefined).message, S.ruleNameEmpty);
});

test("ruleExists: an exact name match against qbt's list", () => {
  const list = [{ name: "Show" }, { name: " odd " }];
  assert.equal(R.ruleExists(list, "Show"), true);
  assert.equal(R.ruleExists(list, "show"), false);
  assert.equal(R.ruleExists(list, " odd "), true);
  assert.equal(R.ruleExists(null, "Show"), false);
});
