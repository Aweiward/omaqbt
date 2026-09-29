// Slice 5b1 (Task 3): RssView.js, the RSS view's pure rules, against the
// feedUrl, name and hasTorrent rows of tests/fixtures/rss-rules-cases.json
// (the window's pre-checks), 5b0's magnetHash rows for the library match,
// and the case file's `window` and `sentences` copy.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// RssView.js imports LinkRules.js as Links; the loader injects it as a
// parameter (tests/search-view.test.js's loader).
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
const R = load("RssView.js", ["Links"], [Links]);
const DATA = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "rss-rules-cases.json"), "utf8"));
const LINK = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "link-rules-cases.json"), "utf8"));
const W = DATA.window;
const S = DATA.sentences;
const fill = (t, v) => Links.fill(t, v);

const V1 = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a";
const MAGNET = "magnet:?xt=urn:btih:" + V1 + "&dn=debian";

function feed(path, extra) {
  const segs = path.split("\\");
  return Object.assign({ path, name: segs[segs.length - 1], depth: segs.length - 1, folder: false, url: "https://e.example/" + segs.join("/"),
    title: "", isLoading: false, hasError: false, unread: 0, total: 0 }, extra || {});
}
function folder(path, extra) {
  const segs = path.split("\\");
  return Object.assign({ path, name: segs[segs.length - 1], depth: segs.length - 1, folder: true, unread: 0, total: 0, feeds: 0 }, extra || {});
}
function art(feedPath, guid, extra) {
  return Object.assign({ feedPath, guid, title: "t " + guid, date: 1000, isRead: false, torrentURL: "", link: "", hasTorrent: false, host: "" }, extra || {});
}

// ---- the copy -----------------------------------------------------------------------------

test("the window's copy and qbt's sentences are the case file's", () => {
  assert.deepEqual(R.WINDOW, W);
  assert.deepEqual(R.SENTENCES, S);
  for (const k of Object.keys(W)) assert.equal(R.sentence(k, {}), W[k], k);
  for (const k of Object.keys(S)) assert.equal(R.sentence(k, {}), S[k], k);
  assert.equal(R.sentence("added", { name: "debian" }), fill(W.added, { name: "debian" }));
  assert.equal(R.sentence("unconfirmedAdd", { name: "debian" }), fill(S.unconfirmedAdd, { name: "debian" }));
  assert.equal(R.sentence("nope", {}), "");
});

// ---- every case-file row of the window's pre-checks ---------------------------------------

for (const kind of ["feedUrl", "name", "hasTorrent"]) {
  test("case file: every " + kind + " row", () => {
    const rows = DATA.cases.filter((c) => c.kind === kind);
    assert.ok(rows.length > 10);
    for (const c of rows) {
      const label = c.why + " " + JSON.stringify(c.input).slice(0, 120);
      const got = R.check(kind, c.input);
      assert.equal(got.ok, c.ok, label);
      if (!c.ok) assert.equal(got.message, c.message, label);
      else assert.deepEqual(got.normalised, c.normalised, label);
    }
  });
}

test("hostOf prefills the feed name with the feedUrl rule's host, or nothing", () => {
  for (const c of DATA.cases.filter((x) => x.kind === "feedUrl")) assert.equal(R.hostOf(c.input), c.ok ? c.normalised : "", c.why);
});

// ---- paths --------------------------------------------------------------------------------

test("joinPath at the root and in a folder; parentPath; folderPath follows OV4", () => {
  assert.equal(R.joinPath("", "Linux"), "Linux");
  assert.equal(R.joinPath("Distros", "Linux"), "Distros\\Linux");
  assert.equal(R.joinPath("A\\B", "c"), "A\\B\\c");
  assert.equal(R.parentPath("A\\B\\c"), "A\\B");
  assert.equal(R.parentPath("c"), "");
  const rows = R.feedRows({ feeds: [folder("Distros", { feeds: 1 }), feed("Distros\\Debian"), feed("News")] });
  const by = (k) => rows.find((r) => r.key === k);
  assert.equal(R.folderPath(by("unread")), "", "Unread: the root");
  assert.equal(R.folderPath(by("all")), "", "All: the root");
  assert.equal(R.folderPath(null), "", "nothing under the cursor: the root");
  assert.equal(R.folderPath(by("p:Distros")), "Distros", "a folder: itself");
  assert.equal(R.folderPath(by("p:Distros\\Debian")), "Distros", "a feed: its folder");
  assert.equal(R.folderPath(by("p:News")), "", "a feed at the root: the root");
  assert.equal(R.folderPath(by("p:Distros").rssItem), "Distros", "the frozen rssItem too");
  assert.equal(R.folderPath(by("p:Distros\\Debian").rssItem), "Distros");
});

