#!/bin/bash
# Integration test for wartafak.windowswitcher — needs a live session
# (running omarchy-shell + Hyprland with >= 2 open windows).
# Run with:  ./tests/integration.sh
# Net focus change is zero (it toggles away and back).

set -u
ID="wartafak.windowswitcher"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

active_addr() { hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])'; }
active_title() { hyprctl activewindow -j | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])'; }
state() { omarchy-shell shell call "$ID" debugState '{}'; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin)["'"$1"'"])'; }

# 0. normalize: overlay closed
omarchy-shell shell hide "$ID" >/dev/null 2>&1
sleep 0.5
[ "$(state | field opened)" = "False" ] && ok "switcher starts closed" || { fail "switcher starts closed"; }

A_ADDR=$(active_addr)

# 1. fresh cycle opens transiently on the last focused window (index 1)
omarchy-shell shell summon "$ID" '{"action": "cycle"}' >/dev/null
sleep 1
S=$(state)
ROWS=$(echo "$S" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')
if [ "$ROWS" -lt 2 ]; then
  omarchy-shell shell hide "$ID" >/dev/null 2>&1
  echo "SKIP: need >= 2 open windows (have $ROWS)"
  exit 2
fi
ok "at least 2 windows ($ROWS)"
[ "$(echo "$S" | field opened)" = "True" ] && ok "cycle opens overlay" || fail "cycle opens overlay"
[ "$(echo "$S" | field selectedIndex)" = "1" ] && ok "preselects index 1" || fail "preselects index 1 (got $(echo "$S" | field selectedIndex))"
[ "$(echo "$S" | field confirmArmed)" = "True" ] && ok "confirm armed" || fail "confirm armed"
TARGET_TITLE=$(echo "$S" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][1].split(" | ", 1)[1][:30])')

# 2. confirm focuses the highlight (quick-switch)
omarchy-shell shell summon "$ID" '{"action": "confirm"}' >/dev/null
sleep 1
B_ADDR=$(active_addr)
[ "$B_ADDR" != "$A_ADDR" ] && ok "focus moved ($A_ADDR -> $B_ADDR)" || fail "focus moved"
case "$(active_title)" in
  "$TARGET_TITLE"*) ok "landed on preselected window" ;;
  *) fail "landed on preselected window (want '$TARGET_TITLE…', at '$(active_title | cut -c1-40)')" ;;
esac

# 3. toggle back (quick-switch is symmetric)
omarchy-shell shell summon "$ID" '{"action": "cycle"}' >/dev/null
sleep 1
omarchy-shell shell summon "$ID" '{"action": "confirm"}' >/dev/null
sleep 1
[ "$(active_addr)" = "$A_ADDR" ] && ok "toggles back to start" || fail "toggles back to start"

# 4. multi-cycle advances (hold-Super + repeated Tab); needs 3+ windows
if [ "$ROWS" -ge 3 ]; then
  omarchy-shell shell summon "$ID" '{"action": "cycle"}' >/dev/null
  sleep 0.6
  omarchy-shell shell summon "$ID" '{"action": "cycle"}' >/dev/null
  sleep 0.6
  [ "$(state | field selectedIndex)" = "2" ] && ok "second cycle advances to index 2" || fail "second cycle advances"
  omarchy-shell shell summon "$ID" '{"action": "confirm"}' >/dev/null
  sleep 1
  C_ADDR=$(active_addr)
  [ "$C_ADDR" != "$A_ADDR" ] && [ "$C_ADDR" != "$B_ADDR" ] && ok "lands on third window" || fail "lands on third window"
else
  echo "SKIP: multi-cycle needs >= 3 windows"
fi

# cleanup: back home, overlay closed
if [ "$(active_addr)" != "$A_ADDR" ]; then
  omarchy-shell shell summon "$ID" '{"action": "cycle"}' >/dev/null
  sleep 1
  omarchy-shell shell summon "$ID" '{"action": "confirm"}' >/dev/null
  sleep 1
fi
[ "$(active_addr)" = "$A_ADDR" ] && ok "back at start window" || fail "back at start window"
omarchy-shell shell hide "$ID" >/dev/null 2>&1
sleep 0.5
[ "$(state | field opened)" = "False" ] && ok "switcher closed at end" || fail "switcher closed at end"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
