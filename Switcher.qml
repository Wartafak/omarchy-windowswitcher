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
import "SwitcherLogic.js" as Logic

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
      // does not stick, so selection is applied on close (release/Enter).
      root.select(Logic.advanceDelta(action))
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
    // Rebuilt (not mutated: QML var arrays don't notify on in-place
    // mutation), pruned and bounded via the shared logic library so old
    // arrays get GC'd and closed windows are never retained.
    root.mruStack = Logic.mruTouch(root.mruStack, t, root.allToplevels || [], 64)
  }

  function syncWindows() {
    var live = root.allToplevels || []
    root.knownWindows = Logic.syncKnown(root.knownWindows, live)
    // Keep MRU in step: prune dead, append brand-new windows as least
    // recent (they have no focus history yet). Bounded by live count,
    // so it can't grow across the session.
    root.mruStack = Logic.mruSync(root.mruStack, live, 64)
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
    // searches keep MRU order too. Ordering/filtering/clamping live in
    // the shared logic library (unit-tested); the closures below are the
    // only place that touches live QObjects.
    function skipFn(t) { return root.isSpecial(t) }
    function hayFn(t) { return root.appId(t) + " " + root.title(t) }
    var ordered = Logic.orderRows(root.mruStack, root.knownWindows, skipFn)
    var out = Logic.filterRows(ordered, q, hayFn)
    root.rows = out
    root.selectedIndex = Logic.clampIndex(root.selectedIndex, out.length)
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
    var wasActive = root.cursorActive
    if (!wasActive) root.cursorActive = true
    root.selectedIndex = Logic.stepIndex(root.selectedIndex, delta, displayModel.count, wasActive)
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
    if (!Logic.inRange(index, root.rows.length)) return
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
