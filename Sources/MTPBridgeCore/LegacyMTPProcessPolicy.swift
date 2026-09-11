import Foundation

public enum LegacyMTPProcessRole: Equatable, Sendable {
    case blockingViewer
    case passiveObserver
    case unrelated
}

public enum LegacyMTPProcessPolicy {
    public static let androidFileTransferViewerBundleIdentifier = "com.google.android.mtpviewer"
    public static let androidFileTransferAgentBundleIdentifier = "com.google.android.mtpagent"

    public static func role(for bundleIdentifier: String) -> LegacyMTPProcessRole {
        switch bundleIdentifier {
        case androidFileTransferViewerBundleIdentifier:
            return .blockingViewer
        case androidFileTransferAgentBundleIdentifier:
            return .passiveObserver
        default:
            return .unrelated
        }
    }

    public static func blocksMTPSession(bundleIdentifier: String) -> Bool {
        role(for: bundleIdentifier) == .blockingViewer
    }
}
