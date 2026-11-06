import QtQuick
import QtMultimedia
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "faceUnlock"

    readonly property string helperPath: "/usr/lib/dms-face-unlock/faceunlock-helper"
    readonly property string installCommand: "sudo make install-system"

    readonly property var strictnessLevels: [
        { label: "Relaxed", value: 0.62, hint: "Works in more lighting and angles, but is easier to fool" },
        { label: "Balanced", value: 0.6942, hint: "Howdy's default" },
        { label: "Strict", value: 0.74, hint: "Harder to fool, but may need extra samples" }
    ]

    // null until the first status arrives
    property var status: null
    property bool helperMissing: false
    property bool howdyMissing: false
    property string busyText: ""
    property string errorText: ""
    property var testResult: null
    property bool previewWanted: false
    property bool cameraReleased: true
    property bool needsShellRestart: false
    property int confirmRemoveId: -1
    property bool confirmClear: false
    property string newLabel: ""

    readonly property bool busy: busyText !== ""
    readonly property bool ready: status !== null
    readonly property var models: status ? status.models : []

    function run(id, args, callback) {
        Proc.runCommand("faceUnlock." + id, ["pkexec", helperPath].concat(args), (stdout, exitCode) => {
            let reply = null;
            try {
                reply = JSON.parse(stdout);
            } catch (e) {
                reply = null;
            }
            callback(reply, exitCode);
        }, 0, 180000);
    }

    function refresh() {
        Proc.runCommand("faceUnlock.probe", ["test", "-x", helperPath], (_, exitCode) => {
            helperMissing = exitCode !== 0;
            if (helperMissing)
                return;
            run("status", ["read", "status"], (reply, code) => {
                if (reply && reply.ok) {
                    status = reply.data;
                    howdyMissing = false;
                    publishSummary();
                } else {
                    howdyMissing = true;
                    errorText = reply && reply.error ? reply.error : "Could not read Face Unlock status.";
                }
            });
        }, 0);
    }

    // The Control Center tile reads this, so it never needs its own polling.
    function publishSummary() {
        if (!pluginService || !status)
            return;
        pluginService.savePluginData(pluginId, "enabled", status.enabled);
        pluginService.savePluginData(pluginId, "faceCount", status.models.length);
    }

    function manage(message, args, done) {
        if (busy)
            return;
        errorText = "";
        busyText = message;
        run("manage", ["manage"].concat(args), (reply, code) => {
            busyText = "";
            const cancelled = code === 126 || code === 127;
            if (!cancelled && !(reply && reply.ok))
                errorText = reply && reply.error ? reply.error : "That change didn't work.";
            const succeeded = !!(reply && reply.ok);
            if (done)
                done(succeeded);
            refresh();
        });
    }

    // The camera can only have one user, so the preview lets go before a scan.
    function withCamera(action) {
        previewWanted = false;
        releaseTimer.action = action;
        releaseTimer.restart();
    }

    function runTest() {
        if (busy)
            return;
        errorText = "";
        testResult = null;
        busyText = "Look at the camera…";
        withCamera(() => {
            run("test", ["read", "test"], (reply) => {
                busyText = "";
                if (reply && reply.ok)
                    testResult = reply.data;
                else
                    errorText = reply && reply.error ? reply.error : "The test couldn't run.";
            });
        });
    }

    function addSample() {
        const label = newLabel.trim();
        if (busy || label === "")
            return;
        withCamera(() => {
            manage("Look at the camera and hold still…", ["add", label], ok => {
                if (ok)
                    newLabel = "";
            });
        });
    }

    function strictnessLabel(value) {
        let closest = strictnessLevels[1];
        for (const level of strictnessLevels) {
            if (Math.abs(level.value - value) < Math.abs(closest.value - value))
                closest = level;
        }
        return closest.label;
    }

    function formatDate(date) {
        const parsed = new Date(String(date).replace(" ", "T"));
        return isNaN(parsed) ? date : parsed.toLocaleDateString(Qt.locale(), Locale.ShortFormat);
    }

    Column {
        id: page

        width: parent ? parent.width : 0
        spacing: Theme.spacingM

        Timer {
            id: releaseTimer

            property var action: null

            interval: 500
            onTriggered: {
                if (action)
                    action();
                action = null;
            }
        }

        Component.onCompleted: root.refresh()

        // --- Setup needed
        Card {
            visible: root.helperMissing
            tone: Theme.warning

            Heading {
                icon: "build"
                title: "One setup step left"
                detail: "Face Unlock needs a small system helper to manage your faces safely. In the plugin's folder, run:"
            }

            Rectangle {
                width: parent.width
                height: commandText.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHighest

                StyledText {
                    id: commandText

                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.spacingM
                    text: root.installCommand
                    font.family: SettingsData.monoFontFamily
                    color: Theme.surfaceText
                }
            }

            DButton {
                text: "Check again"
                iconName: "refresh"
                onClicked: root.refresh()
            }
        }

        // --- Problems and progress
        Card {
            visible: root.errorText !== ""
            tone: Theme.error

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DIcon {
                    name: "error"
                    size: Theme.iconSize
                    color: Theme.error
                }

                StyledText {
                    width: parent.width - Theme.iconSize - Theme.spacingS
                    text: root.errorText
                    wrapMode: Text.WordWrap
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        Card {
            visible: root.needsShellRestart
            tone: Theme.warning

            Heading {
                icon: "restart_alt"
                title: "Restart the shell to apply"
                detail: "The lock screen only reads this setting when the shell starts. Your windows stay open."
            }

            DButton {
                text: "Restart shell"
                iconName: "restart_alt"
                onClicked: Proc.runCommand("faceUnlock.restart", ["dms", "restart"], () => {}, 0)
            }
        }

        // --- Master switch
        Card {
            visible: root.ready

            Item {
                width: parent.width
                height: Math.max(masterHeading.implicitHeight, masterToggle.implicitHeight)

                Heading {
                    id: masterHeading

                    width: parent.width - masterToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    icon: root.status && root.status.enabled ? "face" : "face_retouching_off"
                    iconTint: root.status && root.status.enabled ? Theme.primary : Theme.surfaceVariantText
                    title: "Face Unlock"
                    detail: {
                        if (!root.status)
                            return "";
                        if (!root.status.enabled)
                            return "Off. Only your password unlocks this computer.";
                        if (root.models.length === 0)
                            return "Add a face sample below to start using it.";
                        return root.status.pam.lock ? "On for the lock screen." : "On, but not connected to the lock screen yet.";
                    }
                }

                DToggle {
                    id: masterToggle

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    hideText: true
                    enabled: !root.busy
                    checked: root.status ? root.status.enabled : false
                    onToggled: isOn => root.manage(isOn ? "Turning on…" : "Turning off…", [isOn ? "enable" : "disable"])
                }
            }

            Row {
                visible: root.busy
                spacing: Theme.spacingS

                DSpinner {
                    size: 18
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.busyText
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }

        // --- Camera and test
        Card {
            visible: root.ready

            Heading {
                icon: "videocam"
                title: "Camera and test"
                detail: "Check what the camera sees, then test whether it recognizes you."
            }

            Rectangle {
                width: parent.width
                height: previewLoader.active ? Math.min(width * 9 / 16, 260) : 0
                visible: previewLoader.active
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerLowest
                clip: true

                Loader {
                    id: previewLoader

                    anchors.fill: parent
                    active: root.previewWanted && !root.busy

                    sourceComponent: Item {
                        MediaDevices {
                            id: mediaDevices
                        }

                        CaptureSession {
                            videoOutput: video

                            camera: Camera {
                                active: true
                                cameraDevice: {
                                    const node = root.status ? root.status.deviceNode : "";
                                    const inputs = mediaDevices.videoInputs;
                                    for (let i = 0; i < inputs.length; i++) {
                                        if (node !== "" && String(inputs[i].id).indexOf(node) !== -1)
                                            return inputs[i];
                                    }
                                    return mediaDevices.defaultVideoInput;
                                }
                            }
                        }

                        VideoOutput {
                            id: video

                            anchors.fill: parent
                            fillMode: VideoOutput.PreserveAspectCrop
                            // Mirrored, like looking in a mirror
                            transform: Scale {
                                origin.x: video.width / 2
                                xScale: -1
                            }
                        }
                    }
                }
            }

            Row {
                spacing: Theme.spacingS

                DButton {
                    text: root.previewWanted ? "Hide camera" : "Show camera"
                    iconName: root.previewWanted ? "videocam_off" : "videocam"
                    enabled: !root.busy
                    onClicked: root.previewWanted = !root.previewWanted
                }

                DButton {
                    text: "Test recognition"
                    iconName: "face"
                    enabled: !root.busy && root.models.length > 0
                    onClicked: root.runTest()
                }
            }

            // Result of the last test
            Rectangle {
                width: parent.width
                height: visible ? resultColumn.implicitHeight + Theme.spacingM * 2 : 0
                visible: root.testResult !== null
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHighest

                Column {
                    id: resultColumn

                    x: Theme.spacingM
                    y: Theme.spacingM
                    width: parent.width - Theme.spacingM * 2
                    spacing: Theme.spacingS

                    readonly property var result: root.testResult || {}
                    readonly property bool hasScore: typeof result.score === "number"

                    Row {
                        spacing: Theme.spacingS

                        DIcon {
                            name: resultColumn.result.matched ? "check_circle" : "cancel"
                            size: Theme.iconSize
                            color: resultColumn.result.matched ? Theme.success : Theme.error
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            text: {
                                const r = resultColumn.result;
                                if (r.matched)
                                    return "Recognized in " + (r.milliseconds / 1000).toFixed(1) + " s" + (r.model ? ", using “" + r.model + "”" : "");
                                if (r.tooDark)
                                    return "Too dark to see your face";
                                if (r.cameraError)
                                    return "The camera couldn't be opened";
                                return "Not recognized";
                            }
                        }
                    }

                    // Score meter, showing how far past the match line this attempt landed
                    Item {
                        width: parent.width
                        height: resultColumn.hasScore ? 34 : 0
                        visible: resultColumn.hasScore

                        readonly property real low: 0.4
                        readonly property real high: 1
                        readonly property real scorePos: Math.max(0, Math.min(1, ((resultColumn.result.score || 0) - low) / (high - low)))
                        readonly property real linePos: Math.max(0, Math.min(1, ((resultColumn.result.threshold || 0) - low) / (high - low)))

                        Rectangle {
                            width: parent.width
                            height: 6
                            radius: 3
                            color: Theme.surfaceVariant

                            Rectangle {
                                width: parent.width * parent.parent.scorePos
                                height: parent.height
                                radius: 3
                                color: resultColumn.result.matched ? Theme.success : Theme.error
                            }

                            Rectangle {
                                x: parent.width * parent.parent.linePos - 1
                                y: -3
                                width: 2
                                height: 12
                                color: Theme.surfaceText
                            }
                        }

                        StyledText {
                            y: 14
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            text: "Score " + (resultColumn.result.score || 0).toFixed(2) + " · needs " + (resultColumn.result.threshold || 0).toFixed(2)
                        }
                    }

                    StyledText {
                        width: parent.width
                        visible: !resultColumn.result.matched
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        text: {
                            const r = resultColumn.result;
                            if (r.tooDark)
                                return "Add some light, or raise Low-light tolerance below.";
                            if (r.cameraError)
                                return "Another app may be using it, or check the camera selected below.";
                            return "Try again facing the camera, or add a sample in this lighting.";
                        }
                    }
                }
            }
        }

        // --- Samples
        Card {
            visible: root.ready

            Heading {
                icon: "ar_on_you"
                title: "Face samples"
                detail: root.models.length === 0
                    ? "None yet. Add one while looking straight at the camera."
                    : "Add samples for glasses or different lighting to improve recognition."
            }

            Repeater {
                model: root.models

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool confirming: root.confirmRemoveId === modelData.id

                    width: page.width - Theme.spacingL * 2
                    height: 48
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest

                    DIcon {
                        x: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        name: "person"
                        size: Theme.iconSize
                        color: Theme.primary
                    }

                    Column {
                        x: Theme.spacingM * 2 + Theme.iconSize
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: modelData.label
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: "Added " + root.formatDate(modelData.date)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        DButton {
                            visible: confirming
                            text: "Remove"
                            enabled: !root.busy
                            onClicked: {
                                root.confirmRemoveId = -1;
                                root.manage("Removing…", ["remove", String(modelData.id)]);
                            }
                        }

                        DActionButton {
                            iconName: confirming ? "close" : "delete"
                            enabled: !root.busy
                            tooltipText: confirming ? "Keep this sample" : "Remove this sample"
                            onClicked: root.confirmRemoveId = confirming ? -1 : modelData.id
                        }
                    }
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DTextField {
                    id: labelField

                    width: parent.width - addButton.width - Theme.spacingS
                    placeholderText: root.models.length === 0 ? "Name, like “Default”" : "Name, like “Glasses”"
                    maximumLength: 32
                    enabled: !root.busy
                    text: root.newLabel
                    onTextEdited: root.newLabel = text
                    onAccepted: root.addSample()
                }

                DButton {
                    id: addButton

                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add sample"
                    iconName: "add"
                    enabled: !root.busy && root.newLabel.trim() !== ""
                    onClicked: root.addSample()
                }
            }

            Row {
                visible: root.models.length > 1
                spacing: Theme.spacingS

                DButton {
                    text: root.confirmClear ? "Yes, remove all samples" : "Remove all samples"
                    iconName: "delete_sweep"
                    enabled: !root.busy
                    onClicked: {
                        if (!root.confirmClear) {
                            root.confirmClear = true;
                            return;
                        }
                        root.confirmClear = false;
                        root.manage("Removing all samples…", ["clear"]);
                    }
                }

                DButton {
                    visible: root.confirmClear
                    text: "Cancel"
                    onClicked: root.confirmClear = false
                }
            }
        }

        // --- Where it's used
        Card {
            visible: root.ready

            Heading {
                icon: "lock_person"
                title: "Where it's used"
                detail: "Your password always remains available as a fallback."
            }

            Item {
                width: parent.width
                height: Math.max(lockText.implicitHeight, lockToggle.implicitHeight)

                readonly property var pam: root.status ? root.status.pam : ({})

                Column {
                    id: lockText

                    width: parent.width - lockToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        text: "Lock screen"
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        text: parent.parent.pam.lockState === "custom"
                            ? "Uses a custom PAM file, so it's managed outside this panel."
                            : "Press Enter on the lock screen, then look at the camera."
                    }
                }

                DToggle {
                    id: lockToggle

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    hideText: true
                    enabled: !root.busy && parent.pam.lockState !== "custom"
                    checked: parent.pam.lock === true
                    onToggled: isOn => root.manage("Updating the lock screen…", [isOn ? "lock-enable" : "lock-disable"], ok => {
                        if (ok)
                            root.needsShellRestart = true;
                    })
                }
            }

            Repeater {
                model: [
                    { name: "sudo", key: "sudo" },
                    { name: "Admin prompts", key: "polkit" },
                    { name: "Login screen", key: "greeter" }
                ]

                delegate: Item {
                    required property var modelData
                    readonly property bool active: root.status ? root.status.pam[modelData.key] === true : false

                    width: page.width - Theme.spacingL * 2
                    height: 24

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: parent.active ? "On" : "Off"
                        font.pixelSize: Theme.fontSizeSmall
                        color: parent.active ? Theme.primary : Theme.surfaceVariantText
                    }
                }
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                text: "These three are set up by hand and only shown here. Keeping the login screen on your password lets it unlock your keyring."
            }
        }

        // --- Tuning
        Card {
            visible: root.ready

            Heading {
                icon: "tune"
                title: "Tuning"
                detail: "Run a test after changing these."
            }

            LabeledSlider {
                title: "Scan time"
                caption: value + " s before falling back to your password"
                minimum: 1
                maximum: 10
                value: root.status ? Math.min(10, root.status.timeout) : 4
                onCommitted: newValue => root.manage("Saving…", ["set", "timeout", String(newValue)])
            }

            DDropdown {
                width: parent.width
                text: "Strictness"
                description: {
                    const current = root.status ? root.strictnessLabel(root.status.threshold) : "Balanced";
                    const level = root.strictnessLevels.find(l => l.label === current);
                    return level ? level.hint : "";
                }
                enabled: !root.busy
                options: root.strictnessLevels.map(l => l.label)
                currentValue: root.status ? root.strictnessLabel(root.status.threshold) : "Balanced"
                onValueChanged: value => {
                    const level = root.strictnessLevels.find(l => l.label === value);
                    if (level && root.status && level.value !== root.status.threshold)
                        root.manage("Saving…", ["set", "sface_threshold", String(level.value)]);
                }
            }

            LabeledSlider {
                title: "Low-light tolerance"
                caption: "Higher accepts darker video, which can make matches less reliable"
                minimum: 50
                maximum: 99
                value: root.status ? Math.round(root.status.darkThreshold) : 75
                onCommitted: newValue => root.manage("Saving…", ["set", "dark_threshold", String(newValue)])
            }

            DDropdown {
                width: parent.width
                visible: root.status && root.status.cameras.length > 1
                text: "Camera"
                description: "Which camera Howdy uses"
                enabled: !root.busy
                options: root.status ? root.status.cameras.map(c => c.name) : []
                currentValue: {
                    if (!root.status)
                        return "";
                    const match = root.status.cameras.find(c => c.path === root.status.device);
                    return match ? match.name : "";
                }
                onValueChanged: value => {
                    const match = root.status.cameras.find(c => c.name === value);
                    if (match && match.path !== root.status.device)
                        root.manage("Saving…", ["set", "device_path", match.path]);
                }
            }
        }

        StyledText {
            width: parent.width
            visible: root.ready
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            text: "Face recognition is a convenience, not stronger security: a regular camera can be fooled by a photo. " + (root.status ? root.status.howdyVersion : "")
        }
    }

    component Card: Rectangle {
        default property alias body: cardColumn.data
        property color tone: "transparent"

        width: page.width
        height: visible ? cardColumn.implicitHeight + Theme.spacingL * 2 : 0
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: tone.a > 0 ? 1 : 0
        border.color: tone

        Column {
            id: cardColumn

            x: Theme.spacingL
            y: Theme.spacingL
            width: parent.width - Theme.spacingL * 2
            spacing: Theme.spacingM
        }
    }

    component Heading: Row {
        property string icon: ""
        property color iconTint: Theme.primary
        property string title: ""
        property string detail: ""

        width: parent ? parent.width : 0
        spacing: Theme.spacingM

        DIcon {
            name: parent.icon
            size: Theme.iconSizeLarge
            color: parent.iconTint
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - Theme.iconSizeLarge - Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXXS

            StyledText {
                text: parent.parent.title
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: parent.parent.detail
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    component LabeledSlider: Column {
        property string title: ""
        property string caption: ""
        property int minimum: 0
        property int maximum: 100
        property int value: 0

        signal committed(int newValue)

        width: parent ? parent.width : 0
        spacing: Theme.spacingXS

        StyledText {
            text: parent.title
            color: Theme.surfaceText
        }

        DSlider {
            width: parent.width
            minimum: parent.minimum
            maximum: parent.maximum
            value: parent.value
            enabled: !root.busy
            onSliderDragFinished: finalValue => {
                if (finalValue !== parent.value)
                    parent.committed(finalValue);
            }
        }

        StyledText {
            width: parent.width
            text: parent.caption
            wrapMode: Text.WordWrap
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}
