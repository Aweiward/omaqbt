# Slice 5b1 RSS: the contract

Written by Task 1 (wave 0) before the two lanes start. Task 2 (the backend lane: `qbt`, `lib/rssrules.py`, `lib/rssitems.py`, `tests/fixtures/server.py`, `tests/test_rss.py`) and Task 3 (the window lane: `RssView.js`, `RssPane.qml`, `RssCommands.qml`, `Service.qml`, node and harness tests) both build against this file. A lane that needs something this file doesn't say stops and asks; it doesn't invent a shape.

- **Rules and exact sentences** live in [`rss-rules-cases.json`](rss-rules-cases.json). Its `cases` hold the rules (`feedUrl`, `name`, `hasTorrent`, `errorReason`, `articleText`, each written out in its `_doc`), its `sentences` hold every line `qbt rss` prints, and its `window` holds the window's copy. Both lanes read that file in their tests and never retype a message. Every sentence quoted below is copied from it, and `tests/rss-contract.test.js` checks that it matches.
- **URLs** are split by 5b0's text rule and hosts checked by its host rule ([`link-rules-cases.json`](link-rules-cases.json), `LinkRules.js`, `lib/linkrules.py`), never by a URL library. RSS adds its own rules on top: feed URLs (http and https only), names, the add rule (`hasTorrent`), and the page open, which is 5b0's page-link rule unchanged (its messages are the `pageLink` cases in link-rules-cases.json).
- **The registry rows, footers, palette entries and the mount point** are already in `CommandRegistry.js`, `ClientView.js` and `Client.qml`. What the window's RSS view must provide is documented at the top of `RssPane.qml` (the view host contract).

