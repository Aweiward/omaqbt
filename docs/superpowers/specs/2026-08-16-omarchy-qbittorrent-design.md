# OmaqBT

Daily-driver bar widget for qBittorrent on Omarchy. Left click opens a themed panel for live transfers, magnets, start/stop, remove, and file priorities. Right click starts or stops every torrent. The Qt window becomes an escape hatch, not the everyday UI.

## Goal

Stop opening the qBittorrent window for the work that happens most days:

- See progress, speeds, and ETA on torrents that are downloading or seeding
- Add a magnet or torrent URL
- Start or stop one torrent, or all of them
- Remove a torrent and keep the files
- Remove a torrent and delete the files (with confirm)
- Inspect files in a torrent and set Skip / Low / Normal / High

When the plugin is done, the bar is enough for that loop. The official Qt app stays installed and can still open the same library after the daemon is stopped.

## Non-goals (v1)

- Adding `.torrent` files from disk
- Global or per-torrent speed limits
- Categories, tags, or save-path changes
- RSS, search, trackers, peers, pieces, or graphs
- Completion notifications
- Opening the download folder
- Talking to any host other than localhost
- Replacing qBittorrent settings

## Architecture

Third-party Omarchy bar widget, same contract as `aweiward.mullvad`.

| | |
|---|---|
| Plugin id | `aweiward.omaqbt` |
| Kind | `bar-widget` |
| Entry point | `Panel.qml` |
| Default section | `right` |
| Install | `omarchy plugin add <git-url> --enable` |
| Theme | `qs.Commons` / `qs.Ui` only — no hard-coded palette |

Three processes, one profile:

1. **omarchy-shell** loads the plugin. The bar button and `KeyboardPanel` are QML. `Service.qml` never speaks HTTP.
2. **`qbt` helper** (bash, `curl` + `jq`) owns the Web API. JSON on stdout. This is what we contract-test.
3. **`qbittorrent-nox`** runs as a systemd user service on the existing `~/.config/qBittorrent` session.

The desktop `qbittorrent` binary is not removed. It must not run at the same time as `qbittorrent-nox` against that profile. The helper detects the lock by process name (`qbittorrent` vs `qbittorrent-nox`) and by `~/.config/qBittorrent/lockfile`. If the Qt app holds the lock, the panel explains that and will not start the daemon. It never kills the GUI.

### Bar contract

Matches the rest of Omarchy and Mullvad:

- Left click: toggle the panel
- Right click: start or stop all torrents (no-op with an error if the daemon is down)
- Middle click: refresh

The mark is a QML-drawn icon, not an SVG. Dim when nothing is downloading or seeding. Bright when at least one torrent is. Warning badge if the daemon is down, the API is unreachable, or the Qt lock is held.

## Components

### `manifest.json`

`schemaVersion` 1, id `aweiward.omaqbt`, `kinds: ["bar-widget"]`, `entryPoints.barWidget: "Panel.qml"`. One setting: `refreshIntervalSec` (integer, 5–3600, default 5). That interval is the fallback poll if live sync is not producing updates. `allowMultiple: false`. Category: Network.

### `QbittorrentIcon.qml`

Themed mark. Properties: `color`, `busy` (bright vs dim), `warning` (badge). Drawn with QML primitives so it tracks the current theme.

### `Panel.qml`

Bar button plus one `KeyboardPanel`. Two views, never two windows.

**List view**

- Hero: “OmaqBT”, global ↓ / ↑, active count, start/stop-all `ToggleSwitch`
- Magnet field (paste, Enter adds)
- Clipboard banner when the panel opens and the clipboard holds a `magnet:` link or an `http(s)` URL whose path ends in `.torrent`. Action: Add this. Clipboard is not watched while the panel is closed.
- Torrent rows: name, percent, ↓ / ↑, ETA, thin progress bar
- Default filter: downloading + seeding only

Filter keys change what is shown, not what is fetched:

| Key | Filter |
|-----|--------|
| `a` | Active (downloading + seeding) — default |
| `p` | Paused / stopped |
| `c` | Completed (not seeding) |
| `*` | All |

**Detail view** (Enter on a row)

- Back control
- That torrent as the hero (name, percent, speeds, ETA)
- File list with current priority
- Start/stop this torrent
- Remove and keep files (instant)
- Remove and delete files (`ConfirmDialog` from `qs.Ui`)

