/*
    Goggles OS login screen (SDDM): the wallpaper under a green tint, a glass card with a
    visor line, clock, session picker and power buttons.
    Uses only QtQuick and the objects SDDM provides (sddm, userModel, sessionModel, config,
    keyboard), so it has no extra dependencies. If it ever fails to load, SDDM falls back to
    its built-in login screen.
    SPDX-License-Identifier: GPL-3.0-or-later
*/
import QtQuick 2.15

Rectangle {
    id: root

    readonly property real u: Math.max(12, Math.round(height / 60))
    readonly property color accent: "#3ddc84"
    readonly property color accent2: "#f1ff9c"
    readonly property color ink: "#e6f3ee"
    readonly property color muted: "#9fbfb4"
    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0
    property string message: ""

    color: "#05110f"

    function login() {
        root.message = "";
        sddm.login(userField.text, passField.text, root.sessionIndex);
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.message = "That didn't work. Check your password and try again.";
            passField.text = "";
            passField.forceActiveFocus();
        }
        function onLoginSucceeded() { root.message = "" }
    }

    // Session names, so the picker can show them
    Repeater {
        id: sessions
        model: sessionModel
        Item { property string title: model.name; visible: false }
    }
    function sessionName() {
        var it = sessions.count > 0 ? sessions.itemAt(Math.min(root.sessionIndex, sessions.count - 1)) : null;
        return it ? it.title : "Default session";
    }

    Image {
        anchors.fill: parent
        source: config.background ? config.background : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.10, 0.09, 0.30) }
            GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.10, 0.09, 0.78) }
        }
    }

    Image {
        source: config.logo ? config.logo : ""
        height: root.u * 3
        fillMode: Image.PreserveAspectFit
        horizontalAlignment: Image.AlignLeft
        anchors { top: parent.top; left: parent.left; margins: root.u * 2 }
    }

    // Clock
    Column {
        anchors { top: parent.top; right: parent.right; margins: root.u * 2 }
        spacing: root.u * 0.1
        Text {
            id: clock
            anchors.right: parent.right
            color: root.ink
            font.pixelSize: root.u * 3.4
            font.weight: Font.Light
        }
        Text {
            id: date
            anchors.right: parent.right
            color: root.muted
            font.pixelSize: root.u * 1.05
        }
        Timer {
            interval: 1000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: {
                var now = new Date();
                clock.text = Qt.formatTime(now, "hh:mm");
                date.text = Qt.formatDate(now, "dddd, d MMMM yyyy");
            }
        }
    }

    // Glass card
    Rectangle {
        id: card
        width: root.u * 26
        height: form.height + root.u * 4
        anchors.centerIn: parent
        radius: root.u * 1.3
        color: Qt.rgba(0.04, 0.13, 0.11, 0.78)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)

        Rectangle {   // visor line
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - parent.radius * 2
            height: 2
            radius: 1
            color: root.accent
        }

        Column {
            id: form
            width: parent.width - root.u * 4
            anchors.centerIn: parent
            spacing: root.u * 0.9

            Text {
                text: "Welcome back"
                color: root.ink
                font.pixelSize: root.u * 1.7
                font.weight: Font.DemiBold
            }
            Text {
                text: sddm.hostName ? sddm.hostName : ""
                color: root.muted
                font.pixelSize: root.u * 0.95
                visible: text !== ""
            }
            Item { width: 1; height: root.u * 0.2 }

            // User name
            Rectangle {
                width: parent.width; height: root.u * 2.8; radius: root.u * 0.6
                color: Qt.rgba(0, 0, 0, 0.35)
                border.width: 1
                border.color: userField.activeFocus ? root.accent : Qt.rgba(1, 1, 1, 0.12)
                TextInput {
                    id: userField
                    anchors.fill: parent
                    anchors.leftMargin: root.u * 0.9; anchors.rightMargin: root.u * 0.9
                    verticalAlignment: TextInput.AlignVCenter
                    text: userModel.lastUser
                    color: root.ink
                    selectionColor: root.accent
                    selectedTextColor: "#052012"
                    font.pixelSize: root.u * 1.1
                    clip: true
                    KeyNavigation.tab: passField
                    Keys.onReturnPressed: passField.forceActiveFocus()
                    Keys.onEnterPressed: passField.forceActiveFocus()
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "User name"; color: root.muted; opacity: 0.7
                        font.pixelSize: parent.font.pixelSize
                        visible: parent.text === ""
                    }
                }
            }

            // Password
            Rectangle {
                width: parent.width; height: root.u * 2.8; radius: root.u * 0.6
                color: Qt.rgba(0, 0, 0, 0.35)
                border.width: 1
                border.color: passField.activeFocus ? root.accent : Qt.rgba(1, 1, 1, 0.12)
                TextInput {
                    id: passField
                    anchors.fill: parent
                    anchors.leftMargin: root.u * 0.9; anchors.rightMargin: root.u * 0.9
                    verticalAlignment: TextInput.AlignVCenter
                    echoMode: TextInput.Password
                    color: root.ink
                    selectionColor: root.accent
                    selectedTextColor: "#052012"
                    font.pixelSize: root.u * 1.1
                    clip: true
                    focus: true
                    KeyNavigation.tab: loginButton
                    KeyNavigation.backtab: userField
                    Keys.onReturnPressed: root.login()
                    Keys.onEnterPressed: root.login()
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Password"; color: root.muted; opacity: 0.7
                        font.pixelSize: parent.font.pixelSize
                        visible: parent.text === ""
                    }
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.accent2
                font.pixelSize: root.u * 0.9
                text: root.message !== "" ? root.message : (keyboard.capsLock ? "Caps Lock is on" : "")
                visible: text !== ""
            }

            // Log in
            Rectangle {
                id: loginButton
                width: parent.width; height: root.u * 2.8; radius: root.u * 0.6
                activeFocusOnTab: true
                gradient: Gradient {
                    GradientStop { position: 0.0; color: loginArea.pressed ? "#2fb86c" : root.accent }
                    GradientStop { position: 1.0; color: loginArea.pressed ? "#2fb86c" : "#6fe9a0" }
                }
                border.width: activeFocus ? 2 : 0
                border.color: root.accent2
                Keys.onReturnPressed: root.login()
                Keys.onEnterPressed: root.login()
                Keys.onSpacePressed: root.login()
                KeyNavigation.tab: sessionButton
                KeyNavigation.backtab: passField
                Text {
                    anchors.centerIn: parent
                    text: "Log in"
                    color: "#052012"
                    font.pixelSize: root.u * 1.15
                    font.weight: Font.DemiBold
                }
                MouseArea { id: loginArea; anchors.fill: parent; onClicked: root.login() }
            }

            // Session picker: click to step through the installed sessions
            Rectangle {
                id: sessionButton
                width: parent.width; height: root.u * 2.2; radius: root.u * 0.6
                color: sessionArea.containsMouse || activeFocus ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
                border.width: 1
                border.color: activeFocus ? root.accent : Qt.rgba(1, 1, 1, 0.12)
                activeFocusOnTab: true
                visible: sessions.count > 0
                function next() { root.sessionIndex = (root.sessionIndex + 1) % Math.max(1, sessions.count) }
                Keys.onReturnPressed: next()
                Keys.onSpacePressed: next()
                KeyNavigation.backtab: loginButton
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: root.u * 0.9
                    width: parent.width - root.u * 1.8
                    elide: Text.ElideRight
                    text: "Session: " + root.sessionName() + (sessions.count > 1 ? "   ›" : "")
                    color: root.muted
                    font.pixelSize: root.u * 0.95
                }
                MouseArea { id: sessionArea; anchors.fill: parent; hoverEnabled: true; onClicked: sessionButton.next() }
            }
        }
    }

    // Power buttons
    Row {
        anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: root.u * 2 }
        spacing: root.u * 0.8
        Repeater {
            model: [
                { label: "Sleep", can: sddm.canSuspend, act: "suspend" },
                { label: "Restart", can: sddm.canReboot, act: "reboot" },
                { label: "Shut down", can: sddm.canPowerOff, act: "powerOff" }
            ]
            Rectangle {
                visible: modelData.can
                width: label.width + root.u * 2.2; height: root.u * 2.3; radius: height / 2
                color: area.containsMouse ? Qt.rgba(1, 1, 1, 0.14) : Qt.rgba(0.04, 0.13, 0.11, 0.6)
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.14)
                Text { id: label; anchors.centerIn: parent; text: modelData.label; color: root.ink; font.pixelSize: root.u * 0.95 }
                MouseArea {
                    id: area; anchors.fill: parent; hoverEnabled: true
                    onClicked: {
                        if (modelData.act === "suspend") sddm.suspend();
                        else if (modelData.act === "reboot") sddm.reboot();
                        else sddm.powerOff();
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        if (userField.text === "") userField.forceActiveFocus(); else passField.forceActiveFocus();
    }
}
