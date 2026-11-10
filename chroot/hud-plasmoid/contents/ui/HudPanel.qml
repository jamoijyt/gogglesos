/*
    Goggles HUD layout: CPU, memory, GPU and network modules inside visor brackets.
    Takes plain numbers, so it can be tested without Plasma; main.qml feeds it from the
    system sensors. Values that aren't available yet are NaN.
    SPDX-License-Identifier: GPL-3.0-or-later
*/
import QtQuick 2.15

Item {
    id: hud

    // inputs (NaN = not available)
    property real cpu: NaN            // %
    property real cpuTemp: NaN        // °C
    property real mem: NaN            // %
    property real memUsed: NaN        // bytes
    property real memTotal: NaN       // bytes
    property real gpu: NaN            // %
    property real gpuTemp: NaN        // °C
    property real vramUsed: NaN       // bytes
    property real vramTotal: NaN      // bytes
    property real netDown: NaN        // bytes/s
    property real netUp: NaN          // bytes/s
    property color accent: "#3ddc84"
    property color accent2: "#f1ff9c"
    property color ink: "#e6f3ee"
    property bool backdrop: true      // dark glass behind the readouts

    readonly property bool wide: width >= height * 1.6
    readonly property real pad: Math.max(10, Math.min(width, height) * 0.06)
    property var hCpu: []
    property var hMem: []
    property var hGpu: []
    property var hDown: []
    property var hUp: []
    property real netPeak: 1024 * 100

    function ok(v) { return v === v && v !== undefined && v !== null }
    function pct(v) { return ok(v) ? Math.round(v) + "%" : "--" }
    function deg(v) { return ok(v) && v > 0 ? Math.round(v) + "°C" : "" }
    function gib(v) { return (v / 1073741824).toFixed(1) }
    function rate(v) {
        if (!ok(v)) return "--";
        if (v >= 1048576) return (v / 1048576).toFixed(v >= 10485760 ? 0 : 1) + "M";
        if (v >= 1024) return Math.round(v / 1024) + "K";
        return Math.round(v) + "B";
    }
    function push(list, v) {
        var out = list.slice(-59);
        out.push(ok(v) ? v : 0);
        return out;
    }

    Timer {
        interval: 1000; running: hud.visible; repeat: true; triggeredOnStart: true
        onTriggered: {
            hud.hCpu = hud.push(hud.hCpu, hud.cpu / 100);
            hud.hMem = hud.push(hud.hMem, hud.mem / 100);
            hud.hGpu = hud.push(hud.hGpu, hud.gpu / 100);
            var peak = 1024 * 100;
            var d = hud.hDown.slice(-59), up = hud.hUp.slice(-59);
            d.push(hud.ok(hud.netDown) ? hud.netDown : 0); up.push(hud.ok(hud.netUp) ? hud.netUp : 0);
            for (var i = 0; i < d.length; i++) peak = Math.max(peak, d[i], up[i]);
            hud.netPeak = peak; hud.hDown = d; hud.hUp = up;
        }
    }

    Rectangle {
        visible: hud.backdrop
        anchors.fill: parent
        radius: hud.pad * 0.9
        color: Qt.rgba(0.03, 0.09, 0.08, 0.5)
        border.width: 1
        border.color: Qt.rgba(hud.ink.r, hud.ink.g, hud.ink.b, 0.1)
    }
    // visor line across the top and bracket corners
    Rectangle {
        anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - hud.pad * 3.2; height: 2; radius: 1
        color: hud.accent; opacity: 0.9
    }
    Repeater {      // bracket corners along the bottom
        model: 2
        Item {
            readonly property bool atRight: index === 1
            x: atRight ? hud.width - width : 0
            y: hud.height - height
            width: hud.pad * 1.1; height: width
            Rectangle { color: hud.accent; height: 2; width: parent.width; y: parent.height - 2 }
            Rectangle { color: hud.accent; width: 2; height: parent.height; x: parent.atRight ? parent.width - 2 : 0 }
        }
    }
    Text {
        id: header
        x: hud.pad; y: hud.pad * 0.55
        text: "GOGGLES // SYSTEM"
        color: hud.ink; opacity: 0.6
        font.family: "monospace"; font.pixelSize: Math.max(9, hud.pad * 0.62); font.letterSpacing: 2
    }
    Rectangle {   // live dot
        width: Math.max(5, hud.pad * 0.36); height: width; radius: width / 2
        color: hud.accent
        anchors.verticalCenter: header.verticalCenter
        x: hud.width - hud.pad - width
        SequentialAnimation on opacity {
            loops: Animation.Infinite; running: hud.visible
            NumberAnimation { from: 1; to: 0.25; duration: 900 }
            NumberAnimation { from: 0.25; to: 1; duration: 900 }
        }
    }

    Grid {
        id: grid
        anchors.fill: parent
        anchors.margins: hud.pad
        anchors.topMargin: hud.pad * 1.9
        columns: hud.wide ? 4 : 2
        spacing: hud.pad * (hud.wide ? 1.5 : 0.9)
        readonly property real cellW: (width - spacing * (columns - 1)) / columns
        readonly property real cellH: (height - spacing * (4 / columns - 1)) / (4 / columns)

        HudGauge {
            width: grid.cellW; height: grid.cellH
            accent: hud.accent; accent2: hud.accent2; ink: hud.ink
            label: "CPU"; readout: hud.pct(hud.cpu); caption: hud.deg(hud.cpuTemp)
            fraction: hud.cpu / 100; history: hud.hCpu
        }
        HudGauge {
            width: grid.cellW; height: grid.cellH
            accent: hud.accent; accent2: hud.accent2; ink: hud.ink
            label: "RAM"; readout: hud.pct(hud.mem)
            caption: hud.ok(hud.memUsed) && hud.ok(hud.memTotal) ? hud.gib(hud.memUsed) + "/" + hud.gib(hud.memTotal) + "G" : ""
            fraction: hud.mem / 100; history: hud.hMem
        }
        HudGauge {
            width: grid.cellW; height: grid.cellH
            accent: hud.accent; accent2: hud.accent2; ink: hud.ink
            label: "GPU"; readout: hud.pct(hud.gpu)
            caption: (hud.ok(hud.vramUsed) && hud.vramUsed > 0 ? hud.gib(hud.vramUsed) + "G " : "") + hud.deg(hud.gpuTemp)
            fraction: hud.gpu / 100; history: hud.hGpu
        }
        HudGauge {
            width: grid.cellW; height: grid.cellH
            accent: hud.accent; accent2: hud.accent2; ink: hud.ink
            label: "NET"; readout: "↓" + hud.rate(hud.netDown); caption: "↑" + hud.rate(hud.netUp)
            fraction: hud.ok(hud.netDown) ? hud.netDown / hud.netPeak : NaN
            history: hud.hDown.map(function (v) { return v / hud.netPeak })
            history2: hud.hUp.map(function (v) { return v / hud.netPeak })
        }
    }
}
