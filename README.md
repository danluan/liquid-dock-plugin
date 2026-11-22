# Liquid Dock

A macOS Tahoe-style glass dock for omarchy-shell: intellihide, magnification, pinned and running apps.

Part of the [Liquid Glass theme for Omarchy](https://github.com/danluan/omarchy-liquid-glass-theme), but it can be used on its own.

## Install

```bash
omarchy plugin add https://github.com/danluan/liquid-dock-plugin.git
omarchy plugin enable danluan.dock
```

Plugins run as unsandboxed code inside omarchy-shell: review the code before enabling it.

## Window previews

Hovering an app with open windows shows live thumbnails of each window (Quickshell `ScreencopyView`). Click a thumbnail to bring that window forward; the × on a thumbnail closes that window.

## Settings

`~/.config/omarchy/danluan-dock.json` (saved by the dock, safe to edit by hand):

| key | default | |
| --- | --- | --- |
| `mode` | `"intellihide"` | or `"always"` |
| `pinned` | | desktop ids, in dock order |
| `material` | `"liquid"` | translucent glass over Hyprland's blur, or `"solid"` (opaque) |
| `showApps` | `true` | app-grid button |
| `showTrash` | `true` | trash button |
| `indicators` | `true` | running/focused dots under the icons |
| `reduceTransparency` | `false` | fully opaque surfaces |

Colors, radii, sizes and timings live in `DockTokens.qml`.

## License

MIT
