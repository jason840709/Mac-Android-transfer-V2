#if canImport(AppKit) && canImport(ServiceManagement)
import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class DeviceInsertionService {
    enum RegistrationState: Equatable {
        case enabled
        case enabledCompatibility
        case disabled
        case requiresApproval
        case unavailable
        case failed(String)
    }

    private(set) var desiredEnabled: Bool
    private(set) var state: RegistrationState = .disabled

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let preferenceKey = "AndroidTransferV2.DeviceInsertionWatcherEnabled"
    @ObservationIgnored private let backendKey = "AndroidTransferV2.DeviceInsertionRegistrationBackendV2"
    @ObservationIgnored private let registrationTokenKey = "AndroidTransferV2.DeviceInsertionRegistrationTokenV2"
    @ObservationIgnored private lazy var modernService = SMAppService.loginItem(
        identifier: DeviceInsertionIdentifiers.helperBundleIdentifier
    )

    init() {
        if defaults.object(forKey: preferenceKey) == nil {
            desiredEnabled = true
        } else {
            desiredEnabled = defaults.bool(forKey: preferenceKey)
        }
    }

    func start() {
        removeRetiredDeviceInsertionImplementations()
        migrateStaleDeviceAgentRegistrationIfNeeded()
        if desiredEnabled {
            enableWatcher()
        } else {
            disableWatcher()
        }
    }

    func setEnabled(_ enabled: Bool) {
        desiredEnabled = enabled
        defaults.set(enabled, forKey: preferenceKey)
        if enabled {
            removeRetiredDeviceInsertionImplementations()
            migrateStaleDeviceAgentRegistrationIfNeeded()
            enableWatcher()
        } else {
            disableWatcher()
        }
    }

    func refresh() {
        guard helperBundleExists else {
            state = .unavailable
            return
        }
        guard desiredEnabled else {
            state = .disabled
            return
        }

        switch modernService.status {
        case .enabled:
            state = helperIsRunningFromCurrentBundle ? .enabled : .enabledCompatibility
        case .requiresApproval:
            state = .requiresApproval
        case .notRegistered, .notFound:
            if helperIsRunningFromCurrentBundle || defaults.string(forKey: backendKey) == "legacy" {
                state = .enabledCompatibility
            } else {
                state = .disabled
            }
        @unknown default:
            state = helperIsRunningFromCurrentBundle ? .enabledCompatibility : .unavailable
        }
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    var statusText: String {
        switch state {
        case .enabled:
            return NSLocalizedString("device_watcher.status.enabled", comment: "")
        case .enabledCompatibility:
            return NSLocalizedString("device_watcher.status.enabled_compatibility", comment: "")
        case .disabled:
            return NSLocalizedString("device_watcher.status.disabled", comment: "")
        case .requiresApproval:
            return NSLocalizedString("device_watcher.status.requires_approval", comment: "")
        case .unavailable:
            return NSLocalizedString("device_watcher.status.unavailable", comment: "")
        case let .failed(message):
            return String(
                format: NSLocalizedString("device_watcher.status.failed", comment: ""),
                message
            )
        }
    }

    private var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
    }

    private var currentPackageIdentity: String {
        (Bundle.main.object(forInfoDictionaryKey: "MTPBridgePackageID") as? String) ?? "unknown-package"
    }

    private var currentMainBundlePath: String {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private var currentRegistrationToken: String {
        [currentBuild, currentPackageIdentity, currentMainBundlePath].joined(separator: "|")
    }

    private var helperBundleURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent(DeviceInsertionIdentifiers.helperBundleName, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private var helperExecutableURL: URL {
        helperBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(DeviceInsertionIdentifiers.helperExecutableName)
    }

    private var helperBundleExists: Bool {
        guard FileManager.default.fileExists(atPath: helperBundleURL.path),
              FileManager.default.isExecutableFile(atPath: helperExecutableURL.path),
              let helperBundle = Bundle(url: helperBundleURL),
              helperBundle.bundleIdentifier == DeviceInsertionIdentifiers.helperBundleIdentifier,
              helperBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == currentBuild else {
            return false
        }
        return true
    }

    private var runningHelpers: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: DeviceInsertionIdentifiers.helperBundleIdentifier
        )
    }

    private func isCurrentHelper(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL?
            .standardizedFileURL
            .resolvingSymlinksInPath() else { return false }
        guard url == helperBundleURL else { return false }

        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == DeviceInsertionIdentifiers.helperBundleIdentifier,
              let helperBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return false
        }
        return helperBuild == currentBuild
    }

    private var helperIsRunningFromCurrentBundle: Bool {
        runningHelpers.contains(where: isCurrentHelper)
    }

    private var staleHelperIsRunning: Bool {
        runningHelpers.contains { !isCurrentHelper($0) }
    }

    /// ServiceManagement registrations survive source-folder replacement. A
    /// registration is therefore current only when its build, package identity,
    /// and exact parent-app bundle path all match this running App.
    private func migrateStaleDeviceAgentRegistrationIfNeeded() {
        let recordedToken = defaults.string(forKey: registrationTokenKey)
        let registrationIdentityUnknown = recordedToken == nil && modernService.status == .enabled
        let needsMigration = registrationIdentityUnknown ||
            recordedToken != currentRegistrationToken ||
            staleHelperIsRunning
        guard needsMigration else { return }

        if modernService.status == .enabled || modernService.status == .requiresApproval {
            try? modernService.unregister()
        }
        _ = mtp_legacy_device_agent_set_enabled(0)

        for application in runningHelpers {
            _ = application.terminate()
            if !application.isTerminated {
                _ = application.forceTerminate()
            }
        }

        defaults.removeObject(forKey: backendKey)
        defaults.removeObject(forKey: registrationTokenKey)
    }

    private func recordCurrentRegistration(backend: String) {
        defaults.set(backend, forKey: backendKey)
        defaults.set(currentRegistrationToken, forKey: registrationTokenKey)
    }

    private func enableWatcher() {
        guard helperBundleExists else {
            state = .unavailable
            return
        }

        launchHelperForCurrentSession()

        var shouldTryCompatibilityRegistration = false
        do {
            switch modernService.status {
            case .enabled:
                recordCurrentRegistration(backend: "modern")
                refresh()
                return
            case .requiresApproval:
                recordCurrentRegistration(backend: "modern")
                state = .requiresApproval
                return
            case .notRegistered:
                try modernService.register()
                switch modernService.status {
                case .enabled:
                    recordCurrentRegistration(backend: "modern")
                    state = .enabled
                    return
                case .requiresApproval:
                    recordCurrentRegistration(backend: "modern")
                    state = .requiresApproval
                    return
                case .notRegistered, .notFound:
                    shouldTryCompatibilityRegistration = true
                @unknown default:
                    shouldTryCompatibilityRegistration = true
                }
            case .notFound:
                shouldTryCompatibilityRegistration = true
            @unknown default:
                shouldTryCompatibilityRegistration = true
            }
        } catch {
            shouldTryCompatibilityRegistration = true
        }

        if shouldTryCompatibilityRegistration && mtp_legacy_device_agent_set_enabled(1) == 1 {
            recordCurrentRegistration(backend: "legacy")
            state = .enabledCompatibility
            launchHelperForCurrentSession()
            return
        }

        if helperIsRunningFromCurrentBundle {
            recordCurrentRegistration(backend: "session")
            state = .enabledCompatibility
        } else {
            state = .failed(NSLocalizedString("device_watcher.registration_failed", comment: ""))
        }
    }

    private func disableWatcher() {
        if modernService.status == .enabled || modernService.status == .requiresApproval {
            try? modernService.unregister()
        }
        _ = mtp_legacy_device_agent_set_enabled(0)
        defaults.removeObject(forKey: backendKey)
        defaults.removeObject(forKey: registrationTokenKey)
        for application in runningHelpers {
            _ = application.terminate()
        }
        state = .disabled
    }

    private func launchHelperForCurrentSession() {
        guard helperBundleExists else { return }
        if helperIsRunningFromCurrentBundle { return }

        for application in runningHelpers where !isCurrentHelper(application) {
            _ = application.terminate()
            if !application.isTerminated {
                _ = application.forceTerminate()
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: helperBundleURL, configuration: configuration) { _, error in
            if let error {
                let message = "Android Transfer V2 could not start the hidden device agent: \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }

    private func removeRetiredDeviceInsertionImplementations() {
        let retiredIdentifiers = [
            DeviceInsertionIdentifiers.retiredDeviceAgentBundleIdentifier,
            DeviceInsertionIdentifiers.retiredLoginItemBundleIdentifier,
        ]

        for identifier in retiredIdentifiers {
            let retired = SMAppService.loginItem(identifier: identifier)
            if retired.status == .enabled || retired.status == .requiresApproval {
                try? retired.unregister()
            }
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) {
                _ = application.terminate()
                if !application.isTerminated {
                    _ = application.forceTerminate()
                }
            }
        }

        _ = mtp_legacy_retired_device_agent_set_enabled(0)
        _ = mtp_legacy_retired_auto_launch_set_enabled(0)
        defaults.removeObject(forKey: "AndroidTransferV2.AutoLaunchEnabled")
        defaults.removeObject(forKey: "AndroidTransferV2.DeviceInsertionRegistrationBackend")
        defaults.removeObject(forKey: "AndroidTransferV2.DeviceInsertionRegisteredBuild")
    }
}
#endif
#if !(canImport(AppKit) && canImport(ServiceManagement))
import Foundation
import Observation

@MainActor
@Observable
final class DeviceInsertionService {
    enum RegistrationState: Equatable {
        case enabled, enabledCompatibility, disabled, requiresApproval, unavailable, failed(String)
    }
    private(set) var desiredEnabled = true
    private(set) var state: RegistrationState = .unavailable
    func start() {}
    func setEnabled(_ enabled: Bool) { desiredEnabled = enabled }
    func refresh() {}
    func openLoginItemSettings() {}
    var statusText: String { "" }
}
#endif
