import Foundation

/// A platform-independent description of the text shown for a transfer job.
///
/// Keeping this state mapping outside SwiftUI lets the package test every
/// transfer state on Linux and catches semantic regressions before a macOS App
/// build begins.
public struct TransferStatusPresentation: Equatable, Sendable {
    public var localizationKey: String
    public var integerArguments: [Int]

    public init(localizationKey: String, integerArguments: [Int] = []) {
        self.localizationKey = localizationKey
        self.integerArguments = integerArguments
    }

    public static func make(
        state: TransferState,
        phase: TransferPhase?,
        attempt: Int,
        maxAttempts: Int
    ) -> TransferStatusPresentation {
        if state == .running {
            switch phase {
            case .preparing:
                return TransferStatusPresentation(localizationKey: "transfer.state.preparing")
            case .finalizing:
                return TransferStatusPresentation(localizationKey: "transfer.phase.finalizing")
            case .transferring, .none:
                break
            }
        }

        switch state {
        case .queued:
            return TransferStatusPresentation(localizationKey: "transfer.state.queued")
        case .preparing:
            return TransferStatusPresentation(localizationKey: "transfer.state.preparing")
        case .running:
            return TransferStatusPresentation(localizationKey: "transfer.state.running")
        case .retrying:
            return TransferStatusPresentation(
                localizationKey: "transfer.state.retrying",
                integerArguments: [attempt, maxAttempts]
            )
        case .paused:
            return TransferStatusPresentation(localizationKey: "transfer.state.paused")
        case .completed:
            return TransferStatusPresentation(localizationKey: "transfer.state.completed")
        case .failed:
            return TransferStatusPresentation(localizationKey: "transfer.state.failed")
        case .cancelled:
            return TransferStatusPresentation(localizationKey: "transfer.state.cancelled")
        }
    }
}
