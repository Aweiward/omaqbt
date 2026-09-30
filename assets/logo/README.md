# OmaqBT logo

A square q. The window does not close — the bottom-right opens by one stroke, the way an Omarchy frame breaks — and the right wall continues into a 45-degree download tail.

One color, no radius, no gradient. It tints with the theme, and it still reads at 16px.

Tokyo Night magenta (`#bb9af7`) is the tile color. That is Omarchy's color, not qBittorrent blue.

## Which file

| File | Use |
| --- | --- |
| `omaqbt-knockout.svg` | Outside the bar: the README header and the magnet handler's `Icon=`. Purple tile, night window. This is the one. |
| `omaqbt-symbolic.svg` | `fill="currentColor"`. Two paths, `id="q"` and `id="tail"`. |
| `omaqbt.svg` | Opaque night tile, purple logo. Use if a surface cannot take the knockout. |
| `omaqbt-active.svg` | Reference for the transferring state: q in foreground, tail tinted. |
| `omaqbt-mono.svg` | Night tile, foreground logo. |
| `png/` | 16–1024 rasters for surfaces that cannot take SVG. |

The bar and the popup do not load these files. `OmaqbtLogo.qml` draws the same paths with `QtQuick.Shapes`.

## Transferring

The tail is its own path. The q stays on the theme foreground and the tail takes the theme accent while anything is moving. Idle, both paths are the same dimmed color.

## Geometry

48 grid. Stroke 7. Bowl 26. Counter 12, a tile inside a tile. Channel between the bottom bar and the stem is the open corner. Tail is 45 degrees, centered on the stem, overlapping it so there is no seam.

```
q    M 8 5 H 34 V 37 H 27 V 12 H 15 V 24 H 22 V 31 H 8 Z
tail M 22.5 34 L 30.5 42 L 38.5 34 Z
```
