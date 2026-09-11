#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation

private struct AppModelError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum ConnectionState: Equatable {
    case disconnected
    case searching
    case connecting
    case connected
    case failed(String)
}

typealias BrowserSort = MTPObjectSortKey

extension MTPObjectSortKey {
    var title: String {
        switch self {
        case .name: return NSLocalizedString("sort.name", comment: "")
        case .type: return NSLocalizedString("sort.type", comment: "")
        case .size: return NSLocalizedString("sort.size", comment: "")
        case .created: return NSLocalizedString("sort.created", comment: "")
        case .modified: return NSLocalizedString("sort.modified", comment: "")
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var connectionState: ConnectionState = .disconnected
    private(set) var deviceInfo: MTPDeviceInfo?
    private(set) var storages: [MTPStorage] = []
    var selectedStorageID: UInt32?
    private(set) var breadcrumbs: [RemoteFolder] = []
    private(set) var objects: [MTPObject] = []
    private(set) var pendingCreationDateIDs: Set<UInt32> = []
    var selection: Set<UInt32> = []
    var searchText = ""
    var sort: BrowserSort = .name
    var sortAscending = true
    private(set) var isLoadingFolder = false
    private(set) var isMutating = false
    var presentedError: String?
    private(set) var mtpAccessConflict: MTPAccessConflict?
    let transfers = TransferCoordinator()

    @ObservationIgnored private var client: LibMTPClient?
    @ObservationIgnored private var lastCandidate: MTPDeviceCandidate?
    @ObservationIgnored private let presenceMonitor = USBPresenceMonitor()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var creationDateTask: Task<Void, Never>?
    @ObservationIgnored private var creationDateGeneration = 0
    @ObservationIgnored private var connectionAttemptInFlight = false
    @ObservationIgnored private var connectionGeneration = 0
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var navigationHistory = BrowserNavigationHistory()
    @ObservationIgnored private let navigationInputMonitor = NavigationInputMonitor()
    @ObservationIgnored private var mtpAccessConflictMonitorTask: Task<Void, Never>?

    var selectedStorage: MTPStorage? {
        storages.first { $0.id == selectedStorageID }
    }

    private var currentDeviceIdentity: MTPDeviceIdentity? {
        guard let candidate = lastCandidate, let info = deviceInfo else { return nil }
        return MTPDeviceIdentity(candidate: candidate, info: info)
    }

    var currentFolderID: UInt32 {
        breadcrumbs.last?.objectID ?? mtpRootObjectID
    }

    var currentFolderName: String {
        breadcrumbs.last?.name ?? selectedStorage?.name ?? NSLocalizedString("browser.root", comment: "")
    }

    var selectedObjects: [MTPObject] {
        objects.filter { selection.contains($0.id) }
    }

    var displayedObjects: [MTPObject] {
        let filtered = searchText.isEmpty
            ? objects
            : objects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return MTPObjectSorter.sorted(filtered, by: sort, ascending: sortAscending)
    }

    var canWrite: Bool {
        connectionState == .connected && selectedStorage?.isReadOnly == false && !isMutating
    }

    var canRunBrowserAction: Bool {
        connectionState == .connected && !isLoadingFolder && !isMutating
    }

    var canNavigateBack: Bool {
        canRunBrowserAction && navigationHistory.canGoBack
    }

    var canNavigateForward: Bool {
        canRunBrowserAction && navigationHistory.canGoForward
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        navigationInputMonitor.start(
            canGoBack: { [weak self] in self?.canNavigateBack ?? false },
            canGoForward: { [weak self] in self?.canNavigateForward ?? false },
            goBack: { [weak self] in await self?.navigateBack() },
            goForward: { [weak self] in await self?.navigateForward() }
        )
        startMTPAccessConflictMonitor()
        transfers.configure(
            acquireClient: { [weak self] in
                guard let self else {
                    throw AppModelError(message: NSLocalizedString("error.no_open_device", comment: ""))
                }
                return try await self.acquireConnectedClient()
            },
            reconnectClient: { [weak self] in
                guard let self else {
                    throw AppModelError(message: NSLocalizedString("error.no_open_device", comment: ""))
                }
                return try await self.reconnectForTransfer()
            },
            remoteMutationDidFinish: { [weak self] in
                await self?.refreshAfterTransfer()
            }
        )
        await connect(silentWhenMissing: true, showActivity: true)
        if connectionState != .connected {
            startReconnectLoop()
        }
        transfers.resumePendingJobs()
    }

    func connect(
        silentWhenMissing: Bool = false,
        preserveNavigation: Bool = false,
        showActivity: Bool = true
    ) async {
        guard !connectionAttemptInFlight else { return }
        if updateMTPAccessConflict() {
            connectionState = .disconnected
            return
        }
        if connectionState == .connected, client != nil { return }
        connectionAttemptInFlight = true
        defer { connectionAttemptInFlight = false }

        if showActivity {
            connectionState = silentWhenMissing ? .searching : .connecting
        }
        do {
            let candidates = try await LibMTPClient.detectDevices()
            guard !candidates.isEmpty else {
                connectionState = .disconnected
                return
            }

            // Android changes USB gadget configuration when the user switches
            // from charge-only to File Transfer. Give that re-enumeration a
            // short settling window, then re-check both ownership conflicts
            // and the device list before we claim the MTP interface.
            try await Task.sleep(for: .milliseconds(650))
            if updateMTPAccessConflict() {
                connectionState = .disconnected
                return
            }
            let settledCandidates = try await LibMTPClient.detectDevices()
            guard !settledCandidates.isEmpty else {
                connectionState = .disconnected
                return
            }
            if showActivity { connectionState = .connecting }
            _ = try await openFirstAvailable(
                settledCandidates,
                preserveNavigation: preserveNavigation
            )
        } catch {
            if showActivity {
                connectionState = .failed(error.localizedDescription)
            } else {
                connectionState = .disconnected
            }
            if !silentWhenMissing { presentedError = error.localizedDescription }
        }
    }

    func temporarilyStopLegacyAndroidFileTransfer() async {
        _ = MTPAccessArbiter.requestTemporaryTermination()

        // The legacy background Agent is intentionally allowed to remain.
        // It only watches for insertion and launches the old visible viewer;
        // the viewer is the process that owns a real MTP session. Poll only
        // for that visible viewer to disappear, then reconnect immediately.
        for _ in 0..<8 {
            if !updateMTPAccessConflict() {
                await connect(silentWhenMissing: true, preserveNavigation: true, showActivity: true)
                if connectionState != .connected {
                    startReconnectLoop()
                }
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }

        presentedError = NSLocalizedString("connection.conflict.could_not_stop", comment: "")
    }

    func disconnect() async {
        stopReconnectLoop()
        presenceMonitor.stop()
        let previousClient = client
        transitionToDisconnected(preserveNavigation: false)
        transfers.deviceDidDisconnect()
        lastCandidate = nil
        if let previousClient { await previousClient.close() }
    }

    func selectStorage(_ storage: MTPStorage) async {
        guard canRunBrowserAction else { return }
        await navigate(
            to: BrowserLocation(storageID: storage.id, breadcrumbs: []),
            recordingVisit: true
        )
    }

    func open(_ object: MTPObject) async {
        guard canRunBrowserAction, object.isFolder, let storageID = selectedStorageID else { return }
        let nextBreadcrumbs = breadcrumbs + [
            RemoteFolder(storageID: object.storageID, objectID: object.id, name: object.name)
        ]
        await navigate(
            to: BrowserLocation(storageID: storageID, breadcrumbs: nextBreadcrumbs),
            recordingVisit: true
        )
    }

    func navigateUp() async {
        guard canRunBrowserAction, !breadcrumbs.isEmpty, let storageID = selectedStorageID else { return }
        await navigate(
            to: BrowserLocation(storageID: storageID, breadcrumbs: Array(breadcrumbs.dropLast())),
            recordingVisit: true
        )
    }

    func navigateBack() async {
        guard canNavigateBack else { return }
        let previousIndex = navigationHistory.currentIndex
        guard let location = navigationHistory.goBack() else { return }
        if !(await applyNavigationLocation(location)) {
            navigationHistory.restore(index: previousIndex)
        }
    }

    func navigateForward() async {
        guard canNavigateForward else { return }
        let previousIndex = navigationHistory.currentIndex
        guard let location = navigationHistory.goForward() else { return }
        if !(await applyNavigationLocation(location)) {
            navigationHistory.restore(index: previousIndex)
        }
    }

    func navigate(toBreadcrumb index: Int) async {
        guard canRunBrowserAction, let storageID = selectedStorageID else { return }
        let nextBreadcrumbs: [RemoteFolder]
        if index < 0 {
            nextBreadcrumbs = []
        } else {
            guard breadcrumbs.indices.contains(index) else { return }
            nextBreadcrumbs = Array(breadcrumbs.prefix(index + 1))
        }
        await navigate(
            to: BrowserLocation(storageID: storageID, breadcrumbs: nextBreadcrumbs),
            recordingVisit: true
        )
    }

    func refresh() async {
        guard let client else { return }
        do {
            storages = try await client.readStorages()
            if selectedStorage == nil {
                selectedStorageID = storages.first?.id
                breadcrumbs = []
            }
            await loadCurrentFolder()
        } catch {
            handle(error)
        }
    }

    func createFolder(named name: String) async {
        guard canWrite, let client, let storageID = selectedStorageID else { return }
        do {
            try FilenamePolicy.validate(name)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedKey = FilenamePolicy.collisionKey(trimmed)
            guard !objects.contains(where: { FilenamePolicy.collisionKey($0.name) == requestedKey }) else {
                throw AppModelError(
                    message: String(
                        format: NSLocalizedString("error.name_exists", comment: ""),
                        trimmed
                    )
                )
            }
            isMutating = true
            defer { isMutating = false }
            _ = try await client.createFolder(
                name: trimmed,
                storageID: storageID,
                parentID: currentFolderID
            )
            await loadCurrentFolder()
        } catch {
            handle(error)
        }
    }

    func renameSelected(to newName: String) async {
        guard canWrite, selection.count == 1, let object = selectedObjects.first, let client else { return }
        do {
            try FilenamePolicy.validate(newName)
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedKey = FilenamePolicy.collisionKey(trimmed)
            guard !objects.contains(where: {
                $0.id != object.id && FilenamePolicy.collisionKey($0.name) == requestedKey
            }) else {
                throw AppModelError(
                    message: String(
                        format: NSLocalizedString("error.name_exists", comment: ""),
                        trimmed
                    )
                )
            }
            isMutating = true
            defer { isMutating = false }
            try await client.renameObject(id: object.id, to: trimmed)
            await loadCurrentFolder()
        } catch {
            handle(error)
        }
    }

    func deleteSelected() async {
        await delete(objectIDs: selection)
    }

    func delete(objectIDs: Set<UInt32>) async {
        guard canWrite, !objectIDs.isEmpty, let client else { return }
        let targets = objects.filter { objectIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            for target in targets {
                try await deleteRecursively(target, client: client)
            }
            await loadCurrentFolder()
            storages = try await client.readStorages()
        } catch {
            handle(error)
        }
    }

    func chooseAndEnqueueUploads() async {
        guard canWrite else { return }
#if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("upload.panel.title", comment: "")
        panel.prompt = NSLocalizedString("upload.panel.prompt", comment: "")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }
        enqueueUploads(urls: panel.urls)
#endif
    }

    func enqueueUploads(urls: [URL]) {
        guard canWrite,
              let storageID = selectedStorageID,
              let deviceIdentity = currentDeviceIdentity,
              !urls.isEmpty else { return }
        do {
            let destination = RemoteTransferDestination(
                storageID: storageID,
                parentObjectID: currentFolderID,
                parentPath: breadcrumbs.map(\.name)
            )
            let preferredNames = preferredRemoteNames(for: urls)
            let jobs = try zip(urls, preferredNames).map { url, preferredName -> TransferJob in
                let bookmark = try BookmarkStore.makeBookmark(for: url)
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                let size = values?.isRegularFile == true
                    ? UInt64(max(0, values?.fileSize ?? 0))
                    : 0
                return TransferJob(
                    request: .upload(
                        source: LocalTransferSource(
                            path: url.path,
                            securityScopedBookmark: bookmark,
                            preferredRemoteName: preferredName
                        ),
                        destination: destination
                    ),
                    deviceIdentity: deviceIdentity,
                    displayName: preferredName,
                    direction: .upload,
                    totalBytes: size
                )
            }
            transfers.enqueue(jobs)
        } catch {
            handle(error)
        }
    }

    func chooseAndEnqueueDownloads() async {
        guard canRunBrowserAction, !selectedObjects.isEmpty else { return }
#if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("download.panel.title", comment: "")
        panel.prompt = NSLocalizedString("download.panel.prompt", comment: "")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let directory = panel.url,
              let deviceIdentity = currentDeviceIdentity else { return }
        do {
            let bookmark = try BookmarkStore.makeWritableBookmark(for: directory)
            let selected = selectedObjects
            let preferredNames = preferredLocalNames(
                for: selected,
                in: directory
            )
            let jobs = zip(selected, preferredNames).map { object, preferredName in
                let destination = LocalTransferDestination(
                    directoryPath: directory.path,
                    securityScopedBookmark: bookmark,
                    preferredTopLevelName: preferredName
                )
                return TransferJob(
                    request: .download(source: object, destination: destination),
                    deviceIdentity: deviceIdentity,
                    displayName: preferredName,
                    direction: .download,
                    totalBytes: object.isFolder ? 0 : object.size
                )
            }
            transfers.enqueue(jobs)
        } catch {
            handle(error)
        }
#endif
    }

#if canImport(AppKit)
    func fulfillFilePromise(
        object: MTPObject,
        destinationDirectory: URL,
        promisedName: String
    ) async throws {
        guard connectionState == .connected, let deviceIdentity = currentDeviceIdentity else {
            throw AppModelError(
                message: NSLocalizedString("error.no_device_connected", comment: "")
            )
        }
        let finalName = FilenamePolicy.sanitized(promisedName)
        // NSFilePromiseProvider supplies the exact final item URL, not its
        // parent directory. Marking this explicitly prevents the transfer
        // engine from appending the promised name a second time.
        let destination = LocalTransferDestination(
            directoryPath: destinationDirectory.path,
            securityScopedBookmark: nil,
            preferredTopLevelName: finalName,
            placement: .exactItem
        )
        let job = TransferJob(
            request: .download(source: object, destination: destination),
            deviceIdentity: deviceIdentity,
            displayName: finalName,
            direction: .download,
            totalBytes: object.isFolder ? 0 : object.size
        )
        try await transfers.enqueueAndWait(job)
    }
#endif

    func showInFinder(for job: TransferJob) {
        guard case let .download(source, destination) = job.request,
              let directory = try? BookmarkStore.resolve(
                bookmark: destination.securityScopedBookmark,
                fallbackPath: destination.directoryPath
              ) else { return }
        let target: URL
        switch destination.effectivePlacement {
        case .insideDirectory:
            target = directory.appendingPathComponent(
                destination.preferredTopLevelName ?? FilenamePolicy.sanitized(source.name)
            )
        case .exactItem:
            target = directory
        }
#if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([target])
#endif
    }

    private func preferredRemoteNames(for urls: [URL]) -> [String] {
        let existingKeys = Set(objects.map { normalizedFilenameKey($0.name) })
        var assignedKeys = Set<String>()
        return urls.map { url in
            let proposed = FilenamePolicy.sanitized(url.lastPathComponent)
            let proposedKey = normalizedFilenameKey(proposed)
            if assignedKeys.insert(proposedKey).inserted {
                return proposed
            }

            var index = 2
            while true {
                let candidate = FilenamePolicy.uniqueName(proposed, index: index)
                let key = normalizedFilenameKey(candidate)
                if !existingKeys.contains(key), assignedKeys.insert(key).inserted {
                    return candidate
                }
                index += 1
            }
        }
    }

    private func preferredLocalNames(for sources: [MTPObject], in directory: URL) -> [String] {
        let existingNames = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent)) ?? []
        var usedKeys = Set(existingNames.map(normalizedFilenameKey))

        return sources.map { source in
            let proposed = FilenamePolicy.sanitized(source.name)
            var index = 1
            var candidate = proposed
            while !usedKeys.insert(normalizedFilenameKey(candidate)).inserted {
                index += 1
                candidate = FilenamePolicy.uniqueName(proposed, index: index)
            }
            return candidate
        }
    }

