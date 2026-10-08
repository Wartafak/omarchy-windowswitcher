// BarWidget.qml — wartafak.windowswitcher (WindowsWitcher) v1.4.0
// Top-bar taskbar: little icons for open windows, no overlay, no layout disturbance.
// Window source + icon approach inspired by rosakodu/omarchy-dock (MIT):
// ToplevelManager.toplevels, toplevel.activate()/close(), Quickshell.iconPath lookup.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "SwitcherLogic.js" as Logic

BarWidget {
    id: root
    moduleName: "wartafak.windowswitcher"

    // shell.json per-widget override: { "id": "wartafak.windowswitcher", "showAllWorkspaces": false }
    readonly property bool showAll: setting("showAllWorkspaces", true) !== false
    // Sizes derive from barSize so nothing clips: 2px margin between the
    // bar edge and the highlight box, 2px padding between the box and
    // the icon. The icon-to-box gap stays constant at any bar height.
    readonly property int hiPx: Math.max(20, Math.min(28, barSize - 4))
    readonly property int iconPx: Math.max(16, Math.min(root.hiPx - 4, Math.round(barSize * 0.68)))

    readonly property var allToplevels: ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    readonly property var activeTop: ToplevelManager.activeToplevel
    readonly property var focusedWs: Hyprland.focusedWorkspace

    property var knownWindows: []
    // Plain snapshot, updated imperatively (a bound expression here
    // kept tripping QML's loop detector via the registry writes).
    property var windows: []
    property bool _refreshing: false
    // Authoritative workspace names keyed by live Toplevel object
    // (hyprctl is authoritative — QML workspace fields can come through
    // empty, which used to rank every icon last and leave creation
    // order). Rebuilt on every resolve; pruned to live windows on sync
    // so closed windows are never retained.
    property var authWs: null
    // Icon lookup cache keyed by lowercase appId (see Switcher.qml):
    // iconPath() hits the theme per call; icons never change per app.
    property var iconCache: ({})
    readonly property var iconAliases: ({
        "ghostty": "com.mitchellh.ghostty",
        "vscode": "code",
        "code - oss": "code"
    })
    onFocusedWsChanged: refresh()
    onShowAllChanged: refresh()
    property bool _ready: false
    // Deferred: Hyprland signals fire mid-cascade on every hot-reload;
    // syncing before the component settles trips the loop detector.
    Component.onCompleted: Qt.callLater(function() { root._ready = true; root.syncWindows() })

    function syncWindows() {
        if (!root._ready) return
        var live = root.allToplevels || []
        // Set-based membership: was O(known × live) nested loop plus
        // O(n) indexOf scans. Falls back to indexOf where Set is missing.
        var liveSet = null, seen = null
        try { liveSet = new Set(live); seen = new Set() } catch (e) { liveSet = null; seen = null }
        function isLive(k) {
            if (!k) return false
            try { return liveSet ? liveSet.has(k) : live.indexOf(k) !== -1 }
            catch (e) { return false }
        }
        function seenHas(x) {
            try { return seen ? seen.has(x) : false } catch (e) { return false }
        }
        function seenAdd(x) {
            try { if (seen) seen.add(x) } catch (e) {}
        }
        var next = []
        for (var i = 0; i < root.knownWindows.length; i++) {
            var k = root.knownWindows[i]
            if (!k || !isLive(k) || seenHas(k)) continue
            seenAdd(k)
            next.push(k)
        }
        for (var l = 0; l < live.length; l++) {
            if (!live[l] || seenHas(live[l])) continue
            seenAdd(live[l])
            next.push(live[l])
        }
        var same = next.length === root.knownWindows.length
        if (same) {
            for (var m = 0; m < next.length; m++) {
                if (next[m] !== root.knownWindows[m]) { same = false; break }
            }
        }
        if (!same) {
            root.knownWindows = next
            // Prune the authoritative map to survivors (never retain
            // closed windows); clientsProc re-resolves right after.
            if (root.authWs) {
                try {
                    var pruned = new Map()
                    for (var p = 0; p < next.length; p++) {
                        var pv = root.authWs.get(next[p])
                        if (pv) pruned.set(next[p], pv)
                    }
                    root.authWs = pruned
                } catch (e) { root.authWs = null }
            }
            clientsProc.running = true
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
        // Workspace-first order (ws 1, 2, ...), creation order within a
        // workspace. Plain projections for the shared sorter (QObject
        // fields are read here so the library never touches live QObjects).
        // The hyprctl-resolved name wins per entry (see authWs); the QML
        // id/name pair is the fallback until the first resolve lands.
        var entries = []
        var src = root.knownWindows
        for (var i = 0; i < src.length; i++) {
            var t = src[i]
            if (!t || isSpecial(t) || !onFocusedWs(t)) continue
            var wid = undefined
            try { wid = t.workspace ? t.workspace.id : undefined } catch (e) { wid = undefined }
            var picked = Logic.pickBarWs(authWsName(t), wid, wsName(t))
            entries.push({ t: t, wsId: picked.wsId, wsName: picked.wsName, pos: i })
        }
        var sorted = Logic.orderBarEntries(entries)
        var out = []
        for (var k = 0; k < sorted.length; k++) out.push(sorted[k].t)
        // Only assign on real membership change: a fresh array every
        // focus switch used to churn the Repeater + layout each time.
        // Order changes count: sameWindows is order-sensitive on purpose.
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
    // hyprctl-resolved workspace name for a window ("" when unresolved).
    function authWsName(t) {
        try {
            if (root.authWs) {
                var v = root.authWs.get(t)
                if (v && String(v).length > 0) return String(v)
            }
        } catch (e) {}
        return ""
    }
    function tooltip(t) {
        var ws = authWsName(t) || wsName(t)
        return ws.length > 0 ? ("[" + ws + "] " + title(t)) : title(t)
    }

    function iconFor(t) {
        var raw = appId(t)
        if (!raw) return Quickshell.iconPath("application-x-executable", true) || ""
        var low = raw.toLowerCase()
        var hit = root.iconCache[low]
        if (hit !== undefined) return hit
        function store(p) {
            var next = {}
            for (var k in root.iconCache) next[k] = root.iconCache[k]
            next[low] = p
            root.iconCache = next
            return p
        }
        // The .desktop entry's Icon= first: the appId is often reverse-DNS
        // (`dev.zed.Zed`) while Icon= is the theme name (`zed`). This is
        // what the app menu resolves, so we match it. Then the appId guesses.
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

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { root.syncWindows() }
    }
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { root.syncWindows() }
    }

    // hyprctl is the only reliable source of workspace names (QML fields
    // can come through empty); match clients to rows by class/title like
    // the switcher does, then re-sort by the authoritative names.
    Process {
        id: clientsProc
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var clients = JSON.parse(text)
                    var plainClients = []
                    for (var c = 0; c < clients.length; c++) {
                        var cc = clients[c]
                        var ccWs = "", ccWsLabel = ""
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
                    var rows = root.windows
                    var plainRows = []
                    for (var i = 0; i < rows.length; i++) {
                        var t = rows[i]
                        var cls = "", ttl = ""
                        try {
                            cls = String((t && t.appId) || "").trim()
                            ttl = String((t && t.title) || "")
                        } catch (e) { }
                        plainRows.push({ cls: cls, ttl: ttl, ws: root.wsName(t) })
                    }
                    var res = Logic.matchRowAddrs(plainRows, plainClients)
                    var m = null
                    try { m = new Map() } catch (e) { m = null }
                    if (!m) return
                    for (var k = 0; k < rows.length && k < res.wsNames.length; k++) {
                        if (res.wsNames[k]) m.set(rows[k], res.wsNames[k])
                    }
                    root.authWs = m
                    root.refresh()
                } catch (e) { }
            }
        }
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

                    implicitWidth: root.hiPx + 2
                    implicitHeight: root.barSize

                    Rectangle {
                        anchors.centerIn: parent
                        width: root.hiPx
                        height: root.hiPx
                        radius: 7
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