qBittorrent 5.2.3 facts (the eng review's list, from `rsscontroller.cpp`, `rss_session.cpp`, `rss_feed.cpp`, `rss_article.cpp`, `rss_parser.cpp` and `rss_item.cpp`):
- RSS state is **global**: no SID keying, unlike search jobs.
- `rss/items` is GET. addFolder, addFeed, removeItem, moveItem, markAsRead and refreshItem are POST; a GET on them answers 405.
- The path separator is `\`. A valid path is `\A[^\\]+(\\[^\\]+)*\z`. addFolder, addFeed, moveItem and removeItem answer 409 with a reason text.
- markAsRead and refreshItem on a missing path do nothing and answer 200. So every write reads back.
- `items?withData=true` is a nested object: a folder is `{name: child}`, a feed is `{uid, url, title, lastBuildDate, isLoading, hasError, articles:[{id, date, title, author, description, torrentURL, link, isRead}]}`. `date` is RFC 2822.
- torrentURL falls back to `link` when an item has no enclosure.
- There is no mark-unread. markAsRead without an article id marks a whole feed or folder.
- `hasError` is a bool; the reason is only in `log/main`, as a warning.
- addFeed doesn't fetch the new feed while `rss_processing_enabled` is false, but refreshItem works regardless.

## `qbt rss`

It follows `qbt`'s existing conventions:
- **Every value arrives on stdin**, NUL-separated, never in argv (argv holds only the subcommand). Untrusted values reach curl on stdin too.
- A refusal or failure prints one sentence on stderr and exits 1.
- Success prints one JSON line on stdout and exits 0.
- Every request is localhost-only (`assert_local_base`); errors report codes only, never a response body; response bodies never touch disk.
- Every write is a POST, and every write reads `rss/items` back before it answers.
- Values are checked before any request. A path is checked segment by segment with the `name` rule: a segment the rule refuses gets that rule's message, and a segment the rule would change (one with a Qt space at either end) prints the usage line, since the window always sends trimmed names. qbt posts every path and URL exactly as it received it, never a trimmed variant, and reads back that same path.
- A bare `qbt rss`, an unknown subcommand, or stdin with the wrong number of values prints "usage: qbt rss items|article|error|add-feed|add-folder|rename|remove|refresh|mark-read|add".
- A 409 is passed through in plain words: "RSS feed with given URL already exists" prints "That feed is already added.", "RSS item with given path already exists" prints "There's already a feed or folder called <name> there." (`<name>` is the last segment of the path), and "Parent folder doesn't exist" prints "That folder is gone.". Any other API failure prints qbt's existing failure line (`qBittorrent refused it (…)` with `API_FAIL`).
- A path that doesn't exist (checked in the read before a write) prints "That feed is gone." for `rename`, `remove`, `refresh` and `mark-read` (qbt can't tell a feed from a folder that has gone); a folder that doesn't exist in `add-feed`, `add-folder` or `rename`'s target prints "That folder is gone.".

### `qbt rss items`

No stdin. It reads `rss/items?withData=true` and `app/preferences` in the same call and prints:

```json
{"processing": true, "feeds": [...], "articles": [...]}
```

- `processing` is `rss_processing_enabled`.
- `feeds`, in tree order: a folder comes before its children; siblings are sorted by name, case-insensitively (Python's `str.lower()`), then by the exact name. Folders and feeds sort together.
  - A feed: `{"path", "name", "depth", "folder": false, "url", "title", "isLoading", "hasError", "unread", "total"}`.
  - A folder: `{"path", "name", "depth", "folder": true, "unread", "total", "feeds"}`. `feeds` is the number of feeds anywhere under it (the remove confirm names it). `unread` and `total` sum every feed under it.
  - `path` is the full `\`-joined path, `name` its last segment, and `depth` the number of `\` in the path (0 at the root). `title` is the feed's own title as qBittorrent gives it (`""` when it has none). `unread` counts articles with `isRead` false.
- `articles`, the feeds' order, each feed's articles in qBittorrent's order: `{"feedPath", "guid", "title", "date", "isRead", "torrentURL", "link", "hasTorrent", "host"}`.
  - `guid` is qBittorrent's article `id`. `title`, `torrentURL` and `link` are the raw strings (`""` when missing); the window cleans them.
  - `date` is epoch seconds (an integer) from `email.utils.parsedate_to_datetime`, or `null` when it's missing or unparsable. A date with no zone (`-0000`) is read as UTC.
  - `hasTorrent` is the `hasTorrent` rule (a refused link is `false`).
  - `host` is the page link's host by 5b0's page-link rule (`linkrules.page_link`: lower case, punycode, no port), or `""` when that rule refuses the link.
  - There are no descriptions anywhere in the output (OV6); `qbt rss article` reads one.

### `qbt rss article`

stdin `path\0guid`. It reads `rss/items?withData=true` and prints `{"text": "...", "truncated": false}`: that article's `description` through the `articleText` rule. A missing feed or article prints "That article is gone.".

### `qbt rss error`

stdin `url`. It reads `log/main?normal=false&info=false&warning=true&critical=false&last_known_id=<id>` and prints `{"reason": "..."}` or `{"reason": null}`.
- `$STATE_DIR/rss-errors.json` (mode 0600) holds `{"lastId": N, "reasons": {url: text}}`. Each call also reads `rss/items` (no data) for every feed's URL, reads the log rows after `lastId`, and for each feed URL applies the `errorReason` rule to those rows; a match replaces that URL's stored reason. qbt never extracts a URL from a message (a `'` in a URL makes that ambiguous), so the rule stays the case file's prefix test. It then saves the highest id it saw as `lastId`. It keeps at most 200 URLs, dropping the least recently stored first.
- The reply is the stored reason for that exact URL, or `null`. The window shows "Couldn't refresh: <reason>", or "qBittorrent reported an error but gave no reason." for `null`.

### `qbt rss add-feed`

stdin `url\0path`, where `path` is the new feed's full path. It checks `url` with the `feedUrl` rule and `path` segment by segment, POSTs `rss/addFeed` (`url`, `path`), reads back that `path` exists, then POSTs `rss/refreshItem` with `itemPath=path` (D8: a new feed fills at once even while processing is off). It prints `{"ok": true, "path": "..."}`. A read-back without the path prints "Couldn't confirm <name> was added.".

### `qbt rss add-folder`

stdin `path`. It POSTs `rss/addFolder` and reads back that `path` exists: `{"ok": true, "path": "..."}`, else "Couldn't confirm <name> was added.".

### `qbt rss rename`

stdin `from\0to`. `to` must be in the same folder as `from` (moveItem is used for renames only); otherwise the usage line. It POSTs `rss/moveItem` (`itemPath=from`, `destPath=to`) and reads back that `to` exists and `from` doesn't: `{"ok": true, "path": "..."}` (the window's cursor follows `path`), else "Couldn't confirm the rename.".

### `qbt rss remove`

stdin `path`. It POSTs `rss/removeItem` and reads back that `path` is gone: `{"ok": true}`, else "Couldn't confirm <name> was removed.". A folder removes every feed under it (the confirm names how many).

### `qbt rss refresh`

stdin `path`, or `""` for everything. It checks the path exists first ("That feed is gone.") and POSTs `rss/refreshItem` with `itemPath=path` (`itemPath=` empty for everything): `{"ok": true}`. The window then polls every 2 s while any feed `isLoading`.

### `qbt rss mark-read`

