enum DeviceInsertionIdentifiers {
    /// 0.7.0 deliberately uses a new helper identity. Earlier builds could leave
    /// ServiceManagement pointing at a deleted source-folder copy of the App,
    /// which made the old helper ask NSWorkspace to open a missing file.
    static let helperBundleIdentifier = "io.github.mtpbridge.DeviceInsertionAgentV2"
    static let helperBundleName = "Android 傳輸 V2 裝置偵測器.app"
    static let helperExecutableName = "AndroidTransferV2DeviceAgent"

    static let retiredDeviceAgentBundleIdentifier = "io.github.mtpbridge.DeviceInsertionAgent"
    static let retiredLaunchAgentPlistName = "io.github.mtpbridge.DeviceWatcher.plist"
    static let retiredLaunchAgentLabel = "io.github.mtpbridge.DeviceWatcher"
    static let retiredLoginItemBundleIdentifier = "io.github.mtpbridge.MTPAutoLaunch"
}