// ---- the Feeds column ---------------------------------------------------------------------

test("feedRows: empty items give Unread and All and the emptyFeeds state", () => {
  for (const items of [null, {}, { feeds: [], articles: [] }]) {
    const rows = R.feedRows(items);
    assert.deepEqual(rows.map((r) => r.kind), ["unread", "all"]);
    assert.deepEqual(rows.map((r) => r.label), [W.unreadRow, W.allRow]);
    assert.equal(rows[0].rssItem, null);
    assert.equal(rows[1].rssItem, null);
    assert.equal(R.feedCount(items), 0);
    assert.equal(R.stateText({ loaded: true, feeds: 0, scope: "all", rows: 0 }), W.emptyFeeds);
  }
  assert.equal(R.stateText({ loaded: false, feeds: 0 }), "", "nothing read yet: no state");
});

test("feedRows: nested folders keep qbt's order and depth, with unread counts and rssItem", () => {
  const items = { feeds: [
    folder("Distros", { unread: 3, total: 7, feeds: 2 }),
    folder("Distros\\Arch", { unread: 1, total: 2, feeds: 1 }),
    feed("Distros\\Arch\\Arch news", { unread: 1, total: 2, isLoading: true }),
    feed("Distros\\Debian", { unread: 2, total: 5, hasError: true }),
    feed("News", { unread: 4, total: 4 })
  ] };
  const rows = R.feedRows(items);
  assert.deepEqual(rows.map((r) => r.key), ["unread", "all", "p:Distros", "p:Distros\\Arch", "p:Distros\\Arch\\Arch news", "p:Distros\\Debian", "p:News"]);
  assert.deepEqual(rows.map((r) => r.depth), [0, 0, 0, 1, 2, 1, 0]);
  assert.equal(rows[0].unread, 7, "Unread counts every feed's unread, never a folder's twice");
  assert.equal(rows[1].total, 11, "All counts every feed's articles");
  assert.equal(rows[2].unread, 3);
  assert.deepEqual(rows[2].rssItem, { path: "Distros", name: "Distros", folder: true, feeds: 2 });
  assert.deepEqual(rows[5].rssItem, { path: "Distros\\Debian", name: "Debian", folder: false, feeds: 0 });
  assert.equal(rows[4].state, W.rowRefreshing);
  assert.equal(rows[5].state, W.rowError);
  assert.equal(rows[6].state, "");
  assert.equal(rows[0].rssItem, null, "Unread has no rssItem");
  assert.equal(rows[1].rssItem, null, "All has no rssItem");
  assert.equal(R.feedCount(items), 3);
  assert.equal(R.anyLoading(items), true);
  assert.equal(R.anyLoading({ feeds: [feed("News")] }), false);
});

test("feedRows: a hostile name shows sanitised, and its path stays raw for writes", () => {
  const raw = " ‮Deb\u0007ian ";
  const rows = R.feedRows({ feeds: [feed(raw)] });
  assert.equal(rows[2].label, "Deb ian", "bidi stripped, a control a space, trimmed");
  assert.equal(rows[2].path, raw);
  assert.equal(rows[2].rssItem.name, raw, "rename's prefill and every write keep qbt's name");
});

// ---- the Articles column ------------------------------------------------------------------

const ITEMS = { feeds: [folder("Distros", { feeds: 2 }), feed("Distros\\Arch"), feed("Distros\\Debian"), feed("News")], articles: [
  art("Distros\\Arch", "a1", { date: 300 }),
  art("Distros\\Arch", "a2", { date: null, isRead: true }),
  art("Distros\\Debian", "d1", { date: 500, isRead: true }),
  art("Distros\\Debian", "d2", { date: null }),
  art("News", "n1", { date: 400 }),
  art("News", "n2", { date: 300 })
] };

test("articleRows: newest first, a missing date last, ties in qbt's order", () => {
  const rows = R.articleRows(ITEMS, { kind: "all", path: "" }, Links.librarySet([]));
  assert.deepEqual(rows.map((r) => r.guid), ["d1", "n1", "a1", "n2", "a2", "d2"]);
  assert.equal(rows[0].key, "Distros\\Debian\nd1");
  assert.equal(R.keyOf(rows[0]), "Distros\\Debian\nd1");
  assert.equal(rows[4].date, null);
});

