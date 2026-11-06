# Dual-mode remote WebUI support

Decision (2026-09-07): keep one plugin (`aweiward.omaqbt`) with **local** (default) and **remote** modes. Do not ship a separate `omaqbt.remote` plugin or rely on tunnel-only docs as the product answer.

Related: [#1](https://github.com/Aweiward/omaqbt/issues/1). Upstream inspiration: [manuelseeger/omaqbt](https://github.com/manuelseeger/omaqbt) remote-support work (credit and invite a PR).

## Goals

- Default behavior stays localhost + managed `qbittorrent-nox`.
- Remote mode can talk to a WebUI on another host without deleting local daemon features.
- Secrets never land in `shell.json`, argv, env, or logs.
- Non-loopback endpoints require HTTPS.

## Non-goals (first slice)

- Multiple simultaneous profiles (manifest still `allowMultiple: false`).
- Changing the plugin ID / migration of existing installs.
- Rewriting remote hosts' `qBittorrent.conf` or installing packages there.
- Opening a remote `savePath` in a local file manager.

## Modes

| | Local (default) | Remote |
| --- | --- | --- |
| Endpoint | `http://127.0.0.1:<port>` from local conf | User `baseUrl` + `username` |
| Auth | Loopback whitelist / no password (today) | Secret Service password + cookie/SID |
| Install / start daemon / VPN bind / GUI lock | Yes | Hidden |
| Open folder | Yes | Hidden or disabled |
| Magnet / add / start-stop / priorities / limits | Yes | Yes |

Suggested settings (names TBD in implementation):

- `mode`: `local` \| `remote`
- `baseUrl`: e.g. `https://qbt.example:8080` (ignored in local)
- `username`: WebUI user (ignored in local)
- existing `refreshIntervalSec` unchanged

## Transport (`qbt`)

Port the fork's patterns into upstream `qbt` **without** removing local daemon verbs:

1. `--base-url` / `--username` (or equivalent) passed from QML.
2. URL validation: HTTPS required off-loopback; HTTP only for `127.0.0.1` / `localhost` / `::1`; reject userinfo, query, fragment, empty host.
3. Password via Secret Service (`secret-tool`), keyed by app id + normalized endpoint + username; pipe to curl stdin — never store in config.
4. Per-connection cookie/RID state (hash of endpoint + username).
5. On HTTP 403: one login + replay; handle bad credentials / bans / expired SID.
6. Redact cookies, SID, usernames, password-like fields from errors.
7. Keep `assert_local_base`-style guard when `mode=local` (or when no remote endpoint is set).

Local commands (`start-daemon`, install, status that assumes a shared profile) stay available but must refuse or no-op clearly when the active endpoint is remote.

## UI / service

- `Service.qml`: read mode/endpoint/username; wrap every helper invocation; clear transfer state when connection identity changes; discard late responses from a previous connection key.
- `Panel.qml`: gate install / start-daemon / GUI-lock / VPN / Open folder to local mode; show remote reachability and auth errors plainly.
- `manifest.json`: add the new settings; **keep** plugin id `aweiward.omaqbt`.

## Tests / docs

- Bring over fork coverage: auth, cookie reuse, expired re-login, credential failure, bans, multipart replay, endpoint isolation, URL validation, HTTPS errors, secret sanitization (`tests/api-contract.sh` + fixture server).
- Document Secret Service setup and HTTPS requirement in README Configure section.

## Suggested PR split (for contributors)

1. `qbt` transport/auth/state + fixture tests (no QML mode switch yet, or behind flags).
2. Service / Panel / manifest dual-mode wiring + README.

## Open questions

- Exact Secret Service attribute schema and first-run UX for storing the password.
- Whether local mode should ever gain optional WebUI password support.
- How to display remote `savePath` without implying local open.
- qBittorrent version matrix for login response codes / cookie formats.
