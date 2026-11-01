<div align="center">

# Smart Windows

**Windows-style window management for Omarchy, where nothing moves on its own.**
Everything floats, drag to an edge to snap, Super + A to arrange the screen when you ask.

</div>

Omarchy tiles every window. Smart Windows turns Hyprland into a floating desktop you
arrange yourself: a window moves only because you moved it, or because it is itself
opening or coming back.

## Why this one

- 🪟 **Aero Snap, done right.** Drop a window with the pointer on the top edge to
  maximize it, on a side for half the screen, in a corner for a quarter. Drag it
  away and it gets its old size back. A side fills what the windows already snapped on
  the other side leave free.
- 🧘 **Nothing arranges itself.** Opening, closing, minimizing or restoring a window
  never moves the others.
- ✨ **Super + A arranges the screen, once.** With
  [Island Arrange](https://github.com/hugorolimf/omarchy-island-arrange) you pick from
  models worked out for that screen and those windows, previewed on the screen itself.
  Without it, the suggested model is applied right away. Super + right click without
  dragging does the same.
- 🧠 **Apps come back as they were.** An app reopens at the size and place it had when
  closed, and a minimized window returns to the very same spot.
- 🪜 **A second window of an app** steps down and right instead of hiding the first.
- ↔️ **Super + Shift + arrows** trade places with the neighbouring window.
- 🖥️ **Windows move freely between monitors** by dragging them across.
- 🧲 **Works with [Glass Dock](https://github.com/hugorolimf/omarchy-dock)**: windows
  slide into it when minimized, stop above its line, and can be dragged onto a workspace
  tile. It also stops below [Island Notch](https://github.com/hugorolimf/omarchy-island-notch).

Version 1 arranged windows by itself (neighbours growing into a hole, new windows in
the largest free area). If you prefer that, it stays available at the
[`v1` tag](https://github.com/hugorolimf/omarchy-smart-windows/tree/v1).

## Install

```bash
git clone https://github.com/hugorolimf/omarchy-smart-windows
cd omarchy-smart-windows
./install.sh
```

Your `hyprland.lua` is not edited: the module goes to `~/.config/omarchy-smart-windows/`
and a one-line loader to Omarchy's toggles folder. To update, `git pull` and run
`./install.sh` again; your settings stay. For the picker, add Island Arrange:

```bash
omarchy plugin add https://github.com/hugorolimf/omarchy-island-arrange --enable
```

## Requirements

Omarchy with Hyprland's Lua config.

## Configuration

Open `~/.config/omarchy-smart-windows/windowing/settings.lua` and run `hyprctl reload`
after changing it.

| Setting | Default | What it does |
|---|---|---|
| `GAP` | `8` | Space in px between snapped windows and the screen border |
| `ZONE` | `36` | How close to a screen edge (px) the pointer must be to snap |
| `SHARED` | `4` | The same, on a border shared with another monitor |
| `CORNER` | `0.22` | Share of a side, next to a corner, that snaps a quarter |
| `MIN_W`, `MIN_H` | `160`, `100` | Smallest size a window is arranged to |
| `MINIMIZE_MS` | `230` | Length of the minimize slide, in ms |
| `LOG_MOVES` | `false` | Log every move to `~/.local/state/omarchy/windowing.log` |
| `KEYS.quit` | `SUPER + Q` | Close the window, and the app with its last window |
| `KEYS.minimize` | `SUPER + M` | Minimize the active window |
| `KEYS.arrange` | `SUPER + A` | Arrange the screen |
| `KEYS.arrange_click` | `true` | Super + right click without dragging arranges too |
| `KEYS.maximize` | `false` | A key for maximize / restore, e.g. `"SUPER + CTRL + M"` |
| `KEYS.swap` | `true` | Super + Shift + arrows trade places |
| `MONITOR_WORKSPACES` | `{}` | Pin workspaces to monitors, e.g. `{ ["DP-1"] = { 1, 5 }, ["eDP-1"] = { 6, 10 } }` |

Set a key to `false` to leave it alone. Super + W (close the window) stays Omarchy's.

### Files it keeps

In `~/.local/state/omarchy/`:

- `windowing-geometry`: the last size and place of each app, by window class.
- `windowing-minimized`: where minimized windows go back to.
- `windowing-layouts`: which arrangement you pick most, to suggest it.
- `windowing.log`: only with `LOG_MOVES = true`.
- `io.github.hugorolimf.dock/maximized` and `drag`: only if Glass Dock's state folder exists.

The models for the panel go to a private file in `$XDG_RUNTIME_DIR/island-arrange/`.

## Integration API

Global Lua functions anything can call with `hyprctl eval`. Addresses are written the
way Hyprland prints them (`0x55d0c3a1b2c0`).

| Function | Does |
|---|---|
| `windowing_raise(address)` | Focus a window and bring it above the others |
| `windowing_minimize(address)` | Minimize a window |
| `windowing_minimize_active()` | Minimize the active window |
| `windowing_restore(address)` | Bring a minimized window back to its spot |
| `windowing_maximize([address])` | Maximize or restore the given window, or the active one |
| `windowing_close()` | Close the active window |
| `windowing_close_app()` | Close the active window, and the app with its last window |
| `windowing_quit([class])` | Quit an app by window class, or the active window's app |
| `windowing_refit(monitor)` | Refit maximized windows on a monitor |
| `windowing_arrange()` | Arrange the screen, like Super + A |
| `windowing_fit(address)` | Bring a window back inside its screen |

## Remove

```bash
./uninstall.sh
```

## License

MIT © Hugo Rolim Filho
