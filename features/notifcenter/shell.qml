//@ pragma UseQApplication
// Haku notification centre (quickshell) -- replaces swaync. A SIZED layer (namespace
// "haku-notifcenter") that the compositor keystone warps into a dock-card trapezoid.
//
// DESIGN: matches the shell's monochrome vibe (features/hakuspace). Pure white-on-near-black;
// the accent is read live from ~/.local/state/haku_theme/colors.css (the same token the whole
// shell uses -- @accent_color, currently #ffffff). ACTIVE controls INVERT (accent bg, black text),
// exactly like the waybar workspace chips. Font: DepartureMono Nerd Font, like the rest of the shell.
//
// Widgets: wifi · BT · DND · nosleep · nightmode · battery-mode(eco/bal/perf) · power · volume ·
// brightness · music · notifications.
//
// IPC:  quickshell -c haku-notif ipc call panel toggle|show|hide
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Services.Notifications
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root

    property bool panelOpen: false
    property bool dnd: false
    property bool wifiOn: true
    property bool nightOn: false
    property bool nosleepOn: false
    property string powerProfile: "balanced"

    // Mutual exclusion via the panelbus (features/panelbus): opening THIS centre broadcasts, which
    // closes the dock + any pins. Only on open (closing shouldn't reopen anything). run() detaches it.
    onPanelOpenChanged: if (panelOpen) run("panelbus open notif")

    // --- design tokens (monochrome, live accent) ---
    readonly property string ff: "DepartureMono Nerd Font"
    property string accent: "#ffffff"              // read from the theme below
    readonly property string fg: accent
    readonly property string dim: "#80ffffff"      // 50% accent
    readonly property string bgPanel: "#a6000000"  // ~65% black: the compositor blur layer-rule frosts
                                                    // the desktop behind it (0.9 was too opaque to show)
    readonly property string bgTile: "#16ffffff"   // inactive tile: faint white wash
    readonly property string bgTileHi: "#24ffffff" // hover
    readonly property string invFg: "#000000"   // text/icon ON an active (accent) tile

    // ----- notification DAEMON -----
    NotificationServer {
        id: server
        keepOnReload: false
        bodySupported: true
        bodyMarkupSupported: true
        actionsSupported: true
        imageSupported: true
        onNotification: function (n) { n.tracked = true; if (!root.dnd) popups.add(n); }
    }

    PwObjectTracker { objects: [Pipewire.defaultAudioSink] }

    // ----- state refresh (script-driven toggles + the live theme accent) -----
    Process { id: pAccent; command: ["sh","-c","grep -oE '#[0-9a-fA-F]{6}' $HOME/.local/state/haku_theme/colors.css 2>/dev/null | head -1"]; running: true; stdout: StdioCollector { onStreamFinished: { var c = text.trim(); if (c.length === 7) root.accent = c; } } }
    Process { id: pWifi;  command: ["sh","-c","nmcli -t radio wifi 2>/dev/null"]; stdout: StdioCollector { onStreamFinished: root.wifiOn = text.trim() === "enabled" } }
    Process { id: pNight; command: ["sh","-c","pgrep -x hyprsunset >/dev/null || pgrep -x gammastep >/dev/null"]; onExited: (code) => root.nightOn = (code === 0) }
    Process { id: pSleep; command: ["sh","-c","[ \"$(cat $HOME/.local/state/haku_theme/idle_inhibit 2>/dev/null)\" = 1 ]"]; onExited: (code) => root.nosleepOn = (code === 0) }
    Process { id: pProf;  command: ["sh","-c","powerprofilesctl get 2>/dev/null"]; stdout: StdioCollector { onStreamFinished: root.powerProfile = text.trim() || "balanced" } }
    function refresh() { pAccent.running = true; pWifi.running = true; pNight.running = true; pSleep.running = true; pProf.running = true; }

    Process { id: runner }
    // setsid -f = fire-and-forget, exactly how waybar's on-click spawns (g_spawn_command_line_async):
    // quickshell's Process reaps its child's process group on exit, which kills any daemon the command
    // backgrounded (e.g. nightlight_toggle.sh's `hyprsunset &`) -> the gamma CTM reverts. Detaching
    // into a new session orphans that daemon to init so it survives, same as the waybar night button.
    function run(cmd) { runner.command = ["setsid","-f","sh","-c", cmd + " ; true"]; runner.running = true; refreshTimer.restart(); }
    Timer { id: refreshTimer; interval: 250; onTriggered: root.refresh() }
    Timer { running: root.panelOpen; interval: 3000; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    IpcHandler {
        target: "panel"
        function toggle(): void { root.panelOpen = !root.panelOpen; if (root.panelOpen) root.refresh(); }
        function show(): void { root.panelOpen = true; root.refresh(); }
        function hide(): void { root.panelOpen = false; }
    }

    // ======================= reusable widgets =======================
    // A toggle/action tile. active -> inverts to the accent (like the waybar chips).
    component Tile: Rectangle {
        id: tile
        property string icon: ""
        property string label: ""
        property bool active: false
        signal clicked()
        implicitWidth: 100
        implicitHeight: 62
        radius: 14
        color: active ? root.accent : (ma.containsMouse ? root.bgTileHi : root.bgTile)
        Behavior on color { ColorAnimation { duration: 120 } }
        Column {
            anchors.centerIn: parent; spacing: 3
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.icon; font.family: root.ff; font.pixelSize: 20; color: tile.active ? root.invFg : root.fg }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.label; font.family: root.ff; font.pixelSize: 11; color: tile.active ? root.invFg : root.dim; visible: text.length > 0 }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tile.clicked() }
    }

    component SliderRow: RowLayout {
        id: sr
        property string icon: ""
        property real value: 0
        signal moved(real v)
        spacing: 12
        Text { text: sr.icon; font.family: root.ff; font.pixelSize: 20; color: root.fg; Layout.preferredWidth: 24; horizontalAlignment: Text.AlignHCenter }
        Rectangle {
            Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
            height: 8; radius: 4; color: root.bgTile
            Rectangle { height: parent.height; radius: 4; color: root.accent; width: Math.max(0, Math.min(1, sr.value)) * parent.width }
            MouseArea {
                anchors.fill: parent; anchors.margins: -8   // fat hit target
                onPressed: (m) => sr.moved(Math.max(0, Math.min(1, m.x / width)))
                onPositionChanged: (m) => { if (pressed) sr.moved(Math.max(0, Math.min(1, m.x / width))); }
            }
        }
    }

    // ======================= transient popups =======================
    PanelWindow {
        id: popups
        property var list: []
        function add(n) { list = list.concat([n]); popTimer.restart(); }
        visible: list.length > 0
        WlrLayershell.namespace: "haku-notif-popup"
        WlrLayershell.layer: WlrLayer.Overlay
        anchors { top: true; right: true }
        margins { top: 12; right: 12 }
        exclusiveZone: 0
        implicitWidth: 400
        implicitHeight: Math.max(1, popCol.implicitHeight)
        color: "transparent"
        Timer { id: popTimer; interval: 5000; onTriggered: popups.list = [] }
        Column {
            id: popCol; width: parent.width; spacing: 8
            Repeater {
                model: popups.list
                delegate: Rectangle {
                    required property var modelData
                    width: popCol.width; radius: 16; color: root.bgPanel
                    implicitHeight: pc.implicitHeight + 24
                    Column {
                        id: pc; x: 16; y: 12; width: parent.width - 32; spacing: 3
                        Text { text: modelData.summary || modelData.appName || "Notification"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; width: parent.width }
                        Text { text: modelData.body || ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; wrapMode: Text.WordWrap; width: parent.width; visible: text.length > 0 }
                    }
                    MouseArea { anchors.fill: parent; onClicked: popups.list = [] }
                }
            }
        }
    }

    // ======================= the control panel =======================
    PanelWindow {
        id: panel
        visible: root.panelOpen
        WlrLayershell.namespace: "haku-notifcenter"   // keystone matches this -> trapezoid
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors { top: true; right: true }
        // top 48 (not 104): the layer sits BELOW the waybar's 56px exclusive zone already, so 56+48
        // = 104 = the sidedock card's DOCK_Y -> the panel aligns with the dock + fits (104+1198+48
        // bottom = 1350). margins include the waybar zone; the dock card's 104 is from the screen top.
        margins { top: 48; right: 40; bottom: 48 }
        exclusiveZone: 0
        implicitWidth: 800
        implicitHeight: 1198
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: 20
            color: root.bgPanel

            ColumnLayout {
                anchors { fill: parent; margins: 22 }
                spacing: 18

                // quick toggles
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3; rowSpacing: 12; columnSpacing: 12
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: root.wifiOn ? "󰤨" : "󰤭"; label: "Wi-Fi"; active: root.wifiOn; onClicked: root.run("nmcli radio wifi " + (root.wifiOn ? "off" : "on")) }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰂯"; label: "Bluetooth"; active: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.enabled : false
                           onClicked: { if (Bluetooth.defaultAdapter) Bluetooth.defaultAdapter.enabled = !Bluetooth.defaultAdapter.enabled; } }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: root.dnd ? "󰂛" : "󰂚"; label: "DND"; active: root.dnd; onClicked: root.dnd = !root.dnd }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰒲"; label: "No Sleep"; active: root.nosleepOn
                           onClicked: root.run("f=$HOME/.local/state/haku_theme/idle_inhibit; mkdir -p \"$(dirname $f)\"; [ \"$(cat $f 2>/dev/null)\" = 1 ] && echo 0 > $f || echo 1 > $f") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰛨"; label: "Night"; active: root.nightOn; onClicked: root.run("$HOME/.local/bin/nightlight_toggle.sh") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰐥"; label: "Power"; active: powerMenu.open; onClicked: powerMenu.open = !powerMenu.open }
                }

                RowLayout {
                    id: powerMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 12
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰌾"; label: "Lock"; onClicked: { root.run("$HOME/.local/bin/lock.sh"); powerMenu.open = false; } }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰗽"; label: "Exit"; onClicked: root.run("$HOME/.local/bin/exit.sh") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰜉"; label: "Reboot"; onClicked: root.run("systemctl reboot") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 48; icon: "󰐥"; label: "Off"; onClicked: root.run("systemctl poweroff") }
                }

                // battery mode
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 52; icon: "󰌪"; label: "Eco"; active: root.powerProfile === "power-saver"; onClicked: root.run("powerprofilesctl set power-saver") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 52; icon: "󰂏"; label: "Balanced"; active: root.powerProfile === "balanced"; onClicked: root.run("powerprofilesctl set balanced") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 52; icon: "󱐋"; label: "Perf"; active: root.powerProfile === "performance"; onClicked: root.run("powerprofilesctl set performance") }
                }

                // volume + brightness
                SliderRow {
                    Layout.fillWidth: true; Layout.preferredHeight: 24
                    icon: (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio && Pipewire.defaultAudioSink.audio.muted) ? "󰝟" : "󰕾"
                    value: (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) ? Pipewire.defaultAudioSink.audio.volume : 0
                    onMoved: (v) => { if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) Pipewire.defaultAudioSink.audio.volume = v; }
                }
                SliderRow {
                    id: brightRow
                    Layout.fillWidth: true; Layout.preferredHeight: 24
                    icon: "󰃟"
                    property real cur: 0.5
                    value: cur
                    onMoved: (v) => { cur = v; root.run("brightnessctl set " + Math.round(v*100) + "%"); }
                    Process { id: pBright; command: ["sh","-c","brightnessctl -m 2>/dev/null | cut -d, -f4 | tr -d %"]; stdout: StdioCollector { onStreamFinished: { var n = parseFloat(text.trim()); if (!isNaN(n)) brightRow.cur = n/100; } } }
                    Timer { running: root.panelOpen; interval: 3000; repeat: true; triggeredOnStart: true; onTriggered: pBright.running = true }
                }

                // music (mpris)
                Rectangle {
                    id: musicCard
                    Layout.fillWidth: true; radius: 16; color: root.bgTile
                    implicitHeight: 76
                    property var player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
                    visible: player !== null
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 12
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { text: musicCard.player ? (musicCard.player.trackTitle || "—") : "—"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; Layout.fillWidth: true }
                            Text { text: musicCard.player ? (musicCard.player.trackArtist || "") : ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                        }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: "󰒮"; onClicked: { if (musicCard.player && musicCard.player.canGoPrevious) musicCard.player.previous(); } }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: (musicCard.player && musicCard.player.isPlaying) ? "󰏤" : "󰐊"; onClicked: { if (musicCard.player && musicCard.player.canTogglePlaying) musicCard.player.togglePlaying(); } }
                        Tile { implicitWidth: 46; implicitHeight: 46; icon: "󰒭"; onClicked: { if (musicCard.player && musicCard.player.canGoNext) musicCard.player.next(); } }
                    }
                }

                // notifications header
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Notifications"; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 16; Layout.fillWidth: true }
                    Tile { implicitWidth: 86; implicitHeight: 34; icon: "󰎟"; label: "Clear"; onClicked: { for (var i = server.trackedNotifications.values.length - 1; i >= 0; i--) server.trackedNotifications.values[i].dismiss(); } }
                }

                // notifications list
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; spacing: 8
                    model: server.trackedNotifications
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width; radius: 14; color: root.bgTile
                        implicitHeight: nc.implicitHeight + 22
                        Column {
                            id: nc; x: 14; y: 11; width: parent.width - 28; spacing: 2
                            Text { text: modelData.summary || modelData.appName || ""; font.family: root.ff; color: root.fg; font.bold: true; font.pixelSize: 14; elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.body || ""; font.family: root.ff; color: root.dim; font.pixelSize: 12; wrapMode: Text.WordWrap; width: parent.width; visible: text.length > 0 }
                        }
                        MouseArea { anchors.fill: parent; onClicked: modelData.dismiss() }
                    }
                    Text { anchors.centerIn: parent; visible: parent.count === 0; text: "No notifications"; font.family: root.ff; color: root.dim; font.pixelSize: 13 }
                }
            }
        }
    }
}
