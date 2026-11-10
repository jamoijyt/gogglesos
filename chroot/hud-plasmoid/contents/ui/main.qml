/*
    Goggles HUD: a desktop widget showing CPU, memory, GPU and network activity.
    This file only connects Plasma's system sensors to HudPanel.qml, which does the drawing.
    SPDX-License-Identifier: GPL-3.0-or-later
*/
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.sensors as Sensors

PlasmoidItem {
    id: root

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground
    preferredRepresentation: fullRepresentation

    // A sensor that isn't available (for example no GPU statistics) reports no number
    function num(sensor) {
        return typeof sensor.value === "number" ? sensor.value : NaN;
    }
    function firstNum(a, b) {
        var v = num(a);
        return v === v && v > 0 ? v : num(b);
    }

    Sensors.Sensor { id: cpuUsage; sensorId: "cpu/all/usage"; updateRateLimit: 1000 }
    Sensors.Sensor { id: cpuTemp; sensorId: "cpu/all/averageTemperature"; updateRateLimit: 2000 }
    Sensors.Sensor { id: memPercent; sensorId: "memory/physical/usedPercent"; updateRateLimit: 2000 }
    Sensors.Sensor { id: memUsed; sensorId: "memory/physical/used"; updateRateLimit: 2000 }
    Sensors.Sensor { id: memTotal; sensorId: "memory/physical/total"; updateRateLimit: 10000 }
    Sensors.Sensor { id: gpuUsage; sensorId: "gpu/all/usage"; updateRateLimit: 1000 }
    Sensors.Sensor { id: gpuVram; sensorId: "gpu/all/usedVram"; updateRateLimit: 2000 }
    Sensors.Sensor { id: gpuVramTotal; sensorId: "gpu/all/totalVram"; updateRateLimit: 10000 }
    Sensors.Sensor { id: gpuTemp0; sensorId: "gpu/gpu0/temperature"; updateRateLimit: 2000 }
    Sensors.Sensor { id: gpuTemp1; sensorId: "gpu/gpu1/temperature"; updateRateLimit: 2000 }
    Sensors.Sensor { id: netDown; sensorId: "network/all/download"; updateRateLimit: 1000 }
    Sensors.Sensor { id: netUp; sensorId: "network/all/upload"; updateRateLimit: 1000 }

    fullRepresentation: HudPanel {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        Layout.preferredWidth: Kirigami.Units.gridUnit * 38
        Layout.preferredHeight: Kirigami.Units.gridUnit * 13

        accent: Kirigami.Theme.highlightColor
        cpu: root.num(cpuUsage)
        cpuTemp: root.num(cpuTemp)
        mem: root.num(memPercent)
        memUsed: root.num(memUsed)
        memTotal: root.num(memTotal)
        gpu: root.num(gpuUsage)
        gpuTemp: root.firstNum(gpuTemp0, gpuTemp1)
        vramUsed: root.num(gpuVram)
        vramTotal: root.num(gpuVramTotal)
        netDown: root.num(netDown)
        netUp: root.num(netUp)
    }
}
