// Switcher.qml — wartafak.windowswitcher (WindowsWitcher) overlay
// Quickshell-native Super+Tab window switcher: real app icons, live list,
// in-process activation (no hyprctl). switcher.py stays as fallback.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string filterText: ""
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
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(550), panel.width - Style.gapsOut * 2)
  property int switcherIconPx: Style.font.iconLarge * 2
  property int rowHeight: Math.max(Style.space(50), root.switcherIconPx + Style.space(16), Style.font.body + Style.spacing.rowPaddingX * 2)

  readonly property var allToplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []

  function open(payloadJson) {
    var action = ""
    try { action = JSON.parse(payloadJson || "{}").action || "" } catch (e) { action = "" }
    if (action === "confirm") {
      // Fired by the Super-release binding. Only commits in transient
      // (Super+Tab) mode; a no-op when closed or in persistent picker
      // mode, so unrelated Super taps are harmless. Idempotent with the
      // in-overlay Super-release handler (second one no-ops).
      if (root.opened && root.confirmOnSuperRelease) root.activateIndex(root.selectedIndex)
      return
    }
    if (root.opened && (action === "cycle" || action === "cycleBack")) {
      // Highlight only — focusing while the overlay holds exclusivity
      // does not stick, so selection is applied on close (release/Enter).
      root.select(action === "cycleBack" ? -1 : 1)
      root.confirmOnSuperRelease = true
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    root.syncWindows()
    // Keep MRU tip in sync with the currently active window so a fresh
    // open always has index 0 = current, index 1 = last focused.
    root.touchMru(ToplevelManager.activeToplevel)
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.rebuildDisplay()
    root.opened = true
    if (action === "cycle" || action === "cycleBack") {
      // macOS-style transient mode: first Tab already moves off the
      // current window, and releasing Super commits the highlight.
      // Quick Super+Tab tap => index 1 => toggles to last focused.
      if (root.rows.length > 1) {
        root.selectedIndex = (action === "cycleBack") ? root.rows.length - 1 : 1
      } else {
        root.selectedIndex = 0
      }
      root.confirmOnSuperRelease = true
      if (displayModel.count > 0) {
        resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      }
    } else {
      // Persistent picker mode (toggle without Super): plain open +
      // release keeps the overlay open for typing/arrows/Enter.
      // A stale confirm flag must never leak into a fresh open.
      root.confirmOnSuperRelease = false
    }
    // Resolve addresses for focus; rows are ready now.
    clientsProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.filterText = ""
    root.confirmOnSuperRelease = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function ping() { return "ok" }

  function touchMru(t) {
    if (!t) return
    // Rebuild instead of mutating: QML var arrays don't notify on
    // in-place mutation, and a fresh array lets the old one get GC'd.
    // Bounded by live window count (plus a hard cap), dead entries are
    // dropped so closed windows are never retained.
    var next = [t]
    for (var i = 0; i < root.mruStack.length; i++) {
      var e = root.mruStack[i]
      if (e && e !== t) next.push(e)
    }
    // Prune dead toplevels (closed windows); cap length defensively.
    var live = root.allToplevels || []
    var pruned = []
    for (var k = 0; k < next.length && pruned.length < 64; k++) {
      var c = next[k]
      if (!c) continue
      try {
        if (live.indexOf(c) !== -1) pruned.push(c)
      } catch (err) { /* destroyed QObject: drop it */ }
    }
    root.mruStack = pruned
  }

  function syncWindows() {
    var live = root.allToplevels || []
    var next = []
    var i, j
    for (i = 0; i < root.knownWindows.length; i++) {
      for (j = 0; j < live.length; j++) {
        if (live[j] === root.knownWindows[i]) { next.push(root.knownWindows[i]); break }
      }
    }
    for (i = 0; i < live.length; i++) {
      if (live[i] && next.indexOf(live[i]) === -1) next.push(live[i])
    }
    root.knownWindows = next
    // Keep MRU in step: prune dead, append brand-new windows as least
    // recent (they have no focus history yet). Bounded by live count,
    // so it can't grow across the session; old arrays get GC'd on
    // reassignment.
    var mru = []
    for (i = 0; i < root.mruStack.length && mru.length < 64; i++) {
      var me = root.mruStack[i]
      if (!me) continue
      try {
        if (live.indexOf(me) !== -1) mru.push(me)
      } catch (err) { /* destroyed QObject: drop it */ }
    }
    for (i = 0; i < live.length && mru.length < 64; i++) {
      if (live[i] && mru.indexOf(live[i]) === -1) mru.push(live[i])
    }
    root.mruStack = mru
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
    var alias = {
      "ghostty": "com.mitchellh.ghostty",
      "vscode": "code",
      "code - oss": "code"
    }
    var names = alias[low] ? [alias[low], raw, low] : [raw, low]
    for (var i = 0; i < names.length; i++) {
      var p = Quickshell.iconPath(names[i], true)
      if (p && p.length > 0 && p.indexOf("application-x-executable") === -1) return p
    }
    return Quickshell.iconPath("application-x-executable", true) || ""
  }

  function rebuildDisplay() {
    var q = root.filterText.trim().toLowerCase()
    // MRU order when unfiltered (mruStack[0] = current/active), so
    // index 0 = current window, index 1 = last focused. Filtered
    // searches keep MRU order too.
    var ordered = []
    var i, t
    var useMru = root.mruStack && root.mruStack.length > 0
    var src = useMru ? root.mruStack : root.knownWindows
    for (i = 0; i < src.length; i++) {
      t = src[i]
      if (!t || root.isSpecial(t)) continue
      // Dedupe by object identity guard (QML var arrays hold refs).
      var dup = false
      for (var d = 0; d < ordered.length; d++) {
        if (ordered[d] === t) { dup = true; break }
      }
      if (!dup) ordered.push(t)
    }
    // Append any known window missing from MRU (shouldn't happen after
    // syncWindows, but guards a fresh session before first focus event).
    for (i = 0; i < root.knownWindows.length; i++) {
      t = root.knownWindows[i]
      if (!t || root.isSpecial(t)) continue
      var has = false
      for (var h = 0; h < ordered.length; h++) {
        if (ordered[h] === t) { has = true; break }
      }
      if (!has) ordered.push(t)
    }
    var out = []
    for (i = 0; i < ordered.length; i++) {
      t = ordered[i]
      if (q) {
        var hay = (root.appId(t) + " " + root.title(t)).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      out.push(t)
    }
    root.rows = out
    if (root.selectedIndex >= out.length) root.selectedIndex = Math.max(0, out.length - 1)
    if (root.selectedIndex < 0) root.selectedIndex = 0
    displayModel.clear()
    for (var k = 0; k < out.length; k++) {
      displayModel.append({
        label: root.appId(out[k]) || "window",
        detail: root.title(out[k]),
        ws: root.wsName(out[k]),
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
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(f) {
    root.filterText = f
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() { pointerGate.reset() }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.rows.length) return
    var t = root.rows[index]
    root.opened = false
    root.filterText = ""
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
          var used = {}
          var addrs = []
          var wsNames = []
          for (var i = 0; i < root.rows.length; i++) {
            var t = root.rows[i]
            var cls = "", ttl = ""
            try {
              cls = String((t && t.appId) || "").trim()
              ttl = String((t && t.title) || "")
            } catch (e) { }
            var found = ""
            var foundWs = ""
            // Pass 1: exact class+title+workspace; pass 2: class+title.
            for (var pass = 0; pass < 2 && !found; pass++) {
              for (var j = 0; j < clients.length; j++) {
                if (used[j]) continue
                var c = clients[j]
                var cc = String(c["class"] || "").trim()
                var ct = String(c.title || "")
                if (cc !== cls || ct !== ttl) continue
                if (pass === 0) {
                  var cws = ""
                  try { cws = String((c.workspace && c.workspace.name) || "") } catch (e) { cws = "" }
                  if (cws !== root.wsName(t)) continue
                }
                found = String(c.address || "")
                try { foundWs = String((c.workspace && (c.workspace.name || c.workspace.id)) || "") } catch (e) { foundWs = "" }
                used[j] = true
                break
              }
            }
            addrs.push(found)
            wsNames.push(foundWs)
          }
          root.rowAddrs = addrs
          root.rowWs = wsNames
          // Push authoritative workspace names into the visible rows.
          for (var k = 0; k < wsNames.length && k < displayModel.count; k++) {
            if (wsNames[k] && displayModel.get(k).ws !== wsNames[k]) {
              displayModel.set(k, { ws: wsNames[k] })
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
          var used = {}
          var scored = []
          for (var i = 0; i < live.length; i++) {
            var t = live[i]
            if (!t || root.isSpecial(t)) continue
            var cls = "", ttl = ""
            try {
              cls = String((t && t.appId) || "").trim()
              ttl = String((t && t.title) || "")
            } catch (e) { }
            var best = -1, bestId = 1e9
            for (var j = 0; j < clients.length; j++) {
              if (used[j]) continue
              var c = clients[j]
              if (String(c["class"] || "").trim() !== cls) continue
              if (String(c.title || "") !== ttl) continue
              var fid = Number(c.focusHistoryID)
              if (!(fid >= 0)) fid = 1e9
              if (fid < bestId) { bestId = fid; best = j }
            }
            if (best >= 0) { used[best] = true; scored.push([bestId, t]) }
            else scored.push([1e9, t])
          }
          scored.sort(function(a, b) { return a[0] - b[0] })
          var ordered = []
          for (var k = 0; k < scored.length && ordered.length < 64; k++) {
            if (scored[k][1]) ordered.push(scored[k][1])
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
            if (root.filterText) root.setFilter("")
            else root.close()
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
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Backspace && !root.filterText) {
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
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

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Type to search"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

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

              Rectangle {
                id: wsTag
                visible: row.ws.length > 0
                width: wsLabel.implicitWidth + Style.space(16)
                height: wsLabel.implicitHeight + Style.space(10)
                radius: height / 2
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                border.width: 1
                border.color: row.hasCursor ? root.selectedText : Util.alpha(root.foreground, 0.35)

                Text {
                  id: wsLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: row.ws
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.hasCursor ? 1 : 0.75
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
      }
    }
  }
}
