import XCTest
@testable import MTPBridgeCore

final class MTPSelectionMappingTests: XCTestCase {
    func testSelectionFollowsObjectIdentifierAcrossReordering() {
        let original = [
            object(id: 10, name: "a"),
            object(id: 20, name: "b"),
            object(id: 30, name: "c"),
        ]
        let reordered = [original[2], original[0], original[1]]

        XCTAssertEqual(
            MTPSelectionMapping.rowIndexes(for: [20], in: original),
            IndexSet(integer: 1)
        )
        XCTAssertEqual(
            MTPSelectionMapping.rowIndexes(for: [20], in: reordered),
            IndexSet(integer: 2)
        )
    }

    func testVisibleRowsMapBackToTheCorrectObjectIdentifiers() {
        let values = [
            object(id: 100, name: "first"),
            object(id: 200, name: "second"),
            object(id: 300, name: "third"),
        ]

        XCTAssertEqual(
            MTPSelectionMapping.objectIDs(at: IndexSet([0, 2, 99]), in: values),
            Set([100, 300])
        )
    }

    private func object(id: UInt32, name: String) -> MTPObject {
        MTPObject(
            id: id,
            parentID: 0,
            storageID: 1,
            name: name,
            size: 0,
            modificationDate: nil,
            isFolder: false,
            fileType: 0
        )
    }
}
