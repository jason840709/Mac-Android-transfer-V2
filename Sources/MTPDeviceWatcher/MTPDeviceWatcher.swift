#if canImport(AppKit)
import AppKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let mainBundleIdentifier = "io.github.mtpbridge.MTPBridge"

private func containingMainApplicationURL() -> URL? {
    // Helper layout:
    // Main.app/Contents/Library/LoginItems/Android 傳輸 V2 裝置偵測器.app
    let helperBundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    let loginItemsDirectory = helperBundleURL.deletingLastPathComponent()
    let libraryDirectory = loginItemsDirectory.deletingLastPathComponent()
    let contentsDirectory = libraryDirectory.deletingLastPathComponent()
    let mainAppURL = contentsDirectory.deletingLastPathComponent()
    guard mainAppURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
        return nil
    }
    return mainAppURL
}

private func inspectApplicationCandidate(
    at url: URL,
    source: DeviceAgentLaunchCandidateSource
) -> DeviceAgentLaunchCandidate {
    let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory = ObjCBool(false)
    let bundleExists = FileManager.default.fileExists(
        atPath: normalizedURL.path,
        isDirectory: &isDirectory
    ) && isDirectory.boolValue

    let bundle = bundleExists ? Bundle(url: normalizedURL) : nil
    let executableExists: Bool
    if let executableURL = bundle?.executableURL {
        executableExists = FileManager.default.isExecutableFile(atPath: executableURL.path)
    } else {
        executableExists = false
    }

    return DeviceAgentLaunchCandidate(
        path: normalizedURL.path,
        bundleIdentifier: bundle?.bundleIdentifier,
        build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        packageIdentity: bundle?.object(forInfoDictionaryKey: "MTPBridgePackageID") as? String,
        source: source,
        bundleExists: bundleExists,
        executableExists: executableExists
    )
}

@MainActor
private func launchCandidates() -> [URL] {
    let containing = containingMainApplicationURL().map {
        inspectApplicationCandidate(at: $0, source: .containingBundle)
    }
    let workspaceCandidates = NSWorkspace.shared
        .urlsForApplications(withBundleIdentifier: mainBundleIdentifier)
        .map { inspectApplicationCandidate(at: $0, source: .launchServices) }
    let helperBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    let helperPackageIdentity = Bundle.main.object(forInfoDictionaryKey: "MTPBridgePackageID") as? String

    return DeviceAgentLaunchCandidatePolicy.orderedCandidates(
        containingCandidate: containing,
        launchServicesCandidates: workspaceCandidates,
        expectedBundleIdentifier: mainBundleIdentifier,
        helperBuild: helperBuild,
        helperPackageIdentity: helperPackageIdentity
    ).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
}

private func logAgentMessage(_ message: String) {
    let line = "Android Transfer V2 device agent: \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

@MainActor
private func tryLaunchMainApplication(candidates: [URL], index: Int = 0) {
    guard index < candidates.count else {
        logAgentMessage(
            "no valid main application bundle was found; ignored the insertion instead of opening a missing file"
        )
        return
    }

    let appURL = candidates[index]
    let rechecked = inspectApplicationCandidate(at: appURL, source: .launchServices)
    guard rechecked.bundleExists,
          rechecked.executableExists,
          rechecked.bundleIdentifier == mainBundleIdentifier else {
        tryLaunchMainApplication(candidates: candidates, index: index + 1)
        return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.createsNewApplicationInstance = false

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
        Task { @MainActor in
            if let application {
                _ = application.activate(options: [.activateAllWindows])
                return
            }
            if let error {
                logAgentMessage("could not open \(appURL.path): \(error)")
            }
            tryLaunchMainApplication(candidates: candidates, index: index + 1)
        }
    }
}

@MainActor
private func launchOrActivateMainApplication() {
    let runningApplications = NSRunningApplication.runningApplications(
        withBundleIdentifier: mainBundleIdentifier
    )
    if let running = runningApplications.first {
        _ = running.activate(options: [.activateAllWindows])
        return
    }

    tryLaunchMainApplication(candidates: launchCandidates())
}

private let deviceInsertedCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
    Task { @MainActor in
        launchOrActivateMainApplication()
    }
}

@main
private enum MTPDeviceAgentMain {
    static func main() {
        let result = mtp_device_watcher_run(deviceInsertedCallback, nil)
        if result != 0 {
            logAgentMessage("setup failed: \(result)")
            #if canImport(Darwin)
            Darwin.exit(EXIT_FAILURE)
            #else
            Glibc.exit(EXIT_FAILURE)
            #endif
        }
    }
}
#endif
