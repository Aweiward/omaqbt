# Slice 5a Search: the contract

Written by Task 1 (wave 0, eng OV9) before the two lanes start. Task 2 (the backend lane: `qbt`, `qbt-serve`, `lib/`, `tests/fixtures/server.py`, python tests) and Task 3 (the window lane: `SearchView.js`, `SearchPane.qml`, `SearchCommands.qml`, `Service.qml`, `Sidecar.qml`, node and harness tests) both build against this file. A lane that needs something this file doesn't say stops and asks; it doesn't invent a shape.

- **Rules and exact sentences** live in [`search-rules-cases.json`](search-rules-cases.json) (the pageLink and magnetHash rules also in [`link-rules-cases.json`](link-rules-cases.json)). Its `cases` hold the rules, its `sentences` hold every other line `qbt` prints, and its `window` holds the window's copy. Both lanes read that file in their tests and never retype a message. Every sentence quoted below is copied from it, and a node test checks that it matches.
- **URLs are parsed by the case file's text rule, never by a URL library** (Ruling FB). Both lanes split every URL (plugin URL, page link, add link) the same way:
  1. The scheme, matched case-insensitively.
  2. `://`.
  3. The authority: everything up to the first `/`, `?` or `#`, or the end.
  4. The path: from that `/` up to the first `?` or `#`. Its last segment is what follows the last `/`.

  Within the authority:
  - An `@` anywhere is userinfo, and is refused.
  - What's left is `host[:port]`:
    - an IPv6 literal (`[`, hex digits, `:` and `.` with at least one `:`, then `]`), optionally followed by `:port`;
    - or a name with at most one `:`, the part after it being the port.
  - A port is 1 to 5 digits with a value from 1 to 65535. An empty port is refused.
  - A name is lowercased, and each label containing a non-ASCII character becomes `xn--` plus its RFC 3492 punycode (no other IDNA mapping). The result must be 1 to 253 characters of dot-separated labels. Each label is 1 to 63 characters of `[a-z0-9-]`, not starting or ending with `-`. There is no trailing dot.
  - So a `%`-escape in the host, a trailing dot and an empty label are refused. An IPv4 literal (`192.0.2.10`) and a single-label host (`localhost`) are accepted as names.
  - A backslash is refused anywhere in every URL kind, because browsers read it as `/`.
  - The exact messages are the `pluginUrl`, `pageLink` and `addLink` cases. qbt may do the punycode step in `lib/` (python); the window implements RFC 3492 in `SearchView.js`.
- **The registry rows, footers, palette entries and the mount point** are already in `CommandRegistry.js`, `ClientView.js` and `Client.qml`. What the window's Search view must provide is documented at the top of `SearchPane.qml`.

qBittorrent 5.2.3 facts (from `searchcontroller.cpp`, `searchpluginmanager.cpp` and `searchhandler.cpp`):
- `search/start`, `stop`, `delete`, `downloadTorrent`, `installPlugin`, `uninstallPlugin`, `enablePlugin` and `updatePlugins` are POST. `status`, `results` and `plugins` are GET.
- `start` trims `pattern` and `category` and splits `plugins` on `|`. It returns 409 when Python is missing and 409 when 5 searches are active (`m_activeSearches`, which drops a job once it finishes or is stopped).
- `status` with no `id` returns every job: `[{id, status: "Running"|"Stopped", total}]`. With an unknown `id` it returns 404.
- `results?id&limit&offset`: `offset == total` answers an empty page, `offset > total` is 409, and an unknown `id` is 404. A running job's results only grow.
- The search process is cancelled after 3 minutes, and the job then reads `Stopped` with whatever it found.
- `installPlugin` downloads asynchronously and always answers 200. The plugin is named after the URL's last path segment with its extension dropped, and a version that isn't newer than the installed one is refused silently. `uninstallPlugin` and `enablePlugin` trim each `|`-split name and answer 200 even for an unknown name.
- `downloadTorrent` answers an empty 200 at once. The plugin's own downloader then fetches the file and adds it, or fails with nothing reported to the API.
- **Search jobs are per WebUI session** (`webapplication.cpp:844` registers a `SearchController` per `WebSession`). A job started in one session reads 404 (`status`, `results`, `stop`, `delete`) from any other, and the 5-search cap counts per session. A request with no SID, or an unknown one, opens a fresh session (localhost bypass). Plugins are global.

