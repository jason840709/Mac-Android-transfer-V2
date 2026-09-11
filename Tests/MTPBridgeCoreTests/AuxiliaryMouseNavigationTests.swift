import XCTest
@testable import MTPBridgeCore

final class AuxiliaryMouseNavigationTests: XCTestCase {
    func testStandardLogitechSideButtons() {
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 3), .back)
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 4), .forward)
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 5), .back)
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 6), .forward)
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 7), .back)
        XCTAssertEqual(AuxiliaryMouseNavigation.action(forButtonNumber: 8), .forward)
        XCTAssertNil(AuxiliaryMouseNavigation.action(forButtonNumber: 2))
    }

    func testHorizontalSwipeMapping() {
        XCTAssertEqual(
            AuxiliaryMouseNavigation.action(forHorizontalSwipe: 1, verticalDelta: 0.1),
            .back
        )
        XCTAssertEqual(
            AuxiliaryMouseNavigation.action(forHorizontalSwipe: -1, verticalDelta: 0.1),
            .forward
        )
        XCTAssertNil(
            AuxiliaryMouseNavigation.action(forHorizontalSwipe: 0.2, verticalDelta: 0.1)
        )
        XCTAssertNil(
            AuxiliaryMouseNavigation.action(forHorizontalSwipe: 1, verticalDelta: 2)
        )
    }
}
