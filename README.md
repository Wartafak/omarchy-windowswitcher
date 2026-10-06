# WindowsWitcher — `wartafak.windowswitcher`

Show and navigate currently open windows. Yes, the pun is intended — wind's howling.

Window tracking approach inspired by
[rosakodu/omarchy-dock](https://github.com/rosakodu/omarchy-dock) (MIT).

## Two views, one purpose

- **Persistent (top bar):** `BarWidget.qml` — little icons for open windows. Click to focus, middle/right-click to close. No overlay, no layout disturbance.
- **On-demand (Super+Tab):** `Switcher.qml` overlay — native Quickshell picker with real app icons, live list via `ToplevelManager`, Tab/Shift+Tab + arrows + type-to-filter, Enter to focus. Summoned with `omarchy-shell shell toggle wartafak.windowswitcher`.

## Behavior (bar)

- Lives in the top bar left section, after workspaces:
  `omarchy.menu, omarchy.workspaces, wartafak.windowswitcher`
- One icon per normal window (special workspaces excluded)
- Active window highlighted with `Color.accent`, others get a small dot
- Left-click focuses, middle/right-click closes, hover shows title tooltip
- Hidden when no windows (`visible: false`, zero width)
- `showAllWorkspaces: true` by default (Windows-like); set false in the
  layout entry to show only the focused workspace:
  `{ "id": "wartafak.windowswitcher", "showAllWorkspaces": false }`

## Commands

```bash
omarchy plugin validate ~/.config/omarchy/plugins/wartafak.windowswitcher
omarchy bar put wartafak.windowswitcher --section left --after omarchy.workspaces
```

Super+Tab binding (`~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + TAB", "All windows", "omarchy-shell shell summon wartafak.windowswitcher '{\"action\": \"cycle\"}'")
o.bind("SUPER + SHIFT + TAB", "Previous window", "omarchy-shell shell summon wartafak.windowswitcher '{\"action\": \"cycleBack\"}'")
o.bind("SUPER + SUPER_L", "Confirm window", "omarchy-shell shell summon wartafak.windowswitcher '{\"action\": \"confirm\"}'", { release = true })
o.bind("SUPER + SUPER_R", "Confirm window", "omarchy-shell shell summon wartafak.windowswitcher '{\"action\": \"confirm\"}'", { release = true })
```

macOS-style: first `Super+Tab` already highlights the last focused window
(MRU order, seeded from Hyprland's `focusHistoryID`), repeats cycle while
`Super` is held, releasing `Super` focuses the highlight via the `confirm`
release binding (the overlay's own `Super`-release handler is a fallback).
Quick `Super+Tab` tap toggles between current and last window. `Esc` closes,
`Enter`/click focuses. After editing QML or bindings, reload with
`hyprctl reload` + `omarchy-restart-shell` — the running shell does not pick
up plugin changes on its own.

`Super+Up/Down` is context-aware: while the switcher is open it moves the
selection (`cycleBack`/`cycle`), otherwise it keeps Hyprland's directional
window focus. This is a small router in `bindings.lua` that asks the
switcher via `omarchy-shell shell call wartafak.windowswitcher isOpen`.

## Files

- `manifest.json` — id `wartafak.windowswitcher`, kinds `bar-widget` + `overlay`
- `BarWidget.qml` — icon strip (BarWidget base, RowLayout + Repeater)
- `Switcher.qml` — Super+Tab overlay (PanelWindow, live ToplevelManager list)
- `SwitcherLogic.js` — pure decision logic (open dispatch, selection math,
  MRU ordering, hyprctl matching), shared by QML and the unit tests
- `tests/logic.test.js` — unit tests, no dependencies
- `tests/integration.sh` — live end-to-end test via shell IPC + hyprctl

## Testing

All switcher decisions live in `SwitcherLogic.js` as dependency-free
functions, imported by `Switcher.qml` (`import "SwitcherLogic.js" as Logic`)
and by Node directly — so the same code that runs in the shell runs under
test. QML keeps only thin adapters plus live-QObject field extraction
(which the library never touches, so closed windows can't leak into tests).

```bash
node --test tests/   # 36 unit tests, no runner to install
./tests/integration.sh  # live: needs the shell + >= 2 windows, net-zero focus change
```

The integration test drives the real overlay through
`omarchy-shell shell summon/call` and the `debugState` accessor, asserting
preselect (index 1), arming, focus switch, symmetric toggle-back and
multi-cycle advance.

## Notes

- Hot-reload prints 3 `Binding loop detected for property "windows"`
  warnings per save; steady-state is silent and the widget works
  (verified via screenshots). Cosmetic only, still to root-cause.
- `windows` is updated imperatively via `syncWindows()`/`refresh()`
  with no-change guards so focus switches don't churn the Repeater.