## `qbt search` and `qbt search-plugin`

Both follow `qbt`'s existing conventions:
- A refusal or failure prints one sentence on stderr and exits 1.
- Success prints one JSON line on stdout and exits 0.
- Every write is localhost-only (`assert_local_base`).
- Errors report codes only, never a response body.
- Response bodies never touch disk: pipe through `printf | jq`.
- Arguments are checked before any request.

In the sentences, `<why>` is `qbt`'s `API_FAIL`: "HTTP n", "localhost auth is required" or "couldn't reach qBittorrent". A bare `qbt search` with no known subcommand prints "usage: qbt search start|stop|delete|add".

### `qbt search start --pattern <p> --category <c>`

It prints `{"id":N}`, qBittorrent's job id (1 to 2147483647).

1. The arguments come first. With either flag missing it prints "usage: qbt search start --pattern <p> --category <c>". `<p>` follows the `pattern` rule and `<c>` the `category` rule.
2. It reads `/search/plugins`. A failed read prints "Couldn't read the search plugins (<why>)". With no plugin enabled it prints "All search plugins are off." (OV8: searches use only the enabled plugins).
3. **The stale job.** If `$STATE_DIR/search.id` exists, it deletes that job first (POST `search/delete`, ignoring 404) and removes the file. This covers A5's "a new `/` replaces the old job" and "the next start" (OV14).
4. It sends POST `search/start` with `pattern=<p>&category=<c>&plugins=enabled`.
5. **409.** qBittorrent sends the same code for two causes, so `qbt` reads GET `search/status` (all jobs) to tell them apart (OV6):
   - at least 5 jobs with `status` "Running": "qBittorrent is running 5 searches; stop one first."
   - fewer: "Search needs Python on this machine."
   - the status read fails: "qBittorrent refused it (HTTP 409)".
6. Any other failure prints "qBittorrent refused it (<why>)". A body with no integer `id` prints "qBittorrent sent something unreadable".
7. It writes the id to `$STATE_DIR/search.id` with mode 0600 (created under `umask 077`; the file holds only the number and a newline), then prints `{"id":N}`.

### `qbt search stop <id>` and `qbt search delete <id>`

Each prints `{"ok":true}`.

- `<id>` follows the `searchId` rule, and the usage lines are "usage: qbt search stop <id>" and "usage: qbt search delete <id>".
- `stop` sends POST `search/stop`; `delete` sends POST `search/delete`.
- A 404 also prints `{"ok":true}`: the job is already gone, and cleanup must be idempotent.
- Any other failure prints "qBittorrent refused it (<why>)".
- `delete` removes `$STATE_DIR/search.id` when it holds `<id>`, whether or not the job was still there. `stop` never touches the file.

### `qbt search add <link> [<plugin>]`

It prints `{"ok":true,"via":"add"}` or `{"ok":true,"via":"plugin"}`. The rules are the `addLink` and `pluginName` cases (OV3, OV5), with the usage line "usage: qbt search add <link> [<plugin>]":

- **`magnet:?`**: POST `torrents/add`, exactly the request `qbt add <magnet>` makes (the clipboard add, with your defaults). Any plugin is ignored. Prints `via:"add"`.
- **`https://` with a plugin**: the plugin must be in the current `/search/plugins` list, or it prints "There's no plugin named <name>." A failed read prints "Couldn't read the search plugins (<why>)". Then POST `search/downloadTorrent` with `torrentUrl=<link>&pluginName=<plugin>`, so the plugin's own downloader handles private sites and `/download/123` links. Prints `via:"plugin"`.
- **`https://` without a plugin, ending in `.torrent`**: POST `torrents/add`. Prints `via:"add"`.
- **Anything else** (http, a local path, a `file:` URL, other https links): "That result has no usable link."

A failed request prints "qBittorrent refused it (<why>)".

**`via:"plugin"` is never reported as added.** `downloadTorrent` answers an empty 200 even when the download later fails, so it only proves the request was accepted.

