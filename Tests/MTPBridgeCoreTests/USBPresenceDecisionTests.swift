import XCTest
@testable import MTPBridgeCore

final class USBPresenceDecisionTests: XCTestCase {
    func testRequiresTwoSuccessfulMisses() {
        var decision = USBPresenceDecision(requiredConsecutiveMisses: 2)
        XCTAssertFalse(decision.observe(.missing))
        XCTAssertTrue(decision.observe(.missing))
    }

    func testPresenceResetsAStaleMiss() {
        var decision = USBPresenceDecision(requiredConsecutiveMisses: 2)
        XCTAssertFalse(decision.observe(.missing))
        XCTAssertFalse(decision.observe(.present))
        XCTAssertFalse(decision.observe(.missing))
    }

    func testProbeFailureIsNotTreatedAsRemoval() {
        var decision = USBPresenceDecision(requiredConsecutiveMisses: 2)
        XCTAssertFalse(decision.observe(.missing))
        XCTAssertFalse(decision.observe(.probeFailed))
        XCTAssertFalse(decision.observe(.missing))
    }
}
