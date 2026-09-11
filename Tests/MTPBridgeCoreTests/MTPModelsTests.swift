import XCTest
@testable import MTPBridgeCore

final class MTPModelsTests: XCTestCase {
    func testStorageFractionIsClamped() {
        XCTAssertEqual(MTPStorage(id: 1, name: "A", volumeIdentifier: "", capacity: 100, freeSpace: 25, isReadOnly: false).usedFraction, 0.75)
        XCTAssertEqual(MTPStorage(id: 1, name: "A", volumeIdentifier: "", capacity: 100, freeSpace: 120, isReadOnly: false).usedFraction, 0)
    }

    func testTransferJobRoundTrip() throws {
        let source = MTPObject(id: 7, parentID: 2, storageID: 1, name: "photo.jpg", size: 10, modificationDate: nil, isFolder: false, fileType: 0)
        let job = TransferJob(
            request: .download(source: source, destination: .init(directoryPath: "/tmp", securityScopedBookmark: nil)),
            deviceIdentity: MTPDeviceIdentity(
                vendorID: 0x18D1,
                productID: 0x4EE1,
                manufacturer: "Google",
                model: "Pixel",
                serialNumber: "ABC123"
            ),
            displayName: source.name,
            direction: .download
        )
        let data = try JSONEncoder().encode(job)
        XCTAssertEqual(try JSONDecoder().decode(TransferJob.self, from: data), job)
    }

    func testTransferPhaseAndCreationDateRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = created.addingTimeInterval(60)
        let source = MTPObject(
            id: 8,
            parentID: 2,
            storageID: 1,
            name: "report.pdf",
            size: 20,
            creationDate: created,
            modificationDate: modified,
            isFolder: false,
            fileType: 0
        )
        var job = TransferJob(
            request: .download(
                source: source,
                destination: .init(directoryPath: "/tmp", securityScopedBookmark: nil)
            ),
            displayName: source.name,
            direction: .download
        )
        job.phase = .finalizing

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: data)
        XCTAssertEqual(decoded, job)
        guard case let .download(decodedSource, _) = decoded.request else {
            return XCTFail("Expected a download request")
        }
        XCTAssertEqual(decodedSource.creationDate, created)
        XCTAssertEqual(decodedSource.modificationDate, modified)
        XCTAssertEqual(decoded.phase, .finalizing)
    }

    func testLegacyLocalTransferDestinationDefaultsToDirectoryPlacement() throws {
        let json = #"{"directoryPath":"/tmp/Downloads","securityScopedBookmark":null,"preferredTopLevelName":"report.pdf"}"#.data(using: .utf8)!
        let destination = try JSONDecoder().decode(LocalTransferDestination.self, from: json)
        XCTAssertNil(destination.placement)
        XCTAssertEqual(destination.effectivePlacement, .insideDirectory)
    }

    func testLegacyRemoteTransferDestinationDecodesWithoutParentPath() throws {
        let json = #"{"storageID":7,"parentObjectID":321}"#.data(using: .utf8)!
        let destination = try JSONDecoder().decode(RemoteTransferDestination.self, from: json)
        XCTAssertEqual(destination.storageID, 7)
        XCTAssertEqual(destination.parentObjectID, 321)
        XCTAssertNil(destination.parentPath)
    }

    func testExactFilePromiseDestinationRoundTrip() throws {
        let destination = LocalTransferDestination(
            directoryPath: "/Users/example/Downloads/report.pdf",
            securityScopedBookmark: nil,
            preferredTopLevelName: "report.pdf",
            placement: .exactItem
        )
        let data = try JSONEncoder().encode(destination)
        let decoded = try JSONDecoder().decode(LocalTransferDestination.self, from: data)
        XCTAssertEqual(decoded, destination)
        XCTAssertEqual(decoded.effectivePlacement, .exactItem)
        XCTAssertEqual(decoded.directoryPath, "/Users/example/Downloads/report.pdf")
    }

    func testPartialDownloadFingerprintRequiresStableIdentityAndTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let object = MTPObject(
            id: 42,
            parentID: 2,
            storageID: 1,
            name: "archive.zip",
            size: 8_192,
            modificationDate: date,
            isFolder: false,
            fileType: 0
        )
        let fingerprint = PartialDownloadFingerprint(object: object)
        XCTAssertTrue(fingerprint.safelyMatches(object))

        var changed = object
        changed.size += 1
        XCTAssertFalse(fingerprint.safelyMatches(changed))

        changed = object
        changed.modificationDate = date.addingTimeInterval(3)
        XCTAssertFalse(fingerprint.safelyMatches(changed))
    }

    func testPartialDownloadFingerprintRefusesResumeWithoutTimestamp() {
        let object = MTPObject(
            id: 42,
            parentID: 2,
            storageID: 1,
            name: "archive.zip",
            size: 8_192,
            modificationDate: nil,
            isFolder: false,
            fileType: 0
        )
        XCTAssertFalse(PartialDownloadFingerprint(object: object).safelyMatches(object))
    }

    func testDeviceIdentityUsesSerialNumberWhenAvailable() {
        let candidate = MTPDeviceCandidate(
            busLocation: 1,
            deviceNumber: 2,
            vendorID: 0x18D1,
            productID: 0x4EE1,
            vendor: "Google",
            product: "Pixel"
        )
        let expected = MTPDeviceIdentity(
            vendorID: candidate.vendorID,
            productID: candidate.productID,
            manufacturer: "Google",
            model: "Pixel",
            serialNumber: "ABC123"
        )
        let matching = MTPDeviceInfo(
            manufacturer: "Google",
            model: "Pixel",
            serialNumber: "ABC123",
            friendlyName: "Pixel",
            deviceVersion: "1",
            supportsPartialDownload: true,
            supportsPartialUpload: false,
            supportsMove: true
        )
        var different = matching
        different.serialNumber = "OTHER"
        var caseChanged = matching
        caseChanged.serialNumber = "abc123"
        XCTAssertTrue(expected.matches(candidate: candidate, info: matching))
        XCTAssertFalse(expected.matches(candidate: candidate, info: different))
        XCTAssertFalse(expected.matches(candidate: candidate, info: caseChanged))
    }

    func testDeviceIdentityFallsBackToModelWhenSerialIsUnavailable() {
        let candidate = MTPDeviceCandidate(
            busLocation: 1,
            deviceNumber: 2,
            vendorID: 0x04E8,
            productID: 0x6860,
            vendor: "Samsung",
            product: "Android"
        )
        let expected = MTPDeviceIdentity(
            vendorID: candidate.vendorID,
            productID: candidate.productID,
            manufacturer: "Samsung",
            model: "Galaxy",
            serialNumber: ""
        )
        let info = MTPDeviceInfo(
            manufacturer: "SAMSUNG",
            model: "Galaxy",
            serialNumber: "",
            friendlyName: "Phone",
            deviceVersion: "1",
            supportsPartialDownload: false,
            supportsPartialUpload: false,
            supportsMove: false
        )
        XCTAssertTrue(expected.matches(candidate: candidate, info: info))
    }

}
