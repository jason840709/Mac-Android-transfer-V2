import Foundation
import XCTest
@testable import MTPBridgeCore

final class FilePromiseDestinationLayoutTests: XCTestCase {
    func testRemoteRootUsesTheExactFinderURL() {
        let exact = URL(fileURLWithPath: "/Users/example/Downloads/report.pdf")
        XCTAssertEqual(
            FilePromiseDestinationLayout.targetURL(
                exactDestinationURL: exact,
                relativeComponents: [],
                isDirectory: false
            ),
            exact
        )
    }

    func testFolderChildrenAreAppendedOnlyBelowThePromisedRoot() {
        let exact = URL(fileURLWithPath: "/Users/example/Downloads/Project", isDirectory: true)
        XCTAssertEqual(
            FilePromiseDestinationLayout.targetURL(
                exactDestinationURL: exact,
                relativeComponents: ["Notes", "readme.txt"],
                isDirectory: false
            ).path,
            "/Users/example/Downloads/Project/Notes/readme.txt"
        )
    }

    func testFinderCollisionResolvedNameIsNotReplacedByTheRemoteName() {
        let exact = URL(fileURLWithPath: "/Users/example/Downloads/report 2.pdf")
        XCTAssertEqual(
            FilePromiseDestinationLayout.targetURL(
                exactDestinationURL: exact,
                relativeComponents: [],
                isDirectory: false
            ).lastPathComponent,
            "report 2.pdf"
        )
    }
}
