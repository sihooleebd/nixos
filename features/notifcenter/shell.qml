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
    onPanelOpenChanged: if (panelOpen) { run("panelbus open notif"); pWeather.running = true; }

    // --- design tokens (monochrome, live accent) ---
    readonly property string ff: "DepartureMono Nerd Font"
    property string accent: "#ffffff"              // read from the theme below
    readonly property string fg: accent
    readonly property string dim: "#80ffffff"      // 50% accent
    readonly property string bgPanel: "#e6000000"  // ~90% black: the compositor blur layer-rule frosts
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

    // ----- weather (runs HAKU_WEATHER_CMD -> linecast --json; see features/notifcenter/home.nix) -----
    property var wx: null
    function wxDay(d) { return Qt.formatDate(new Date(d), "ddd"); }
    Process {
        id: pWeather
        command: ["sh","-c","$HAKU_WEATHER_CMD 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: { try { var o = JSON.parse(text); if (o && o.current) root.wx = o; } catch (e) {} } }
    }
    Timer { running: true; interval: 1200000; repeat: true; triggeredOnStart: true; onTriggered: pWeather.running = true }  // every 20 min

    // Fire-and-forget launcher. MUST be Quickshell.execDetached, NOT a tracked Process: a tracked
    // Process reaps its child's whole process group when the object exits or is reused for the next
    // command, which KILLS any daemon the command started. That is exactly why NIGHT was dead while
    // every other tile worked -- hyprsunset is a long-lived daemon that has to survive, whereas
    // nmcli / powerprofilesctl / the file writes are one-shot and had already exited, so the reap
    // never touched them. (setsid -f alone did NOT save it here: reusing the single `runner` Process
    // across clicks tore the session down.) execDetached runs fully detached + untracked -> nothing
    // reaps it; setsid keeps it in its own session too. Verified: the command works under the service env.
    function run(cmd) { console.log("[notif] run:", cmd); Quickshell.execDetached(["setsid","-f","sh","-c", cmd + " ; true"]); refreshTimer.restart(); }

    // ----- Wi-Fi picker state (nmcli; Bluetooth uses the native Quickshell.Bluetooth service) -----
    property var    wifiNets: []     // [{ ssid, signal, security, active }]
    property bool   wifiBusy: false
    property string wifiSel:  ""     // ssid awaiting credentials (secured + not already saved)
    property bool   wifiSelEnt: false // the selected network is WPA-Enterprise (802.1X: needs an identity + EAP)
    Process {
        id: pScan
        command: ["sh","-c","nmcli -t -f ACTIVE,SSID,SIGNAL,SECURITY dev wifi list --rescan auto 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.parseWifi(text) }
    }
    function wifiScan() { root.wifiBusy = true; pScan.running = true; }
    function parseWifi(txt) {
        // nmcli -t is colon-separated with ':' inside a field escaped as '\:'. ACTIVE + SIGNAL +
        // SECURITY never contain ':', so take the ends and rejoin the middle as the SSID.
        var out = [], seen = {};
        var lines = txt.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]; if (!l) continue;
            var p = l.split(":"); if (p.length < 4) continue;
            var active   = p[0] === "yes";
            var security = p[p.length - 1];
            var signal   = parseInt(p[p.length - 2]) || 0;
            var ssid     = p.slice(1, p.length - 2).join(":").replace(/\\:/g, ":");
            if (!ssid) continue;
            out.push({ ssid: ssid, signal: signal, security: security, active: active, enterprise: security.indexOf("802.1X") >= 0 });
        }
        out.sort(function (a, b) { return b.signal - a.signal; });
        var dedup = [];
        for (var j = 0; j < out.length; j++) { if (seen[out[j].ssid]) continue; seen[out[j].ssid] = 1; dedup.push(out[j]); }
        root.wifiNets = dedup; root.wifiBusy = false;
    }
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }  // single-quote for sh -c
    function wifiConnect(ssid, pw) {
        var c = "nmcli dev wifi connect " + shq(ssid);
        if (pw && pw.length > 0) c += " password " + shq(pw);
        root.run(c); root.wifiSel = "";
    }
    // WPA-Enterprise (802.1X): `nmcli dev wifi connect` can't express EAP, so build the profile. PEAP +
    // MSCHAPv2 is the near-universal school/eduroam default (ksa.hs.kr included). delete-then-add keeps
    // re-entry idempotent; NM validates the server cert against the system CA bundle. identity is typed
    // by the user (e.g. a student id or email) -- never pre-filled.
    function wifiConnectEnterprise(ssid, identity, pw) {
        var q = shq(ssid);
        var cmd = "nmcli connection delete id " + q + " 2>/dev/null; " +
                  "nmcli connection add type wifi con-name " + q + " ssid " + q +
                  " wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2" +
                  " 802-1x.identity " + shq(identity) + " 802-1x.password " + shq(pw) +
                  " && nmcli connection up id " + q;
        root.run(cmd); root.wifiSel = "";
    }

    // ----- timer / stopwatch / pomodoro (notif panel tool) -----
    property string timerMode: "pomodoro"   // "stopwatch" | "timer" | "pomodoro"
    property bool   timerRunning: false
    property int    timerSecs: 25 * 60       // stopwatch: elapsed; timer/pomodoro: remaining
    property int    timerSetMin: 25          // configured work/timer length (flexible, +/- in the UI)
    readonly property int pomoBreakMin: 5
    property string pomoPhase: "work"        // pomodoro: "work" | "break"
    function fmtTime(s) {
        s = Math.max(0, Math.floor(s));
        var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
        var mm = (m < 10 ? "0" : "") + m, xx = (x < 10 ? "0" : "") + x;
        return h > 0 ? (h + ":" + mm + ":" + xx) : (mm + ":" + xx);
    }
    function timerReset() {
        root.timerRunning = false;
        if (root.timerMode === "stopwatch") root.timerSecs = 0;
        else { root.pomoPhase = "work"; root.timerSecs = root.timerSetMin * 60; }
    }
    function timerSetMode(m) { root.timerMode = m; root.timerReset(); }
    function timerStartPause() {
        if (!root.timerRunning && root.timerMode !== "stopwatch" && root.timerSecs <= 0) root.timerReset();
        root.timerRunning = !root.timerRunning;
    }
    function timerAdjust(d) {
        root.timerSetMin = Math.max(1, Math.min(180, root.timerSetMin + d));
        if (!root.timerRunning && root.timerMode !== "stopwatch")
            root.timerSecs = (root.timerMode === "pomodoro" && root.pomoPhase === "break" ? root.pomoBreakMin : root.timerSetMin) * 60;
    }
    // toast + a short chime. Both run even when the panel is closed (notify-send + pw-play are on the
    // service PATH; HAKU_ALERT_SOUND is set in features/notifcenter/home.nix). 2>/dev/null so a missing
    // audio sink never swallows the toast. (title/body are literals here, so plain quoting is safe.)
    function timerAlert(title, body) {
        root.run("notify-send -a 'Haku Timer' '" + title + "' '" + body + "' ; pw-play \"$HAKU_ALERT_SOUND\" 2>/dev/null");
    }
    Timer {
        id: timerTick; interval: 1000; repeat: true; running: root.timerRunning
        onTriggered: {
            if (root.timerMode === "stopwatch") { root.timerSecs++; return; }
            root.timerSecs--;
            if (root.timerSecs > 0) return;
            if (root.timerMode === "pomodoro") {
                if (root.pomoPhase === "work") { root.pomoPhase = "break"; root.timerSecs = root.pomoBreakMin * 60; root.timerAlert("Break time", "Rest for " + root.pomoBreakMin + " min"); }
                else { root.pomoPhase = "work"; root.timerSecs = root.timerSetMin * 60; root.timerAlert("Back to work", "Focus for " + root.timerSetMin + " min"); }
            } else {
                root.timerRunning = false; root.timerSecs = 0; root.timerAlert("Timer done", "Time is up");
            }
        }
    }
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
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.icon; visible: text.length > 0; font.family: root.ff; font.pixelSize: 20; color: tile.active ? root.invFg : root.fg }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: tile.label; font.family: root.ff; font.pixelSize: 11; color: tile.active ? root.invFg : root.dim; visible: text.length > 0 }
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tile.clicked() }
    }

    component SliderRow: RowLayout {
        id: sr
        property string icon: ""
        property real value: 0
        signal moved(real v)
        signal iconClicked()
        spacing: 12
        Text {
            text: sr.icon; font.family: root.ff; font.pixelSize: 20; color: root.fg; Layout.preferredWidth: 24; horizontalAlignment: Text.AlignHCenter
            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: sr.iconClicked() }
        }
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
        // Renamed OFF "haku-notifcenter" so the compositor keystone (features/hyprland/trapezoid.patch,
        // which matches that prefix) NO LONGER warps this layer: the LAYER keystone mis-renders at a
        // fractional monitor scale (0.8 here), compressing the panel into the right ~45% with a dead
        // transparent left gutter (the "vertical bar"). Flat, full-width panel instead. To bring the
        // trapezoid back, fix the layer path's scale handling in the patch, then restore this name.
        WlrLayershell.namespace: "haku-notifcenter"
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

                // weather (linecast --json: current + 5-day forecast)
                Rectangle {
                    visible: root.wx !== null
                    Layout.fillWidth: true; radius: 16; color: root.bgTile
                    implicitHeight: wxCol.implicitHeight + 24
                    ColumnLayout {
                        id: wxCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                        spacing: 8
                        RowLayout {   // location + AQI
                            Layout.fillWidth: true
                            Text { text: root.wx ? root.wx.location : ""; font.family: root.ff; font.pixelSize: 13; font.bold: true; color: root.fg; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: (root.wx && root.wx.aqi) ? ("AQI " + root.wx.aqi.us_aqi) : ""; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                        }
                        RowLayout {   // current: icon + temp + condition, H/L on the right
                            Layout.fillWidth: true; spacing: 12
                            Text { text: root.wx ? root.wx.current.icon : ""; font.family: root.ff; font.pixelSize: 36; color: root.fg }
                            ColumnLayout {
                                spacing: 0
                                Text { text: root.wx ? (Math.round(root.wx.current.temperature) + "°") : ""; font.family: root.ff; font.pixelSize: 28; color: root.fg }
                                Text { text: root.wx ? root.wx.current.condition : ""; font.family: root.ff; font.pixelSize: 12; color: root.dim }
                            }
                            Item { Layout.fillWidth: true }
                            ColumnLayout {
                                spacing: 0
                                Text { text: root.wx ? ("H " + Math.round(root.wx.today.high) + "°") : ""; font.family: root.ff; font.pixelSize: 13; color: root.fg; Layout.alignment: Qt.AlignRight }
                                Text { text: root.wx ? ("L " + Math.round(root.wx.today.low) + "°") : ""; font.family: root.ff; font.pixelSize: 13; color: root.dim; Layout.alignment: Qt.AlignRight }
                            }
                        }
                        Text {   // details
                            Layout.fillWidth: true; elide: Text.ElideRight
                            text: root.wx ? ("Feels " + Math.round(root.wx.current.feels_like) + "°   Humidity " + root.wx.current.humidity + "%   Wind " + Math.round(root.wx.current.wind_speed) + " km/h   Rain " + root.wx.today.precipitation_probability + "%") : ""
                            font.family: root.ff; font.pixelSize: 11; color: root.dim
                        }
                        RowLayout {   // 5-day forecast
                            Layout.fillWidth: true; spacing: 4
                            Repeater {
                                model: (root.wx && root.wx.daily) ? root.wx.daily.slice(0, 5) : []
                                delegate: ColumnLayout {
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: 1
                                    Text { text: root.wxDay(modelData.date); font.family: root.ff; font.pixelSize: 10; color: root.dim; Layout.alignment: Qt.AlignHCenter }
                                    Text { text: modelData.icon; font.family: root.ff; font.pixelSize: 17; color: root.fg; Layout.alignment: Qt.AlignHCenter }
                                    Text { text: Math.round(modelData.high) + "°"; font.family: root.ff; font.pixelSize: 11; color: root.fg; Layout.alignment: Qt.AlignHCenter }
                                    Text { text: Math.round(modelData.low) + "°"; font.family: root.ff; font.pixelSize: 10; color: root.dim; Layout.alignment: Qt.AlignHCenter }
                                }
                            }
                        }
                    }
                }

                // quick toggles
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3; rowSpacing: 12; columnSpacing: 12
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: root.wifiOn ? "󰤨" : "󰤭"; label: "Wi-Fi"; active: root.wifiOn
                           onClicked: { wifiMenu.open = !wifiMenu.open; if (wifiMenu.open) { btMenu.open = false; powerMenu.open = false; root.wifiScan(); } } }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰂯"; label: "Bluetooth"; active: Bluetooth.defaultAdapter ? Bluetooth.defaultAdapter.enabled : false
                           onClicked: { btMenu.open = !btMenu.open; if (btMenu.open) { wifiMenu.open = false; powerMenu.open = false; } } }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: root.dnd ? "󰂛" : "󰂚"; label: "DND"; active: root.dnd; onClicked: root.dnd = !root.dnd }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰒲"; label: "No Sleep"; active: root.nosleepOn
                           onClicked: root.run("f=$HOME/.local/state/haku_theme/idle_inhibit; mkdir -p \"$(dirname $f)\"; [ \"$(cat $f 2>/dev/null)\" = 1 ] && echo 0 > $f || echo 1 > $f") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰛨"; label: "Night"; active: root.nightOn; onClicked: root.run("$HOME/.local/bin/nightlight_toggle.sh") }
                    Tile { Layout.fillWidth: true; Layout.preferredHeight: 62; icon: "󰐥"; label: "Power"; active: powerMenu.open
                           onClicked: { powerMenu.open = !powerMenu.open; if (powerMenu.open) { wifiMenu.open = false; btMenu.open = false; } } }
                }

                // Wi-Fi picker (nmcli). Click the Wi-Fi tile to open; pick a network to connect
                // (saved/open connect straight away; a secured new one shows a password field).
                ColumnLayout {
                    id: wifiMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 8
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Text { text: "Wi-Fi"; font.family: root.ff; font.pixelSize: 14; color: root.fg; Layout.fillWidth: true }
                        Tile { implicitWidth: 58; implicitHeight: 30; label: root.wifiOn ? "On" : "Off"; active: root.wifiOn
                               onClicked: root.run("nmcli radio wifi " + (root.wifiOn ? "off" : "on")) }
                        Tile { implicitWidth: 40; implicitHeight: 30; icon: "󰑐"; onClicked: root.wifiScan() }
                    }
                    Repeater {
                        model: root.wifiNets
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8
                            color: wna.containsMouse ? root.bgTileHi : root.bgTile
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: modelData.signal > 66 ? "󰤨" : modelData.signal > 33 ? "󰤥" : "󰤟"; font.family: root.ff; font.pixelSize: 15; color: root.fg }
                                Text { text: modelData.ssid; font.family: root.ff; font.pixelSize: 12; color: root.fg; Layout.fillWidth: true; elide: Text.ElideRight }
                                Text { text: (modelData.security && modelData.security !== "") ? "󰌾" : ""; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                                Text { text: modelData.active ? "󰄬" : ""; font.family: root.ff; font.pixelSize: 13; color: root.accent }
                            }
                            MouseArea {
                                id: wna; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.active) return;
                                    if (modelData.security && modelData.security !== "") { root.wifiSel = modelData.ssid; root.wifiSelEnt = modelData.enterprise === true; }
                                    else root.wifiConnect(modelData.ssid, "");
                                }
                            }
                        }
                    }
                    Text { visible: root.wifiNets.length === 0; text: root.wifiBusy ? "Scanning…" : "No networks"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
                    ColumnLayout {   // credentials for a selected secured network (PSK: password; enterprise: identity + password)
                        visible: root.wifiSel !== ""
                        Layout.fillWidth: true; spacing: 6
                        onVisibleChanged: if (visible) { if (root.wifiSelEnt) idField.forceActiveFocus(); else pwField.forceActiveFocus(); }
                        Rectangle {   // identity / username (WPA-Enterprise 802.1X only)
                            visible: root.wifiSelEnt
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8; color: root.bgTile
                            onVisibleChanged: if (visible) idField.forceActiveFocus()
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: "󰀄"; font.family: root.ff; font.pixelSize: 13; color: root.dim }
                                TextInput {
                                    id: idField; Layout.fillWidth: true; clip: true
                                    enabled: root.wifiSel !== ""   // disabled while hidden -> can't hold focus or draw a caret
                                    color: root.fg; font.family: root.ff; font.pixelSize: 12; verticalAlignment: TextInput.AlignVCenter
                                    onAccepted: pwField.forceActiveFocus()
                                    Text { anchors.fill: parent; visible: !idField.text; verticalAlignment: Text.AlignVCenter
                                           text: "Username / identity"; color: root.dim; font: idField.font }
                                }
                            }
                        }
                        Rectangle {   // password (PSK key, or the 802.1X password)
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8; color: root.bgTile
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: "󰌾"; font.family: root.ff; font.pixelSize: 13; color: root.dim }
                                TextInput {
                                    id: pwField; Layout.fillWidth: true; clip: true
                                    enabled: root.wifiSel !== ""   // disabled while hidden -> can't hold focus or draw a caret
                                    color: root.fg; font.family: root.ff; font.pixelSize: 12
                                    echoMode: TextInput.Password; verticalAlignment: TextInput.AlignVCenter
                                    onAccepted: {
                                        if (root.wifiSelEnt) root.wifiConnectEnterprise(root.wifiSel, idField.text, text);
                                        else root.wifiConnect(root.wifiSel, text);
                                        text = "";
                                    }
                                    Text { anchors.fill: parent; visible: !pwField.text; verticalAlignment: Text.AlignVCenter
                                           text: "Password · " + root.wifiSel + "  ↵"; color: root.dim; font: pwField.font }
                                }
                            }
                        }
                    }
                }

                // Bluetooth picker (native Quickshell.Bluetooth). Click the Bluetooth tile to open.
                ColumnLayout {
                    id: btMenu; property bool open: false
                    visible: open; Layout.fillWidth: true; spacing: 8
                    property var adapter: Bluetooth.defaultAdapter
                    RowLayout {
                        Layout.fillWidth: true; spacing: 10
                        Text { text: "Bluetooth"; font.family: root.ff; font.pixelSize: 14; color: root.fg; Layout.fillWidth: true }
                        Tile { implicitWidth: 58; implicitHeight: 30; label: (btMenu.adapter && btMenu.adapter.enabled) ? "On" : "Off"; active: btMenu.adapter ? btMenu.adapter.enabled : false
                               onClicked: if (btMenu.adapter) btMenu.adapter.enabled = !btMenu.adapter.enabled }
                        Tile { implicitWidth: 40; implicitHeight: 30; icon: "󰑐"; active: btMenu.adapter ? btMenu.adapter.discovering : false
                               onClicked: if (btMenu.adapter) btMenu.adapter.discovering = !btMenu.adapter.discovering }
                    }
                    Repeater {
                        model: Bluetooth.devices
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 34; radius: 8
                            color: bda.containsMouse ? root.bgTileHi : root.bgTile
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 8
                                Text { text: modelData.connected ? "󰂱" : "󰂯"; font.family: root.ff; font.pixelSize: 15; color: modelData.connected ? root.accent : root.fg }
                                Text { text: (modelData.name && modelData.name !== "") ? modelData.name : modelData.address; font.family: root.ff; font.pixelSize: 12; color: root.fg; Layout.fillWidth: true; elide: Text.ElideRight }
                                Text { text: modelData.connected ? "Connected" : ((modelData.paired || modelData.bonded) ? "Paired" : ""); font.family: root.ff; font.pixelSize: 10; color: root.dim }
                            }
                            MouseArea {
                                id: bda; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (modelData.connected) modelData.disconnect(); else modelData.connect(); }
                            }
                        }
                    }
                    Text { visible: !btMenu.adapter || !btMenu.adapter.enabled; text: "Bluetooth is off"; font.family: root.ff; font.pixelSize: 11; color: root.dim }
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
                    onMoved: (v) => { if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) { Pipewire.defaultAudioSink.audio.volume = v; Pipewire.defaultAudioSink.audio.muted = false; } }
                    onIconClicked: { if (Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio) Pipewire.defaultAudioSink.audio.muted = !Pipewire.defaultAudioSink.audio.muted; }
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

                // timer / stopwatch / pomodoro -- in its own card (matches the music card), centered
                Rectangle {
                    Layout.fillWidth: true; radius: 16; color: root.bgTile
                    implicitHeight: timerCol.implicitHeight + 28
                    ColumnLayout {
                        id: timerCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                        spacing: 12
                        RowLayout {   // mode tabs (segmented)
                            Layout.fillWidth: true; spacing: 6
                            Tile { Layout.fillWidth: true; implicitHeight: 28; radius: 9; label: "Stopwatch"; active: root.timerMode === "stopwatch"; onClicked: root.timerSetMode("stopwatch") }
                            Tile { Layout.fillWidth: true; implicitHeight: 28; radius: 9; label: "Timer"; active: root.timerMode === "timer"; onClicked: root.timerSetMode("timer") }
                            Tile { Layout.fillWidth: true; implicitHeight: 28; radius: 9; label: "Pomodoro"; active: root.timerMode === "pomodoro"; onClicked: root.timerSetMode("pomodoro") }
                        }
                        Text {   // pomodoro phase
                            visible: root.timerMode === "pomodoro"
                            Layout.alignment: Qt.AlignHCenter
                            text: root.pomoPhase === "work" ? "WORK" : "BREAK"
                            font.family: root.ff; font.pixelSize: 11; font.letterSpacing: 2; color: root.dim
                        }
                        Text {   // big time
                            Layout.alignment: Qt.AlignHCenter
                            text: root.fmtTime(root.timerSecs)
                            font.family: root.ff; font.pixelSize: 42; color: root.timerRunning ? root.accent : root.fg
                        }
                        RowLayout {   // duration (timer/pomodoro only)
                            visible: root.timerMode !== "stopwatch"
                            Layout.alignment: Qt.AlignHCenter; spacing: 12
                            Tile { implicitWidth: 38; implicitHeight: 28; radius: 9; icon: "󰍴"; onClicked: root.timerAdjust(-5) }
                            Text { text: root.timerSetMin + " min"; font.family: root.ff; font.pixelSize: 12; color: root.dim; Layout.preferredWidth: 56; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                            Tile { implicitWidth: 38; implicitHeight: 28; radius: 9; icon: "󰐕"; onClicked: root.timerAdjust(5) }
                        }
                        RowLayout {   // start/pause + reset
                            Layout.fillWidth: true; spacing: 8
                            Tile { Layout.fillWidth: true; implicitHeight: 38; radius: 12; icon: root.timerRunning ? "󰏤" : "󰐊"; active: root.timerRunning; onClicked: root.timerStartPause() }
                            Tile { implicitWidth: 54; implicitHeight: 38; radius: 12; icon: "󰜉"; onClicked: root.timerReset() }
                        }
                    }
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
                        Rectangle {   // album-art thumbnail (note-icon placeholder when there's no art)
                            Layout.preferredWidth: 48; Layout.preferredHeight: 48
                            radius: 8; color: root.bgPanel; clip: true
                            Image {
                                id: artImg; anchors.fill: parent
                                source: (musicCard.player && musicCard.player.trackArtUrl) ? musicCard.player.trackArtUrl : ""
                                fillMode: Image.PreserveAspectCrop; sourceSize.width: 96; sourceSize.height: 96
                                asynchronous: true; cache: true; visible: status === Image.Ready
                            }
                            Text {
                                anchors.centerIn: parent; visible: artImg.status !== Image.Ready
                                text: "󰎆"; font.family: root.ff; font.pixelSize: 22; color: root.dim
                            }
                        }
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
