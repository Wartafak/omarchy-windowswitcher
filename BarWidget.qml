// BarWidget.qml — wartafak.windowswitcher (WindowsWitcher) v1.0.0
// Top-bar taskbar: little icons for open windows, no overlay, no layout disturbance.
// Window source + icon approach inspired by rosakodu/omarchy-dock (MIT):
// ToplevelManager.toplevels, toplevel.activate()/close(), Quickshell.iconPath lookup.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "wartafak.windowswitcher"

    // shell.json per-widget override: { "id": "wartafak.windowswitcher", "showAllWorkspaces": false }
    readonly property bool showAll: setting("showAllWorkspaces", true) !== false
    readonly property int iconPx: Math.max(14, Math.min(24, Math.round(barSize * 0.52)))

    readonly property var allToplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    readonly property var activeTop: ToplevelManager.activeToplevel
    readonly property var focusedWs: Hyprland.focusedWorkspace

    property var knownWindows: []
    // Plain snapshot, updated imperatively (a bound expression here
    // kept tripping QML's loop detector via the registry writes).
    property var windows: []
    property bool _refreshing: false
    onFocusedWsChanged: refresh()
    onShowAllChanged: refresh()
    property bool _ready: false
    // Deferred: Hyprland signals fire mid-cascade on every hot-reload;
    // syncing before the component settles trips the loop detector.
    Component.onCompleted: Qt.callLater(function() { root._ready = true; root.syncWindows() })

    function syncWindows() {
        if (!root._ready) return
        var live = root.allToplevels || []
        var next = []
        for (var i = 0; i < root.knownWindows.length; i++) {
            var k = root.knownWindows[i]
            for (var j = 0; j < live.length; j++) {
                if (live[j] === k) { next.push(k); break }
            }
        }
        for (var l = 0; l < live.length; l++) {
            if (live[l] && next.indexOf(live[l]) === -1) next.push(live[l])
        }
        var same = next.length === root.knownWindows.length
        if (same) {
            for (var m = 0; m < next.length; m++) {
                if (next[m] !== root.knownWindows[m]) { same = false; break }
            }
        }
        if (!same) {
            root.knownWindows = next
        }
        root.refresh()
    }

    function sameWindows(a, b) {
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) {
            if (a[i] !== b[i]) return false
        }
        return true
    }

    function refresh() {
        if (!root._ready || root._refreshing) return
        root._refreshing = true
        var out = []
        var src = root.knownWindows
        for (var i = 0; i < src.length; i++) {
            var t = src[i]
            if (!t || isSpecial(t) || !onFocusedWs(t)) continue
            out.push(t)
        }
        // Only assign on real membership change: a fresh array every
        // focus switch used to churn the Repeater + layout each time.
        if (!sameWindows(root.windows, out)) root.windows = out
        root._refreshing = false
    }

    function isSpecial(t) {
        var ws = t && t.workspace
        var n = ws ? String(ws.name || "") : ""
        return n.indexOf("special:") === 0
    }

    function onFocusedWs(t) {
        if (root.showAll) return true
        if (!t || !t.workspace || !root.focusedWs) return true
        var a = t.workspace.id, b = root.focusedWs.id
        if (a !== undefined && b !== undefined) return a === b
        return String(t.workspace.name || "") === String(root.focusedWs.name || "")
    }

    // (Removed bound `windows` expression: the registry writes kept
    // tripping QML's loop detector. See refresh() instead.)

    function appId(t) { return String((t && t.appId) || "").trim() }
    function title(t) {
        var s = t ? String(t.title || "") : ""
        return s.length > 0 ? s : appId(t)
    }
    function wsName(t) {
        return (t && t.workspace) ? String(t.workspace.name || "") : ""
    }
    function tooltip(t) {
        var ws = wsName(t)
        return ws.length > 0 ? ("[" + ws + "] " + title(t)) : title(t)
    }

    function iconFor(t) {
        var raw = appId(t)
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

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { root.syncWindows() }
    }
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { root.syncWindows() }
    }

    visible: !vertical && root.windows.length > 0
    implicitWidth: visible ? taskRow.implicitWidth + Style.space(4) : 0
    implicitHeight: barSize

    RowLayout {
        id: taskRow
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: root.windows
            delegate: Component {
                Item {
                    id: cell
                    required property var modelData
                    required property int index
                    property var win: modelData
                    property bool isActive: ToplevelManager.activeToplevel === win

                    implicitWidth: 26
                    implicitHeight: root.barSize

                    Rectangle {
                        anchors.centerIn: parent
                        width: 24
                        height: 24
                        radius: 6
                        color: cell.isActive
                            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.25)
                            : hover.containsMouse ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
                        border.width: cell.isActive ? 1 : 0
                        border.color: cell.isActive ? Color.accent : "transparent"

                        Image {
                            anchors.centerIn: parent
                            width: root.iconPx
                            height: root.iconPx
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            mipmap: true
                            cache: true
                            source: root.iconFor(cell.win)
                            sourceSize: Qt.size(96, 96)
                        }

                        // running dot for non-active windows
                        Rectangle {
                            visible: !cell.isActive
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 1
                            width: 3
                            height: 3
                            radius: 1.5
                            color: Color.muted
                            opacity: 0.8
                        }
                    }

                    MouseArea {
                        id: hover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: function(mouse) {
                            if (!cell.win) return
                            if (mouse.button === Qt.LeftButton) {
                                if (typeof cell.win.activate === "function") cell.win.activate()
                            } else {
                                if (typeof cell.win.close === "function") cell.win.close()
                            }
                        }
                        onEntered: if (root.bar) root.bar.showTooltip(cell, root.tooltip(cell.win))
                        onExited: if (root.bar) root.bar.hideTooltip(cell)
                    }
                }
            }
        }
    }
}