File priorities shown as Skip, Low, Normal, High, mapped to qBittorrent values `0`, `1`, `6`, `7`. Enter cycles that order. `x` sets Skip.

### `Service.qml`

The only QML object that runs processes. Holds: installed, daemon running, lock holder (`none` / `nox` / `gui`), API reachable, global speeds, torrent list, selected torrent files, `lastError`, `actionStatus`, `busy`. Optimistic start/stop on the affected rows, then a status refresh confirms.

### `Model.js`

Pure functions, no I/O:

- Classify a qBittorrent `state` string into `downloading` | `seeding` | `paused` | `completed` | `error`
- `filterTorrents(list, mode)`
- Format size, rate, ETA, percent
- `isAddableUrl(text)` — magnet or `.torrent` URL
- Priority number ↔ label
- `torrentId(row)` — `hash` if non-empty, else `infohash_v1`, else `infohash_v2`. Every helper verb uses that id.

Active (`downloading`): `downloading`, `metaDL`, `stalledDL`, `queuedDL`, `forcedDL`, `allocating`, `checkingDL`.
Active (`seeding`): `uploading`, `stalledUP`, `queuedUP`, `forcedUP`, `checkingUP`.
Paused: `pausedDL`, `pausedUP`, `stoppedDL`, `stoppedUP` (v5 renamed pause → stop; accept both).
Completed: classified as paused **and** `progress >= 1.0` (finished and not seeding).
Error: `error`, `missingFiles`, `unknown`.
Checking resume data or `moving` stay in the list under All only; they are not Active.

Filters are exclusive: `p` is paused with `progress < 1.0`; `c` is the completed bucket; a finished stopped torrent appears only under Completed.

### `qbt` helper

Path: plugin root, executable `qbt`. Stdout is JSON. Stderr is human text. Non-zero exit on failure. Never prints a SID cookie, password, or `SID=` fragment.

| Verb | Does |
|------|------|
| `status` | Probe daemon/lock, `/sync/maindata` with no cookie, print daemon + torrents |
| `add <url>` | `POST /api/v2/torrents/add` |
| `start <hash\|all>` | `POST /api/v2/torrents/start` |
| `stop <hash\|all>` | `POST /api/v2/torrents/stop` |
| `delete <hash> [--files]` | `POST /api/v2/torrents/delete` |
| `files <hash>` | `GET /api/v2/torrents/files` |
| `prio <hash> <index> <0\|1\|6\|7>` | `POST /api/v2/torrents/filePrio` |
| `install` | `omarchy pkg add qbittorrent-nox` |
| `start-daemon` | Enable and start the user unit, after refusing if the Qt app holds the lock |
| `stop-daemon` | Stop the user unit |

v5 endpoint names only (`start` / `stop`). Do not call `/torrents/pause` or `/torrents/resume`.

`status` JSON shape:

```json
{
  "installed": true,
  "daemon": true,
  "lockHolder": "nox",
  "api": true,
  "dlSpeed": 2202009,
  "upSpeed": 143360,
  "torrents": [
    {
      "hash": "…",
      "name": "…",
      "state": "downloading",
      "progress": 0.42,
      "dlSpeed": 1887436,
      "upSpeed": 0,
      "eta": 720,
      "ratio": 0.1,
      "size": 661651456
    }
  ]
}
```

`hash` in that object is `torrentId`: `hash` if the API sent one, else `infohash_v1`, else `infohash_v2`. Every later verb uses that string.

`files` JSON is an array of `{ index, name, progress, priority }`.

### User service and Web UI

The helper writes `~/.config/systemd/user/omaqbt-nox.service` if it is missing:

```
[Unit]
Description=qBittorrent-nox for OmaqBT
After=network-online.target

[Service]
ExecStart=/usr/bin/qbittorrent-nox
Restart=on-failure

[Install]
WantedBy=default.target
```

Named `omaqbt-nox` so it does not fight a packaged system unit. It runs as the user, so it uses `~/.config/qBittorrent`.

On `start-daemon`, the helper always writes these three keys (they are required for a local-only plugin and override a previous LAN Web UI):

```
WebUI\Enabled=true
WebUI\Address=127.0.0.1
WebUI\LocalHostAuth=false
```

If `WebUI\Port` is already set, use it. Otherwise set `8080`. No other keys are rewritten. The helper talks only to `127.0.0.1` on that port. It tries each request without a cookie first; if the server returns 403 it fails with “localhost auth is required” rather than guessing a password.

