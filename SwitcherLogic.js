// SwitcherLogic.js — wartafak.windowswitcher shared decision logic.
//
// Pure functions only: no QML imports, no Quickshell APIs, no access to
// QML scope. Operates on plain data (strings, numbers, arrays) plus opaque
// window identities compared with === (real Toplevel QObjects from QML,
// stub ids/objects under test).
//
// Dual runtime: imported by Switcher.qml via `import "SwitcherLogic.js" as
// Logic`, and unit-tested under Node via require() (see tests/). Keep it
// dependency-free and side-effect-free.

// ---------------------------------------------------------------------------
// Action parsing / open() dispatch
// ---------------------------------------------------------------------------

function parseAction(payloadJson) {
  try {
    var action = JSON.parse(payloadJson || "{}").action || ""
    return String(action)
  } catch (e) {
    return ""
  }
}

function isCycleAction(action) {
  return action === "cycle" || action === "cycleBack"
}

// +1 forward (Tab), -1 backward (Shift+Tab).
function advanceDelta(action) {
  return action === "cycleBack" ? -1 : 1
}

// Super-release confirm is only meaningful in transient (Super+Tab) mode:
// the overlay must be open AND armed. Unrelated Super taps are harmless.
function confirmAllowed(opened, armed) {
  return !!opened && !!armed
}

// Fresh-open highlight: quick Super+Tab lands on the last focused window
// (index 1); Shift+Tab starts from the far end; single window stays at 0.
function freshIndex(action, rowCount) {
  if (rowCount <= 1) return 0
  if (action === "cycleBack") return rowCount - 1
  if (action === "cycle") return 1
  return 0
}

// ---------------------------------------------------------------------------
// Selection index math
// ---------------------------------------------------------------------------

// Advance with wrap-around. cursorActive=false means "no cursor yet": jump
// to the far end in the direction of travel. count===0 yields -1 (empty).
function stepIndex(current, delta, count, cursorActive) {
  if (count <= 0) return -1
  if (!cursorActive) return delta < 0 ? count - 1 : 0
  return (((current + delta) % count) + count) % count
}

function clampIndex(index, count) {
  if (count <= 0) return 0
  if (index >= count) return count - 1
  if (index < 0) return 0
  return index
}

function inRange(index, count) {
  return index >= 0 && index < count
}

// ---------------------------------------------------------------------------
// MRU stack (most-recently-focused first)
//
// Items are opaque identities (===). live is the current live set.
// Results are fresh arrays (old ones get GC'd); length is bounded by the
// live set size plus a hard cap, so closed windows are never retained.
// ---------------------------------------------------------------------------

var MRU_CAP = 64

function mruTouch(stack, item, live, cap) {
  if (!item) return stack.slice()
  // Fast path: already the head — skip rebuild + live scans on every
  // re-focus of the same window. Dead-entry pruning is mruSync's job
  // (runs on valuesChanged), so stragglers wait for the next sync.
  if (stack.length > 0 && stack[0] === item) {
    return stack.slice()
  }
  cap = cap || MRU_CAP
  var liveSet = null
  try {
    liveSet = new Set(live)
  } catch (err) {
    liveSet = null
  }
  function alive(c) {
    if (!c) return false
    try {
      return liveSet ? liveSet.has(c) : live.indexOf(c) !== -1
    } catch (err) {
      return false
    }
  }
  var out = [item].filter(alive)
  // `next` is implicit: item first, then stack order minus item.
  // Single pass, no intermediate `next` array.
  for (var i = 0; i < stack.length && out.length < cap; i++) {
    var e = stack[i]
    if (!e || e === item) continue
    if (alive(e)) out.push(e)
  }
  return out
}

// Prune dead entries, append brand-new windows as least recent.
function mruSync(stack, live, cap) {
  cap = cap || MRU_CAP
  var liveSet = null, seen = null
  try {
    liveSet = new Set(live)
    seen = new Set()
  } catch (err) {
    liveSet = null
    seen = null
  }
  function alive(e) {
    if (!e) return false
    try {
      return liveSet ? liveSet.has(e) : live.indexOf(e) !== -1
    } catch (err) {
      return false
    }
  }
  var out = []
  for (var i = 0; i < stack.length && out.length < cap; i++) {
    var e = stack[i]
    if (!e || !alive(e)) continue
    if (seen) {
      if (seen.has(e)) continue
      seen.add(e)
    } else if (out.indexOf(e) !== -1) continue
    out.push(e)
  }
  for (var j = 0; j < live.length && out.length < cap; j++) {
    var w = live[j]
    if (!w) continue
    if (seen) {
      if (seen.has(w)) continue
      seen.add(w)
    } else if (out.indexOf(w) !== -1) continue
    out.push(w)
  }
  return out
}

// Stable creation-order registry: keep survivors in order, append new.
function syncKnown(known, live) {
  var liveSet = null, seen = null
  try {
    liveSet = new Set(live)
    seen = new Set()
  } catch (err) {
    liveSet = null
    seen = null
  }
  var next = []
  for (var i = 0; i < known.length; i++) {
    var k = known[i]
    if (!k) continue
    var keep = false
    try {
      keep = liveSet ? liveSet.has(k) : live.indexOf(k) !== -1
    } catch (err) {
      keep = false
    }
    if (!keep) continue
    if (seen) {
      if (seen.has(k)) continue
      seen.add(k)
    } else if (next.indexOf(k) !== -1) continue
    next.push(k)
  }
  for (var j = 0; j < live.length; j++) {
    var w = live[j]
    if (!w) continue
    if (seen) {
      if (seen.has(w)) continue
      seen.add(w)
    } else if (next.indexOf(w) !== -1) continue
    next.push(w)
  }
  return next
}

