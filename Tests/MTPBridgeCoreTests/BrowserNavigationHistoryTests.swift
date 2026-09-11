import XCTest
@testable import MTPBridgeCore

final class BrowserNavigationHistoryTests: XCTestCase {
    private func location(_ id: UInt32, _ name: String = "") -> BrowserLocation {
        BrowserLocation(
            storageID: 1,
            breadcrumbs: id == mtpRootObjectID ? [] : [
                RemoteFolder(storageID: 1, objectID: id, name: name.isEmpty ? "Folder \(id)" : name)
            ]
        )
    }

    func testBackAndForwardFollowVisitedLocations() {
        var history = BrowserNavigationHistory()
        let root = location(mtpRootObjectID)
        let downloads = location(10, "Download")
        let github = location(20, "GitHub")
        history.visit(root)
        history.visit(downloads)
        history.visit(github)

        XCTAssertEqual(history.goBack(), downloads)
        XCTAssertEqual(history.goBack(), root)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), downloads)
        XCTAssertEqual(history.goForward(), github)
        XCTAssertNil(history.goForward())
    }

    func testNewVisitAfterBackClearsForwardBranch() {
        var history = BrowserNavigationHistory()
        let root = location(mtpRootObjectID)
        let first = location(10)
        let obsolete = location(20)
        let replacement = location(30)
        history.visit(root)
        history.visit(first)
        history.visit(obsolete)
        XCTAssertEqual(history.goBack(), first)

        history.visit(replacement)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.entries, [root, first, replacement])
    }

    func testDuplicateCurrentLocationIsNotAdded() {
        var history = BrowserNavigationHistory()
        let root = location(mtpRootObjectID)
        history.visit(root)
        history.visit(root)
        XCTAssertEqual(history.entries.count, 1)
    }

    func testMaximumCountDropsOldestLocations() {
        var history = BrowserNavigationHistory(maximumCount: 3)
        history.visit(location(1))
        history.visit(location(2))
        history.visit(location(3))
        history.visit(location(4))
        XCTAssertEqual(history.entries.map { $0.breadcrumbs.last?.objectID }, [2, 3, 4])
        XCTAssertEqual(history.current?.breadcrumbs.last?.objectID, 4)
    }

    func testFailedNavigationCanRestorePreviousCursor() {
        var history = BrowserNavigationHistory()
        let root = location(mtpRootObjectID)
        let downloads = location(10, "Download")
        history.visit(root)
        history.visit(downloads)

        let previousIndex = history.currentIndex
        XCTAssertEqual(history.goBack(), root)
        history.restore(index: previousIndex)

        XCTAssertEqual(history.current, downloads)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)
    }
}
