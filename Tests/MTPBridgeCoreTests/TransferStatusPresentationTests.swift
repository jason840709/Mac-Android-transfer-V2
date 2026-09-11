import XCTest
@testable import MTPBridgeCore

final class TransferStatusPresentationTests: XCTestCase {
    func testRunningPhasesUseExplicitStatusKeys() {
        XCTAssertEqual(
            TransferStatusPresentation.make(
                state: .running,
                phase: .preparing,
                attempt: 1,
                maxAttempts: 4
            ),
            TransferStatusPresentation(localizationKey: "transfer.state.preparing")
        )
        XCTAssertEqual(
            TransferStatusPresentation.make(
                state: .running,
                phase: .finalizing,
                attempt: 1,
                maxAttempts: 4
            ),
            TransferStatusPresentation(localizationKey: "transfer.phase.finalizing")
        )
        XCTAssertEqual(
            TransferStatusPresentation.make(
                state: .running,
                phase: .transferring,
                attempt: 1,
                maxAttempts: 4
            ),
            TransferStatusPresentation(localizationKey: "transfer.state.running")
        )
        XCTAssertEqual(
            TransferStatusPresentation.make(
                state: .running,
                phase: nil,
                attempt: 1,
                maxAttempts: 4
            ),
            TransferStatusPresentation(localizationKey: "transfer.state.running")
        )
    }

    func testEveryTransferStateHasAStatusKey() {
        let expected: [(TransferState, String)] = [
            (.queued, "transfer.state.queued"),
            (.preparing, "transfer.state.preparing"),
            (.running, "transfer.state.running"),
            (.paused, "transfer.state.paused"),
            (.completed, "transfer.state.completed"),
            (.failed, "transfer.state.failed"),
            (.cancelled, "transfer.state.cancelled"),
        ]

        for (state, key) in expected {
            XCTAssertEqual(
                TransferStatusPresentation.make(
                    state: state,
                    phase: state == .running ? .transferring : nil,
                    attempt: 0,
                    maxAttempts: 4
                ),
                TransferStatusPresentation(localizationKey: key)
            )
        }
    }

    func testRetryingCarriesAttemptArguments() {
        XCTAssertEqual(
            TransferStatusPresentation.make(
                state: .retrying,
                phase: nil,
                attempt: 2,
                maxAttempts: 4
            ),
            TransferStatusPresentation(
                localizationKey: "transfer.state.retrying",
                integerArguments: [2, 4]
            )
        )
    }
}
