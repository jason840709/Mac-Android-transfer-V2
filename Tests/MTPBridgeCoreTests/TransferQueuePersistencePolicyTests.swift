import XCTest
@testable import MTPBridgeCore

final class TransferQueuePersistencePolicyTests: XCTestCase {
    private func uploadJob(parentPath: [String]?, state: TransferState = .retrying) -> TransferJob {
        TransferJob(
            request: .upload(
                source: LocalTransferSource(path: "/tmp/file.txt", securityScopedBookmark: nil),
                destination: RemoteTransferDestination(
                    storageID: 65_537,
                    parentObjectID: 123,
                    parentPath: parentPath
                )
            ),
            displayName: "file.txt",
            direction: .upload,
            state: state
        )
    }

    func testLegacyUploadIsNeverAutomaticallyResumed() {
        XCTAssertTrue(
            TransferQueuePersistencePolicy.requiresUserRestart(
                uploadJob(parentPath: ["Download"]),
                sourceSchemaVersion: nil
            )
        )
    }

    func testSchemaAwareUploadRequiresBreadcrumb() {
        XCTAssertTrue(
            TransferQueuePersistencePolicy.requiresUserRestart(
                uploadJob(parentPath: nil),
                sourceSchemaVersion: TransferQueuePersistencePolicy.currentSchemaVersion
            )
        )
        XCTAssertFalse(
            TransferQueuePersistencePolicy.requiresUserRestart(
                uploadJob(parentPath: ["Download"]),
                sourceSchemaVersion: TransferQueuePersistencePolicy.currentSchemaVersion
            )
        )
    }

    func testTerminalLegacyUploadCanRemainAsHistory() {
        XCTAssertFalse(
            TransferQueuePersistencePolicy.requiresUserRestart(
                uploadJob(parentPath: nil, state: .completed),
                sourceSchemaVersion: nil
            )
        )
    }
}
