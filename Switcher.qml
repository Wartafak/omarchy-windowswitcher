// Switcher.qml — wartafak.windowswitcher (WindowsWitcher) overlay
// Quickshell-native Super+Tab window switcher: real app icons, live list,
// in-process activation plus hyprctl address fallback.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "SwitcherLogic.js" as Logic

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property int selectedIndex: 0
  property bool cursorActive: true
  property bool confirmOnSuperRelease: false

  // Stable creation-order registry (same approach as BarWidget).
  property var knownWindows: []
  // MRU stack, most-recently-focused first. Updated on every
  // activeToplevel change so a quick Super+Tab tap can switch to the
  // last focused window without waiting for hyprctl.
  property var mruStack: []
  property var rows: []
  // Resolved hyprctl addresses parallel to rows (matched by key).
  property var rowAddrs: []
  // Workspace names parallel to rows (hyprctl is authoritative; QML names
  // may be empty).
  property var rowWs: []
  // Icon lookup cache keyed by lowercase appId: Quickshell.iconPath()
  // hits the icon theme per call, but icons never change per window, so
  // resolve once and reuse across rebuilds/keystrokes. Bounded by the
  // number of distinct apps (tiny); plain strings only, no Toplevel refs.
  property var iconCache: ({})
  // Display-name cache keyed by lowercase appId (same copy-on-write
  // pattern as iconCache). Names come from the .desktop file's `Name=`
  // via DesktopEntries — no alias table to go stale. When no entry
  // resolves the raw appId shows. Cleared when the desktop-entry store
  // changes so early misses upgrade once entries load.
  property var nameCache: ({})
  // Hoisted alias table (was allocated per iconFor call).
  readonly property var iconAliases: ({
    "ghostty": "com.mitchellh.ghostty",
    "vscode": "code",
    "code - oss": "code"
  })

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBackground, 0)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(550), panel.width - Style.gapsOut * 2)
  property int switcherIconPx: Style.font.iconLarge * 2
  property int rowHeight: Math.max(Style.space(50), root.switcherIconPx + Style.space(16), Style.font.body + Style.spacing.rowPaddingX * 2)

  readonly property var allToplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []

  function open(payloadJson) {
    var action = Logic.parseAction(payloadJson)
    if (action === "confirm") {
      // Fired by the Super-release binding. Only commits in transient
      // (Super+Tab) mode; a no-op when closed or in persistent picker
      // mode, so unrelated Super taps are harmless. Idempotent with the
      // in-overlay Super-release handler (second one no-ops).
      if (Logic.confirmAllowed(root.opened, root.confirmOnSuperRelease)) {
        root.activateIndex(root.selectedIndex)
      }
      return
    }
    if (root.opened && Logic.isCycleAction(action)) {
      // Highlight only — focusing while the overlay holds exclusivity
      // does not stick, so selection is applied on close (release/click).
      root.select(Logic.advanceDelta(action))
      root.confirmOnSuperRelease = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    root.syncWindows()
    // Keep MRU tip in sync with the currently active window so a fresh
    // open always has index 0 = current, index 1 = last focused.
    root.touchMru(ToplevelManager.activeToplevel)
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    root.opened = true
    if (Logic.isCycleAction(action)) {
      // macOS-style transient mode: first Tab already moves off the
      // current window, and releasing Super commits the highlight.
      // Quick Super+Tab tap => index 1 => toggles to last focused.
      root.selectedIndex = Logic.freshIndex(action, root.rows.length)
      root.confirmOnSuperRelease = true
      if (displayModel.count > 0) {
        resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      }
    } else {
      // Persistent picker mode (toggle without Super): plain open +
      // release keeps the overlay open for arrows/click.
      // A stale confirm flag must never leak into a fresh open.
      root.confirmOnSuperRelease = false
    }
    // Resolve addresses for focus; rows are ready now.
    clientsProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.confirmOnSuperRelease = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function ping() { return "ok" }

  // State query for the Hyprland arrow router (see bindings.lua):
  // "true" while the overlay is open, "false" otherwise. Reached via
  // `omarchy-shell shell call wartafak.windowswitcher isOpen '{}'`.
  function isOpen() { return root.opened ? "true" : "false" }

  // Read-only diagnostics: selection, arming flag, row order and MRU
  // order (appId/title, truncated). Reached via
  // `omarchy-shell shell call wartafak.windowswitcher debugState '{}'`.
  function debugState() {
    function short(t) {
      try {
        return (String((t && t.appId) || "?") + " | " + String((t && t.title) || "")).substring(0, 48)
      } catch (e) { return "?" }
    }
    var rows = [], mru = [], i
    for (i = 0; i < root.rows.length; i++) rows.push(short(root.rows[i]))
    for (i = 0; i < root.mruStack.length; i++) mru.push(short(root.mruStack[i]))
    var active = null
    try { active = short(ToplevelManager.activeToplevel) } catch (e) { }
    return JSON.stringify({
      opened: root.opened,
      selectedIndex: root.selectedIndex,
      confirmArmed: root.confirmOnSuperRelease,
      active: active,
      rows: rows,
      mru: mru
    })
  }

  function touchMru(t) {
    if (!t) return
    // Fast path: already the head — skip the Logic round-trip, prune and
    // array churn on every re-focus of the same window. Dead-entry pruning
    // is syncWindows()/mruSync's job (runs on valuesChanged).
    if (root.mruStack.length > 0 && root.mruStack[0] === t) return
    // Rebuilt (not mutated: QML var arrays don't notify on in-place
    // mutation), pruned and bounded via the shared logic library so old
    // arrays get GC'd and closed windows are never retained.
    root.mruStack = Logic.mruTouch(root.mruStack, t, root.allToplevels || [], 64)
  }

  function sameWindows(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return false
    }
    return true
  }

  function syncWindows() {
    var live = root.allToplevels || []
    var nextKnown = Logic.syncKnown(root.knownWindows, live)
    // Guard: var-array assignment always notifies, even for identical
    // content — skip it when nothing changed to avoid downstream churn.
    if (!root.sameWindows(root.knownWindows, nextKnown)) root.knownWindows = nextKnown
    // Keep MRU in step: prune dead, append brand-new windows as least
    // recent (they have no focus history yet). Bounded by live count,
    // so it can't grow across the session.
    var nextMru = Logic.mruSync(root.mruStack, live, 64)
    if (!root.sameWindows(root.mruStack, nextMru)) root.mruStack = nextMru
  }

  function isSpecial(t) {
    var ws = t && t.workspace
    var n = ws ? String(ws.name || "") : ""
    return n.indexOf("special:") === 0
  }

  function appId(t) { return String((t && t.appId) || "").trim() }
  function title(t) {
    var s = t ? String(t.title || "") : ""
    return s.length > 0 ? s : root.appId(t)
  }
  function wsName(t) {
    if (!t || !t.workspace) return ""
    try {
      var n = String(t.workspace.name || "")
      if (n.length > 0) return n
      // QML workspace names can come through empty; fall back to the id.
      var id = t.workspace.id
      return (id !== undefined && id !== null) ? String(id) : ""
    } catch (e) { return "" }
  }

  function iconFor(t) {
    var raw = root.appId(t)
    if (!raw) return Quickshell.iconPath("application-x-executable", true) || ""
    var low = raw.toLowerCase()
    var hit = root.iconCache[low]
    if (hit !== undefined) return hit
    function store(p) {
      // Copy-on-write: QML var objects don't notify on in-place
      // mutation, so reassign to persist (single notify per new app).
      var next = {}
      for (var k in root.iconCache) next[k] = root.iconCache[k]
      next[low] = p
      root.iconCache = next
      return p
    }
    // The .desktop entry's Icon= first: the appId is often reverse-DNS
    // (`dev.zed.Zed`) while Icon= is the theme name (`zed`). This is what
    // the app menu resolves, so we match it. Then the appId guesses.
    try {
      var de = DesktopEntries.heuristicLookup(raw)
      if (de && de.icon) {
        var dein = String(de.icon)
        if (dein.charAt(0) === "/") return store(Util.fileUrl(dein))
        var p0 = Quickshell.iconPath(dein, true)
        if (p0 && p0.length > 0 && p0.indexOf("application-x-executable") === -1) return store(p0)
      }
    } catch (e) {}
    var alias = root.iconAliases
    var names = alias[low] ? [alias[low], raw, low] : [raw, low]
    for (var i = 0; i < names.length; i++) {
      var p = Quickshell.iconPath(names[i], true)
      if (p && p.length > 0 && p.indexOf("application-x-executable") === -1) return store(p)
    }
    return store(Quickshell.iconPath("application-x-executable", true) || "")
  }

  function appDisplayName(t) {
    var raw = root.appId(t)
    if (!raw) return ""
    var low = raw.toLowerCase()
    var hit = root.nameCache[low]
    if (hit !== undefined) return hit
    var nice = ""
    try {
      var de = DesktopEntries.heuristicLookup(raw)
      if (de && de.name) nice = String(de.name)
    } catch (e) { nice = "" }
    if (!nice) nice = raw
    // Copy-on-write: QML var objects don't notify on in-place mutation.
    var next = {}
    for (var k in root.nameCache) next[k] = root.nameCache[k]
    next[low] = nice
    root.nameCache = next
    return nice
  }

  function rebuildDisplay() {
    // MRU order when unfiltered (mruStack[0] = current/active), so
    // index 0 = current window, index 1 = last focused. Ordering and
    // clamping live in the shared logic library (unit-tested); the
    // closures below are the only place that touches live QObjects.
    // Per-rebuild memo: appId/title/wsName extracted ONCE per window and
    // shared by the model rows below (previously each was recomputed
    // 2-3x per row per rebuild).
    var memo = null
    try { memo = new Map() } catch (e) { memo = null }
    function entry(t) {
      if (memo) {
        var hit = memo.get(t)
        if (hit !== undefined) return hit
      }
      var a = root.appId(t)
      var b = root.title(t)
      var w = root.wsName(t)
      // Human-friendly label: raw appIds are often reverse-DNS
      // (`dev.zed.Zed`). Resolved from the .desktop entry (`Zed`); the
      // raw appId shows when none resolves.
      var nice = root.appDisplayName(t)
      var e2 = { app: a, nice: nice, ttl: b, ws: w }
      if (memo) memo.set(t, e2)
      return e2
    }
    function skipFn(t) { return root.isSpecial(t) }
    var out = Logic.orderRows(root.mruStack, root.knownWindows, skipFn)
    root.rows = out
    root.selectedIndex = Logic.clampIndex(root.selectedIndex, out.length)
    displayModel.clear()
    for (var k = 0; k < out.length; k++) {
      var e = entry(out[k])
      displayModel.append({
        label: e.nice || e.app || "window",
        detail: e.ttl,
        ws: e.ws,
        icon: root.iconFor(out[k])
      })
    }
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    var wasActive = root.cursorActive
    if (!wasActive) root.cursorActive = true
    root.selectedIndex = Logic.stepIndex(root.selectedIndex, delta, displayModel.count, wasActive)
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function disarmPointer() { pointerGate.reset() }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (!Logic.inRange(index, root.rows.length)) return
    var t = root.rows[index]
    root.opened = false
    root.confirmOnSuperRelease = false
    root.focusToplevel(t, index)
  }

  // Focus a row: close first (the overlay's exclusivity blocks focusing
  // while open), then activate in-process plus hyprctl by resolved address.
  // t.activate() is honored for real input (clicks); QML toplevels expose
  // no address, so addresses resolve via hyprctl (matched by class/title).
  function focusToplevel(t, index) {
    if (!t) return
    if (typeof t.activate === "function") t.activate()
    var addr = (index !== undefined && index !== null
      && index < root.rowAddrs.length) ? String(root.rowAddrs[index] || "") : ""
    if (addr && addr.indexOf("0x") === 0) {
      Quickshell.execDetached(["hyprctl", "eval",
        'hl.dispatch(hl.dsp.focus({window = "address:' + addr + '"}))'])
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() {
      root.syncWindows()
      if (root.opened) {
        root.rebuildDisplay()
        clientsProc.running = true
      }
    }
  }

  // Desktop-entry store (re)loaded: cached names may upgrade from
  // heuristic fallbacks to real .desktop names.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.nameCache = ({})
      if (root.opened) root.rebuildDisplay()
    }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() {
      root.touchMru(ToplevelManager.activeToplevel)
    }
  }

  Component.onCompleted: {
    root.syncWindows()
    root.touchMru(ToplevelManager.activeToplevel)
    // Seed MRU from Hyprland's focus history so the very first
    // quick-switch after a shell restart already targets the last
    // focused window (QML otherwise only learns recency incrementally).
    mruSeedProc.running = true
  }

  ListModel { id: displayModel }

  // hyprctl is the only source of window addresses; match clients to rows
  // by class/title (workspace only as tiebreak — QML workspace names may
  // be empty). First unmatched wins for duplicates.
  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var clients = JSON.parse(text)
          // Plain-data projections for the shared matcher (QObject
          // fields are read here, with guards, so the library — and
          // the unit tests — never touch live QObjects).
          var plainClients = []
          for (var c = 0; c < clients.length; c++) {
            var cc = clients[c]
            var ccWs = ""
            var ccWsLabel = ""
            try {
              ccWs = String((cc.workspace && cc.workspace.name) || "")
              ccWsLabel = String((cc.workspace && (cc.workspace.name || cc.workspace.id)) || "")
            } catch (e) { }
            plainClients.push({
              cls: String(cc["class"] || "").trim(),
              title: String(cc.title || ""),
              ws: ccWs,
              wsLabel: ccWsLabel,
              address: String(cc.address || "")
            })
          }
          var plainRows = []
          for (var i = 0; i < root.rows.length; i++) {
            var t = root.rows[i]
            var cls = "", ttl = ""
            try {
              cls = String((t && t.appId) || "").trim()
              ttl = String((t && t.title) || "")
            } catch (e) { }
            plainRows.push({ cls: cls, ttl: ttl, ws: root.wsName(t) })
          }
          var res = Logic.matchRowAddrs(plainRows, plainClients)
          root.rowAddrs = res.addrs
          root.rowWs = res.wsNames
          // Push authoritative workspace names into the visible rows.
          for (var k = 0; k < res.wsNames.length && k < displayModel.count; k++) {
            if (res.wsNames[k] && displayModel.get(k).ws !== res.wsNames[k]) {
              displayModel.set(k, { ws: res.wsNames[k] })
            }
          }
        } catch (e) { }
      }
    }
  }

  // One-shot at startup: seed mruStack from Hyprland's focusHistoryID
  // (0 = most recent). Matched by class/title like clientsProc; ambiguous
  // duplicates keep live order. Never runs while open, so it can't
  // reorder a switcher session in progress. Bounded + pruned like
  // touchMru, so closed windows are never retained.
  Process {
    id: mruSeedProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          if (root.opened) return
          var clients = JSON.parse(text)
          var live = root.allToplevels || []
          var liveKeys = []
          var liveObjs = []
          for (var i = 0; i < live.length; i++) {
            var t = live[i]
            if (!t || root.isSpecial(t)) continue
            var cls = "", ttl = ""
            try {
              cls = String((t && t.appId) || "").trim()
              ttl = String((t && t.title) || "")
            } catch (e) { }
            liveKeys.push({ cls: cls, ttl: ttl })
            liveObjs.push(t)
          }
          var plainClients = []
          for (var j = 0; j < clients.length; j++) {
            var cj = clients[j]
            plainClients.push({
              cls: String(cj["class"] || "").trim(),
              title: String(cj.title || ""),
              fid: cj.focusHistoryID
            })
          }
          var order = Logic.seedOrder(liveKeys, plainClients)
          var ordered = []
          for (var k = 0; k < order.length && ordered.length < 64; k++) {
            if (liveObjs[order[k]]) ordered.push(liveObjs[order[k]])
          }
          if (ordered.length > 0) root.mruStack = ordered
        } catch (e) { }
      }
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "wartafak-windowswitcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(contentCol.implicitHeight + root.contentMargin * 2, panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            // Only Super+Tab cycles (plain Tab is ignored); the Hypr
            // binding also summons a cycle, which the compositor consumes.
            // Either path arms Super-release confirm (macOS behaviour).
            if (event.modifiers & Qt.MetaModifier) {
              root.select((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
              root.confirmOnSuperRelease = true
              event.accepted = true
            }
          } else if (event.key === Qt.Key_Up) {
            // Arrow selection also arms Super-release confirm, same as
            // Tab: navigating then releasing Super focuses the highlight.
            root.select(-1)
            root.confirmOnSuperRelease = true
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            root.confirmOnSuperRelease = true
            event.accepted = true
          }
        }

        Keys.onReleased: function(event) {
          if (!root.opened) return
          if (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R
              || event.key === Qt.Key_Meta) {
            event.accepted = true
            // macOS-style: releasing Super always commits the highlight
            // in transient (Super+Tab) mode. Persistent picker mode
            // (toggle without Super) leaves confirm disarmed, so release
            // keeps the overlay open. Esc/scrim dismisses.
            if (root.confirmOnSuperRelease) root.activateIndex(root.selectedIndex)
          }
        }
      }

      Column {
        id: contentCol
        width: parent.width
        spacing: root.contentSpacing

        ListView {
          id: resultList
          width: parent.width
          height: Math.min(displayModel.count * (root.rowHeight + 4), Math.round(panel.height * 0.5))
          visible: displayModel.count > 0
          model: displayModel
          clip: true
          spacing: 4
          boundsBehavior: Flickable.StopAtBounds

          delegate: BorderSurface {
            id: row
            required property int index
            required property string label
            required property string detail
            required property string ws
            required property string icon

            readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex

            width: ListView.view.width
            height: root.rowHeight
            radius: root.cornerRadius
            color: row.hasCursor ? root.selectedBackground : "transparent"
            borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(10)

              Image {
                width: root.switcherIconPx
                height: root.switcherIconPx
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                cache: true
                source: row.icon
                sourceSize: Qt.size(192, 192)
              }

              Column {
                width: parent.width - root.switcherIconPx - parent.spacing * 2 - wsTag.width
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.detail
                  visible: row.detail.length > 0
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.hasCursor ? 0.85 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              // Subtle filled chip (no outline): quieter than the old
              // bordered pill, tints with the selection when focused.
              Rectangle {
                id: wsTag
                visible: row.ws.length > 0
                width: wsLabel.implicitWidth + Style.space(16)
                height: wsLabel.implicitHeight + Style.space(8)
                radius: height / 2
                anchors.verticalCenter: parent.verticalCenter
                color: row.hasCursor ? Util.alpha(root.selectedText, 0.22) : Util.alpha(root.foreground, 0.12)

                Text {
                  id: wsLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: row.ws
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.hasCursor ? 0.95 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.selectFromPointer(row.index, row, { x: mouseX, y: mouseY })
              onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
              onClicked: {
                root.cursorActive = true
                root.selectedIndex = row.index
                root.activateIndex(row.index)
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: displayModel.count === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No open windows"
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
        }

        // Shortcut hints: thin divider + dim centered hints (↑↓ are
        // plain-Unicode arrows — no icon font needed).
        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.foreground, 0.1)
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: "Tab: cycle"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            text: "·"
            color: root.foreground
            opacity: 0.3
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            text: "↑↓: navigate"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            text: "·"
            color: root.foreground
            opacity: 0.3
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Text {
            textFormat: Text.PlainText
            text: "Release Super: select"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
