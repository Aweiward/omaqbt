// Slice 5b1 (Task 1): the shared RSS contract's own consistency. The lanes
// test their code against tests/fixtures/rss-rules-cases.json; this pins the
// file's shape, the brief's exact sentences, and that rss-contract.md quotes
// only the case file's sentences (so neither can drift from the other).
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const Registry = require("../CommandRegistry.js");

const FIX = path.join(__dirname, "fixtures");
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), "utf8"));
const data = fixture("rss-rules-cases.json");
const SEARCH = fixture("search-rules-cases.json");
const LINK = fixture("link-rules-cases.json");
const contract = fs.readFileSync(path.join(FIX, "rss-contract.md"), "utf8");

function load(name) {
  const file = path.join(__dirname, "..", name);
  const src = fs.readFileSync(file, "utf8").split("\n").map((l) => (/^\s*\.(import|pragma)\b/.test(l) ? "" : l)).join("\n");
  const mod = { exports: {} };
  vm.compileFunction(src, ["module"], { filename: file })(mod);
  return mod.exports;
}
const Links = load("LinkRules.js");

const KINDS = ["feedUrl", "name", "hasTorrent", "errorReason", "articleText"];
const ALWAYS_OK = ["errorReason", "articleText"];

// The brief's sentences, exactly (plus the four feedUrl lines and the usage
// line this task added, see the report).
const SENTENCES = {
  rssUsage: "usage: qbt rss items|article|error|add-feed|add-folder|rename|remove|refresh|mark-read|add",
  feedDup: "That feed is already added.",
  itemExists: "There's already a feed or folder called <name> there.",
  feedGone: "That feed is gone.",
  folderGone: "That folder is gone.",
  articleGone: "That article is gone.",
  nameEmpty: "Enter a name.",
  nameBackslash: "Names can't contain \\.",
  nameControl: "Names can't contain control characters.",
  feedUrlEmpty: "Enter a feed URL.",
  feedUrlBad: "Feed URLs can't contain spaces, control characters, | or \\.",
  feedUrlScheme: "Feed URLs start with http:// or https://.",
  feedUrlUser: "Feed URLs can't contain a user name or password.",
  feedUrlHost: "That feed URL has no valid host.",
  noTorrent: "This article has no torrent link.",
  badTorrentLink: "That link isn't http, https or magnet.",
  unconfirmedAdd: "Couldn't confirm <name> was added.",
  unconfirmedRemove: "Couldn't confirm <name> was removed.",
  unconfirmedRename: "Couldn't confirm the rename.",
  unconfirmedRead: "Couldn't confirm the articles were marked read."
};

const WINDOW = {
  banner: "RSS is off in qBittorrent, so feeds only refresh when you press r. O turns it on (also in Settings → RSS).",
  emptyFeeds: "No feeds yet. Press a and paste a feed URL.",
  emptyArticles: "No articles in this feed yet.",
  emptyUnread: "Nothing unread.",
  rowRefreshing: "refreshing…",
  rowError: "error",
  rowInLibrary: "in library",
  stillRefreshing: "Still refreshing; qBittorrent hasn't answered.",
  errorReason: "Couldn't refresh: <reason>",
  errorNoReason: "qBittorrent reported an error but gave no reason.",
  hasTorrentYes: "Torrent link",
  hasTorrentNo: "No torrent link",
  articleUnread: "unread",
  articleRead: "read",
  alreadyInLibrary: "Already in your library.",
  sent: "Sent to qBittorrent; Space marks it read.",
  added: "Added <name>.",
  cantUnread: "qBittorrent can't mark articles unread.",
  confirmAdd: "Add <title> from <host>?",
  confirmOpen: "Open <host> in your browser? It won't go through the VPN.",
  confirmRemoveFeed: "Remove <name>? This can't be undone.",
  confirmRemoveFolder: "Remove <name> and its <n> feeds? This can't be undone.",
  confirmMarkRead: "Mark <n> articles in <name> read? This can't be undone.",
  confirmMarkAll: "Mark all <n> articles in every feed read? This can't be undone.",
  moreArrived: "More articles arrived: mark <n> read? This can't be undone.",
  moreArrivedNote: "More articles arrived, so nothing was marked read; <n> are unread.",
  confirmOn: "Turn on RSS processing in qBittorrent? Feeds refresh every <n> min.",
  unreadRow: "Unread",
  allRow: "All articles",
  reasonItem: "Pick a feed or folder.",
  reasonArticle: "No article here.",
  reasonUnread: "Nothing unread.",
  reasonProcessingOn: "RSS is already on.",
  reasonDown: "qBittorrent isn't reachable.",
  promptFeedUrl: "Feed URL",
  placeholderFeedUrl: "https://…",
  promptFeedName: "Feed name",
  promptFolderName: "Folder name",
  promptRename: "Rename"
};

