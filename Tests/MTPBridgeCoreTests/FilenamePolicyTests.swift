import XCTest
@testable import MTPBridgeCore

final class FilenamePolicyTests: XCTestCase {
    func testRejectsUnsafeNames() {
        XCTAssertThrowsError(try FilenamePolicy.validate(""))
        XCTAssertThrowsError(try FilenamePolicy.validate(".."))
        XCTAssertThrowsError(try FilenamePolicy.validate("a/b"))
        XCTAssertThrowsError(try FilenamePolicy.validate("a:b"))
        XCTAssertThrowsError(try FilenamePolicy.validate("a\u{0}b"))
    }

    func testTemporaryNamePreservesExtensionAndLimit() {
        let name = FilenamePolicy.temporaryUploadName(
            finalName: String(repeating: "長", count: 200) + ".mov",
            token: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        )
        XCTAssertTrue(name.hasPrefix(".mtpbridge-upload-01234567-"))
        XCTAssertTrue(name.hasSuffix(".mov"))
        XCTAssertLessThanOrEqual(name.lengthOfBytes(using: .utf8), FilenamePolicy.maximumUTF8Bytes)
    }

    func testSanitizesPathSeparators() {
        XCTAssertEqual(FilenamePolicy.sanitized("a/b:c"), "a-b-c")
    }

    func testUniqueNamePreservesExtensionAndLimit() {
        let proposed = String(repeating: "檔", count: 100) + ".jpg"
        let result = FilenamePolicy.uniqueName(proposed, index: 12)
        XCTAssertTrue(result.hasSuffix(" (12).jpg"))
        XCTAssertLessThanOrEqual(result.lengthOfBytes(using: .utf8), FilenamePolicy.maximumUTF8Bytes)
    }

    func testHiddenNameHandlesPathologicalExtension() {
        let proposed = "x." + String(repeating: "a", count: 235)
        let result = FilenamePolicy.temporaryUploadName(
            finalName: proposed,
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
        XCTAssertLessThanOrEqual(result.lengthOfBytes(using: .utf8), FilenamePolicy.maximumUTF8Bytes)
        XCTAssertTrue(result.hasPrefix(".mtpbridge-upload-00000000-"))
    }

    func testCollisionKeyIsStableAcrossCaseWidthAndDiacritics() {
        XCTAssertEqual(FilenamePolicy.collisionKey("Résumé"), FilenamePolicy.collisionKey("RESUME"))
        XCTAssertEqual(FilenamePolicy.collisionKey("Ｆｏｏ"), FilenamePolicy.collisionKey("foo"))
    }

    func testStableTokenIsDeterministicAndFixedWidth() {
        let first = FilenamePolicy.stableToken(String(repeating: "長", count: 200))
        let second = FilenamePolicy.stableToken(String(repeating: "長", count: 200))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, FilenamePolicy.stableToken("different"))
    }

    func testFinderPromiseNameKeepsExtensionExactlyOnce() {
        XCTAssertEqual(FilenamePolicy.promisedFileName("report.pdf"), "report.pdf")
        XCTAssertEqual(FilenamePolicy.promisedFileName("notes.txt"), "notes.txt")
        XCTAssertFalse(FilenamePolicy.promisedFileName("report.pdf").hasSuffix(".pdf.pdf"))
    }

}
