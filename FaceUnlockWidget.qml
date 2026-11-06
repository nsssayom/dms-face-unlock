import QtQuick
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string helperPath: "/usr/lib/dms-face-unlock/faceunlock-helper"
    readonly property bool faceEnabled: pluginData.enabled === true
    readonly property int faceCount: pluginData.faceCount || 0

    function save(enabled, count) {
        if (!pluginService)
            return;
        if (pluginData.enabled !== enabled)
            pluginService.savePluginData(pluginId, "enabled", enabled);
        if (pluginData.faceCount !== count)
            pluginService.savePluginData(pluginId, "faceCount", count);
    }

    function refresh() {
        Proc.runCommand("faceUnlockWidget.status", ["pkexec", helperPath, "read", "status"], (stdout, exitCode) => {
            if (exitCode !== 0)
                return;
            try {
                const reply = JSON.parse(stdout);
                if (reply.ok)
                    save(reply.data.enabled, reply.data.models.length);
            } catch (e) {
                return;
            }
        }, 0);
    }

    ccWidgetIcon: faceEnabled ? "face" : "face_retouching_off"
    ccWidgetPrimaryText: "Face Unlock"
    ccWidgetSecondaryText: {
        if (!faceEnabled)
            return "Off";
        return faceCount === 1 ? "On · 1 sample" : `On · ${faceCount} samples`;
    }
    ccWidgetIsActive: faceEnabled

    onCcWidgetToggled: {
        const turnOn = !faceEnabled;
        Proc.runCommand("faceUnlockWidget.toggle", ["pkexec", helperPath, "manage", turnOn ? "enable" : "disable"], (stdout, exitCode) => {
            if (exitCode === 126 || exitCode === 127)
                return;
            if (exitCode !== 0)
                ToastService.showError("Face Unlock", "That change didn't work.");
            refresh();
        }, 0);
    }

    Component.onCompleted: refresh()

    horizontalBarPill: Component {
        DIcon {
            name: root.faceEnabled ? "face" : "face_retouching_off"
            color: root.faceEnabled ? Theme.primary : Theme.surfaceVariantText
            size: root.iconSize
        }
    }

    verticalBarPill: Component {
        DIcon {
            name: root.faceEnabled ? "face" : "face_retouching_off"
            color: root.faceEnabled ? Theme.primary : Theme.surfaceVariantText
            size: root.iconSize
        }
    }
}