test("rss cases: every case has the documented shape", () => {
  assert.equal(typeof data._doc, "string");
  assert.deepEqual(Object.keys(data).sort(), ["_doc", "cases", "sentences", "window"]);
  assert.ok(Array.isArray(data.cases) && data.cases.length > 60);
  const messages = new Set(Object.values(data.sentences));
  for (const c of data.cases) {
    const label = c.kind + " " + JSON.stringify(c.input).slice(0, 80);
    assert.ok(KINDS.includes(c.kind), label);
    assert.ok("input" in c, label);
    assert.equal(typeof c.ok, "boolean", label);
    assert.equal(typeof c.why, "string", label);
    for (const k of Object.keys(c)) assert.ok(["kind", "input", "ok", "normalised", "message", "why"].includes(k), label + " " + k);
    assert.equal("message" in c, c.ok === false, label + ": a message exactly when refused");
    assert.equal("normalised" in c, c.ok === true, label + ": normalised exactly when ok");
    if ("message" in c) assert.ok(messages.has(c.message), label + ": the message is one of `sentences`");
  }
  for (const kind of KINDS) {
    const of = data.cases.filter((c) => c.kind === kind);
    assert.ok(of.some((c) => c.ok), kind + " has an ok case");
    if (ALWAYS_OK.includes(kind)) assert.ok(of.every((c) => c.ok), kind + " is never refused");
    else assert.ok(of.some((c) => !c.ok), kind + " has a refused case");
  }
});

