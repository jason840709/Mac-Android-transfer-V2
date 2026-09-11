import XCTest
@testable import MTPBridgeCore

final class DeviceAgentLaunchCandidatePolicyTests: XCTestCase {
    private let bundleID = "io.github.mtpbridge.MTPBridge"
    private let packageID = "0.7.0-device-launch-r1"

    func testRejectsDeletedContainingApplicationAndUsesCurrentLaunchServicesMatch() {
        let staleContaining = candidate(
            "/old/Android 傳輸 V2.app",
            build: "21",
            source: .containingBundle,
            exists: false
        )
        let current = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .launchServices
        )

        let result = ordered(containing: staleContaining, workspace: [current])

        XCTAssertEqual(result.map(\.path), [current.path])
    }

    func testPrefersContainingApplicationWhenItMatchesHelperIdentity() {
        let containing = candidate(
            "/Downloads/current/dist/Android 傳輸 V2.app",
            build: "22",
            source: .containingBundle
        )
        let applicationsCopy = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .launchServices
        )

        let result = ordered(containing: containing, workspace: [applicationsCopy])

        XCTAssertEqual(result.map(\.path), [containing.path, applicationsCopy.path])
    }

    func testPrefersMatchingPackageFromLaunchServicesOverSameBuildHotfix() {
        let containing = candidate(
            "/Downloads/other-hotfix/Android 傳輸 V2.app",
            build: "22",
            packageIdentity: "0.7.0-other-r1",
            source: .containingBundle
        )
        let current = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .launchServices
        )

        let result = ordered(containing: containing, workspace: [current])

        XCTAssertEqual(result.map(\.path), [current.path, containing.path])
    }

    func testPrefersMatchingBuildFromLaunchServicesOverMismatchedContainingApp() {
        let containing = candidate(
            "/Downloads/old/dist/Android 傳輸 V2.app",
            build: "21",
            source: .containingBundle
        )
        let current = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .launchServices
        )

        let result = ordered(containing: containing, workspace: [current])

        XCTAssertEqual(result.map(\.path), [current.path, containing.path])
    }

    func testRejectsWrongBundleIdentifierAndMissingExecutable() {
        let wrongID = DeviceAgentLaunchCandidate(
            path: "/Applications/Wrong.app",
            bundleIdentifier: "example.wrong",
            build: "22",
            packageIdentity: packageID,
            source: .launchServices,
            bundleExists: true,
            executableExists: true
        )
        let noExecutable = DeviceAgentLaunchCandidate(
            path: "/Applications/Broken.app",
            bundleIdentifier: bundleID,
            build: "22",
            packageIdentity: packageID,
            source: .launchServices,
            bundleExists: true,
            executableExists: false
        )

        let result = ordered(containing: nil, workspace: [wrongID, noExecutable])

        XCTAssertTrue(result.isEmpty)
    }

    func testDeduplicatesSameResolvedPath() {
        let containing = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .containingBundle
        )
        let launchServices = candidate(
            "/Applications/Android 傳輸 V2.app",
            build: "22",
            source: .launchServices
        )

        let result = ordered(containing: containing, workspace: [launchServices])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.source, .containingBundle)
    }

    private func ordered(
        containing: DeviceAgentLaunchCandidate?,
        workspace: [DeviceAgentLaunchCandidate]
    ) -> [DeviceAgentLaunchCandidate] {
        DeviceAgentLaunchCandidatePolicy.orderedCandidates(
            containingCandidate: containing,
            launchServicesCandidates: workspace,
            expectedBundleIdentifier: bundleID,
            helperBuild: "22",
            helperPackageIdentity: packageID
        )
    }

    private func candidate(
        _ path: String,
        build: String,
        packageIdentity: String? = nil,
        source: DeviceAgentLaunchCandidateSource,
        exists: Bool = true
    ) -> DeviceAgentLaunchCandidate {
        DeviceAgentLaunchCandidate(
            path: path,
            bundleIdentifier: bundleID,
            build: build,
            packageIdentity: packageIdentity ?? packageID,
            source: source,
            bundleExists: exists,
            executableExists: exists
        )
    }
}