test("articleRows: the Unread scope is every unread article across feeds; a folder's is its feeds'", () => {
  const lib = Links.librarySet([]);
  assert.deepEqual(R.articleRows(ITEMS, { kind: "unread", path: "" }, lib).map((r) => r.guid), ["n1", "a1", "n2", "d2"]);
  assert.deepEqual(R.articleRows(ITEMS, { kind: "folder", path: "Distros" }, lib).map((r) => r.guid), ["d1", "a1", "a2", "d2"]);
  assert.deepEqual(R.articleRows(ITEMS, { kind: "feed", path: "News" }, lib).map((r) => r.guid), ["n1", "n2"]);
  // A folder's prefix is a whole segment: "Distros2" isn't in "Distros".
  const more = { feeds: [], articles: ITEMS.articles.concat([art("Distros2", "x")]) };
  assert.ok(!R.articleRows(more, { kind: "folder", path: "Distros" }, lib).some((r) => r.guid === "x"));
  assert.deepEqual(R.scopeOf(R.feedRows(ITEMS)[2]), { kind: "folder", path: "Distros" });
  assert.deepEqual(R.scopeOf(R.feedRows(ITEMS)[0]), { kind: "unread", path: "" });
  assert.deepEqual(R.scopeOf(null), { kind: "all", path: "" });
  assert.equal(R.stateText({ loaded: true, feeds: 3, scope: "unread", rows: 0 }), W.emptyUnread);
  assert.equal(R.stateText({ loaded: true, feeds: 3, scope: "feed", rows: 0 }), W.emptyArticles);
  assert.equal(R.stateText({ loaded: true, feeds: 3, scope: "feed", rows: 2 }), "");
});

test("articleRows: the rows are lean (D14)", () => {
  const rows = R.articleRows({ articles: [art("News", "n1", { description: "x".repeat(1000), author: "a" })] }, { kind: "all" }, Links.librarySet([]));
  assert.deepEqual(Object.keys(rows[0]).sort(),
    ["date", "feedPath", "guid", "hasTorrent", "host", "inLibrary", "isRead", "key", "link", "title", "torrentURL", "v1", "v2"]);
});

// Review Focus 1: every string a feed sends is sanitised, with 5b0's rules.
test("articleRows: sanitise every string (bidi stripped, controls spaces, a 10k title capped)", () => {
  const long = "x".repeat(10000);
  const rows = R.articleRows({ articles: [
    art("F", "1", { title: "a‮b⁦c⁩", host: "e‮.example" }),
    art("F", "2", { title: "a\u0000b\u0007c\u009fd", date: 999 }),
    art("F", "3", { title: long, date: 998 }),
    art("F", "4", { title: "<b>bold</b> &amp; <img src=x onerror=alert(1)>", date: 997 }),
    art("F", "5", { title: 42, date: 996, host: 7 })
  ] }, { kind: "all" }, Links.librarySet([]));
  const by = (g) => rows.find((r) => r.guid === g);
  assert.equal(by("1").title, Links.cleanName("a‮b⁦c⁩"));
  assert.equal(by("1").title, "abc");
  assert.equal(by("1").host, "e.example");
  assert.equal(by("2").title, "a b c d");
  assert.equal(Array.from(by("3").title).length, 300);
  assert.equal(by("3").title, "x".repeat(299) + "…");
  assert.equal(by("4").title, "<b>bold</b> &amp; <img src=x onerror=alert(1)>", "markup stays text (the pane shows it PlainText)");
  assert.equal(by("5").title, Links.EMPTY);
  assert.equal(by("5").host, "");
  // The description: bidi stripped, controls but \n a space, 12 lines.
  const lines = Array.from({ length: 20 }, (_, i) => "line " + i + "‮\u0007");
  const d = R.descriptionText(lines.join("\n"));
  assert.equal(d.split("\n").length, 12);
  assert.equal(d.split("\n")[0], "line 0 ");
  assert.ok(!/[‪-‮⁦-⁩]/.test(d));
  assert.equal(R.descriptionText(null), "");
  // A failing feed's reason.
  assert.equal(R.errorText("HTTP 404‮"), fill(W.errorReason, { reason: "HTTP 404" }));
  assert.equal(R.errorText(null), W.errorNoReason);
  assert.equal(R.errorText(""), W.errorNoReason);
});

