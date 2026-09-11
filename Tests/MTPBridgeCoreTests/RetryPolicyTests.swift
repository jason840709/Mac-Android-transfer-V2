import XCTest
@testable import MTPBridgeCore

final class RetryPolicyTests: XCTestCase {
    func testExponentialBackoffWithoutJitter() {
        let policy = RetryPolicy(maxAttempts: 4, initialDelay: 1, multiplier: 2, maximumDelay: 5, jitterFraction: 0)
        XCTAssertEqual(policy.delay(afterAttempt: 1), 1)
        XCTAssertEqual(policy.delay(afterAttempt: 2), 2)
        XCTAssertEqual(policy.delay(afterAttempt: 3), 4)
        XCTAssertEqual(policy.delay(afterAttempt: 4), 5)
    }

    func testRetryLimit() {
        let policy = RetryPolicy(maxAttempts: 3)
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 1, retryable: true))
        XCTAssertTrue(policy.shouldRetry(afterAttempt: 2, retryable: true))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 3, retryable: true))
        XCTAssertFalse(policy.shouldRetry(afterAttempt: 1, retryable: false))
    }
}
