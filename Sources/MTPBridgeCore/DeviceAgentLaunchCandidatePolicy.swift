import Foundation

public enum DeviceAgentLaunchCandidateSource: Int, Codable, Equatable, Sendable {
    case containingBundle = 0
    case launchServices = 1
}

public struct DeviceAgentLaunchCandidate: Equatable, Sendable {
    public let path: String
    public let bundleIdentifier: String?
    public let build: String?
    public let packageIdentity: String?
    public let source: DeviceAgentLaunchCandidateSource
    public let bundleExists: Bool
    public let executableExists: Bool

    public init(
        path: String,
        bundleIdentifier: String?,
        build: String?,
        packageIdentity: String?,
        source: DeviceAgentLaunchCandidateSource,
        bundleExists: Bool,
        executableExists: Bool
    ) {
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.build = build
        self.packageIdentity = packageIdentity
        self.source = source
        self.bundleExists = bundleExists
        self.executableExists = executableExists
    }
}

public enum DeviceAgentLaunchCandidatePolicy {
    /// Returns safe launch candidates in preference order.
    ///
    /// A stale login item may continue running after the app that contained it
    /// was moved or deleted. The policy therefore rejects missing bundles and
    /// missing executables before any NSWorkspace launch is attempted. It then
    /// prefers the app embedded around the helper when it matches the helper's
    /// build, followed by Launch Services candidates with the same build.
    public static func orderedCandidates(
        containingCandidate: DeviceAgentLaunchCandidate?,
        launchServicesCandidates: [DeviceAgentLaunchCandidate],
        expectedBundleIdentifier: String,
        helperBuild: String?,
        helperPackageIdentity: String?
    ) -> [DeviceAgentLaunchCandidate] {
        let all = ([containingCandidate].compactMap { $0 } + launchServicesCandidates)
            .filter {
                $0.bundleExists &&
                    $0.executableExists &&
                    $0.bundleIdentifier == expectedBundleIdentifier
            }

        var seenPaths = Set<String>()
        let unique = all.filter { seenPaths.insert($0.path).inserted }

        func rank(_ candidate: DeviceAgentLaunchCandidate) -> Int {
            let packageMatches = helperPackageIdentity != nil &&
                candidate.packageIdentity == helperPackageIdentity
            let buildMatches = helperBuild != nil && candidate.build == helperBuild
            switch (packageMatches, buildMatches, candidate.source) {
            case (true, true, .containingBundle): return 0
            case (true, true, .launchServices): return 1
            case (_, true, .containingBundle): return 2
            case (_, true, .launchServices): return 3
            case (_, false, .containingBundle): return 4
            case (_, false, .launchServices): return 5
            }
        }

        return unique.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(lhs.element)
            let rhsRank = rank(rhs.element)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