    private func normalizedFilenameKey(_ name: String) -> String {
        FilenamePolicy.collisionKey(name)
    }

    private func acquireConnectedClient() async throws -> LibMTPClient {
        if let client, connectionState == .connected { return client }
        return try await reconnectForTransfer()
    }

    private func reconnectForTransfer() async throws -> LibMTPClient {
        if updateMTPAccessConflict() {
            connectionState = .disconnected
            throw AppModelError(message: NSLocalizedString("connection.conflict.message", comment: ""))
        }
        connectionState = .connecting
        if let client { await client.close() }
        self.client = nil

        let candidates = try await LibMTPClient.detectDevices()
        guard !candidates.isEmpty else {
            connectionState = .disconnected
            throw MTPClientError(
                code: Int32(MTP_BRIDGE_ERROR_NO_DEVICE.rawValue),
                retryable: true,
                message: NSLocalizedString("error.no_device_connected", comment: "")
            )
        }
        return try await openFirstAvailable(candidates, preserveNavigation: true)
    }

    private func openFirstAvailable(
        _ candidates: [MTPDeviceCandidate],
        preserveNavigation: Bool
    ) async throws -> LibMTPClient {
        let ordered = candidates.sorted { lhs, rhs in
            let lhsPreferred = isSamePhysicalKind(lhs, as: lastCandidate)
            let rhsPreferred = isSamePhysicalKind(rhs, as: lastCandidate)
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            let productOrder = lhs.product.localizedStandardCompare(rhs.product)
            if productOrder != .orderedSame { return productOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
        var lastError: Error?
        for candidate in ordered {
            let newClient = LibMTPClient()
            do {
                let (info, availableStorages) = try await newClient.open(candidate)
                client = newClient
                lastCandidate = candidate
                deviceInfo = info
                storages = availableStorages
                if selectedStorageID == nil || !availableStorages.contains(where: { $0.id == selectedStorageID }) {
                    selectedStorageID = availableStorages.first?.id
                    breadcrumbs = []
                    navigationHistory.reset()
                } else if !preserveNavigation {
                    breadcrumbs = []
                    navigationHistory.reset()
                }
                connectionGeneration &+= 1
                let generation = connectionGeneration
                connectionState = .connected
                stopReconnectLoop()
                startPresenceMonitor(for: candidate, generation: generation)

                // USB mode changes and MTP session reopenings can invalidate object
                // handles. Rebuild the visible breadcrumb IDs from their names before
                // loading the folder, otherwise a stale parent handle can later make
                // SendObjectInfo fail with PTP 0x2009 (Invalid Object Handle).
                if preserveNavigation, !breadcrumbs.isEmpty {
                    let savedNames = breadcrumbs.map(\.name)
                    do {
                        if let rebound = try await RemoteFolderPathResolver.resolveBreadcrumbs(
                            storageID: selectedStorageID ?? availableStorages.first?.id ?? 0,
                            names: savedNames,
                            listChildren: { storageID, parentID in
                                try await newClient.listChildren(storageID: storageID, parentID: parentID)
                            }
                        ) {
                            breadcrumbs = rebound
                        } else {
                            breadcrumbs = []
                            navigationHistory.reset()
                        }
                    } catch {
                        breadcrumbs = []
                        navigationHistory.reset()
                    }
                }

                let loaded = await loadCurrentFolder(fallbackToRoot: preserveNavigation)
                if loaded, let location = currentNavigationLocation() {
                    if navigationHistory.current == nil || !preserveNavigation {
                        navigationHistory.reset(to: location)
                    } else if navigationHistory.current != location {
                        navigationHistory.visit(location)
                    }
                }
                transfers.deviceDidConnect()
                return newClient
            } catch {
                await newClient.close()
                lastError = error
            }
        }
        connectionState = .failed(lastError?.localizedDescription ?? NSLocalizedString("error.generic_mtp", comment: ""))
        throw lastError ?? AppModelError(message: NSLocalizedString("error.generic_mtp", comment: ""))
    }

    private func isSamePhysicalKind(
        _ candidate: MTPDeviceCandidate,
        as previous: MTPDeviceCandidate?
    ) -> Bool {
        guard let previous else { return false }
        return candidate.vendorID == previous.vendorID &&
            candidate.productID == previous.productID &&
            candidate.vendor == previous.vendor &&
            candidate.product == previous.product
    }

    @discardableResult
    private func loadCurrentFolder(fallbackToRoot: Bool = false) async -> Bool {
        cancelCreationDateEnrichment()
        guard let client, let storageID = selectedStorageID else {
            objects = []
            return false
        }
        let generation = connectionGeneration
        let requestedParentID = currentFolderID
        isLoadingFolder = true
        defer {
            if generation == connectionGeneration { isLoadingFolder = false }
        }
        do {
            let listed = try await client.listChildren(
                storageID: storageID,
                parentID: requestedParentID
            )
            guard generation == connectionGeneration, connectionState == .connected else { return false }
            objects = listed
            selection = []
            startCreationDateEnrichment(
                for: listed,
                client: client,
                connectionGeneration: generation,
                storageID: storageID,
                parentID: requestedParentID
            )
            return true
        } catch {
            guard generation == connectionGeneration, connectionState == .connected else { return false }
            if fallbackToRoot, !breadcrumbs.isEmpty {
                breadcrumbs = []
                do {
                    let listed = try await client.listChildren(
                        storageID: storageID,
                        parentID: mtpRootObjectID
                    )
                    guard generation == connectionGeneration, connectionState == .connected else { return false }
                    objects = listed
                    selection = []
                    startCreationDateEnrichment(
                        for: listed,
                        client: client,
                        connectionGeneration: generation,
                        storageID: storageID,
                        parentID: mtpRootObjectID
                    )
                    return true
                } catch {
                    guard generation == connectionGeneration else { return false }
                    handle(error)
                    return false
                }
            }
            handle(error)
            return false
        }
    }

    private func startCreationDateEnrichment(
        for listedObjects: [MTPObject],
        client: LibMTPClient,
        connectionGeneration expectedConnectionGeneration: Int,
        storageID: UInt32,
        parentID: UInt32
    ) {
        cancelCreationDateEnrichment()
        guard !listedObjects.isEmpty else { return }

        creationDateGeneration &+= 1
        let metadataGeneration = creationDateGeneration
        pendingCreationDateIDs = Set(listedObjects.map(\.id))
        creationDateTask = Task { [weak self] in
            var resolvedDates: [UInt32: Date] = [:]
            var completedIDs = Set<UInt32>()

            for (index, object) in listedObjects.enumerated() {
                guard !Task.isCancelled else { return }

                // Creation metadata is cosmetic. Never compete with an active
                // upload/download for the single serialized MTP command channel.
                while true {
                    guard let self else { return }
                    if !self.transfers.isRunning { break }
                    do {
                        try await Task.sleep(for: .milliseconds(150))
                    } catch {
                        return
                    }
                }

                do {
                    if let date = try await client.readCreationDate(
                        objectID: object.id,
                        fileType: object.fileType
                    ) {
                        resolvedDates[object.id] = date
                    }
                    completedIDs.insert(object.id)
                } catch {
                    // Transport failures are handled by the independent USB monitor.
                    // Do not mislabel a connection failure as "device did not provide".
                    return
                }

                let shouldPublish = completedIDs.count >= 16 || index == listedObjects.count - 1
                if shouldPublish {
                    guard let self,
                          self.creationDateGeneration == metadataGeneration,
                          self.connectionGeneration == expectedConnectionGeneration,
                          self.connectionState == .connected,
                          self.selectedStorageID == storageID,
                          self.currentFolderID == parentID else { return }
                    self.applyCreationDateBatch(
                        dates: resolvedDates,
                        completedIDs: completedIDs
                    )
                    resolvedDates.removeAll(keepingCapacity: true)
                    completedIDs.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }

            guard let self, self.creationDateGeneration == metadataGeneration else { return }
            self.creationDateTask = nil
        }
    }

    private func applyCreationDateBatch(
        dates: [UInt32: Date],
        completedIDs: Set<UInt32>
    ) {
        guard !completedIDs.isEmpty else { return }
        for index in objects.indices {
            if let date = dates[objects[index].id] {
                objects[index].creationDate = date
            }
        }
        pendingCreationDateIDs.subtract(completedIDs)
    }

    private func cancelCreationDateEnrichment() {
        creationDateGeneration &+= 1
        creationDateTask?.cancel()
        creationDateTask = nil
        pendingCreationDateIDs = []
    }

    private func deleteRecursively(_ object: MTPObject, client: LibMTPClient) async throws {
        if object.isFolder {
            let children = try await client.listChildren(
                storageID: object.storageID,
                parentID: object.id
            )
            for child in children {
                try await deleteRecursively(child, client: client)
            }
        }
        try await client.deleteObject(id: object.id)
    }

    private func refreshAfterTransfer() async {
        guard let client, connectionState == .connected else { return }
        do {
            storages = try await client.readStorages()
            guard let storageID = selectedStorageID ?? storages.first?.id else {
                selectedStorageID = nil
                objects = []
                return
            }
            selectedStorageID = storageID
            await loadCurrentFolder()
        } catch {
            // A finished transfer should stay completed even if the cosmetic refresh fails.
        }
    }

    private func startPresenceMonitor(
        for candidate: MTPDeviceCandidate,
        generation: Int
    ) {
        presenceMonitor.start(candidate: candidate) { [weak self] in
            guard let self else { return }
            self.handlePhysicalDisconnect(candidate: candidate, generation: generation)
        }
    }

    private func handlePhysicalDisconnect(
        candidate: MTPDeviceCandidate,
        generation: Int
    ) {
        guard connectionState == .connected,
              connectionGeneration == generation,
              lastCandidate == candidate else { return }

        presenceMonitor.stop()
        let previousClient = client
        transitionToDisconnected(preserveNavigation: true)
        transfers.deviceDidDisconnect()

        // Do not wait for a synchronous MTP call that is unwinding after USB
        // removal. The browser returns to the waiting state immediately; the
        // stale session closes whenever its actor becomes available.
        Task { await previousClient?.close() }
        startReconnectLoop()
    }

    @discardableResult
    private func updateMTPAccessConflict() -> Bool {
        let conflict = MTPAccessArbiter.currentConflict()
        mtpAccessConflict = conflict
        return conflict != nil
    }

    private func startMTPAccessConflictMonitor() {
        guard mtpAccessConflictMonitorTask == nil else { return }
        mtpAccessConflictMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
                guard let self else { return }
                let previous = self.mtpAccessConflict
                let current = MTPAccessArbiter.currentConflict()
                self.mtpAccessConflict = current

                if current != nil, previous == nil, self.connectionState == .connected {
                    let previousClient = self.client
                    self.transitionToDisconnected(preserveNavigation: true)
                    self.transfers.deviceDidDisconnect()
                    Task { await previousClient?.close() }
                    self.startReconnectLoop()
                } else if current == nil, previous != nil, self.connectionState != .connected {
                    self.startReconnectLoop()
                }
            }
        }
    }

    private func startReconnectLoop() {
        guard didStart, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1.5))
                } catch {
                    return
                }
                guard let self else { return }
                if self.connectionState == .connected {
                    self.reconnectTask = nil
                    return
                }
                guard !self.connectionAttemptInFlight,
                      !self.isMutating,
                      !self.isLoadingFolder else { continue }
                await self.connect(
                    silentWhenMissing: true,
                    preserveNavigation: self.lastCandidate != nil,
                    showActivity: false
                )
                if self.connectionState == .connected {
                    self.reconnectTask = nil
                    return
                }
            }
        }
    }

    private func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func transitionToDisconnected(preserveNavigation: Bool) {
        presenceMonitor.stop()
        cancelCreationDateEnrichment()
        connectionGeneration &+= 1
        connectionState = .disconnected
        client = nil
        deviceInfo = nil
        storages = []
        objects = []
        selection = []
        isLoadingFolder = false
        if !preserveNavigation {
            selectedStorageID = nil
            breadcrumbs = []
            navigationHistory.reset()
        }
    }

    private func currentNavigationLocation() -> BrowserLocation? {
        guard let selectedStorageID else { return nil }
        return BrowserLocation(storageID: selectedStorageID, breadcrumbs: breadcrumbs)
    }

    private func navigate(
        to location: BrowserLocation,
        recordingVisit: Bool
    ) async {
        let previousStorageID = selectedStorageID
        let previousBreadcrumbs = breadcrumbs
        selectedStorageID = location.storageID
        breadcrumbs = location.breadcrumbs
        guard await loadCurrentFolder() else {
            selectedStorageID = previousStorageID
            breadcrumbs = previousBreadcrumbs
            return
        }
        if recordingVisit {
            if navigationHistory.current == nil {
                navigationHistory.reset(to: location)
            } else {
                navigationHistory.visit(location)
            }
        }
    }

    private func applyNavigationLocation(_ location: BrowserLocation) async -> Bool {
        guard storages.contains(where: { $0.id == location.storageID }) else { return false }
        let previousStorageID = selectedStorageID
        let previousBreadcrumbs = breadcrumbs
        selectedStorageID = location.storageID
        breadcrumbs = location.breadcrumbs
        guard await loadCurrentFolder(fallbackToRoot: false) else {
            selectedStorageID = previousStorageID
            breadcrumbs = previousBreadcrumbs
            return false
        }
        return true
    }

    private func handle(_ error: Error) {
        if let filenameError = error as? FilenamePolicyError {
            presentedError = localizedMessage(for: filenameError)
        } else {
            presentedError = error.localizedDescription
        }
    }

    private func localizedMessage(for error: FilenamePolicyError) -> String {
        switch error {
        case .empty: NSLocalizedString("error.filename.empty", comment: "")
        case .reserved: NSLocalizedString("error.filename.reserved", comment: "")
        case .containsPathSeparator: NSLocalizedString("error.filename.separator", comment: "")
        case .containsControlCharacter: NSLocalizedString("error.filename.control", comment: "")
        case .tooLong: NSLocalizedString("error.filename.long", comment: "")
        }
    }
}
