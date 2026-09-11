import Foundation

public enum TransferQueuePersistencePolicy {
    public static let currentSchemaVersion = 3

    /// A persisted upload can only be resumed when it carries a stable folder
    /// breadcrumb that can be rebound to fresh MTP handles in the new session.
    public static func canResumePersistedUpload(_ destination: RemoteTransferDestination) -> Bool {
        destination.parentPath != nil
    }

    public static func requiresUserRestart(_ job: TransferJob, sourceSchemaVersion: Int?) -> Bool {
        guard !job.state.isTerminal else { return false }
        switch job.request {
        case let .upload(_, destination):
            // Legacy array queues have no schema contract. Even when a legacy
            // destination happens to decode, never replay a session-bound parent
            // handle without an explicit path that can be rebound.
            if sourceSchemaVersion == nil { return true }
            return !canResumePersistedUpload(destination)
        case .download:
            // Preserve the existing download-resume behavior for schema-aware
            // queues. Legacy queues are allowed for now because their local
            // partial fingerprint performs its own safety verification.
            return false
        }
    }
}
