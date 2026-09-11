import Foundation

/// Defines how queued and active transfer work is represented immediately when
/// the physical Android device disappears.
public enum TransferDisconnectPolicy {
    public static func nextState(
        current: TransferState,
        isEphemeral: Bool
    ) -> TransferState {
        guard !current.isTerminal else { return current }
        if current == .paused { return isEphemeral ? .failed : .paused }
        // Finder file promises cannot be resumed after their drag destination
        // gives up waiting. Persistent queue jobs, however, can safely pause and
        // continue when the same phone reconnects.
        return isEphemeral ? .failed : .queued
    }
}
