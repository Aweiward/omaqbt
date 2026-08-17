# OmaqBT

A themed [Omarchy](https://omarchy.org) Quattro bar widget for qBittorrent. Left-click the mark to watch live transfers, add a magnet, start or stop, remove a torrent, and set file priorities. Right-click starts or stops everything. The official Qt window stays as an escape hatch.

OmaqBT talks to `qbittorrent-nox` on your existing `~/.config/qBittorrent` library through the local Web API. It does not talk to any host other than `127.0.0.1`.

License: [MIT](LICENSE).

## Install

```sh
omarchy plugin add https://github.com/Aweiward/omaqbt.git --enable
```

If `qbittorrent-nox` is missing, open the widget and click **Install qBittorrent-nox**. That runs `pkexec omarchy pkg add qbittorrent-nox` (Arch extra, polkit password prompt) and then starts the user service `omaqbt-nox.service`. It will not remove desktop `qbittorrent` if you already have it.

Close the Qt qBittorrent window before starting the daemon. Stop the daemon before opening the Qt app. They share one profile and must not run at the same time.

```sh
omarchy bar move aweiward.omaqbt --section right
```

## Usage

- Left click: open or close the panel
- Right click: start or stop all torrents
- Middle click: refresh
- Esc: close the panel

List keys: `j`/`k` move, Enter opens files, Space start/stop, `x` remove (keep files), `X` delete files, `t` start/stop all, `a`/`p`/`c`/`*` filter, `/` magnet field, `y` add clipboard magnet, `r` refresh.

File view keys: `j`/`k` move, Enter cycle priority, `x` skip, Space start/stop, `X` delete files, Backspace or `h` back.

## Configure

The only plugin setting is `refreshIntervalSec` (default 5) on the widget entry in `~/.config/omarchy/shell.json`.

Starting the daemon writes these keys under `[Preferences]` in `~/.config/qBittorrent/qBittorrent.conf` if you click **Install** or **Start daemon**:

```
WebUI\Enabled=true
WebUI\Address=127.0.0.1
WebUI\LocalHostAuth=false
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=127.0.0.1, ::1
WebUI\Port=<existing port, or 8080>
```

If `wg0-mullvad` is present (or `QBT_BIND_IFACE` is set), starting the daemon also writes under `[BitTorrent]`:

```
Session\Interface=<iface>
Session\InterfaceName=<iface>
Session\InterfaceAddress=
```

That binds the tunnel interface, not a single relay IP, so a Mullvad city change does not stall announces.

No other qBittorrent keys are rewritten. The plugin never stores a Web UI password.

## Remove

```sh
omarchy plugin remove aweiward.omaqbt
```

That disables the widget and deletes the plugin checkout. It does **not** uninstall `qbittorrent-nox`, stop `omaqbt-nox.service`, delete torrents, or revert the Web UI keys above.

To stop the daemon yourself:

```sh
systemctl --user stop omaqbt-nox.service
```

## Requirements

- Omarchy 4 (Quattro) / `omarchy-shell`
- `qbittorrent-nox` 5.2+ (installed from the panel if missing)
- On PATH for the helper: `curl`, `jq`, `python3`
- `pkexec` only when installing the package from the panel (no TTY for `sudo`)
- `systemctl --user` for `omaqbt-nox.service`

## What this plugin does on your system

- Runs `qbt` from the plugin folder. That helper is the only process that talks HTTP, and only to `127.0.0.1`.
- Installs the Arch extra package `qbittorrent-nox` through `omarchy pkg add` when you click Install. Privilege is `pkexec`, not a sudoers rule.
- Writes `~/.config/systemd/user/omaqbt-nox.service` and enables it as your user.
- Writes the localhost Web UI keys listed under Configure. It stops the daemon first so qBittorrent does not overwrite those keys on exit.
- Stores sync state in `$XDG_RUNTIME_DIR/omaqbt/` (private, mode 700). If that variable is unset it falls back to a uid-scoped `/tmp/omaqbt-<uid>`, created with `umask 077`, and refuses to write through a symlink or a directory it does not own.
- Does not add torrents, delete files, or start the daemon unless you click or press the matching control.

## Dev

```sh
node --test tests/*.test.js
tests/api-contract.sh
omarchy plugin validate .
```

`tests/api-contract.sh` talks to a fixture HTTP server. It does not start `qbittorrent-nox`, add a real torrent, or delete files on disk.
