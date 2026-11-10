/*
    One Goggles HUD module: a ring gauge, a big readout, a caption and a history graph.
    Plain QtQuick. SPDX-License-Identifier: GPL-3.0-or-later
*/
import QtQuick 2.15

Item {
    id: gauge

    property string label: ""
    property string readout: "--"       // big text in the ring
    property string caption: ""         // small line under the label
    property real fraction: 0            // 0..1 for the ring; NaN hides the arc
    property var history: []             // primary series, values 0..1
    property var history2: []            // optional second series (drawn in accent2)
    property color accent: "#3ddc84"
    property color accent2: "#f1ff9c"
    property color ink: "#e6f3ee"
    readonly property real u: Math.max(8, Math.min(width / 9, height / 11))
    readonly property bool hot: fraction > 0.9

    onFractionChanged: ring.requestPaint()
    onHistoryChanged: graph.requestPaint()
    onHistory2Changed: graph.requestPaint()
    onAccentChanged: { ring.requestPaint(); graph.requestPaint() }
    onInkChanged: { ring.requestPaint(); graph.requestPaint() }

    Text {
        id: title
        text: gauge.label
        color: gauge.accent
        font.family: "monospace"
        font.pixelSize: gauge.u * 0.95
        font.letterSpacing: gauge.u * 0.18
        font.bold: true
        anchors.top: parent.top
        anchors.left: parent.left
    }
    Text {
        text: gauge.caption
        color: gauge.ink
        opacity: 0.7
        font.family: "monospace"
        font.pixelSize: gauge.u * 0.8
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        anchors.baseline: title.baseline
        anchors.right: parent.right
        anchors.left: title.right
        anchors.leftMargin: gauge.u * 0.5
    }

    Canvas {
        id: ring
        anchors.top: title.bottom
        anchors.topMargin: gauge.u * 0.5
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width, parent.height - gauge.u * 5.4)
        height: width
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var c = width / 2, r = c - gauge.u * 0.45, lw = Math.max(2, gauge.u * 0.42);
            var a0 = Math.PI * 0.75, sweep = Math.PI * 1.5;
            ctx.lineCap = "round";
            // track
            ctx.lineWidth = lw;
            ctx.strokeStyle = Qt.rgba(gauge.ink.r, gauge.ink.g, gauge.ink.b, 0.14);
            ctx.beginPath(); ctx.arc(c, c, r, a0, a0 + sweep); ctx.stroke();
            // tick marks
            ctx.lineWidth = 1;
            ctx.strokeStyle = Qt.rgba(gauge.ink.r, gauge.ink.g, gauge.ink.b, 0.35);
            for (var i = 0; i <= 10; i++) {
                var a = a0 + sweep * i / 10, r1 = r - lw * 1.1, r2 = r1 - (i % 5 === 0 ? lw * 1.1 : lw * 0.55);
                ctx.beginPath();
                ctx.moveTo(c + Math.cos(a) * r1, c + Math.sin(a) * r1);
                ctx.lineTo(c + Math.cos(a) * r2, c + Math.sin(a) * r2);
                ctx.stroke();
            }
            // value
            var f = gauge.fraction;
            if (f === f) {   // not NaN
                f = Math.max(0, Math.min(1, f));
                ctx.lineWidth = lw;
                ctx.strokeStyle = gauge.hot ? gauge.accent2 : gauge.accent;
                ctx.beginPath(); ctx.arc(c, c, r, a0, a0 + sweep * Math.max(f, 0.004)); ctx.stroke();
            }
        }
    }
    Text {
        anchors.centerIn: ring
        text: gauge.readout
        color: gauge.hot ? gauge.accent2 : gauge.ink
        font.family: "monospace"
        font.bold: true
        font.pixelSize: ring.width * (gauge.readout.length > 5 ? 0.15 : 0.22)
    }

    Canvas {
        id: graph
        anchors.top: ring.bottom
        anchors.topMargin: gauge.u * 0.3
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var w = width, h = height;
            ctx.lineWidth = 1;
            ctx.strokeStyle = Qt.rgba(gauge.ink.r, gauge.ink.g, gauge.ink.b, 0.16);
            ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke();
            ctx.beginPath(); ctx.moveTo(0, h * 0.5); ctx.lineTo(w, h * 0.5); ctx.stroke();
            function series(data, colour, fill) {
                var n = data.length;
                if (n < 2) return;
                var step = w / 59, x0 = w - (n - 1) * step;
                ctx.beginPath();
                for (var i = 0; i < n; i++) {
                    var y = h - 1 - Math.max(0, Math.min(1, data[i])) * (h - 3);
                    if (i === 0) ctx.moveTo(x0, y); else ctx.lineTo(x0 + i * step, y);
                }
                ctx.lineWidth = 1.5;
                ctx.strokeStyle = colour;
                ctx.stroke();
                if (fill) {
                    ctx.lineTo(w, h); ctx.lineTo(x0, h); ctx.closePath();
                    ctx.fillStyle = Qt.rgba(colour.r, colour.g, colour.b, 0.16);
                    ctx.fill();
                }
            }
            series(gauge.history, gauge.accent, true);
            series(gauge.history2, gauge.accent2, false);
        }
    }
}
