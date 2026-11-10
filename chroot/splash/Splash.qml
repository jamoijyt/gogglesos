/*
    Goggles OS startup splash: the logo over dark glass, two lenses that light up as the
    desktop loads, and a visor line that fills.
    Plain QtQuick only, so it can't fail on a missing module. Plasma sets `stage` (1 to 6).
    SPDX-License-Identifier: GPL-3.0-or-later
*/
import QtQuick 2.15

Rectangle {
    id: root

    property int stage: 0
    readonly property real u: Math.max(10, Math.round(Math.min(width, height) / 54))
    readonly property color accent: "#3ddc84"
    readonly property color accent2: "#f1ff9c"

    gradient: Gradient {
        GradientStop { position: 0.0; color: "#0d2e28" }
        GradientStop { position: 1.0; color: "#030d0b" }
    }

    onStageChanged: if (stage >= 1) content.opacity = 1

    Item {
        id: content
        anchors.fill: parent
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 500; easing.type: Easing.InOutQuad } }

        Image {
            id: logo
            source: "file:///usr/share/gogglesos/logo-dark.png"
            width: root.u * 26
            fillMode: Image.PreserveAspectFit
            smooth: true
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: -root.u * 4
        }

        // Two lenses: left lights at stage 2, right at stage 4
        Row {
            id: lenses
            spacing: root.u * 2.2
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: logo.bottom
            anchors.topMargin: root.u * 3

            Repeater {
                model: [2, 4]
                Rectangle {
                    id: lens
                    readonly property bool lit: root.stage >= modelData
                    width: root.u * 2.6
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: Math.max(2, root.u * 0.16)
                    border.color: lit ? root.accent : Qt.rgba(1, 1, 1, 0.28)
                    Behavior on border.color { ColorAnimation { duration: 400 } }

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * 0.56
                        height: width
                        radius: width / 2
                        opacity: lens.lit ? 1 : 0
                        scale: lens.lit ? 1 : 0.4
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: root.accent2 }
                            GradientStop { position: 1.0; color: root.accent }
                        }
                        Behavior on opacity { NumberAnimation { duration: 400 } }
                        Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }
                    }

                    // Unlit lenses breathe so the screen never looks frozen
                    SequentialAnimation on opacity {
                        running: !lens.lit
                        loops: Animation.Infinite
                        NumberAnimation { from: 1; to: 0.45; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.45; to: 1; duration: 900; easing.type: Easing.InOutSine }
                        onRunningChanged: if (!running) lens.opacity = 1
                    }
                }
            }
        }

        // Visor line: fills as the stages pass
        Rectangle {
            id: track
            width: root.u * 18
            height: Math.max(2, Math.round(root.u * 0.14))
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.12)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: lenses.bottom
            anchors.topMargin: root.u * 2.4

            Rectangle {
                height: parent.height
                radius: parent.radius
                color: root.accent
                width: parent.width * Math.min(Math.max(root.stage, 0), 6) / 6
                Behavior on width { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
            }
        }
    }
}
