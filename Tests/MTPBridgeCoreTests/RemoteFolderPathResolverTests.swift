import XCTest
@testable import MTPBridgeCore

final class RemoteFolderPathResolverTests: XCTestCase {
    func testRebindsStaleCapturedParentUsingBreadcrumbNames() async throws {
        let destination = RemoteTransferDestination(
            storageID: 7,
            parentObjectID: 9_999,
            parentPath: ["Download", "Target"]
        )
        let root = mtpRootObjectID
        let tree: [UInt32: [MTPObject]] = [
            root: [folder(id: 101, parent: root, name: "Download")],
            101: [folder(id: 202, parent: 101, name: "Target")]
        ]

        let resolved = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { _, parent in tree[parent] ?? [] }
        )
        XCTAssertEqual(resolved, 202)
        XCTAssertNotEqual(resolved, destination.parentObjectID)
    }

    func testRootPathResolvesToRootObject() async throws {
        let destination = RemoteTransferDestination(
            storageID: 7,
            parentObjectID: 123,
            parentPath: []
        )
        let resolved = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { _, _ in XCTFail("Root resolution must not enumerate"); return [] }
        )
        XCTAssertEqual(resolved, mtpRootObjectID)
    }

    func testLegacyDestinationRefusesCapturedHandle() async throws {
        let destination = RemoteTransferDestination(storageID: 7, parentObjectID: 321)
        let resolved = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { _, _ in XCTFail("Legacy destination must not enumerate"); return [] }
        )
        XCTAssertNil(resolved)
    }

    func testMissingOrNonFolderBreadcrumbFailsResolution() async throws {
        let destination = RemoteTransferDestination(
            storageID: 7,
            parentObjectID: 999,
            parentPath: ["Download"]
        )
        let child = MTPObject(
            id: 44, parentID: mtpRootObjectID, storageID: 7, name: "Download",
            size: 5, modificationDate: nil, isFolder: false, fileType: 0
        )
        let resolved = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { _, _ in [child] }
        )
        XCTAssertNil(resolved)
    }

    func testBreadcrumbRebindRefreshesEveryHandle() async throws {
        let root = mtpRootObjectID
        let tree: [UInt32: [MTPObject]] = [
            root: [folder(id: 500, parent: root, name: "Pictures")],
            500: [folder(id: 600, parent: 500, name: "Screenshots")]
        ]
        let rebound = try await RemoteFolderPathResolver.resolveBreadcrumbs(
            storageID: 7,
            names: ["Pictures", "Screenshots"],
            listChildren: { _, parent in tree[parent] ?? [] }
        )
        XCTAssertEqual(rebound?.map(\.objectID), [500, 600])
        XCTAssertEqual(rebound?.map(\.name), ["Pictures", "Screenshots"])
    }

}

private func folder(id: UInt32, parent: UInt32, name: String) -> MTPObject {
    MTPObject(
        id: id, parentID: parent, storageID: 7, name: name, size: 0,
        modificationDate: nil, isFolder: true, fileType: 0
    )
}
