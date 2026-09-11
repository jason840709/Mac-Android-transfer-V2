import Foundation
#if canImport(AppKit)
import AppKit
#endif

struct MTPAccessConflict: Equatable, Sendable {
    let applicationNames: [String]
    let bundleIdentifiers: [String]

    var displayName: String {
        applicationNames.joined(separator: "、")
    }
}

@MainActor
enum MTPAccessArbiter {
    /// The old Android File Transfer background Agent is deliberately *not*
    /// treated as an MTP-session owner. Static inspection of the user-supplied
    /// Google binary shows the Agent using LIBMTP_Detect_Raw_Devices to watch
    /// for insertion and launching com.google.android.mtpviewer, while the
    /// visible viewer contains LIBMTP_Open_Raw_Device_Uncached and owns the
    /// real MTP session. Blocking on the Agent alone made Android Transfer V2
    /// unusable after the user had already quit the old viewer.
    static func currentConflict() -> MTPAccessConflict? {
#if canImport(AppKit)
        let identifier = LegacyMTPProcessPolicy.androidFileTransferViewerBundleIdentifier
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        guard !applications.isEmpty else { return nil }

        var names: [String] = []
        for application in applications {
            let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty, !names.contains(name) {
                names.append(name)
            }
        }
        if names.isEmpty {
            names = ["Android File Transfer"]
        }
        return MTPAccessConflict(applicationNames: names, bundleIdentifiers: [identifier])
#else
        return nil
#endif
    }

    static func passiveLegacyAgentIsRunning() -> Bool {
#if canImport(AppKit)
        let identifier = LegacyMTPProcessPolicy.androidFileTransferAgentBundleIdentifier
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
#else
        return false
#endif
    }

    /// User-initiated, session-only attempt to stop only the visible legacy
    /// viewer. The old background Agent is intentionally left alone: it is a
    /// passive insertion watcher and does not hold the MTP session itself.
    /// This never deletes the old app or edits its Login Item registration.
    @discardableResult
    static func requestTemporaryTermination() -> Bool {
#if canImport(AppKit)
        let identifier = LegacyMTPProcessPolicy.androidFileTransferViewerBundleIdentifier
        var requested = false
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
            requested = application.terminate() || requested
        }
        return requested
#else
        return false
#endif
    }
}
