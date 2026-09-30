# Slice 5b2 RSS rules: the contract

Written by Task 1 (wave 0) before the two lanes start. Task 2 (the backend lane: `qbt`, `lib/rssautorules.py`, `tests/fixtures/server.py`, `tests/test_rss_rules.py`, `tests/live/rss-probe.sh`, Settings' auto-download confirm) and Task 3 (the window lane: `RssRules.js`, `RssRulesPane.qml`, `RssRuleCommands.qml`, `Service.qml`'s rules calls, node and harness tests) both build against this file. A lane that needs something this file doesn't say stops and asks; it doesn't invent a shape.

- **Rules and exact sentences** live in [`rss-autorules-cases.json`](rss-autorules-cases.json), a new file with 5b1's shape (`_doc`, `cases`, `sentences`, `window`). T2 and T3 read that file in their tests and never retype a message. Its `cases` hold the rules (`ruleName`, `regex`, `episode`, `ignoreDays`, `savePath`, `fields`, `patch`, `previewJoin`, each written out in its `_doc`), its `sentences` hold every line `qbt rss rule-*` prints, and its `window` holds the window's copy. RssRules.js pins its `WINDOW` and `SENTENCES` to rss-autorules-cases.json (deep equality), as RssView.js does to 5b1's file. Every sentence quoted below is copied from it, and `tests/rss-rules-contract.test.js` checks that.
- **5b1's contract stands**: [`rss-contract.md`](rss-contract.md) and [`rss-rules-cases.json`](rss-rules-cases.json) are unchanged, and so are their tests. 5b1's stdin framing, localhost rule, error reporting and read-back discipline apply to every command below.
- **The registry rows, footers, INSERT purposes, confirm kinds and the mount point** are already in `CommandRegistry.js`, `ClientView.js`, `RssPane.qml` and the placeholder `RssRulesPane.qml`. What the rules area must provide is documented at the top of `RssRulesPane.qml` (its host contract). Client.qml and ClientCommands.qml need no change: the rules panes are RSS panes (5b0's table-driven views).

qBittorrent 5.2.3 facts (the eng review's list and its Outside voice, from `rss_autodownloadrule.cpp`, `rss_autodownloader.cpp`, `rsscontroller.cpp`, `addtorrentparams.cpp` and `gui/rss/automatedrssdownloader.cpp` at release-5.2.3):
- **setRule replaces the whole rule** with `fromJsonObject(ruleDef)`. Missing keys get their defaults, and `enabled` defaults to **true**. Once the rule has a `torrentParams` key, with any value, even one that isn't an object (fromJsonObject uses `find()` and reads a non-object as `{}`), the flat keys (`savePath`, `assignedCategory`, `addPaused`, `torrentContentLayout`) are ignored. `toJsonObject` emits both the flat keys and `torrentParams`; `torrentParams` always holds category, tags, save_path, download_path, operating_mode, skip_checking, upload_limit, download_limit, seeding_time_limit, inactive_seeding_time_limit, share_limit_action, ratio_limit and the three ssl keys, and holds stopped, content_layout, use_auto_tmm, add_to_top_of_queue, stop_condition and use_download_path only when set.
- **Every setRule re-runs the queue** while auto-downloading is on: every **unread** article with a non-empty torrent URL is queued (Article::torrentUrl is the torrentURL, or the link when that's empty; an article with neither never is, rss_autodownloader.cpp:401), and disabled rules are skipped.
- **First match wins**: rules are tried by priority, and the first enabled rule that accepts an article adds it with that rule's options.
- **`accepts()` bumps `lastMatch` and appends to `previouslyMatchedEpisodes` before the add**, so a rule changes under an open editor.
- **Failed http adds stay unread** and are retried on every later re-queue; only a magnet is marked read at once (an http torrent on success or as a duplicate).
- **matchingArticles** works only for a saved rule, runs `matches()` on every article (read or not) of each `affectedFeeds` URL, and answers `{feedName: [titles]}` keyed by the feed's **name**: a later same-named feed overwrites an earlier one (rsscontroller.cpp:242), and a feed with no match has no key.
- **renameRule** answers 200 and does nothing when the new name exists or the old one doesn't; **removeRule** answers 200 for an unknown name. So every write reads back.
- **An invalid regex never matches**: must-contain then matches nothing, must-not-contain excludes nothing. Matching is case-insensitive QRegularExpression (PCRE2). In wildcard mode each pattern is split on `|` and each alternative on whitespace, and every word must match.
- **The episode filter** must fit the matcher's `(^\d{1,4})x(.*;$)`, or nothing matches.

## RULE_FIELDS

The editor's fields, in this order (RssRules.js' `RULE_FIELDS`; the labels and help lines are the case file's `window` `label<Key>` and `help<Key>`):

| Key | Label | Kind | What it edits |
|---|---|---|---|
| `enabled` | "Enabled" | toggle | Routed to `rss.ruleToggle` (never a field commit). |
| `mustContain` | "Must contain" | regexText | The `regex` kind. |
| `mustNotContain` | "Must not contain" | regexText | The `regex` kind. |
| `useRegex` | "Use regular expressions" | toggle | Space. |
| `episodeFilter` | "Episode filter" | episode | The `episode` kind. |
| `smartFilter` | "Smart episode filter" | toggle | Space. |
| `affectedFeeds` | "Feeds" | feeds | A ListOverlay (multi) of every feed by path; a rule URL no feed has shows as "(gone) <url>" and can be unticked. |
| `category` | "Category" | category | A ListOverlay (single): the library's categories plus "(none)" (the empty category). |
| `savePath` | "Save to" | path | The `savePath` kind: absolute or empty. |
| `addStopped` | "Add stopped" | triBool | A ListOverlay (single): default, yes, no (window `addStoppedDefault`, `addStoppedYes`, `addStoppedNo`). |
| `ignoreDays` | "Ignore for (days)" | number | The `ignoreDays` kind: 0 to 365. |

Values, as `fields` (the case file's `fields` kind, `fields_of`) derives them from a rule's JSON: booleans for the toggles, strings for the patterns, the episode filter, the category and the path, a list of URLs for the feeds, `default`, `yes` or `no` for addStopped, and an integer for ignoreDays. An empty pattern shows as "(empty)", an empty category as "(none)" and an empty path as "(default)"; a toggle as "on" or "off" (window `stateOn`, `stateOff`, also the rule list's state).

## `qbt rss rule-*`

It follows `qbt rss`' conventions from 5b1:
- **Every value arrives on stdin**, UTF-8, NUL-separated, never in argv (argv holds only the subcommand). Untrusted values reach curl, python and pcre2grep on stdin or a pipe, never in argv; response bodies never touch disk; every request is localhost-only.
- each command takes exactly K fields: `rules` and `rules-preview-enabled` read no stdin; `rule-preview` and `rule-remove` take 1; `rule-create` and `rule-rename` take 2; `rule-check` takes 3; `rule-set` takes 4; there is no trailing NUL; an empty stdin is one empty field.
- A wrong field count, a field that isn't the shape named below (JSON that doesn't parse, a key or type outside the table, an `enable` other than keep, off or on, a `useRegex` other than true or false) exits 2 with "usage: qbt rss rules|rules-preview-enabled|rule-check|rule-create|rule-set|rule-preview|rule-rename|rule-remove". A bare `qbt rss` or an unknown subcommand still prints 5b1's usage line (its `rssUsage`, unchanged).
- A refusal or failure prints one sentence on stderr and exits 1. Success prints one JSON line on stdout and exits 0. API failures print qbt's existing failure line (`API_FAIL`), codes only, never a body.
- Every write is a POST: `rss/setRule` (`ruleName`, `ruleDef` as JSON), `rss/renameRule` (`ruleName`, `newRuleName`), `rss/removeRule` (`ruleName`). The reads are `rss/rules`, `rss/matchingArticles?ruleName=` and 5b1's lean `rss/items?withData=true` and `app/preferences`.
- A rule name that isn't in `rss/rules` prints "That rule is gone." for `rule-set`, `rule-preview`, `rule-rename`'s `from` and `rule-remove`. Existing names are taken exactly as `rss/rules` gave them; only a new name (`rule-create`'s, `rule-rename`'s `to`) goes through the `ruleName` rule, so an odd name made elsewhere stays manageable.
- The regex check (the `regex` kind) runs only when `useRegex` is on: `pcre2grep -u -i -f <(printf '%s\n' "$pattern") /dev/null`, the pattern on a pipe or a file descriptor, never in argv. Exit 0 or 1 is valid; exit 2 with `Error in regex` on stderr is "That isn't a valid regular expression."; any other outcome (exit 2 without it, such as a pattern past pcre2grep's 8192-byte limit) is "Couldn't check the regular expression."; pcre2grep missing is "Checking regular expressions needs pcre2grep." An empty pattern is no condition and isn't checked; a pattern with a newline is "Patterns go on one line." in either mode. Python's `re` is never the check (it refuses `\K`, which PCRE2 accepts). `qbt probe` gains `"pcre2grep": bool`.

### `qbt rss rules`

No stdin. It reads `rss/rules` and `app/preferences` and prints `{"autoDownload": bool, "rules": [{"name", "enabled", "fields", "raw"}]}`:
- `autoDownload` is `rss_auto_downloading_enabled`.
- `rules` are sorted by name case-insensitively (Python's `str.lower()`), then by the exact name. `raw` is the rule's JSON as qBittorrent gave it, `fields` is `fields_of(raw)` (every RULE_FIELDS key, the `fields` kind) and `enabled` is `fields.enabled`.

### `qbt rss rule-check`

stdin `key\0value\0useRegex`. `key` is `mustContain` or `mustNotContain` (the `regex` kind with `useRegex`), `episodeFilter` (`episode`), `ignoreDays` (`ignoreDays`) or `savePath` (`savePath`); `useRegex` is `true` or `false` and is read only for the patterns. It makes no request. It prints `{"ok": true, "value": normalised}` (ignoreDays' value is a number), or the kind's sentence with exit 1. The window runs it before every INSERT commit of those fields and keeps the INSERT open with the sentence on a refusal; rule-set checks again.

### `qbt rss rule-create`

stdin `name\0feedUrl`. `name` goes through the `ruleName` rule ("Enter a rule name.", "Rule names can't contain control characters."); a name `rss/rules` already has prints "There's already a rule called <name>.". It POSTs `rss/setRule` with `{"enabled": false, "affectedFeeds": [feedUrl]}` (`[]` when `feedUrl` is empty; the window passes the url of the feed under the Feeds cursor, or empty), reads back that the rule exists, is disabled and has those feeds, and prints `{"ok": true, "name": n}` with the trimmed name; otherwise "Couldn't confirm <name> was added.". A new rule is always created **disabled** (OV7).

### `qbt rss rule-set`

stdin `name\0changesJson\0snapshotJson\0enable`:
- `changesJson` is an object holding only the edited fields (keys from RULE_FIELDS without `enabled`, values in `fields`' types); `snapshotJson` holds the same keys with their `fields` values at the draft's start, plus `enabled` whenever there are changes (so a `keep` save refuses when the rule was turned on or off elsewhere), plus `useAutoTmm` (true, false or null for absent) exactly when `changesJson` holds `savePath`; `enable` is `keep`, `off` or `on`.
- With `on`, `changesJson` and `snapshotJson` must both be `{}`: turning on never carries changes (the window saves a dirty draft with `keep` first). Anything else with `on`, `keep` with no changes, or a snapshot whose keys aren't exactly those, is the usage line (exit 2), and nothing is written. `{}` with `off` only turns the rule off.
- Steps, in order (the `patch` kind is steps 2 to 5):
  1. Read `rss/rules`; the rule missing prints "That rule is gone.".
  2. **D6**: each changed key's current `fields` value, and `enabled`'s, must equal its snapshot value, else "<name> changed elsewhere; press r to reload it." and nothing is written.
  3. **OV13**: only the changed fields are validated, each by its kind (and both patterns as regexes when the change turns `useRegex` on); the first refusal's sentence, and nothing is written. An untouched odd value (a stored episode filter of `1x2; 3;`) round-trips.
  4. **D5, OV10**: patch the changes onto the **current** JSON; nothing else changes (priority, lastMatch, previouslyMatchedEpisodes, tags, content layout, limits and every other key round-trip). Setting a path writes `torrentParams.save_path` and `use_auto_tmm` false; clearing it removes `save_path` and restores `use_auto_tmm` to `snapshot.useAutoTmm` (removed when null). The flat keys are mirrored; a rule without `torrentParams` gets none created.
  5. Apply `enable`: `on` true, `off` false, `keep` the current value, always written explicitly.
  6. With `on` (changes `{}`), qbt previews the saved rule as `rule-preview` does before any write. noTorrent > 0 prints "<m> matching articles have no torrent link, and qBittorrent would retry them forever. Tighten the rule first." (m filled), exit 1, having written nothing: the rule stays off. Otherwise it writes the current rule with `enabled` true and nothing else changed. So a rule is never on without the preview check, and never downloads before the window's confirm has named n (the window previews the same saved rule for its confirm). n counts only the previewable feeds: OV4's same-named feeds are excluded from it, yet qBittorrent still reads them once the rule is on, so with such a pair more than n can download (the spec's decision; the preview shows the pair as unpreviewable).
  7. POST `rss/setRule`, then read back. The read-back must hold every field: the rule's `fields` equal the written ones, and every other key equals the written JSON after qBittorrent's own re-serialisation (`torrentParams.save_path` absent reads back as `""`), except `lastMatch` and `previouslyMatchedEpisodes`, which step 8 owns. A mismatch prints "Couldn't confirm the save.".
  8. **OV9**, `union_episodes(written, reread)`: `merged` is the written `previouslyMatchedEpisodes`, then every entry of the re-read list not already in it (in the re-read order), and `lastMatch` is the later of the written and the re-read one (RFC 2822; an unparsable or empty one is the oldest). If `merged` and that `lastMatch` equal the re-read rule's, nothing more happens. Otherwise it writes the re-read rule once more with `merged` and that `lastMatch`, and reads back once (a mismatch is "Couldn't confirm the save."). It never loops.
  9. Print `{"ok": true}`.
- pcre2grep missing while a regex needs checking prints "Checking regular expressions needs pcre2grep." before any write.

### `qbt rss rule-preview`

stdin `name`. It reads `rss/rules` (missing: "That rule is gone."), `rss/matchingArticles?ruleName=name` and 5b1's `qbt rss items` data, and prints `{"will": [{"feedPath", "guid", "title", "dup"}], "read": [...], "noTorrent": [...], "unpreviewable": [{"name", "feedPaths"}], "gone": [url]}`, the `previewJoin` kind's groups:
- `will`: unread, with a torrent by 5b1's `hasTorrent` rule; `read`: matched and read; `noTorrent`: unread, no torrent, and a non-empty URL by the effective URL: torrentURL, or link when torrentURL is empty (Article::torrentUrl falls back; qBittorrent would try it, fail and retry it forever); an unread article with neither is in no group.
- `dup` is k when a title maps to k guids in the feed (OV5: each counts).
- `unpreviewable`: the rule's feeds that share a name (OV4), counted nowhere. `gone`: rule URLs no feed has.
- n is `will`'s length and m is `noTorrent`'s. The confirms and D8 use n.

### `qbt rss rules-preview-enabled`

No stdin. For every enabled rule it runs `rule-preview`'s join, then prints `{"rules": r, "will": n, "noTorrent": m}`: r the number of enabled rules, n and m the `will` and `noTorrent` articles counted once each by `feedPath` and `guid` (first match wins, so an article two rules match downloads once). Settings' auto-download confirm (D8) uses it through `Service.rssAutoPreview(cb)` → `cb(ok, err, {rules, will, noTorrent})`.

### `qbt rss rule-rename`

stdin `from\0to`. `to` goes through the `ruleName` rule; the window skips an unchanged name without calling qbt (qbt answers `{"ok": true, "name": to}` without a request for it too). `from` missing prints "That rule is gone."; `to` already in `rss/rules` prints "There's already a rule called <name>." (the pre-check: renameRule is a silent no-op on a clash). It POSTs `rss/renameRule`, reads back that `from` is gone and `to` exists, and prints `{"ok": true, "name": to}`; otherwise "Couldn't confirm the rename.".

### `qbt rss rule-remove`

stdin `name`. A name not in `rss/rules` prints "That rule is gone.". It POSTs `rss/removeRule`, reads back that it's gone, and prints `{"ok": true}`; otherwise "Couldn't confirm <name> was removed.".

### Auto-download on (D8, Task 2)

`settings-schema.json` un-defers `rss_auto_downloading_enabled` with `"confirmVia": "rssAutoDl"`. Turning it on runs `Service.rssAutoPreview(cb)`, then raises CONFIRM `rssAutoDlOn` (y "turn on"). That kind is Settings', not RSS's: it is in `View.SETTINGS_ACCEPT` (ClientView.js, which gives `View.confirmLine` its word), never in `View.RSS_ACCEPT`, so RssPane's dropConfirm can't drop it; Task 2 adds its drop to `SettingsCommands.dropConfirm` (drop any kind in `View.SETTINGS_ACCEPT` alongside `settingConfirm` and `secretClear`). The line is "Turn on auto-download? <r> rules are on; up to <n> unread articles download now.", or "No rules are on yet; nothing downloads until you turn one on." when r is 0, or "Turn on auto-download? Couldn't count what would download." when the count failed. Turning it off asks nothing.

## The window (Task 3)

The Service calls, on 5b1's serial `rss` lane: `rssRules(cb)`, `rssRuleCheck(key, value, useRegex, cb)`, `rssRuleCreate(name, feedUrl)`, `rssRuleSet(name, changes, snapshot, enable)`, `rssRulePreview(name, cb)`, `rssRuleRename(from, to)`, `rssRuleRemove(name)`; Task 2 adds `rssAutoPreview(cb)`.

The edit model (the Outside voice's OV15, OV1, OV2; no shadow rules, no `w` save step):
- **Edit while off.** Enter on an enabled rule asks "Editing turns <name> off until you turn it back on." (CONFIRM `rssRuleEditOff`, y "turn off and edit"): y writes `enable: "off"`, then the fields take the keys. A disabled rule goes straight into the fields.
- **The draft.** Entering the fields snapshots the rule's `fields` (`enabled` included) and `torrentParams.use_auto_tmm` (true, false, or null when absent). Every save sends the changed keys' snapshot plus `enabled`. After any successful save the draft is clean and its snapshot becomes the written values; `useAutoTmm` stays the value from when the fields were entered, so clearing a path set in this visit restores it.
- **Auto-download off**: each committed field (Enter after `rssRuleCheck` accepts it, a toggle, a picker's apply) saves at once (`rssRuleSet`, that field only, `enable: "keep"`) and previews. Previews run on commit, never per keystroke; one at a time, the newest queued request wins, and stale answers are dropped by generation (D12). The column shows "updating…" while one runs, and "Couldn't update the preview." when one fails.
- **Auto-download on** (OV2): commits change only the local draft (no `rssRuleSet` until the user asks). `View.rssRulesFooterNote(pane, flags)` then gives "auto-download is on: p saves and previews", shown as a muted note line under the rules area's footer key hints (the rule list, the fields and the narrow preview). `p` saves the draft once (`keep`) and previews. `D` discards after "Discard your changes to <name>?" (CONFIRM `rssRuleDiscard`), as does `r` with a dirty draft.
- **Leaving a dirty draft.** Every action that leaves a dirty draft's rule raises CONFIRM `rssRuleLeave` first, "Save changes to <name>? y save · n keep editing" (y "save"): `h`/Esc in the fields (`rss.fieldsBack`), Tab (`rss.rulesSwitch`), Esc in the list (`rss.rulesBack`), a pick in the narrow rule list (`rss.ruleListPick`), Enter, `x`, `e` or `n` on a different rule, `R` (`rss.rules`), and closing the rules by a key. y saves the draft (`keep`), then the action runs as if pressed again (raising its own confirm if it has one); n keeps editing and the action doesn't run. When the Client closes RSS itself (a magnet's CONFIRM, a torrent row from the palette), the dirty draft is kept: the view's state survives leaving, as Search's does, so the draft is there when the rules reopen, still dirty, and the leave confirm still guards it. When the window closes, the draft is dropped with no write.
- **Turning on** (`e`, or Space on Enabled), in this order, and never carrying changes: a dirty draft is saved first (`rssRuleSet(name, changes, snapshot, "keep")`); then the saved rule is previewed; noTorrent > 0 refuses with the `noTorrentBlock` sentence as a note and no confirm; otherwise the confirm (CONFIRM `rssRuleOn`, y "turn on") names that preview's n: "Turn on <name>? Up to <n> unread articles download now.", or "Turn on <name>? Nothing in your feeds matches yet." with n = 0, or, while auto-download is off, "Turn on <name>? Auto-download is off, so nothing downloads until you turn it on in Settings → RSS."; y runs `rssRuleSet(name, {}, {}, "on")`, which previews again and, if noTorrent has grown past 0, refuses having written nothing. Turning off is immediate, with no confirm: `rssRuleSet(name, {}, {}, "off")`.
- **New, rename, remove**: `a` asks for "Rule name" (INSERT `rssRuleName`), then `rssRuleCreate` with the Feeds cursor's feed url (or empty) and notes "Created <name>; it stays off until you turn it on."; `n` asks "Rename rule" (INSERT `rssRuleRename`, prefilled); `x` asks "Remove rule <name>? This can't be undone." (CONFIRM `rssRuleRemove`, y "remove") and notes "Removed rule <name>.". Turning on and off note "<name> is on." and "<name> is off.".
- **The field INSERT** is `rssRuleField` ("New value", prefilled with the value); the field key stays in the rules area's own input state.
- **The preview column**: "Would download (<n>)", then muted "No torrent link (<m>)" and "Already read (<k>)"; a title with dup > 1 shows "(same title ×<k>)"; each unpreviewable name shows "can't preview: two feeds are called <name>; rename one"; nothing at all shows "Nothing in your feeds matches yet.". The column's title is "Preview".
- **The rule list** is titled "Rules"; with no rules it shows "No rules. a creates one that downloads matching articles automatically."
- **The blocked keys' muted notes** (the registry's needs): "No rule here." (`rssRule`), "This field can't be edited here." (`rssFieldEditable`), "Space toggles on/off fields." (`rssFieldToggle`), "Nothing to discard." (`rssRuleDirty`), and 5b1's down reason for `rssUp` (and first for the other four: `D` needs qBittorrent up too).
- **The help lines**, one per field: "While it's on and auto-download is on, qBittorrent adds every unread article it matches. e turns it on or off.", "Titles must match this. Wildcards: * and ?; words separated by spaces must all appear; | separates alternatives. Empty matches every title.", "Titles that match this are skipped, with the same syntax as Must contain. Empty skips nothing.", "Read both patterns as Perl-compatible regular expressions, ignoring case.", "Episodes to take, such as 1x2;8-15;5;30-; for season 1's episodes 2, 5, 8 to 15 and 30 on. Empty takes every episode.", "Take each episode once, using qBittorrent's memory of matched episodes and its smart filter settings.", "The feeds this rule reads.", "The category matching torrents are added to.", "Where matching torrents are saved. Empty uses the category's folder or qBittorrent's default." and "Add matching torrents stopped, started, or as qBittorrent's own setting says." and "After a match, skip this rule's matches for this many days. 0 never skips."
- **The value words**: "on", "off", "(empty)", "(none)", "(default)", "default", "yes" and "no".
- Window close with a dirty draft drops it with no write, and drops a rules CONFIRM.
- `rssRuleSet(name, {}, {}, "on")` is the only call that turns a rule on.

## The sentences

For reference, every sentence `qbt rss rule-*` prints, as the case file holds them:

- Usage: "usage: qbt rss rules|rules-preview-enabled|rule-check|rule-create|rule-set|rule-preview|rule-rename|rule-remove".
- Names: "Enter a rule name.", "Rule names can't contain control characters." and "There's already a rule called <name>.".
- Gone and changed: "That rule is gone." and "<name> changed elsewhere; press r to reload it.".
- Values: "That isn't a valid regular expression.", "Couldn't check the regular expression.", "Checking regular expressions needs pcre2grep.", "Patterns go on one line.", "Use an episode filter such as 1x2;8-15;", "Ignore for a whole number of days, 0 to 365." and "Enter an absolute path, or leave it empty.".
- Turning on: "<m> matching articles have no torrent link, and qBittorrent would retry them forever. Tighten the rule first.".
- Read-backs: "Couldn't confirm the save.", "Couldn't confirm <name> was added.", "Couldn't confirm the rename." and "Couldn't confirm <name> was removed." (the last three repeat 5b1's text).