test("rss cases: the brief's required cases are there", () => {
  const of = (kind) => data.cases.filter((c) => c.kind === kind);
  const has = (kind, pred, why) => assert.ok(of(kind).some(pred), kind + ": " + why);
  // feedUrl: http and https ok; ftp, file, javascript, userinfo, |, whitespace and \ refused; an uppercase scheme accepted.
  has("feedUrl", (c) => c.ok && /^http:\/\//.test(c.input), "http");
  has("feedUrl", (c) => c.ok && /^https:\/\//.test(c.input), "https");
  has("feedUrl", (c) => c.ok && /^HTTPS:\/\//.test(c.input), "an uppercase scheme");
  for (const s of ["ftp:", "file:", "javascript:"]) has("feedUrl", (c) => !c.ok && c.input.startsWith(s) && c.message === data.sentences.feedUrlScheme, s);
  has("feedUrl", (c) => !c.ok && c.input.includes("@") && c.message === data.sentences.feedUrlUser, "userinfo");
  has("feedUrl", (c) => !c.ok && c.input.includes("|") && c.message === data.sentences.feedUrlBad, "|");
  has("feedUrl", (c) => !c.ok && / /.test(c.input) && c.message === data.sentences.feedUrlBad, "whitespace");
  has("feedUrl", (c) => !c.ok && c.input.includes("\\") && c.message === data.sentences.feedUrlBad, "\\");
  // name: ok, empty, whitespace only, \, control characters, U+FEFF kept (ruling FE), and trim.
  has("name", (c) => c.ok && c.input === c.normalised, "ok");
  has("name", (c) => !c.ok && c.input === "" && c.message === data.sentences.nameEmpty, "empty");
  has("name", (c) => !c.ok && c.input !== "" && c.input.trim() === "" && c.message === data.sentences.nameEmpty, "whitespace only");
  has("name", (c) => !c.ok && c.message === data.sentences.nameBackslash, "\\");
  has("name", (c) => !c.ok && c.message === data.sentences.nameControl, "control characters");
  has("name", (c) => c.ok && c.input.includes("﻿") && c.normalised.includes("﻿"), "U+FEFF kept");
  has("name", (c) => c.ok && c.normalised !== c.input, "trim");
  // hasTorrent.
  const ht = (pred) => (c) => pred(c.input.torrentURL, c.input.link, c);
  has("hasTorrent", ht((t, l, c) => c.ok && t.startsWith("magnet:") && c.normalised === "magnet"), "a magnet");
  has("hasTorrent", ht((t, l, c) => c.ok && t !== l && /^https?:/.test(t) && l !== "" && c.normalised === "url"), "an enclosure different from the link");
  has("hasTorrent", ht((t, l, c) => !c.ok && t === l && !/\.torrent/i.test(t) && c.message === data.sentences.noTorrent), "torrentURL equal to the link, both news");
  has("hasTorrent", ht((t, l, c) => c.ok && t === l && /\.torrent$/.test(t) && c.normalised === "url"), "torrentURL equal to the link, ending in .torrent");
  has("hasTorrent", ht((t, l, c) => c.ok && t === l && t.endsWith(".TORRENT?x=1")), ".TORRENT?x=1");
  has("hasTorrent", ht((t, l, c) => !c.ok && t.startsWith("javascript:") && c.message === data.sentences.badTorrentLink), "javascript");
  has("hasTorrent", ht((t, l, c) => !c.ok && t.includes("@") && c.message === data.sentences.badTorrentLink), "userinfo");
  has("hasTorrent", ht((t, l, c) => !c.ok && t === "" && c.message === data.sentences.noTorrent), "an empty torrentURL");
  has("hasTorrent", ht((t, l, c) => c.ok && /download\.php\?id=/.test(t)), "OV1: a download.php link");
  // errorReason.
  const er = (pred) => (c) => pred(c.input.log, c.input.url, c.normalised);
  has("errorReason", er((log, u, n) => n !== null && log.some((r) => r.message.startsWith("Failed to download RSS feed at '"))), "a download message");
  has("errorReason", er((log, u, n) => n !== null && log.some((r) => r.message.startsWith("Failed to parse RSS feed at '"))), "a parse message");
  has("errorReason", er((log, u, n) => log.length > 1 && n !== null && log[0].id < log[1].id), "the newest wins (later row)");
  has("errorReason", er((log, u, n) => log.length > 1 && n !== null && log[0].id > log[1].id), "the newest wins (earlier row)");
  has("errorReason", er((log, u, n) => n === null && log.some((r) => r.message.startsWith("Failed to download RSS feed at 'https://example.net"))), "another URL");
  has("errorReason", er((log, u, n) => n === null && log.some((r) => !r.message.startsWith("Failed"))), "a translated message");
  has("errorReason", er((log, u, n) => n !== null && u.includes("'")), "a URL containing '");
  for (const c of of("errorReason")) assert.ok(c.normalised === null || typeof c.normalised === "string", JSON.stringify(c.input));
  // articleText.
  const at = (pred, why) => has("articleText", (c) => pred(c.input, c.normalised), why);
  at((i, n) => /<script>/.test(i) && !n.text.includes("alert"), "script");
  at((i, n) => /<style>/.test(i) && !n.text.includes("color"), "style");
  at((i, n) => /&amp;/.test(i) && n.text.includes("&"), "entities");
  at((i, n) => /<br>/.test(i) && n.text.includes("\n"), "<br>");
  at((i, n) => (i.match(/<ul>/g) || []).length >= 2, "nested lists");
  at((i, n) => i.length >= 10000 && n.truncated === true && Array.from(n.text).length === 4096, "a 10 KB input capped at 4096 with truncated true");
  at((i, n) => /[‪-‮⁦-⁩]/.test(n.text), "bidi characters kept");
  for (const c of of("articleText")) {
    assert.deepEqual(Object.keys(c.normalised).sort(), ["text", "truncated"], c.why);
    assert.equal(typeof c.normalised.truncated, "boolean", c.why);
    if (c.normalised.truncated) assert.equal(Array.from(c.normalised.text).length, 4096, c.why + ": a truncated text is exactly 4096 code points");
    assert.ok(Array.from(c.normalised.text).length <= 4096, c.why);
    assert.ok(!/^\n|\n$|\n{4}/.test(c.normalised.text), c.why + ": no edge newlines, at most 2 blank lines");
  }
});

test("rss cases: the sentences and the window's copy are the brief's, exactly", () => {
  assert.deepEqual(data.sentences, SENTENCES);
  assert.deepEqual(data.window, WINDOW);
});

test("rss cases: every placeholder is one of name, title, host, n and reason", () => {
  for (const group of ["sentences", "window"]) {
    for (const [k, s] of Object.entries(data[group])) {
      for (const m of s.match(/<[^<>]*>/g) || []) assert.ok(["<name>", "<title>", "<host>", "<n>", "<reason>"].includes(m), group + "." + k + ": " + m);
    }
  }
  for (const c of data.cases) if (c.message) assert.ok(!/<[a-z]+>/.test(c.message), "a case message is filled: " + c.message);
});

test("rss cases: shared copy agrees with Search's and the registry's", () => {
  assert.equal(data.window.confirmOpen, SEARCH.window.openConfirm);
  assert.equal(data.window.added, SEARCH.window.added);
  assert.equal(data.sentences.unconfirmedAdd, SEARCH.window.addUnconfirmed);
  assert.equal(data.window.reasonDown, Registry.SEARCH_REASONS.down + ".");
  assert.equal(data.window.alreadyInLibrary, SEARCH.window.inLibrary);
});

test("rss cases: the window's pre-checks agree with 5b0's LinkRules", () => {
  // A feed URL's host is the page-link rule's host.
  for (const c of data.cases.filter((x) => x.kind === "feedUrl" && x.ok)) {
    assert.deepEqual(Links.checkPageLink(c.input), { ok: true, host: c.normalised }, c.input);
  }
  // A name is trimmed with Qt's isSpace set (LinkRules.qtTrim).
  for (const c of data.cases.filter((x) => x.kind === "name")) {
    const t = Links.qtTrim(c.input);
    if (c.ok) assert.equal(t, c.normalised, c.why);
    else if (c.message === data.sentences.nameEmpty) assert.equal(t, "", c.why);
    else assert.notEqual(t, "", c.why);
  }
  // Every refused URL kind refuses what LinkRules' BAD class holds.
  for (const c of data.cases.filter((x) => x.kind === "feedUrl" && !x.ok && x.message === data.sentences.feedUrlBad)) {
    assert.ok(Links.BAD.test(c.input) || c.input.includes("|"), c.why);
  }
  assert.ok(LINK.cases.length > 0);
});

test("rss contract: every sentence and window line is quoted, and it quotes no other sentence", () => {
  for (const group of ["sentences", "window"]) {
    for (const [k, s] of Object.entries(data[group])) assert.ok(contract.includes(s), group + "." + k + ": " + s);
  }
  const known = new Set(Object.values(data.sentences).concat(Object.values(data.window)));
  for (const c of LINK.cases) if (c.message) known.add(c.message);
  const quoted = Array.from(contract.matchAll(/"([^"\n]+)"/g)).map((m) => m[1]).filter((q) => /^[A-Za-z]/.test(q) && /[.?]$/.test(q));
  assert.ok(quoted.length > 40, "the contract quotes its sentences");
  for (const q of quoted) assert.ok(known.has(q), "rss-contract.md quotes a sentence the case file doesn't hold: " + q);
});

test("rss contract: the qbt shapes the lanes build against are written down", () => {
  for (const s of [
    "### `qbt rss items`", "### `qbt rss article`", "### `qbt rss error`", "### `qbt rss add-feed`", "### `qbt rss add-folder`",
    "### `qbt rss rename`", "### `qbt rss remove`", "### `qbt rss refresh`", "### `qbt rss mark-read`", "### `qbt rss add`",
    "**Every value arrives on stdin**, NUL-separated, never in argv",
    "`{\"path\", \"name\", \"depth\", \"folder\": false, \"url\", \"title\", \"isLoading\", \"hasError\", \"unread\", \"total\"}`",
    "`{\"path\", \"name\", \"depth\", \"folder\": true, \"unread\", \"total\", \"feeds\"}`",
    "`{\"feedPath\", \"guid\", \"title\", \"date\", \"isRead\", \"torrentURL\", \"link\", \"hasTorrent\", \"host\"}`",
    "`log/main?normal=false&info=false&warning=true&critical=false&last_known_id=<id>`",
    "`$STATE_DIR/rss-errors.json` (mode 0600) holds `{\"lastId\": N, \"reasons\": {url: text}}`",
    "It keeps at most 200 URLs, dropping the least recently stored first.",
    "qbt never extracts a URL from a message",
    "qbt posts every path and URL exactly as it received it, never a trimmed variant",
    "stdin `path\\0guid\\0expect`",
    "prints `{\"ok\": false, \"unread\": M}` (OV11; exit 0)",
    "`folderPath === \"\" ? name : folderPath + \"\\\\\" + name`",
    "`qbt pref-set rss_processing_enabled -- true`",
    // Fix round 1 (the controller's rulings).
    "The framing is new in 5b1 (`qbt pref-set --stdin` reads one raw value, not fields)",
    "each command takes exactly K fields: `items` reads no stdin; `error`, `add-folder`, `remove` and `refresh` take 1; `article`, `add-feed`, `rename` and `add` take 2; `mark-read` takes 3;",
    "an empty stdin is ONE empty field",
    "a wrong field count exits 2 with the usage line below.",
    "That includes `mark-read`'s `{\"ok\": false, \"unread\": M}`, which is an answer, not a failure.",
    "The `name` rule applies **only to the segment being created**",
    "are taken exactly as `rss/items` gave them",
    "qbt matches each on its prefix",
    "Every write except `qbt rss add` and `qbt rss refresh` reads `rss/items` back",
    "`refreshInterval` is `rss_refresh_interval`",
    "Absent means false; qbt always outputs `isRead` as a bool. The fixture omits it on unread articles.",
    "A feed whose `hasError` is false has its stored reason dropped",
    "qbt resets `lastId` to 0 and rescans the whole log",
    "for `null` and for an empty reason (`\"\"`)",
    "the feed check comes first, so a missing feed prints \"That feed is gone.\"",
    "The POST must **omit** `articleId` entirely",
    "The window skips an unchanged rename (the same name) without calling qbt.",
    "The name and rename placeholders never show"
  ]) assert.ok(contract.includes(s), s);
});
