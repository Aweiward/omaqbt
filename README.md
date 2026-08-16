# qBittorrent for Omarchy

A status-bar plugin for [Omarchy](https://omarchy.org) Quattro that puts qBittorrent on the desktop instead of in the Qt window.

Left-click the themed mark to see what is downloading or seeding, paste a magnet, start or stop transfers, remove a torrent, and set file priorities. Right-click starts or stops everything. It talks to `qbittorrent-nox` on your existing library, so the daemon you already trust is still what is running.

## Install

```bash
omarchy plugin add https://github.com/Aweiward/omarchy-qbittorrent.git --enable
```

If `qbittorrent-nox` is missing, open the widget and click **Install qBittorrent-nox**. That runs `omarchy pkg add qbittorrent-nox` and starts `omarchy-qbittorrent-nox.service`. It will not remove the desktop qBittorrent app if you already have it.

Close the Qt qBittorrent window before starting the daemon. Stop the daemon (`systemctl --user stop omarchy-qbittorrent-nox.service`) before opening the Qt app. They share `~/.config/qBittorrent` and must not run at the same time.

## Remove

```bash
omarchy plugin remove aweiward.qbittorrent
```

That disables the widget and deletes the plugin checkout. It does **not** uninstall `qbittorrent-nox`, stop the user service, delete torrents, or change other Omarchy config.

## Use

- Left click: panel
- Right click: start / stop all torrents
- Middle click: refresh

Keys in the list: `j`/`k` move, Enter opens files, Space start/stop, `x` remove (keep files), `X` delete files, `t` start/stop all, `a`/`p`/`c`/`*` filter, `/` magnet field, `y` add clipboard magnet, `r` refresh, Esc close.

Keys in the file view: `j`/`k` move, Enter cycle priority, `x` skip, Space start/stop, `X` delete files, Backspace or `h` back, Esc close.

## Requirements

- Omarchy 4 (Quattro) / `omarchy-shell`
- qBittorrent 5.2+ Web API (`start`/`stop`, not `pause`/`resume`)

## Dev

```bash
node --test tests/*.test.js
tests/api-contract.sh
```

`tests/api-contract.sh` talks to a fixture HTTP server. It does not start `qbittorrent-nox`, add a real torrent, or delete files on disk.