// ---------------------------------------------------------------------------
// Row ordering + filtering
//
// skipFn(t) -> true when t must be excluded (QML passes isSpecial).
// hayFn(t) -> lowercase "appId title" haystack (QML extracts QObject
// fields so the library never touches live QObjects).
// ---------------------------------------------------------------------------

function orderRows(mruStack, knownWindows, skipFn) {
  var ordered = []
  var seen = null
  try {
    seen = new Set()
  } catch (e) {
    seen = null
  }
  var src = (mruStack && mruStack.length > 0) ? mruStack : knownWindows
  function pushUnique(t) {
    if (!t) return
    var skip = false
    try {
      skip = !!skipFn(t)
    } catch (e) {
      skip = true
    }
    if (skip) return
    if (seen) {
      if (seen.has(t)) return
      seen.add(t)
    } else {
      for (var d = 0; d < ordered.length; d++) {
        if (ordered[d] === t) return
      }
    }
    ordered.push(t)
  }
  for (var i = 0; i < src.length; i++) pushUnique(src[i])
  for (var k = 0; k < knownWindows.length; k++) pushUnique(knownWindows[k])
  return ordered
}

function filterRows(ordered, query, hayFn) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return ordered.slice()
  var out = []
  for (var i = 0; i < ordered.length; i++) {
    var hay = ""
    try {
      hay = String(hayFn(ordered[i]) || "")
    } catch (e) {
      hay = ""
    }
    if (hay.toLowerCase().indexOf(q) !== -1) out.push(ordered[i])
  }
  return out
}

// ---------------------------------------------------------------------------
// hyprctl client matching (plain-data in, plain-data out)
//
// clients: [{ cls, title, ws, wsLabel, address, fid }]
//   ws = workspace name (match key), wsLabel = name || id (display)
// rows:    [{ cls, ttl, ws }]
//
// matchRowAddrs: two passes (exact incl. workspace, then class+title).
// First unmatched client wins, so duplicates resolve deterministically.
// ---------------------------------------------------------------------------

function matchRowAddrs(rows, clients) {
  // Straight two-pass scan (exact incl. workspace, then class+title).
  // Rows are <= 64 and clients <= a few hundred, and this runs only on
  // hyprctl output -- a bucket index measured slower at these sizes
  // (build cost dominates), so the simple loop stays.
  // First unmatched client wins, so duplicates resolve deterministically.
  var used = {}
  var addrs = []
  var wsNames = []
  for (var i = 0; i < rows.length; i++) {
    var found = ""
    var foundWs = ""
    for (var pass = 0; pass < 2 && !found; pass++) {
      for (var j = 0; j < clients.length; j++) {
        if (used[j]) continue
        var c = clients[j]
        if (c.cls !== rows[i].cls || c.title !== rows[i].ttl) continue
        if (pass === 0 && c.ws !== rows[i].ws) continue
        found = c.address || ""
        foundWs = c.wsLabel || c.ws || ""
        used[j] = true
        break
      }
    }
    addrs.push(found)
    wsNames.push(foundWs)
  }
  return { addrs: addrs, wsNames: wsNames }
}

// Order live indices by focusHistoryID ascending (0 = most recent).
// liveKeys: [{ cls, ttl }]. Unmatched go last, order otherwise stable.
// Returns live indices (QML maps back to Toplevel objects).
function seedOrder(liveKeys, clients) {
  var used = {}
  var scored = []
  for (var i = 0; i < liveKeys.length; i++) {
    var best = -1
    var bestId = 1e9
    for (var j = 0; j < clients.length; j++) {
      if (used[j]) continue
      var c = clients[j]
      if (c.cls !== liveKeys[i].cls || c.title !== liveKeys[i].ttl) continue
      var fid = Number(c.fid)
      if (!(fid >= 0)) fid = 1e9
      if (fid < bestId) {
        bestId = fid
        best = j
      }
    }
    if (best >= 0) {
      used[best] = true
      scored.push({ fid: bestId, index: i })
    } else {
      scored.push({ fid: 1e9, index: i })
    }
  }
  scored.sort(function(a, b) { return a.fid - b.fid })
  var ordered = []
  for (var k = 0; k < scored.length; k++) ordered.push(scored[k].index)
  return ordered
}

// Node export (QML has no `module`, so this is skipped there).
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    MRU_CAP: MRU_CAP,
    parseAction: parseAction,
    isCycleAction: isCycleAction,
    advanceDelta: advanceDelta,
    confirmAllowed: confirmAllowed,
    freshIndex: freshIndex,
    stepIndex: stepIndex,
    clampIndex: clampIndex,
    inRange: inRange,
    mruTouch: mruTouch,
    mruSync: mruSync,
    syncKnown: syncKnown,
    orderRows: orderRows,
    filterRows: filterRows,
    matchRowAddrs: matchRowAddrs,
    seedOrder: seedOrder
  }
}
