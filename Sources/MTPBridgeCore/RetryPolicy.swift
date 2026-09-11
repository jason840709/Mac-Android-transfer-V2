import Foundation

public struct RetryPolicy: Sendable, Hashable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var multiplier: Double
    public var maximumDelay: TimeInterval
    public var jitterFraction: Double

    public init(
        maxAttempts: Int = 4,
        initialDelay: TimeInterval = 0.75,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 8,
        jitterFraction: Double = 0.2
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.multiplier = max(1, multiplier)
        self.maximumDelay = max(0, maximumDelay)
        self.jitterFraction = min(max(0, jitterFraction), 1)
    }

    /// Attempt is one-based. The returned delay occurs before the next attempt.
    public func delay(afterAttempt attempt: Int, unitRandom: Double = 0.5) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let base = min(initialDelay * pow(multiplier, Double(exponent)), maximumDelay)
        let normalized = min(max(unitRandom, 0), 1)
        let signedJitter = (normalized * 2) - 1
        return max(0, base * (1 + signedJitter * jitterFraction))
    }

    public func shouldRetry(afterAttempt attempt: Int, retryable: Bool) -> Bool {
        retryable && attempt < maxAttempts
    }
}
