# TasksWitcher — `wartafak.taskswitcher`

Show and navigate currently open windows. Yes, the pun is intended — toss a Window to your switcher.

Merged from `pedromota.taskbar` (persistent top-bar view) + `omarchy-windows` script (on-demand switcher).

Window tracking approach inspired by
[rosakodu/omarchy-dock](https://github.com/rosakodu/omarchy-dock) (MIT).

## Two views, one purpose

- **Persistent (top bar):** `BarWidget.qml` — little icons for open windows. Click to focus, middle/right-click to close. No overlay, no layout disturbance.
- **On-demand (Super+Tab):** `Switcher.qml` overlay — native Quickshell picker with real app icons, live list via `ToplevelManager`, Tab/Shift+Tab + arrows + type-to-filter, Enter to focus. Summoned with `omarchy-shell shell toggle wartafak.taskswitcher`.

## Behavior (bar)

- Lives in the top bar left section, after workspaces:
  `omarchy.menu, omarchy.workspaces, wartafak.taskswitcher`
- One icon per normal window (special workspaces excluded)
- Active window highlighted with `Color.accent`, others get a small dot
- Left-click focuses, middle/right-click closes, hover shows title tooltip
- Hidden when no windows (`visible: false`, zero width)
- `showAllWorkspaces: true` by default (Windows-like); set false in the
  layout entry to show only the focused workspace:
  `{ "id": "wartafak.taskswitcher", "showAllWorkspaces": false }`

## Commands

```bash
omarchy plugin validate ~/.config/omarchy/plugins/wartafak.taskswitcher
omarchy bar put wartafak.taskswitcher --section left --after omarchy.workspaces
```

Super+Tab binding (`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + TAB", "All windows", "omarchy-shell shell summon wartafak.taskswitcher '{\"action\": \"cycle\"}'")
o.bind("SUPER + SHIFT + TAB", "Previous window", "omarchy-shell shell summon wartafak.taskswitcher '{\"action\": \"cycleBack\"}'")
```

Repeats cycle while open (macOS-style); `Esc` closes, `Enter`/click focuses.

## Files

- `manifest.json` — id `wartafak.taskswitcher`, kinds `bar-widget` + `overlay`
- `BarWidget.qml` — icon strip (BarWidget base, RowLayout + Repeater)
- `Switcher.qml` — Super+Tab overlay (PanelWindow, live ToplevelManager list)

## Notes

- Hot-reload prints 3 `Binding loop detected for property "windows"`
  warnings per save; steady-state is silent and the widget works
  (verified via screenshots). Cosmetic only, still to root-cause.
- `windows` is updated imperatively via `syncWindows()`/`refresh()`
  with no-change guards so focus switches don't churn the Repeater.