Binding to `127.0.0.1` with `LocalHostAuth=false` is the security model: the API is not on the LAN, and the plugin never stores a password.

If 8080 (or the configured port) fails to bind, surface the helper error. Do not scan for another port.

## Data flow

1. On interval, and when the panel opens, `Service` runs `qbt status`.
2. First successful contact uses a full `/sync/maindata` snapshot. Later `status` calls pass the last `rid` so the helper can request a delta and merge. If the server returns a full update, replace the cache.
3. `Model.filterTorrents` decides the visible list. Filter changes do not re-fetch.
4. Start, stop, add, delete, and priority: panel → `Service` → `qbt <verb>` → Web API. Start/stop update the row immediately, then `status` confirms.
5. Add reads the magnet field or the clipboard offer. The new torrent appears on the next snapshot.
6. Delete-with-files is the only path that waits for `ConfirmDialog` before the helper runs. Remove-and-keep-files does not confirm.
7. The bar mark reads the same `Service` state. No second poll.
8. Clipboard is read only when the panel opens.

## Keyboard

List view, when the magnet field is not focused:

| Key | Action |
|-----|--------|
| `j` / `k` or arrows | Move |
| Enter | Open detail |
| Space | Start or stop the selected torrent |
| `x` | Remove, keep files |
| `X` | Remove and delete files (confirm) |
| `t` | Start or stop all |
| `a` `p` `c` `*` | Filters |
| `/` | Focus magnet field |
| `y` | Add the clipboard offer, if shown |
| `r` | Refresh |
| Esc | Close panel |

Detail view:

| Key | Action |
|-----|--------|
| `j` / `k` or arrows | Move among files |
| Enter | Cycle file priority |
| `x` | Skip that file |
| Space | Start or stop this torrent |
| `X` | Remove and delete files (confirm) |
| Backspace or `h` | Back to the list |
| `r` | Refresh files + status |
| Esc | Close panel |

Tab switches to the next bar panel, same as other Omarchy widgets.

## Error handling

| Situation | Panel | Bar |
|-----------|-------|-----|
| `qbittorrent-nox` not installed | Hero + Install | Warning badge |
| Daemon down | Hero + Start daemon | Warning badge |
| Qt app holds the lock | Message: close qBittorrent first. No auto-kill | Warning badge |
| API unreachable | Error + Retry. Helper does not tight-loop; `Service` backs off | Warning badge |
| One command fails | List stays up. One error line under the hero. Clears on next success or refresh | Unchanged |

Install uses `omarchy pkg add qbittorrent-nox` and the usual privilege prompt. It does not uninstall desktop `qbittorrent`.

The helper never targets a host other than `127.0.0.1`. It strips SID/password-shaped tokens from any error string before printing.

## Testing

Same split as Mullvad: pure model, then a helper contract that does not touch the real library.

**`tests/model.test.js`** — classify states; default filter keeps downloading/seeding only; size/rate/ETA; `isAddableUrl`; priority map.

**`tests/api-contract.sh`** — fixture HTTP server, not the real daemon. Asserts `status` shape, `add` posts a magnet, `start`/`stop` hit the v5 endpoints, `delete` with and without `deleteFiles`, `files` and `prio`, and that errors never contain `SID`. Does not start nox, add a real torrent, or delete files.

**`omarchy plugin validate .`** — manifest schema, no reserved `omarchy.*` id, entry points exist.

No screenshot tests and no live-library tests in v1.

## Theming and copy

Use `Color.foreground`, `Color.urgent`, `Style.font`, `PanelHero`, `PanelSectionHeader`, `PanelSeparator`, `ToggleSwitch`, `TextField`, `ConfirmDialog`, `KeyboardPanel`, `BarIconButton`. No third-party QML controls. No raw hex except inside theme-aware `Color` / `Style` helpers.

Hero title is “OmaqBT” on the list and the torrent name on detail. Empty active list: “Nothing downloading or seeding.” Empty paused/completed filters get their own one-line empty states.

## Implementation notes

- Follow `omarchy-mullvad` file layout and naming so the two plugins stay siblings.
- qBittorrent 5.2 is the target (already installed here). v5 renamed pause/resume to start/stop.
- `refreshIntervalSec` default is 5 seconds because transfer rows go stale faster than VPN status. The helper still prefers `/sync/maindata` deltas inside each `status` call.
- Do not add a settings UI beyond the manifest schema. Web UI port and bind address stay in `qBittorrent.conf`.
