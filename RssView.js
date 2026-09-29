.pragma library
.import "LinkRules.js" as Links

// The RSS view's pure rules (slice 5b1, Task 3). No I/O, no Date, no Qt
// objects: everything comes in through arguments, so tests/rss-view.test.js
// runs it in node against tests/fixtures/rss-rules-cases.json. It imports
// LinkRules.js (5b0's link and text rules).
//
// The `.pragma library` line above is QML-only; the node test strips it.
//
// What lives here (tests/fixtures/rss-contract.md is the contract):
// - the window's pre-checks of the case file's rules (qbt enforces): the
//   feedUrl rule (a's URL), the name rule (a's name, N, n) and the
//   hasTorrent rule (Enter);
// - the Feeds column (feedRows: Unread, All articles, then qbt's tree) and
//   the Articles column (articleRows: lean rows, newest first, sanitised,
//   each with its library match), keyed by keyOf;
// - the paths the window builds (folderPath, parentPath, joinPath) and the
//   name prompt's prefill (hostOf);
// - the confirm lines, the empty states and every other sentence, from the
//   case file's `window` and `sentences` copy below (the node test checks
//   each one against it, so none can drift).

var EMPTY = Links.EMPTY;

// The case file's `window`.
var WINDOW = {
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

// The case file's `sentences` (every line `qbt rss` prints; the window
// uses the rules' messages and unconfirmedAdd).
var SENTENCES = {
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

// The description shows as its first 12 lines (D11).
var DESCRIPTION_LINES = 12;
// The path separator qBittorrent uses.
var SEP = "\\";

function fill(template, vars) { return Links.fill(template, vars); }
function refuse(message) { return Links.refuse(message); }
function cleanName(value) { return Links.cleanName(value); }

// sentence(key, vars) -> the window's copy (or qbt's sentence) of that
// key, with <name>, <title>, <host>, <n> and <reason> filled in.
function sentence(key, vars) {
  var t = Object.prototype.hasOwnProperty.call(WINDOW, key) ? WINDOW[key] : SENTENCES[key];
  return t === undefined ? "" : fill(t, vars);
}

// ---- the rules (the window's pre-checks; qbt enforces) ------------------------------------

// feedUrl: {ok, normalised (the host the name prompt prefills)} or
// {ok:false, message}. The URL itself is posted exactly as given.
function checkFeedUrl(input) {
  var s = typeof input === "string" ? input : "";
  if (s === "") return refuse(SENTENCES.feedUrlEmpty);
  if (Links.BAD.test(s) || s.indexOf("|") !== -1) return refuse(SENTENCES.feedUrlBad);
  var len = Links.startsWithCi(s, "https://") ? 8 : (Links.startsWithCi(s, "http://") ? 7 : 0);
  if (len === 0) return refuse(SENTENCES.feedUrlScheme);
  var h = Links.hostOf(Links.splitUrl(s, len).authority);
  if (h.userinfo) return refuse(SENTENCES.feedUrlUser);
  if (!h.ok) return refuse(SENTENCES.feedUrlHost);
  return { ok: true, normalised: h.host };
}

// name: trimmed with Qt's isSpace set (ruling FE), then non-empty, no \,
// no control character. {ok, normalised (the trimmed name)}.
function checkName(input) {
  var s = Links.qtTrim(typeof input === "string" ? input : "");
  if (s === "") return refuse(SENTENCES.nameEmpty);
  if (s.indexOf(SEP) !== -1) return refuse(SENTENCES.nameBackslash);
  if (Links.CONTROL.test(s)) return refuse(SENTENCES.nameControl);
  return { ok: true, normalised: s };
}

// hasTorrent (Enter, D4/OV1): input {torrentURL, link} -> {ok, normalised
// "magnet" | "url"} or {ok:false, message}.
function checkHasTorrent(input) {
  var x = input || {};
  var t = typeof x.torrentURL === "string" ? x.torrentURL : "";
  var link = typeof x.link === "string" ? x.link : "";
  if (t === "") return refuse(SENTENCES.noTorrent);
  if (Links.BAD.test(t) || t.indexOf("|") !== -1) return refuse(SENTENCES.badTorrentLink);
  if (Links.startsWithCi(t, "magnet:?")) return { ok: true, normalised: "magnet" };
  var len = Links.startsWithCi(t, "https://") ? 8 : (Links.startsWithCi(t, "http://") ? 7 : 0);
  if (len === 0) return refuse(SENTENCES.badTorrentLink);
  var u = Links.splitUrl(t, len);
  var h = Links.hostOf(u.authority);
  if (!h.ok) return refuse(SENTENCES.badTorrentLink);
  if (t !== link) return { ok: true, normalised: "url" };
  if (/\.torrent$/i.test(u.path)) return { ok: true, normalised: "url" };
  return refuse(SENTENCES.noTorrent);
}

// check(kind, input) -> the rule of that kind (the node test runs every
// feedUrl, name and hasTorrent case through it).
function check(kind, input) {
  switch (kind) {
  case "feedUrl": return checkFeedUrl(input);
  case "name": return checkName(input);
  case "hasTorrent": return checkHasTorrent(input);
  default: return refuse("unknown rule");
  }
}

// hostOf(url) -> the host a's name prompt prefills (OV4): the feedUrl
// rule's host, or "" when the rule refuses the URL.
function hostOf(url) {
  var r = checkFeedUrl(url);
  return r.ok ? r.normalised : "";
}

// ---- paths ------------------------------------------------------------------------------------

function joinPath(folder, name) {
  var f = typeof folder === "string" ? folder : "";
  return f === "" ? String(name) : f + SEP + String(name);
}

// parentPath("a\\b\\c") -> "a\\b"; "" at the root.
function parentPath(path) {
  var p = typeof path === "string" ? path : "";
  var at = p.lastIndexOf(SEP);
  return at === -1 ? "" : p.slice(0, at);
}

// folderPath(item) -> the folder a new feed or folder goes in (OV4): the
// folder under the Feeds cursor, or the folder of the feed under it, else
// the root. item: a feedRows row or its rssItem ({path, folder}); null,
// Unread and All are the root.
function folderPath(item) {
  if (!item || typeof item !== "object") return "";
  var it = item.rssItem !== undefined ? item.rssItem : item;
  if (!it || typeof it.path !== "string") return "";
  return it.folder === true ? it.path : parentPath(it.path);
}

// ---- the Feeds column ---------------------------------------------------------------------

function num(v) {
  var n = Number(v);
  return isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

function feedsOf(items) {
  return items && Array.isArray(items.feeds) ? items.feeds : [];
}

function articlesOf(items) {
  return items && Array.isArray(items.articles) ? items.articles : [];
}

// feedRows(items) -> the Feeds column's rows: Unread and All articles
// first, then qbt's tree (in its order, with its depth). Each row:
// {key, kind ("unread" | "all" | "folder" | "feed"), label (sanitised),
// depth, unread, total, feeds, path, url, title (a feed's own title,
// sanitised, else its label: the Article pane's feed line, OV4), isLoading,
// hasError, state (rowRefreshing, rowError or ""), rssItem ({path, name, folder, feeds}
// for a real feed or folder, null on Unread and All)}. `path`, `name` and
// `url` stay raw: every write sends them exactly as qbt gave them.
function feedRows(items) {
  var feeds = feedsOf(items);
  var unread = 0, total = 0;
  var out = [];
  for (var i = 0; i < feeds.length; i++) {
    var f = feeds[i];
    if (!f || typeof f !== "object" || typeof f.path !== "string") continue;
    var folder = f.folder === true;
    if (!folder) {
      unread += num(f.unread);
      total += num(f.total);
    }
    var name = typeof f.name === "string" ? f.name : "";
    var loading = !folder && f.isLoading === true;
    var err = !folder && f.hasError === true;
    var label = cleanName(name);
    var title = !folder && typeof f.title === "string" ? cleanName(f.title) : EMPTY;
    out.push({
      key: "p:" + f.path,
      kind: folder ? "folder" : "feed",
      label: label,
      title: title !== EMPTY ? title : label,
      depth: num(f.depth),
      unread: num(f.unread),
      total: num(f.total),
      feeds: folder ? num(f.feeds) : 0,
      path: f.path,
      url: !folder && typeof f.url === "string" ? f.url : "",
      isLoading: loading,
      hasError: err,
      state: loading ? WINDOW.rowRefreshing : (err ? WINDOW.rowError : ""),
      rssItem: { path: f.path, name: name, folder: folder, feeds: folder ? num(f.feeds) : 0 }
    });
  }
  var head = [
    { key: "unread", kind: "unread", label: WINDOW.unreadRow, title: WINDOW.unreadRow, depth: 0, unread: unread, total: unread, feeds: 0, path: "", url: "",
      isLoading: false, hasError: false, state: "", rssItem: null },
    { key: "all", kind: "all", label: WINDOW.allRow, title: WINDOW.allRow, depth: 0, unread: unread, total: total, feeds: 0, path: "", url: "",
      isLoading: false, hasError: false, state: "", rssItem: null }
  ];
  return head.concat(out);
}

// feedCount(items) -> how many feeds (not folders) qbt listed.
function feedCount(items) {
  var feeds = feedsOf(items);
  var n = 0;
  for (var i = 0; i < feeds.length; i++) if (feeds[i] && feeds[i].folder !== true) n++;
  return n;
}

// anyLoading(items) -> some feed is refreshing (the 2 s poll).
function anyLoading(items) {
  var feeds = feedsOf(items);
  for (var i = 0; i < feeds.length; i++) if (feeds[i] && feeds[i].folder !== true && feeds[i].isLoading === true) return true;
  return false;
}

// ---- the Articles column ------------------------------------------------------------------

function keyOf(row) {
  var r = row || {};
  return String(r.feedPath) + "\n" + String(r.guid);
}

// scopeOf(feedRow) -> {kind, path}: what the Articles column shows.
function scopeOf(row) {
  if (!row || typeof row !== "object") return { kind: "all", path: "" };
  return { kind: row.kind, path: typeof row.path === "string" ? row.path : "" };
}

function inScope(a, scope) {
  var s = scope || { kind: "all" };
  if (s.kind === "unread") return a.isRead !== true;
  if (s.kind === "feed") return a.feedPath === s.path;
  if (s.kind === "folder") return a.feedPath.indexOf(s.path + SEP) === 0;
  return true;
}

// articleRows(items, scope, libSet) -> the Articles column's lean rows (D14),
// newest first (a missing date last, then qbt's order): {key, feedPath,
// guid, title (sanitised), date (epoch seconds or null), isRead,
// hasTorrent, inLibrary, torrentURL, link, host (sanitised), v1, v2}.
// inLibrary is the magnet's hash in the library (D7); an http(s) link
// never matches.
function articleRows(items, scope, libSet) {
  var list = articlesOf(items);
  var picked = [];
  for (var i = 0; i < list.length; i++) {
    var a = list[i];
    if (!a || typeof a !== "object" || typeof a.feedPath !== "string" || typeof a.guid !== "string") continue;
    var r = {
      feedPath: a.feedPath,
      guid: a.guid,
      isRead: a.isRead === true
    };
    if (!inScope(r, scope)) continue;
    var torrentURL = typeof a.torrentURL === "string" ? a.torrentURL : "";
    var h = Links.magnetHash(torrentURL);
    r.key = keyOf(r);
    r.title = cleanName(a.title);
    r.date = typeof a.date === "number" && isFinite(a.date) ? a.date : null;
    r.hasTorrent = a.hasTorrent === true;
    r.torrentURL = torrentURL;
    r.link = typeof a.link === "string" ? a.link : "";
    r.host = typeof a.host === "string" && a.host !== "" ? cleanName(a.host) : "";
    r.v1 = h && h.v1 ? h.v1 : "";
    r.v2 = h && h.v2 ? h.v2 : "";
    r.inLibrary = !!h && Links.inLibrary(r.v1, r.v2, libSet);
    r.seq = i;
    picked.push(r);
  }
  picked.sort(function(x, y) {
    if (x.date === null && y.date !== null) return 1;
    if (y.date === null && x.date !== null) return -1;
    if (x.date !== y.date) return y.date - x.date;
    return x.seq - y.seq;
  });
  for (var j = 0; j < picked.length; j++) delete picked[j].seq;
  return picked;
}

// articleMeta(row, feeds) -> the Article pane's lines: {title, host,
// torrent ("Torrent link" / "No torrent link"), date (epoch seconds or
// null), state ("unread" / "read": state as text, not only the row's ●),
// feed (the article's feed title, looked up by feedPath in feeds, the
// feedRows list; "—" when the feed isn't there, OV4)}.
function articleMeta(row, feeds) {
  if (!row) return null;
  var feed = EMPTY;
  var list = Array.isArray(feeds) ? feeds : [];
  for (var i = 0; i < list.length; i++) {
    var f = list[i];
    if (f && f.kind === "feed" && f.path === row.feedPath) { feed = typeof f.title === "string" && f.title !== "" ? f.title : EMPTY; break; }
  }
  return {
    title: typeof row.title === "string" ? row.title : EMPTY,
    host: typeof row.host === "string" && row.host !== "" ? row.host : EMPTY,
    torrent: row.hasTorrent === true ? WINDOW.hasTorrentYes : WINDOW.hasTorrentNo,
    date: typeof row.date === "number" ? row.date : null,
    state: row.isRead === true ? WINDOW.articleRead : WINDOW.articleUnread,
    feed: feed
  };
}

// descriptionText(text) -> `qbt rss article`'s text as the Article pane
// shows it: bidi controls removed (qbt keeps them), every other control
// character but \n a space, and its first 12 lines.
function descriptionText(text) {
  var s = typeof text === "string" ? text : "";
  s = s.replace(Links.BIDI, "").replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, " ");
  return s.split("\n").slice(0, DESCRIPTION_LINES).join("\n");
}

// errorText(reason) -> a failing feed's line: "Couldn't refresh: <reason>",
// or errorNoReason for null and "" (qbt rss error's reply).
function errorText(reason) {
  if (typeof reason !== "string") return WINDOW.errorNoReason;
  var r = reason.replace(Links.BIDI, "").replace(Links.CONTROLS, " ").trim();
  return r === "" ? WINDOW.errorNoReason : fill(WINDOW.errorReason, { reason: r });
}

// confirmLine(kind, vars) -> the line of one of RSS's CONFIRMs
// (View.RSS_ACCEPT's kinds). vars: rssAdd {title, host}; rssOpenPage
// {host}; rssRemove {name, folder, n}; rssMarkRead {name, n, all, more};
// rssProcessingOn {n}.
function confirmLine(kind, vars) {
  var v = vars || {};
  switch (kind) {
  case "rssAdd": return fill(WINDOW.confirmAdd, { title: v.title, host: v.host });
  case "rssOpenPage": return fill(WINDOW.confirmOpen, { host: v.host });
  case "rssRemove":
    return v.folder === true ? fill(WINDOW.confirmRemoveFolder, { name: v.name, n: num(v.n) }) : fill(WINDOW.confirmRemoveFeed, { name: v.name });
  case "rssMarkRead":
    if (v.more === true) return fill(WINDOW.moreArrived, { n: num(v.n) });
    return v.all === true ? fill(WINDOW.confirmMarkAll, { n: num(v.n) }) : fill(WINDOW.confirmMarkRead, { n: num(v.n), name: v.name });
  case "rssProcessingOn": return fill(WINDOW.confirmOn, { n: num(v.n) });
  default: return "";
  }
}

// stateText({loaded, feeds, scope, rows}) -> the Articles column's empty
// state, or "" when it has rows (or nothing is read yet).
function stateText(c) {
  var x = c || {};
  if (x.loaded !== true) return "";
  if (num(x.feeds) === 0) return WINDOW.emptyFeeds;
  if (num(x.rows) > 0) return "";
  return x.scope === "unread" ? WINDOW.emptyUnread : WINDOW.emptyArticles;
}

if (typeof module !== "undefined") {
  module.exports = {
    EMPTY: EMPTY, WINDOW: WINDOW, SENTENCES: SENTENCES, DESCRIPTION_LINES: DESCRIPTION_LINES,
    sentence: sentence, checkFeedUrl: checkFeedUrl, checkName: checkName, checkHasTorrent: checkHasTorrent, check: check,
    hostOf: hostOf, joinPath: joinPath, parentPath: parentPath, folderPath: folderPath,
    feedRows: feedRows, feedCount: feedCount, anyLoading: anyLoading, keyOf: keyOf, scopeOf: scopeOf,
    articleRows: articleRows, articleMeta: articleMeta, descriptionText: descriptionText, errorText: errorText,
    confirmLine: confirmLine, stateText: stateText
  };
}
