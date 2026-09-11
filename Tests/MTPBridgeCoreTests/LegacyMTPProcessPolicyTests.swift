import XCTest
@testable import MTPBridgeCore

final class LegacyMTPProcessPolicyTests: XCTestCase {
    func testVisibleAndroidFileTransferViewerBlocksMTPSession() {
        XCTAssertEqual(
            LegacyMTPProcessPolicy.role(for: "com.google.android.mtpviewer"),
            .blockingViewer
        )
        XCTAssertTrue(
            LegacyMTPProcessPolicy.blocksMTPSession(bundleIdentifier: "com.google.android.mtpviewer")
        )
    }

    func testBackgroundAndroidFileTransferAgentIsPassiveObserver() {
        XCTAssertEqual(
            LegacyMTPProcessPolicy.role(for: "com.google.android.mtpagent"),
            .passiveObserver
        )
        XCTAssertFalse(
            LegacyMTPProcessPolicy.blocksMTPSession(bundleIdentifier: "com.google.android.mtpagent")
        )
    }

    func testUnrelatedApplicationDoesNotBlock() {
        XCTAssertEqual(
            LegacyMTPProcessPolicy.role(for: "example.unrelated"),
            .unrelated
        )
        XCTAssertFalse(
            LegacyMTPProcessPolicy.blocksMTPSession(bundleIdentifier: "example.unrelated")
        )
    }
}
