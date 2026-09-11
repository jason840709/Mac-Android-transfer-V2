import XCTest
@testable import MTPBridgeCore

final class TransferDisconnectPolicyTests: XCTestCase {
    func testEveryNonterminalEphemeralJobFailsImmediately() {
        for state in [
            TransferState.queued,
            .preparing,
            .running,
            .retrying,
        ] {
            XCTAssertEqual(
                TransferDisconnectPolicy.nextState(current: state, isEphemeral: true),
                .failed
            )
        }
    }

    func testPersistentNonterminalJobsReturnToQueue() {
        for state in [
            TransferState.queued,
            .preparing,
            .running,
            .retrying,
        ] {
            XCTAssertEqual(
                TransferDisconnectPolicy.nextState(current: state, isEphemeral: false),
                .queued
            )
        }
    }

    func testPausedJobStaysPausedAcrossDisconnect() {
        XCTAssertEqual(
            TransferDisconnectPolicy.nextState(current: .paused, isEphemeral: false),
            .paused
        )
        XCTAssertEqual(
            TransferDisconnectPolicy.nextState(current: .paused, isEphemeral: true),
            .failed
        )
    }

    func testTerminalStateIsNeverRewritten() {
        for state in [
            TransferState.completed,
            .failed,
            .cancelled,
        ] {
            XCTAssertEqual(
                TransferDisconnectPolicy.nextState(current: state, isEphemeral: true),
                state
            )
            XCTAssertEqual(
                TransferDisconnectPolicy.nextState(current: state, isEphemeral: false),
                state
            )
        }
    }
}
