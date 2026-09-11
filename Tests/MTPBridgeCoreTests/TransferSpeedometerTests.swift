import XCTest
@testable import MTPBridgeCore

final class TransferSpeedometerTests: XCTestCase {
    func testRollingSpeed() {
        var meter = TransferSpeedometer(window: 3)
        XCTAssertEqual(meter.record(bytes: 0, at: 0), 0)
        XCTAssertEqual(meter.record(bytes: 1_000, at: 1), 1_000, accuracy: 0.001)
        XCTAssertEqual(meter.record(bytes: 3_000, at: 2), 1_500, accuracy: 0.001)
    }

    func testCounterResetDoesNotUnderflow() {
        var meter = TransferSpeedometer(window: 3)
        _ = meter.record(bytes: 2_000, at: 1)
        XCTAssertEqual(meter.record(bytes: 100, at: 2), 0)
    }
}
