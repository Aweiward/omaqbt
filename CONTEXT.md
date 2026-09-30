# OmaqBT

OmaqBT is qBittorrent's client inside the Omarchy bar. It has two surfaces: a small popup under the bar mark, and a full window.

## Language

**Mark**:
The OmaqBT icon in the bar, showing the **Logo**, live speeds and status badges.
_Avoid_: icon, widget

**Logo**:
OmaqBT's artwork: a square q whose right wall runs down into a download arrow. It appears on the **Mark**, in the **Popup**, and anywhere OmaqBT is shown outside the bar.
_Avoid_: mark, icon

**Popup**:
The small view that opens under the mark on a left click, for quick checks: transfers, adding a magnet, start/stop, remove, file priorities.
_Avoid_: panel, dropdown

**Window**:
The full OmaqBT window, with the torrent table, inspector, library tools, Settings, Search and RSS. It opens from the popup or with `omarchy-shell shell toggle aweiward.omaqbt`.
_Avoid_: panel, client, full client (in user-facing text)

**View**:
One of the window's screens: the torrents, Settings, Search or RSS. Exactly one view shows at a time.
_Avoid_: tab, page, mode

## Relationships

- The **Mark** opens and closes the **Popup**.
- The **Window** shows exactly one **View** at a time. The torrents are the default view.
- The **Popup** and the **Window** show the same torrents from the same qBittorrent daemon.

## Flagged ambiguities

- "Mark" meant the bar item in this glossary and the q artwork in the logo's brand notes. Resolved: the artwork is the **Logo**; the **Mark** is the bar item that shows it.
- "Panel" meant the **Popup** in the README and the **Window** in the plugin manifest (Omarchy's `"panel"` kind). Resolved: user-facing text says **Popup** and **Window**; "panel" appears only as Omarchy's manifest kind.
