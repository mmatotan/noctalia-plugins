import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Services.UI

QtObject {
    id: root

    readonly property var pluginSettings: pluginApi?.pluginSettings ?? ({})

    readonly property var toast: root.pluginSettings?.disableToastNotifications ? null : ToastService

    property var pluginApi: null

    property var vpnList: []
    property real connectedCount: 0
    readonly property bool isLoading: Object.keys(root._pending).length > 0

    property var _pending: ({})
    
    // Password prompt state
    property string _passwordConnectionName: ""
    property string _passwordConnectionUuid: ""
    property var _passwordProc: Process {}
    property bool _passwordProcRunning: false

    // Needed only to detect disconnection not initiated by the user
    property var _pollTimer: Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }

    property var _lines: []

    property var _listProc: Process {
        command: ["nmcli", "-t", "-f", "NAME,TYPE,STATE,UUID", "connection", "show"]
        running: true

        stdout: SplitParser {
            onRead: (line) => {
                if (line.trim() !== "")
                    root._lines.push(line)
            }
        }

        onExited: (exitCode) => {
            if (exitCode === 0) {
                const parsed = []
                const newPending = Object.assign({}, root._pending)
                for (const line of root._lines) {
                    const parts = line.split(":")
                    if (parts.length >= 4) {
                        const name  = parts[0]
                        const type  = parts[1]
                        const state = parts[2]
                        const uuid = parts[3]
                        if (type === "vpn" || type === "wireguard") {
                            if (newPending[uuid]) {
                                const wasConnecting = newPending[uuid] === "connect"
                                if (wasConnecting && state === "activated")
                                    delete newPending[uuid]
                                else if (!wasConnecting && state !== "activated")
                                    delete newPending[uuid]
                            }
                            parsed.push({
                                name,
                                type,
                                connected: state === "activated",
                                isLoading: !!newPending[uuid],
                                uuid
                            })
                        }
                    }
                }
                root._pending = newPending
                root.vpnList = parsed
                root.connectedCount = parsed.filter(v => v.connected).length
            }
            root._lines = []
        }
    }

    property var _connectProc: Process {
        property string targetName: ""
        property string targetUuid: ""
        property string targetPasswordFile: ""
        command: ["nmcli", "connection", "up", "uuid", targetUuid, "--ask-password-file", targetPasswordFile]
        onExited: (exitCode) => {
            // Exit code 128 means nmcli failed (likely needs password)
            if (exitCode === 128) {
                root._passwordConnectionName = targetName
                root._passwordConnectionUuid = targetUuid
                root._passwordProcRunning = false
                root.showPasswordPrompt()
            } else if (exitCode === 0) {
                toast?.showNotice(t("toast.connectedTo", { name: targetName }))
                root.stopLoading(targetUuid)
                root.refresh()
            } else {
                root.stopLoading(targetUuid)
                toast?.showError(t("toast.connectionError", { name: targetName }))
                root.refresh()
            }
        }
    }

    property var _disconnectProc: Process {
        property string targetName: ""
        property string targetUuid: ""
        command: ["nmcli", "connection", "down", "uuid", targetUuid]
        onExited: (exitCode) => {
            if (exitCode === 0)
                toast?.showNotice(t("toast.disconnectedFrom", { name: targetName }))
            else {
                root.stopLoading(targetUuid)
                toast?.showError(t("toast.disconnectionError", { name: targetName }))
            }
            root.refresh()
        }
    }

    property var _addProc: Process {
        property string targetType: ""

        command: ["nm-connection-editor", "--create", "--type", targetType]
        onExited: (exitCode) => {
            root.refresh();
        }
    }

    property var _editProc: Process {
        property string targetName: ""
        property string targetUuid: ""

        command: ["nm-connection-editor", "--edit", targetUuid]
        onExited: (exitCode) => {
            root.refresh();
        }
    }

    property var _removeProc: Process {
        property string targetName: ""
        property string targetUuid: ""

        command: ["nmcli", "connection", "delete", "uuid", targetUuid]
        onExited: (exitCode) => {
            if (exitCode === 0)
                toast?.showNotice(t("toast.vpnRemoved", { "name": targetName }));
            else
                toast?.showError(t("toast.vpnRemoveError", { "name": targetName }));
            root.refresh();
        }
    }

    function t(key: string, data) {
        if (!pluginApi)
            return null;

        return pluginApi.tr(key, data);
    }

    // Password prompt functions
    function showPasswordPrompt() {
        root._passwordConnectionName = _connectProc.targetName
        root._passwordConnectionUuid = _connectProc.targetUuid
        root._passwordProcRunning = false
        root.passwordPrompt?.open()
    }

    function handlePasswordPrompt() {
        if (root._passwordProcRunning) {
            return
        }
        root._passwordProcRunning = true
        const connectionName = root._passwordConnectionName
        const connectionUuid = root._passwordConnectionUuid
        const password = root.passwordPrompt?.input?.text || ""

        // Create temporary password file
        const timestamp = Date.now()
        const passwordFile = "/tmp/nmcli-password-" + timestamp + ".txt"
        root._connectProc.targetPasswordFile = passwordFile

        // Write password to file
        const writeProc = Process {
            command: ["sh", "-c", "echo -n '" + password + "' > '" + passwordFile + "'"]
            onExited: (exitCode) => {
                if (exitCode === 0) {
                    // Start nmcli with password file
                    root._connectProc.start()
                } else {
                    // Failed to write password, close prompt and show error
                    root.passwordPrompt?.close()
                    toast?.showError(t("toast.passwordWriteError", { name: connectionName }))
                    root._passwordProcRunning = false
                    root._passwordConnectionName = ""
                    root._passwordConnectionUuid = ""
                }
            }
        }
        writeProc.running = true
    }

    function refresh() {
        _listProc.running = true
    }

    function stopLoading(uuid) {
        if (uuid && _pending[uuid]) {
            const p = Object.assign({}, _pending)
            delete p[uuid]
            _pending = p
        }

        vpnList = vpnList.map(v => {
            if (v.uuid !== uuid) {
                return v
            }

            return Object.assign({}, v, { isLoading: false })
        })
    }

    function connectTo(uuid) {
        const p = Object.assign({}, _pending)
        p[uuid] = "connect"
        _pending = p
        let name = ""
        vpnList = vpnList.map(v => {
            if (v.uuid !== uuid) {
                return v
            }
            
            name = v.name
            return Object.assign({}, v, { isLoading: true })
        })
        _connectProc.targetName = name
        _connectProc.targetUuid = uuid
        _connectProc.running = true
    }

    function disconnectFrom(uuid) {
        const p = Object.assign({}, _pending)
        p[uuid] = "disconnect"
        _pending = p
        let name = ""
        vpnList = vpnList.map(v => {
            if (v.uuid !== uuid) {
                return v
            }
            
            name = v.name
            return Object.assign({}, v, { isLoading: true })
        })
        _disconnectProc.targetName = name
        _disconnectProc.targetUuid = uuid
        _disconnectProc.running = true
    }

    function addConnection(type) {
        _addProc.targetType = type || "vpn";
        _addProc.running = true;
    }

    function editConnection(uuid) {
        const vpn = vpnList.find((v) => {
            return v.uuid === uuid;
        });
        _editProc.targetName = vpn ? vpn.name : uuid;
        _editProc.targetUuid = uuid;
        _editProc.running = true;
    }

    function removeConnection(uuid) {
        const vpn = vpnList.find((v) => {
            return v.uuid === uuid;
        });
        _removeProc.targetName = vpn ? vpn.name : uuid;
        _removeProc.targetUuid = uuid;
        _removeProc.running = true;
    }

    Component.onCompleted: {
        Logger.i("NetworkManagerVPN", "Started")
    }

    // Password prompt dialog
    NPopup {
        id: passwordPrompt
        modal: true
        property string input: ""
        property bool opened: false
        anchors.centerIn: parent
        width: 400 * Style.uiScaleRatio
        height: 200 * Style.uiScaleRatio
        visible: opened

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.marginL
            spacing: Style.marginS

            NLabel {
                Layout.fillWidth: true
                text: t("passwordPrompt.title") || "Enter Password"
                font.bold: true
                font.size: Style.fontSizeM
            }

            NLabel {
                Layout.fillWidth: true
                text: t("passwordPrompt.subtitle") || "Enter your VPN password to continue"
                font.size: Style.fontSizeS
                color: Color.fGray
            }

            NTextInput {
                Layout.fillWidth: true
                label: t("passwordPrompt.password") || "Password"
                password: true
                onTextChanged: passwordPrompt.input = text
            }

            NBox {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.buttonHeight
                Layout.alignment: Qt.AlignHCenter
                spacing: Style.marginXS

                NButton {
                    Layout.preferredWidth: 100 * Style.uiScaleRatio
                    text: t("passwordPrompt.cancel") || "Cancel"
                    onClicked: {
                        passwordPrompt.close()
                        root._passwordProcRunning = false
                        root._passwordConnectionName = ""
                        root._passwordConnectionUuid = ""
                    }
                }

                NButton {
                    Layout.preferredWidth: 120 * Style.uiScaleRatio
                    text: t("passwordPrompt.enter") || "Enter"
                    onClicked: {
                        if (passwordPrompt.input) {
                            root.handlePasswordPrompt()
                        }
                    }
                }
            }
        }
    }
}
