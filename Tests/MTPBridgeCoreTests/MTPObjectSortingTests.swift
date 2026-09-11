import XCTest
@testable import MTPBridgeCore

final class MTPObjectSortingTests: XCTestCase {
    private let old = Date(timeIntervalSince1970: 100)
    private let new = Date(timeIntervalSince1970: 200)

    func testNameSortUsesNaturalOrderingAndTogglesDirection() {
        let values = [
            object(id: 1, name: "file10.txt", size: 10),
            object(id: 2, name: "file2.txt", size: 20),
        ]
        XCTAssertEqual(
            MTPObjectSorter.sorted(values, by: .name, ascending: true).map(\.name),
            ["file2.txt", "file10.txt"]
        )
        XCTAssertEqual(
            MTPObjectSorter.sorted(values, by: .name, ascending: false).map(\.name),
            ["file10.txt", "file2.txt"]
        )
    }

    func testEveryColumnHasARealSortOrder() {
        let values = [
            object(id: 1, name: "z.pdf", size: 5, created: new, modified: old),
            object(id: 2, name: "a.txt", size: 20, created: old, modified: new),
            object(id: 3, name: "photo.jpg", size: 10, created: nil, modified: nil),
        ]

        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .type, ascending: true).map(\.id), [3, 1, 2])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .type, ascending: false).map(\.id), [2, 1, 3])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .size, ascending: true).map(\.id), [1, 3, 2])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .size, ascending: false).map(\.id), [2, 3, 1])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .created, ascending: true).map(\.id), [2, 1, 3])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .created, ascending: false).map(\.id), [1, 2, 3])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .modified, ascending: true).map(\.id), [1, 2, 3])
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .modified, ascending: false).map(\.id), [2, 1, 3])
    }

    func testFoldersRemainAtTop() {
        let values = [
            object(id: 1, name: "a.txt", size: 1),
            object(id: 2, name: "Folder", size: 0, folder: true),
        ]
        XCTAssertEqual(MTPObjectSorter.sorted(values, by: .size, ascending: false).map(\.id), [2, 1])
    }

    private func object(
        id: UInt32,
        name: String,
        size: UInt64,
        created: Date? = nil,
        modified: Date? = nil,
        folder: Bool = false
    ) -> MTPObject {
        MTPObject(
            id: id,
            parentID: 0,
            storageID: 1,
            name: name,
            size: size,
            creationDate: created,
            modificationDate: modified,
            isFolder: folder,
            fileType: 0
        )
    }
}