test("inLibrary: btih, base32 btih and btmh match; an http link never does", () => {
  const b32 = LINK.cases.find((c) => c.kind === "magnetHash" && c.ok && /btih:[a-z2-7]{32}/i.test(c.input));
  const btmh = LINK.cases.find((c) => c.kind === "magnetHash" && c.ok && /btmh:/i.test(c.input) && c.normalised.v2);
  assert.ok(b32 && btmh, "the link case file has base32 and btmh rows");
  const lib = Links.librarySet([
    { hash: V1, infohash_v1: V1, infohash_v2: "" },
    { hash: b32.normalised.v1, infohash_v1: b32.normalised.v1, infohash_v2: "" },
    { hash: btmh.normalised.v2.slice(0, 40), infohash_v1: "", infohash_v2: btmh.normalised.v2 }
  ]);
  const rows = R.articleRows({ articles: [
    art("F", "hex", { torrentURL: MAGNET, date: 5 }),
    art("F", "b32", { torrentURL: b32.input, date: 4 }),
    art("F", "btmh", { torrentURL: btmh.input, date: 3 }),
    art("F", "http", { torrentURL: "https://e.example/" + V1 + ".torrent", link: "https://e.example/x", date: 2 }),
    art("F", "other", { torrentURL: "magnet:?xt=urn:btih:" + "0".repeat(40), date: 1 })
  ] }, { kind: "all" }, lib);
  assert.deepEqual(rows.map((r) => [r.guid, r.inLibrary]), [["hex", true], ["b32", true], ["btmh", true], ["http", false], ["other", false]]);
  assert.equal(rows[0].v1, V1, "the awaiter's hash");
  assert.equal(rows[3].v1, "");
});

test("articleMeta: the Article pane's lines, with the feed's title and the read state as text", () => {
  const feeds = R.feedRows({ feeds: [folder("Distros", { feeds: 1 }), feed("Distros\\Debian", { title: "Debian ‮News\u0007 " }), feed("News")] });
  assert.deepEqual(R.articleMeta({ feedPath: "Distros\\Debian", title: "Debian 13", host: "debian.org", hasTorrent: true, date: 5, isRead: false }, feeds),
    { title: "Debian 13", host: "debian.org", torrent: W.hasTorrentYes, date: 5, state: W.articleUnread, feed: "Debian News" });
  assert.deepEqual(R.articleMeta({ feedPath: "News", title: "News", host: "", hasTorrent: false, date: null, isRead: true }, feeds),
    { title: "News", host: Links.EMPTY, torrent: W.hasTorrentNo, date: null, state: W.articleRead, feed: "News" },
    "no title: the feed's name (OV4)");
  assert.equal(R.articleMeta({ feedPath: "Gone", title: "x", isRead: false }, feeds).feed, Links.EMPTY, "a feed that's gone");
  assert.equal(R.articleMeta({ feedPath: "News", title: "x" }).feed, Links.EMPTY, "no feed list");
  assert.equal(R.articleMeta(null), null);
});

test("feedRows: a feed's title is sanitised, and falls back to its name; a folder's is its name", () => {
  const rows = R.feedRows({ feeds: [folder("Distros", { title: "ignored" }), feed("Distros\\A", { title: "  ‮Arch\u0000Linux  " }),
    feed("Distros\\B", { title: "" }), feed("C", { title: " \u0007 " }), feed("D", { title: 5 })] });
  assert.deepEqual(rows.map((r) => r.title), [W.unreadRow, W.allRow, "Distros", "Arch Linux", "B", "C", "D"]);
});

// ---- the confirms -------------------------------------------------------------------------

test("every confirmLine is the case file's copy, filled in", () => {
  assert.equal(R.confirmLine("rssAdd", { title: "Debian 13", host: "debian.org" }), fill(W.confirmAdd, { title: "Debian 13", host: "debian.org" }));
  assert.equal(R.confirmLine("rssOpenPage", { host: "xn--bcher-kva.example" }), fill(W.confirmOpen, { host: "xn--bcher-kva.example" }));
  assert.equal(R.confirmLine("rssRemove", { name: "News", folder: false }), fill(W.confirmRemoveFeed, { name: "News" }));
  assert.equal(R.confirmLine("rssRemove", { name: "Distros", folder: true, n: 3 }), fill(W.confirmRemoveFolder, { name: "Distros", n: 3 }));
  assert.equal(R.confirmLine("rssMarkRead", { name: "News", n: 4 }), fill(W.confirmMarkRead, { name: "News", n: 4 }));
  assert.equal(R.confirmLine("rssMarkRead", { all: true, n: 9 }), fill(W.confirmMarkAll, { n: 9 }));
  assert.equal(R.confirmLine("rssMarkRead", { more: true, n: 12 }), fill(W.moreArrived, { n: 12 }));
  assert.equal(R.confirmLine("rssProcessingOn", { n: 30 }), fill(W.confirmOn, { n: 30 }));
  assert.equal(R.confirmLine("nope", {}), "");
  // Every kind is one View.RSS_ACCEPT names.
  const accept = /var RSS_ACCEPT = (\{[^}]*\});/.exec(fs.readFileSync(path.join(__dirname, "..", "ClientView.js"), "utf8"));
  assert.ok(accept);
  for (const k of ["rssAdd", "rssOpenPage", "rssRemove", "rssMarkRead", "rssProcessingOn"]) assert.ok(accept[1].includes(k + ":"), k);
});