### `qbt search-plugin list|install <url>|uninstall <name>|enable <name> on|off|update`

With a wrong subcommand or arguments it prints "usage: qbt search-plugin list|install <url>|uninstall <name>|enable <name> on|off|update". `<name>` follows the `pluginName` rule and must be in the current list, or it prints "There's no plugin named <name>." A failed list read always prints "Couldn't read the search plugins (<why>)", and a failed write prints "qBittorrent refused it (<why>)".

- **`list`** prints one JSON array, in qBittorrent's order: `[{"name","fullName","version","enabled","url","supportedCategories"}]`.
  - Every field is qBittorrent's own.
  - `supportedCategories` is qBittorrent's `[{"id","name"}]` (for example `{"id":"movies","name":"Movies"}`).
  - An empty list is `[]`.
- **`install <url>`**:
  1. `<url>` follows the `pluginUrl` rule. Its `normalised` is the name the read-back looks for (OV4: qBittorrent's naming).
  2. It reads the list (the version `before`, or none) and sends POST `search/installPlugin` with `sources=<url>`.
  3. It re-reads the list every 0.5 s for up to 20 s, until the name is there with a version different from `before` (A3).
  4. Success prints `{"ok":true}`. Otherwise it prints what the `installReadback` cases pin: "<name> v<version> is already installed." when it was there before with the same version, else "Couldn't confirm the install of <name>."
- **`uninstall <name>`** sends POST `search/uninstallPlugin` with `names=<name>`, then re-reads the list once. If the name is gone it prints `{"ok":true}`, else "Couldn't confirm the uninstall of <name>."
- **`enable <name> on|off`** sends POST `search/enablePlugin` with `names=<name>&enable=true|false`, then re-reads the list once. If `enabled` matches it prints `{"ok":true}`, else "Couldn't confirm <name> is on." or "Couldn't confirm <name> is off."
- **`update`** sends POST `search/updatePlugins`, then re-reads the list once (A3: no version promise; qBittorrent checks and installs asynchronously). It prints `{"ok":true}`.

## `$STATE_DIR/search.id`

- It holds the id of the job the window is running, mode 0600, as the number and a newline.
- It is written only by `qbt search start`, and removed by `qbt search delete <that id>` or by the next `start`.
- The window deletes its job:
  - when a new `/` starts (`start` does it);
  - right after the final read of a Stopped job (OV14);
  - when the window closes (`SearchPane.windowClosed`).
  So the file only ever names a running job, or one a crash left behind.
- **A crash leftover is deleted by the next `qbt search start`** (step 3 above). Nothing reads `search.id` when Service starts: Ruling FB dropped A5's "next Service start" cleanup.

## The sidecar's search watch (`qbt-serve`)

The window owns the offset (OV7). The sidecar keeps only the current watch: `{id, offset}` from the latest command, plus the `status` and `total` it last reported (so it can tell when they change). A restarted sidecar resumes exactly where the window says; forgetting what it last reported costs one extra reply.

**The command** (stdin, one line):

```json
{"cmd":"search","id":N,"offset":k}
{"cmd":"search","id":null}
```

- `id: N` replaces any watch with job `N` from `offset` `k` (0 to start, or how many rows the window already holds).
- `id: null` drops the watch, with no reply.
- The `id` key must be present, null or an integer (Ruling FG). `{"cmd":"search"}` without it is not `id: null`: like any other malformed search command, it answers `{"type":"error","id":<its id, or null>,"error":"bad command"}` and leaves the watch as it was.
- A restarted sidecar has no watch until the window (Service) sends its command again.

**The session (Ruling FH).** `qbt search start` creates the job in qbt's session: the SID in its curl cookie file (`qbt probe`'s `cookieFile`). So the sidecar's search reads, and only those, go through that same session. The status and inspect reads keep the sidecar's own in-memory session, since torrents, sync and preferences are global.
- The sidecar loads the cookie file (`qbtsync.CurlCookieJar`) when a watch is set, and never writes it: curl rewrites that file on every `qbt` run.
- On a 404 it reloads the file once and retries the read, so a SID that rotated since the load is picked up. Only a second 404 is `gone`.
- A load that fails (a half-written or unreadable file) is transient: nothing is sent, the watch stays, and the next poll loads again. It is never `gone`.
- A missing file is an empty jar: qbt has made no request, so no job of its can exist, and the read without a SID gets the 404.
- The SID never appears in a log line, an error or a reply.