stdin `path\0guid\0expect`. `guid` is `""` for a whole feed or folder, and `path` is `""` for everything (Unread and All). `expect` is the unread count the window's confirm named (a whole number; `0` with a `guid`).
- With a `guid`: a missing article prints "That article is gone."; otherwise it POSTs `rss/markAsRead` (`itemPath`, `articleId`) and reads back `isRead`: `{"ok": true}`.
- Without a `guid`: it first re-reads the unread count in that scope. If it's greater than `expect`, it doesn't post and prints `{"ok": false, "unread": M}` (OV11), and the window asks again: "More articles arrived: mark <n> read? This can't be undone.". Otherwise it POSTs `rss/markAsRead` (`itemPath`) and reads back unread 0: `{"ok": true}`.
- A read-back that doesn't hold prints "Couldn't confirm the articles were marked read.".

### `qbt rss add`

stdin `torrentURL\0link`. It applies the `hasTorrent` rule ("This article has no torrent link." or "That link isn't http, https or magnet."), then POSTs `torrents/add` with `urls=torrentURL` and prints `{"ok": true, "via": "magnet"}` or `{"ok": true, "via": "url"}` (the rule's `normalised`).
- A magnet: the window waits for its hash in the library with 5b0's AddAwaiter, then marks the article read and says "Added <name>.", or after 30 s "Couldn't confirm <name> was added." (OV2).
- An http(s) enclosure: the window says "Sent to qBittorrent; Space marks it read." and leaves the article unread.

### Processing on

`O` is the existing `qbt pref-set rss_processing_enabled -- true` (Service `setPref`), after the confirm "Turn on RSS processing in qBittorrent? Feeds refresh every <n> min.". Task 2 un-defers the key.

### Paths

The window builds every path: `folderPath === "" ? name : folderPath + "\\" + name`, with the name through the `name` rule first. `a` puts the feed in the folder under the Feeds cursor, or the folder of the feed under it, else the root (OV4). `qbt` validates every segment again.

## The window's copy

Every line the RSS view shows comes from the case file's `window`:

- The banner while processing is off: "RSS is off in qBittorrent, so feeds only refresh when you press r. O turns it on (also in Settings → RSS)."
- Empty states: "No feeds yet. Press a and paste a feed URL.", "No articles in this feed yet." and "Nothing unread.".
- Feed rows: "Unread" and "All articles" first; a feed's state "refreshing…" or "error". An article row: "in library" (a magnet whose hash is in the library, D7).
- A refresh that doesn't end within 60 s: "Still refreshing; qBittorrent hasn't answered."
- The Article pane: "Torrent link" or "No torrent link"; a failing feed's reason as above.
- Notes: "Already in your library.", "qBittorrent can't mark articles unread." and the add notes above.
- The confirms (CONFIRM kinds in `View.RSS_ACCEPT`):
  - `rssAdd` (y add): "Add <title> from <host>?"
  - `rssOpenPage` (y open): "Open <host> in your browser? It won't go through the VPN."
  - `rssRemove` (y remove): "Remove <name>? This can't be undone." for a feed, "Remove <name> and its <n> feeds? This can't be undone." for a folder.
  - `rssMarkRead` (y mark read): "Mark <n> articles in <name> read? This can't be undone.", or on Unread and All "Mark all <n> articles in every feed read? This can't be undone.".
  - `rssProcessingOn` (y turn on): the confirm under Processing on.
- The blocked keys' muted notes (the registry's needs): "Pick a feed or folder." (`x` and `n` on Unread and All, OV5), "No article here.", "Nothing unread.", "RSS is already on." and "qBittorrent isn't reachable.".
- The INSERT prompts: `rssFeedUrl` "Feed URL" (placeholder "https://…"), `rssFeedName` "Feed name" (prefilled with the feed URL's host), `rssFolderName` "Folder name", `rssRename` "Rename" (prefilled with the current name).

## The sentences

For reference, every sentence `qbt rss` prints, as the case file holds them:

- Names: "Enter a name.", "Names can't contain \." and "Names can't contain control characters.".
- Feed URLs: "Enter a feed URL.", "Feed URLs can't contain spaces, control characters, | or \.", "Feed URLs start with http:// or https://.", "Feed URLs can't contain a user name or password." and "That feed URL has no valid host.".
- Adds: "This article has no torrent link." and "That link isn't http, https or magnet.".
- Gone: "That feed is gone.", "That folder is gone." and "That article is gone.".
- 409s: "That feed is already added." and "There's already a feed or folder called <name> there.".
- Read-backs: "Couldn't confirm <name> was added.", "Couldn't confirm <name> was removed.", "Couldn't confirm the rename." and "Couldn't confirm the articles were marked read.".
