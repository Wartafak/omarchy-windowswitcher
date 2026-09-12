// Switcher.qml — wartafak.taskswitcher (TasksWitcher) overlay
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
  property var rows: []
  // Resolved hyprctl addresses parallel to rows (matched by key).
  property var rowAddrs: []

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
      if (root.opened) root.activateIndex(root.selectedIndex)
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
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    // First Super+Tab only opens; repeats cycle, so a Super release
    // afterwards applies the highlight. Reset here so stale state from a
    // previous confirm can never leak into a fresh open. Cleared on close.
    root.confirmOnSuperRelease = false
    root.rebuildDisplay()
    root.opened = true
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
    return (t && t.workspace) ? String(t.workspace.name || "") : ""
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
    var out = []
    for (var i = 0; i < root.knownWindows.length; i++) {
      var t = root.knownWindows[i]
      if (!t || root.isSpecial(t)) continue
      if (q) {
        var hay = (root.appId(t) + " " + root.title(t)).toLowerCase()
        if (hay.indexOf(q) < 0) continue
      }
      out.push(t)
    }
    // Most recently focused first when unfiltered (active window on top).
    if (!q && ToplevelManager.activeToplevel) {
      var ai = out.indexOf(ToplevelManager.activeToplevel)
      if (ai > 0) {
        var act = out.splice(ai, 1)
        out = act.concat(out)
      }
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

  Component.onCompleted: root.syncWindows()

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
          for (var i = 0; i < root.rows.length; i++) {
            var t = root.rows[i]
            var cls = "", ttl = ""
            try {
              cls = String((t && t.appId) || "").trim()
              ttl = String((t && t.title) || "")
            } catch (e) { }
            var found = ""
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
                used[j] = true
                break
              }
            }
            addrs.push(found)
          }
          root.rowAddrs = addrs
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
    WlrLayershell.namespace: "wartafak-taskswitcher"
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
            if (event.modifiers & Qt.MetaModifier) {
              root.select((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
              event.accepted = true
            }
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
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
            // Plain open + release keeps the overlay open; release after
            // cycling applies the highlight. Esc/scrim dismisses.
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
