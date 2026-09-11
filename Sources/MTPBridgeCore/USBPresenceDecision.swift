import Foundation

public enum USBPresenceObservation: Sendable {
    case present
    case missing
    case probeFailed
}

/// Small, deterministic state machine used by the out-of-band USB monitor.
/// Probe failures are not evidence of removal; two successful misses are.
public struct USBPresenceDecision: Sendable {
    public let requiredConsecutiveMisses: Int
    public private(set) var consecutiveMisses = 0

    public init(requiredConsecutiveMisses: Int = 2) {
        self.requiredConsecutiveMisses = max(1, requiredConsecutiveMisses)
    }

    /// Returns true exactly when the endpoint should be treated as removed.
    @discardableResult
    public mutating func observe(_ observation: USBPresenceObservation) -> Bool {
        switch observation {
        case .present, .probeFailed:
            consecutiveMisses = 0
            return false
        case .missing:
            consecutiveMisses += 1
            return consecutiveMisses >= requiredConsecutiveMisses
        }
    }
}