**Polling.** About every second while it watches, the sidecar reads GET `search/results?id=N&offset=<offset>&limit=<L>`, where `L = min(500, 2000 - offset)`. The reply's `status`, `total` and `rows` all come from that one `results` response (`{status, total, results}`), so they always agree.

The sidecar never asks past row 2000 (OV15: the 2000-row cap is the sidecar's, so extra rows never cross into QML). Once `offset` reaches 2000, it reads GET `search/status?id=N` instead, for `status` and `total`, and `rows` is `[]`. The switch matters because a `results` read with `limit` 0 would return every row.

**The reply** (stdout, one line):

```json
{"type":"search","id":N,"status":"Running","total":T,"offset":k,"rows":[...],"capped":false}
```

- `status` is qBittorrent's `Running` or `Stopped`, and `total` is its `total` (every row it holds, past 2000 too). Both come from the `results` response (from `status` once at the cap).
- `reply.offset` is the offset before the reply's rows: the watch's offset when this read was made, where `rows[0]` sits.
- `rows` holds qBittorrent's result objects exactly as received, `{fileName, fileUrl, fileSize, nbSeeders, nbLeechers, engineName, siteUrl, descrLink, pubDate}`. There are at most 500, and never enough to pass row 2000. The sidecar passes rows through untouched; sanitising lives only in `SearchView.js` (OV9).
- `capped` is true when `total` > 2000, so the window says "showing 2000 of <n>".
- After a reply, the watch's offset advances by `rows.length`.
- A reply is sent after every command, whenever `rows` is non-empty, and whenever `status` or `total` changed since the last reply. Otherwise nothing is sent. The final reply (below) is always sent.
- **The window's side:** it appends a reply's rows only when `reply.offset` equals the number of rows it holds, and otherwise re-sends `{"cmd":"search","id":N,"offset":<rows it holds>}`. So a duplicate or a gap can't survive a restart.

**When the job ends (Ruling FB).** A reply is **final** when `status` is `"Stopped"` AND `offset + rows.length == min(total, 2000)`. The sidecar always sends the final reply, even with zero rows, and then drops the watch. The window applies it (appends its rows by the offset rule above), then deletes the job with `qbt search delete <id>` (OV14). A reply that is `Stopped` but not final (more rows are still to read) is not final: the watch continues from the advanced offset.

**404.** The job is gone, for example after a qBittorrent restart:

```json
{"type":"search","id":N,"error":"gone"}
```

The sidecar drops the watch, and the window says "The search ended when qBittorrent restarted." Other failures (connection refused, other HTTP errors) send nothing: the watch stays and is retried on the next tick, and the status line's `api:false` shows qBittorrent is down. A `results` 409 (offset past the end) can't happen while the offset invariant holds: the window's offset is at most the rows it holds, which is at most `total`, and a job's results only grow. If one ever comes back, the sidecar treats it like the 404 and sends `gone`, so a watch can never retry a bad offset forever.

## The window (Task 3), against the mount point

- **`F` or ":Search"** makes Search the active view (`Client.activeView`). It works from the torrent panes only, like `,`. ":Search" from Settings leaves Settings first. Esc stops a running search (`qbt search stop`), then leaves.
- **`c`** (`search.category`, in the results and the Plugins column) opens a single-choice picker (ListOverlay in PICKER mode, like Settings' choice picker; `SearchPane` documents the hook). Its rows:
  - `all` (qBittorrent's "All categories") first, then each category id that at least one **enabled** plugin lists in `supportedCategories`, once each;
  - in qBittorrent's table order: anime, books, games, movies, music, pictures, software, tv;
  - each titled with qBittorrent's name for it (`supportedCategories[].name`: "Anime", "Books", "Games", "Movies", "Music", "Pictures", "Software", "TV shows").

  The default is `all`. The chosen id goes to the next `qbt search start --category <id>`. A chosen category no enabled plugin supports any more falls back to `all`. `c` needs an enabled plugin (the dim reason "all plugins are off (P)").
- **Enter** (A1) raises a one-line CONFIRM, "Add <name> (<size>) from <host>?" with `y` add, unless the result is already in the library (OV11, `magnetHash`), in which case it notes "Already in your library." `y` runs `qbt search add <fileUrl> [<engineName>]` (the plugin only when `engineName` is non-empty).
  - **The library match reads the status rows (Ruling FG).** Each torrent row in the sidecar's `status` line (and `qbt status`, from `lib/qbtsync.py` `merge_maindata`) carries qBittorrent's `infohash_v1` and `infohash_v2`, always strings, `""` when qBittorrent doesn't send one (a v1 torrent has no v2 hash and the reverse; the fixture's `debian.iso` has only a v1). A magnet's `v1` (its btih) matches a row whose `hash` or `infohash_v1` equals it; its `v2` (its btmh with `1220` stripped) matches a row whose `infohash_v2` equals it.
- **The done notes.** Only the window says something was added:
  - "Added <name>." is shown once a magnet's hash appears in the library (`via:"add"` for a magnet).
  - "Sent <name> to qBittorrent · it appears when its download finishes." is shown for `via:"plugin"`, and for an https `.torrent` added through `via:"add"`, whose hash isn't known in advance.
- **`d`** checks the `pageLink` rule, then asks "Open <host> in your browser? It won't go through the VPN." `y` launches `xdg-open` detached (OV10).
- **`i`** takes an https URL (`pluginUrl`), then asks "Install <name> from <host>?" with the detail "This runs Python code as qBittorrent, with access to your downloads." **`x`** asks "Uninstall <name>?".
- **The query bar** reads "searching… · <k> results", "done · <k> results", or "stopped · <k> results" after Esc (OV1: no per-plugin progress).
- **The empty states** are "No search plugins yet", "No results yet", and "No results for "<q>". Try fewer words, or check which plugins are on (P)."
- **Added in Task 3's fix round 1** (Rulings FD, FE, FF):
  - under "No search plugins yet": "qBittorrent searches through plugins it runs with Python on this machine. P manages them; i installs one from an https URL.";
  - while a search is Running and the sidecar isn't up (never on reply silence): "No results are arriving; press Esc and try again.";
  - a magnet whose hash isn't in the library 30 s after a successful add: "Couldn't confirm <name> was added.";
  - a Plugins column filter that hides every row: "No results from <plugin>.";
  - the plugins overlay's progress labels: "installing…", "updating…", "uninstalling…" and "saving…" (on/off).
  - The pattern rule trims with Qt's QChar::isSpace set (Zs, Zl, Zp, U+0009-U+000D, U+0085, U+00A0; not U+FEFF), never String.prototype.trim (Ruling FE).
  - A result with an empty `engineName` is the installed plugin whose `url` equals its `siteUrl`, for the counts and for `qbt search add`; otherwise it is "other" (Ruling FF).

**Failure modes.**

| Path | Failure | Handled | User sees |
|---|---|---|---|
| add, `via:"plugin"` | the plugin's download fails | nothing can report it (downloadTorrent's empty 200) | "Sent <name> to qBittorrent · it appears when its download finishes.", and nothing appears |
| add, https `.torrent` | qBittorrent can't fetch the file | the same | "Sent <name> to qBittorrent · it appears when its download finishes.", and nothing appears |
| results | the job is gone (404), after one reload of qbt's cookie file and a retry | the watch drops | "The search ended when qBittorrent restarted." |
| results | the job is in another session (the sidecar read a different cookie file, or qbt's session was replaced since the start) | the same 404 | the same "The search ended when qBittorrent restarted.": it looks exactly like a restart |
| results | qbt's cookie file is half-written or unreadable | nothing sent; the next poll loads it again | nothing: the rows arrive once it loads |
| start | 409 | status read (OV6) | "qBittorrent is running 5 searches; stop one first." / "Search needs Python on this machine." |
| install | the download or the plugin fails | 20 s read-back | "Couldn't confirm the install of <name>." |
| install | the same or an older version | read-back unchanged | "<name> v<version> is already installed." |
