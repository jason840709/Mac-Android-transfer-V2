import Foundation
import Observation

private struct TransferCoordinatorError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct LocalManifestEntry: Sendable {
    let localPath: String
    let relativeComponents: [String]
    let isDirectory: Bool
    let size: UInt64
}

private struct LocalManifest: Sendable {
    let entries: [LocalManifestEntry]
    let totalBytes: UInt64
}

private enum LocalManifestBuilder {
    static func build(
        rootURL: URL,
        rootNameOverride: String? = nil,
        cancellation: BridgeCancellation? = nil
    ) throws -> LocalManifest {
        if cancellation?.isRequested == true { throw CancellationError() }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        let rootValues = try rootURL.resourceValues(forKeys: keys)
        let rootName = FilenamePolicy.sanitized(
            rootNameOverride ?? rootURL.lastPathComponent
        )

        if rootValues.isSymbolicLink == true {
            throw TransferCoordinatorError(
                message: NSLocalizedString("error.symbolic_link", comment: "")
            )
        }
        if rootValues.isDirectory != true {
            guard rootValues.isRegularFile == true else {
                throw TransferCoordinatorError(
                    message: NSLocalizedString("error.unsupported_local_item", comment: "")
                )
            }
            let size = UInt64(max(0, rootValues.fileSize ?? 0))
            return LocalManifest(
                entries: [
                    LocalManifestEntry(
                        localPath: rootURL.path,
                        relativeComponents: [rootName],
                        isDirectory: false,
                        size: size
                    )
                ],
                totalBytes: size
            )
        }

        var entries = [
            LocalManifestEntry(
                localPath: rootURL.path,
                relativeComponents: [rootName],
                isDirectory: true,
                size: 0
            )
        ]
        var totalBytes: UInt64 = 0
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return LocalManifest(entries: entries, totalBytes: 0)
        }

        let rootComponentsCount = rootURL.standardizedFileURL.pathComponents.count
        var resolvedComponentsByRawPath: [[String]: [String]] = [
            []: [rootName]
        ]
        var usedNamesByResolvedParent: [[String]: Set<String>] = [
            [rootName]: []
        ]

        for case let itemURL as URL in enumerator {
            if cancellation?.isRequested == true { throw CancellationError() }
            let name = itemURL.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") {
                if (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values = try itemURL.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory == true || values.isRegularFile == true else { continue }

            let rawComponents = Array(
                itemURL.standardizedFileURL.pathComponents.dropFirst(rootComponentsCount)
            )
            guard let rawName = rawComponents.last else { continue }
            let rawParent = Array(rawComponents.dropLast())
            guard let resolvedParent = resolvedComponentsByRawPath[rawParent] else {
                throw TransferCoordinatorError(
                    message: NSLocalizedString("error.upload_parent_missing", comment: "")
                )
            }

            var usedNames = usedNamesByResolvedParent[resolvedParent] ?? []
            let proposed = FilenamePolicy.sanitized(rawName)
            var collisionIndex = 1
            var remoteName = proposed
            while !usedNames.insert(FilenamePolicy.collisionKey(remoteName)).inserted {
                collisionIndex += 1
                remoteName = FilenamePolicy.uniqueName(proposed, index: collisionIndex)
            }
            usedNamesByResolvedParent[resolvedParent] = usedNames

            let components = resolvedParent + [remoteName]
            let isDirectory = values.isDirectory == true
            let size = isDirectory ? 0 : UInt64(max(0, values.fileSize ?? 0))
            entries.append(
                LocalManifestEntry(
                    localPath: itemURL.path,
                    relativeComponents: components,
                    isDirectory: isDirectory,
                    size: size
                )
            )
            if isDirectory {
                resolvedComponentsByRawPath[rawComponents] = components
                usedNamesByResolvedParent[components] = []
            } else {
                let (sum, overflow) = totalBytes.addingReportingOverflow(size)
                totalBytes = overflow ? UInt64.max : sum
            }
        }
        if let enumerationError { throw enumerationError }

        entries.sort { lhs, rhs in
            if lhs.relativeComponents.count != rhs.relativeComponents.count {
                return lhs.relativeComponents.count < rhs.relativeComponents.count
            }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.relativeComponents.joined(separator: "/")
                .localizedStandardCompare(rhs.relativeComponents.joined(separator: "/")) == .orderedAscending
        }
        return LocalManifest(entries: entries, totalBytes: totalBytes)
    }
}

private struct RemoteManifestEntry: Sendable {
    let object: MTPObject
    let relativeComponents: [String]
}

private struct RemoteFolderKey: Hashable, Sendable {
    let storageID: UInt32
    let objectID: UInt32
}

private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmission: TimeInterval = 0
    private let minimumInterval: TimeInterval
    private let handler: @Sendable (UInt64, UInt64) -> Void

    init(
        minimumInterval: TimeInterval = 0.1,
        handler: @escaping @Sendable (UInt64, UInt64) -> Void
    ) {
        self.minimumInterval = minimumInterval
        self.handler = handler
    }

    func report(_ completed: UInt64, _ total: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let shouldEmit = now - lastEmission >= minimumInterval || completed >= total
        if shouldEmit { lastEmission = now }
        lock.unlock()
        if shouldEmit { handler(completed, total) }
    }
}

@MainActor
@Observable
final class TransferCoordinator {
    private(set) var jobs: [TransferJob]
    var isExpanded = false
    private(set) var isRunning = false
    private(set) var activeJobID: UUID?

    @ObservationIgnored private let store = TransferQueueStore()
    @ObservationIgnored private let retryPolicy = RetryPolicy()
    @ObservationIgnored private var runnerTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTokens: [UUID: BridgeCancellation] = [:]
    @ObservationIgnored private var speedometers: [UUID: TransferSpeedometer] = [:]
    @ObservationIgnored private var lastProgressPublish: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var lastPersistTime: TimeInterval = 0
    @ObservationIgnored private var acquireClient: (() async throws -> LibMTPClient)?
    @ObservationIgnored private var reconnectClient: (() async throws -> LibMTPClient)?
    @ObservationIgnored private var remoteMutationDidFinish: (() async -> Void)?
    @ObservationIgnored private var remoteMutationPending = false
    @ObservationIgnored private var completionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @ObservationIgnored private var ephemeralJobIDs = Set<UUID>()
    @ObservationIgnored private var disconnectInterruptedJobIDs = Set<UUID>()
    @ObservationIgnored private var pauseRequestedJobIDs = Set<UUID>()
    @ObservationIgnored private var deviceAvailable = false

    init() {
        jobs = store.load()
    }

    var unfinishedCount: Int {
        jobs.filter { !$0.state.isTerminal }.count
    }

    var activeJob: TransferJob? {
        guard let activeJobID else { return nil }
        return jobs.first { $0.id == activeJobID }
    }

    func configure(
        acquireClient: @escaping () async throws -> LibMTPClient,
        reconnectClient: @escaping () async throws -> LibMTPClient,
        remoteMutationDidFinish: @escaping () async -> Void
    ) {
        self.acquireClient = acquireClient
        self.reconnectClient = reconnectClient
        self.remoteMutationDidFinish = remoteMutationDidFinish
    }

    func resumePendingJobs() {
        startRunnerIfNeeded()
    }

    func deviceDidConnect() {
        deviceAvailable = true
        startRunnerIfNeeded()
    }

    func deviceDidDisconnect() {
        deviceAvailable = false
        if let activeJobID {
            disconnectInterruptedJobIDs.insert(activeJobID)
        }

        let message = NSLocalizedString("error.no_device_connected", comment: "")
        var changed = false
        for index in jobs.indices where !jobs[index].state.isTerminal {
            let jobID = jobs[index].id
            let isEphemeral = ephemeralJobIDs.contains(jobID)
            jobs[index].state = TransferDisconnectPolicy.nextState(
                current: jobs[index].state,
                isEphemeral: isEphemeral
            )
            jobs[index].errorMessage = isEphemeral ? message : nil
            jobs[index].bytesPerSecond = 0
            jobs[index].phase = nil
            jobs[index].updatedAt = Date()
            changed = true

            // Finder waits on this continuation. Resume it immediately even if
            // an unplugged libmtp call takes a long time to unwind in the actor.
            if isEphemeral {
                finishWaiter(
                    jobID: jobID,
                    result: .failure(TransferCoordinatorError(message: message))
                )
            }
        }
        if changed { persistImmediately() }

        for token in cancellationTokens.values {
            token.request()
        }
    }

    func enqueue(_ newJobs: [TransferJob]) {
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        persistImmediately()
        isExpanded = true
        startRunnerIfNeeded()
    }

    func enqueueAndWait(_ job: TransferJob) async throws {
        ephemeralJobIDs.insert(job.id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completionWaiters[job.id] = continuation
                enqueue([job])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(jobID: job.id)
            }
        }
    }

    func pause(jobID: UUID) {
        if ephemeralJobIDs.contains(jobID) {
            cancel(jobID: jobID)
            return
        }
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              !jobs[index].state.isTerminal,
              jobs[index].state != .paused else { return }

        pauseRequestedJobIDs.insert(jobID)
        cancellationTokens[jobID]?.request()

        if jobs[index].state == .queued || jobs[index].state == .retrying || jobs[index].state == .preparing {
            markPaused(jobID: jobID)
        }
    }

    func resume(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .paused else { return }
        pauseRequestedJobIDs.remove(jobID)
        jobs[index].state = .queued
        jobs[index].errorMessage = nil
        jobs[index].bytesPerSecond = 0
        jobs[index].phase = nil
        jobs[index].updatedAt = Date()
        persistImmediately()
        startRunnerIfNeeded()
    }

    /// Permanently ends this transfer attempt but keeps the row as a cancelled
    /// record until the user explicitly deletes it.
    func terminate(jobID: UUID) {
        pauseRequestedJobIDs.remove(jobID)
        cancel(jobID: jobID)
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[index].state.isTerminal { return }
        pauseRequestedJobIDs.remove(jobID)
        cancellationTokens[jobID]?.request()
        if jobs[index].state == .queued || jobs[index].state == .retrying || jobs[index].state == .preparing || jobs[index].state == .paused {
            jobs[index].state = .cancelled
            jobs[index].errorMessage = nil
            jobs[index].bytesPerSecond = 0
            jobs[index].phase = nil
            jobs[index].updatedAt = Date()
            persistImmediately()
            finishWaiter(
                jobID: jobID,
                result: .failure(CancellationError())
            )
        }
    }

    func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .failed || jobs[index].state == .cancelled else { return }
        jobs[index].state = .queued
        jobs[index].attempt = 0
        jobs[index].errorMessage = nil
        jobs[index].bytesPerSecond = 0
        jobs[index].updatedAt = Date()
        persistImmediately()
        startRunnerIfNeeded()
    }

    func remove(jobID: UUID) {
        guard activeJobID != jobID, completionWaiters[jobID] == nil else { return }
        jobs.removeAll { $0.id == jobID }
        ephemeralJobIDs.remove(jobID)
        pauseRequestedJobIDs.remove(jobID)
        persistImmediately()
    }

    func clearFinished() {
        let removedIDs = Set(
            jobs.filter { $0.state.isTerminal && $0.id != activeJobID }.map(\.id)
        )
        jobs.removeAll { removedIDs.contains($0.id) }
        ephemeralJobIDs.subtract(removedIDs)
        pauseRequestedJobIDs.subtract(removedIDs)
        persistImmediately()
    }

    private func startRunnerIfNeeded() {
        guard deviceAvailable,
              runnerTask == nil,
              jobs.contains(where: { $0.state == .queued }) else { return }
        runnerTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        isRunning = true
        while deviceAvailable, let jobID = jobs.first(where: { $0.state == .queued })?.id {
            if Task.isCancelled { break }
            await run(jobID: jobID)
        }

        if remoteMutationPending {
            remoteMutationPending = false
            await remoteMutationDidFinish?()
        }

        isRunning = false
        activeJobID = nil
        runnerTask = nil
        if deviceAvailable, jobs.contains(where: { $0.state == .queued }) {
            startRunnerIfNeeded()
        }
    }

    private func run(jobID: UUID) async {
        guard let token = BridgeCancellation() else {
            fail(jobID: jobID, message: NSLocalizedString("error.cancellation_token", comment: ""))
            return
        }
        cancellationTokens[jobID] = token
        speedometers[jobID] = TransferSpeedometer()
        activeJobID = jobID
        defer {
            cancellationTokens[jobID] = nil
            speedometers[jobID] = nil
            lastProgressPublish[jobID] = nil
            activeJobID = nil
        }

        while let index = jobs.firstIndex(where: { $0.id == jobID }) {
            if token.isRequested || jobs[index].state == .cancelled {
                if pauseRequestedJobIDs.remove(jobID) != nil {
                    markPaused(jobID: jobID)
                } else if disconnectInterruptedJobIDs.remove(jobID) != nil {
                    handleDisconnectInterruption(jobID: jobID)
                } else {
                    markCancelled(jobID: jobID)
                }
                return
            }

            jobs[index].attempt += 1
            jobs[index].state = jobs[index].attempt == 1 ? .preparing : .retrying
            jobs[index].errorMessage = nil
            jobs[index].bytesPerSecond = 0
            jobs[index].phase = .preparing
            jobs[index].updatedAt = Date()
            persistImmediately()

            do {
                let provider: (() async throws -> LibMTPClient)? = jobs[index].attempt == 1
                    ? acquireClient
                    : reconnectClient
                guard let provider else {
                    throw TransferCoordinatorError(
                        message: NSLocalizedString("error.transfer_engine_not_configured", comment: "")
                    )
                }
                let client = try await provider()
                guard !token.isRequested else {
                    throw MTPClientError(
                        code: Int32(MTP_BRIDGE_ERROR_CANCELLED.rawValue),
                        retryable: false,
                        message: NSLocalizedString("transfer.cancelled", comment: "")
                    )
                }
                guard let currentJob = jobs.first(where: { $0.id == jobID }) else { return }
                try await validateDeviceBinding(for: currentJob, client: client)

                updateState(jobID: jobID, state: .running)
                try await execute(jobID: jobID, client: client, cancellation: token)
                guard !token.isRequested else { throw cancelledError() }
                complete(jobID: jobID)
                if jobs.first(where: { $0.id == jobID })?.direction == .upload {
                    remoteMutationPending = true
                }
                return
            } catch let error as MTPClientError {
                if error.isCancelled || token.isRequested {
                    if pauseRequestedJobIDs.remove(jobID) != nil {
                        markPaused(jobID: jobID)
                    } else if disconnectInterruptedJobIDs.remove(jobID) != nil {
                        handleDisconnectInterruption(jobID: jobID)
                    } else {
                        markCancelled(jobID: jobID)
                    }
                    return
                }
                guard let current = jobs.first(where: { $0.id == jobID }) else { return }
                let shouldRetry = RetryPolicy(maxAttempts: current.maxAttempts)
                    .shouldRetry(afterAttempt: current.attempt, retryable: error.retryable)
                if shouldRetry {
                    updateState(jobID: jobID, state: .retrying, errorMessage: error.message)
                    let delay = retryPolicy.delay(afterAttempt: current.attempt)
                    do {
                        try await sleepBeforeRetry(delay, cancellation: token)
                    } catch {
                        if pauseRequestedJobIDs.remove(jobID) != nil {
                            markPaused(jobID: jobID)
                        } else if disconnectInterruptedJobIDs.remove(jobID) != nil {
                            handleDisconnectInterruption(jobID: jobID)
                        } else {
                            markCancelled(jobID: jobID)
                        }
                        return
                    }
                    continue
                }
                fail(jobID: jobID, message: error.message)
                return
            } catch {
                if token.isRequested {
                    if pauseRequestedJobIDs.remove(jobID) != nil {
                        markPaused(jobID: jobID)
                    } else if disconnectInterruptedJobIDs.remove(jobID) != nil {
                        handleDisconnectInterruption(jobID: jobID)
                    } else {
                        markCancelled(jobID: jobID)
                    }
                } else {
                    fail(jobID: jobID, message: error.localizedDescription)
                }
                return
            }
        }
    }

    private func sleepBeforeRetry(
        _ delay: TimeInterval,
        cancellation: BridgeCancellation
    ) async throws {
        var remaining = max(0, delay)
        while remaining > 0 {
            if cancellation.isRequested { throw CancellationError() }
            let slice = min(remaining, 0.2)
            try await Task.sleep(for: .seconds(slice))
            remaining -= slice
        }
    }

    private func validateDeviceBinding(
        for job: TransferJob,
        client: LibMTPClient
    ) async throws {
        guard let expected = job.deviceIdentity else {
            throw TransferCoordinatorError(
                message: NSLocalizedString("error.transfer_unbound_device", comment: "")
            )
        }
        guard let candidate = await client.candidate else {
            throw MTPClientError(
                code: Int32(MTP_BRIDGE_ERROR_NO_DEVICE.rawValue),
                retryable: true,
                message: NSLocalizedString("error.no_open_device", comment: "")
            )
        }
        let info = try await client.readDeviceInfo()
        guard expected.matches(candidate: candidate, info: info) else {
            throw TransferCoordinatorError(
                message: NSLocalizedString("error.transfer_wrong_device", comment: "")
            )
        }
    }

    private func execute(
        jobID: UUID,
        client: LibMTPClient,
        cancellation: BridgeCancellation
    ) async throws {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        switch job.request {
        case let .upload(source, destination):
            try await upload(
                jobID: jobID,
                source: source,
                destination: destination,
                client: client,
                cancellation: cancellation
            )
        case let .download(source, destination):
            try await download(
                jobID: jobID,
                source: source,
                destination: destination,
                client: client,
                cancellation: cancellation
            )
        }
    }

    private func upload(
        jobID: UUID,
        source: LocalTransferSource,
        destination: RemoteTransferDestination,
        client: LibMTPClient,
        cancellation: BridgeCancellation
    ) async throws {
        let resolved = try BookmarkStore.resolve(
            bookmark: source.securityScopedBookmark,
            fallbackPath: source.path
        )
        let access = ScopedURLAccess(url: resolved)
        defer { access.stop() }

        let manifest = try await Task.detached(priority: .userInitiated) {
            try LocalManifestBuilder.build(
                rootURL: resolved,
                rootNameOverride: source.preferredRemoteName,
                cancellation: cancellation
            )
        }.value
        setTotal(jobID: jobID, totalBytes: manifest.totalBytes)
        let isRetry = (jobs.first { $0.id == jobID }?.attempt ?? 1) > 1

        guard let resolvedDestinationParentID = try await RemoteFolderPathResolver.resolveParentID(
            destination: destination,
            listChildren: { storageID, parentID in
                try await client.listChildren(storageID: storageID, parentID: parentID)
            }
        ) else {
            throw TransferCoordinatorError(
                message: NSLocalizedString("error.upload_destination_changed", comment: "")
            )
        }

        var remoteDirectoryIDs: [[String]: UInt32] = [
            []: resolvedDestinationParentID
        ]
        var childrenCache: [RemoteFolderKey: [String: MTPObject]] = [:]
        var completedBytes: UInt64 = 0

        for entry in manifest.entries {
            if cancellation.isRequested { throw cancelledError() }
            guard let finalName = entry.relativeComponents.last else { continue }
            try FilenamePolicy.validate(finalName)
            let parentComponents = Array(entry.relativeComponents.dropLast())
            guard let remoteParentID = remoteDirectoryIDs[parentComponents] else {
                throw TransferCoordinatorError(
                    message: NSLocalizedString("error.upload_parent_missing", comment: "")
                )
            }
            let key = RemoteFolderKey(storageID: destination.storageID, objectID: remoteParentID)
            var children = try await cachedChildren(
                key: key,
                cache: &childrenCache,
                client: client
            )
            let existing = matchingChild(named: finalName, in: children)

            if entry.isDirectory {
                if let existing {
                    guard existing.isFolder else {
                        throw TransferCoordinatorError(
                            message: String(
                                format: NSLocalizedString("error.remote_type_conflict", comment: ""),
                                finalName
                            )
                        )
                    }
                    remoteDirectoryIDs[entry.relativeComponents] = existing.id
                } else {
                    let folderID = try await client.createFolder(
                        name: finalName,
                        storageID: destination.storageID,
                        parentID: remoteParentID
                    )
                    let folder = MTPObject(
                        id: folderID,
                        parentID: remoteParentID,
                        storageID: destination.storageID,
                        name: finalName,
                        size: 0,
                        modificationDate: Date(),
                        isFolder: true,
                        fileType: 0
                    )
                    if let existing { children[existing.name] = nil }
                    children[finalName] = folder
                    childrenCache[key] = children
                    remoteDirectoryIDs[entry.relativeComponents] = folderID
                }
                continue
            }

            if existing?.isFolder == true {
                throw TransferCoordinatorError(
                    message: String(
                        format: NSLocalizedString("error.remote_type_conflict", comment: ""),
                        finalName
                    )
                )
            }
            if isRetry,
               let existing,
               isLikelyComplete(remoteObject: existing, localPath: entry.localPath) {
                completedBytes &+= entry.size
                publishProgress(
                    jobID: jobID,
                    completedBytes: completedBytes,
                    totalBytes: manifest.totalBytes,
                    force: true
                )
                continue
            }
            let base = completedBytes
            let total = manifest.totalBytes
            let relay = ProgressRelay { [weak self] fileCompleted, _ in
                Task { @MainActor in
                    self?.publishProgress(
                        jobID: jobID,
                        completedBytes: base &+ fileCompleted,
                        totalBytes: total
                    )
                }
            }
            let temporaryName = FilenamePolicy.temporaryUploadName(finalName: finalName)
            let backupName = FilenamePolicy.backupName(finalName: finalName)
            let uploadedID = try await client.uploadAtomic(
                localURL: URL(fileURLWithPath: entry.localPath),
                storageID: destination.storageID,
                parentID: remoteParentID,
                temporaryName: temporaryName,
                finalName: finalName,
                existingObjectID: existing?.id,
                backupName: backupName,
                cancellation: cancellation,
                progress: { completed, total in
                    relay.report(completed, total)
                }
            )
            completedBytes &+= entry.size
            if let existing { children[existing.name] = nil }
            children[finalName] = MTPObject(
                id: uploadedID,
                parentID: remoteParentID,
                storageID: destination.storageID,
                name: finalName,
                size: entry.size,
                modificationDate: Date(),
                isFolder: false,
                fileType: 0
            )
            childrenCache[key] = children
            publishProgress(
                jobID: jobID,
                completedBytes: completedBytes,
                totalBytes: total,
                force: true
            )
        }
    }

    private func matchingChild(
        named name: String,
        in children: [String: MTPObject]
    ) -> MTPObject? {
        if let exact = children[name] { return exact }
        let key = FilenamePolicy.collisionKey(name)
        return children.values.first { FilenamePolicy.collisionKey($0.name) == key }
    }

    private func cachedChildren(
        key: RemoteFolderKey,
        cache: inout [RemoteFolderKey: [String: MTPObject]],
        client: LibMTPClient
    ) async throws -> [String: MTPObject] {
        if let cached = cache[key] { return cached }
        let listed = try await client.listChildren(
            storageID: key.storageID,
            parentID: key.objectID
        )
        let dictionary = Dictionary(listed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        cache[key] = dictionary
        return dictionary
    }

    private func download(
        jobID: UUID,
        source: MTPObject,
        destination: LocalTransferDestination,
        client: LibMTPClient,
        cancellation: BridgeCancellation
    ) async throws {
        let resolved = try BookmarkStore.resolve(
            bookmark: destination.securityScopedBookmark,
            fallbackPath: destination.directoryPath
        )
        let access = ScopedURLAccess(url: resolved)
        defer { access.stop() }

        if destination.effectivePlacement == .exactItem {
            try await downloadFilePromiseExactly(
                jobID: jobID,
                source: source,
                destinationURL: resolved,
                client: client,
                cancellation: cancellation
            )
            return
        }

        let manifest = try await buildRemoteManifest(
            source: source,
            topLevelName: destination.preferredTopLevelName,
            client: client,
            cancellation: cancellation
        )
        let totalBytes = manifest.reduce(UInt64(0)) { partial, entry in
            entry.object.isFolder ? partial : partial &+ entry.object.size
        }
        setTotal(jobID: jobID, totalBytes: totalBytes)

        let manager = FileManager.default
        var completedBytes: UInt64 = 0
        for entry in manifest {
            if cancellation.isRequested { throw cancelledError() }
            let targetURL = entry.relativeComponents.reduce(resolved) { partial, component in
                partial.appendingPathComponent(component, isDirectory: entry.object.isFolder)
            }
            if entry.object.isFolder {
                try manager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                continue
            }
            try manager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let partial = partialDownloadURLs(for: targetURL)
            if isLikelyComplete(localURL: targetURL, remoteObject: entry.object) {
                try? manager.removeItem(at: partial.data)
                try? manager.removeItem(at: partial.metadata)
                completedBytes &+= entry.object.size
                publishProgress(
                    jobID: jobID,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    force: true
                )
                continue
            }

            try preparePartialDownload(
                dataURL: partial.data,
                metadataURL: partial.metadata,
                remoteObject: entry.object,
                fileManager: manager
            )
            let base = completedBytes
            let relay = ProgressRelay { [weak self] fileCompleted, _ in
                Task { @MainActor in
                    self?.publishProgress(
                        jobID: jobID,
                        completedBytes: base &+ fileCompleted,
                        totalBytes: totalBytes
                    )
                }
            }
            _ = try await client.download(
                object: entry.object,
                to: partial.data,
                cancellation: cancellation,
                progress: { completed, total in
                    relay.report(completed, total)
                }
            )

            let attributes = try manager.attributesOfItem(atPath: partial.data.path)
            let localSize = (attributes[FileAttributeKey.size] as? NSNumber)?.uint64Value ?? 0
            guard localSize == entry.object.size else {
                throw MTPClientError(
                    code: Int32(MTP_BRIDGE_ERROR_VERIFICATION.rawValue),
                    retryable: true,
                    message: String(
                        format: NSLocalizedString("error.download_size_mismatch", comment: ""),
                        targetURL.lastPathComponent,
                        entry.object.size,
                        localSize
                    )
                )
            }

            if manager.fileExists(atPath: targetURL.path) {
                _ = try manager.replaceItemAt(targetURL, withItemAt: partial.data)
            } else {
                try manager.moveItem(at: partial.data, to: targetURL)
            }
            try? manager.removeItem(at: partial.metadata)
            if let date = entry.object.modificationDate {
                try? manager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
            }
            completedBytes &+= entry.object.size
            publishProgress(
                jobID: jobID,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                force: true
            )
        }
    }


    /// Fulfills an NSFilePromiseProvider by writing the remote root directly to
    /// the exact URL supplied by Finder. This intentionally bypasses the normal
    /// resumable sidecar path: the sandbox extension covers the promised item,
    /// not arbitrary hidden siblings in its parent directory.
    private func downloadFilePromiseExactly(
        jobID: UUID,
        source: MTPObject,
        destinationURL: URL,
        client: LibMTPClient,
        cancellation: BridgeCancellation
    ) async throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destinationURL.path) else {
            throw TransferCoordinatorError(
                message: String(
                    format: NSLocalizedString("error.file_promise_destination_exists", comment: ""),
                    destinationURL.path
                )
            )
        }

        let manifest = try await buildRemoteManifest(
            source: source,
            topLevelName: nil,
            includeTopLevelName: false,
            client: client,
            cancellation: cancellation
        )
        let totalBytes = manifest.reduce(UInt64(0)) { partial, entry in
            entry.object.isFolder ? partial : partial &+ entry.object.size
        }
        setTotal(jobID: jobID, totalBytes: totalBytes)

        var completedBytes: UInt64 = 0
        do {
            for entry in manifest {
                if cancellation.isRequested { throw cancelledError() }
                let targetURL = FilePromiseDestinationLayout.targetURL(
                    exactDestinationURL: destinationURL,
                    relativeComponents: entry.relativeComponents,
                    isDirectory: entry.object.isFolder
                )

                if entry.object.isFolder {
                    try manager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                    continue
                }

                let parentURL = targetURL.deletingLastPathComponent()
                if !manager.fileExists(atPath: parentURL.path) {
                    try manager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                }

                let base = completedBytes
                let relay = ProgressRelay { [weak self] fileCompleted, _ in
                    Task { @MainActor in
                        self?.publishProgress(
                            jobID: jobID,
                            completedBytes: base &+ fileCompleted,
                            totalBytes: totalBytes
                        )
                    }
                }
                _ = try await client.download(
                    object: entry.object,
                    to: targetURL,
                    allowResume: false,
                    cancellation: cancellation,
                    progress: { completed, total in
                        relay.report(completed, total)
                    }
                )

                let attributes = try manager.attributesOfItem(atPath: targetURL.path)
                let localSize = (attributes[FileAttributeKey.size] as? NSNumber)?.uint64Value ?? 0
                guard localSize == entry.object.size else {
                    throw MTPClientError(
                        code: Int32(MTP_BRIDGE_ERROR_VERIFICATION.rawValue),
                        retryable: true,
                        message: String(
                            format: NSLocalizedString("error.download_size_mismatch", comment: ""),
                            targetURL.lastPathComponent,
                            entry.object.size,
                            localSize
                        )
                    )
                }

                if let date = entry.object.modificationDate {
                    try? manager.setAttributes([.modificationDate: date], ofItemAtPath: targetURL.path)
                }
                completedBytes &+= entry.object.size
                publishProgress(
                    jobID: jobID,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    force: true
                )
            }

            let values = try destinationURL.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
            let correctType = source.isFolder
                ? values.isDirectory == true
                : values.isRegularFile == true
            guard correctType else {
                throw MTPClientError(
                    code: Int32(MTP_BRIDGE_ERROR_VERIFICATION.rawValue),
                    retryable: true,
                    message: String(
                        format: NSLocalizedString("error.file_promise_type_mismatch", comment: ""),
                        destinationURL.path
                    )
                )
            }
        } catch {
            // The exact destination did not exist before this promise began, so
            // removing it cannot overwrite or delete a user's pre-existing item.
            try? manager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func partialDownloadURLs(for targetURL: URL) -> (data: URL, metadata: URL) {
        let directory = targetURL.deletingLastPathComponent()
        let token = FilenamePolicy.stableToken(targetURL.lastPathComponent)
        let baseName = ".mtpbridge-partial-\(token)"
        return (
            data: directory.appendingPathComponent(baseName + ".data"),
            metadata: directory.appendingPathComponent(baseName + ".json")
        )
    }

    private func preparePartialDownload(
        dataURL: URL,
        metadataURL: URL,
        remoteObject: MTPObject,
        fileManager: FileManager
    ) throws {
        let fingerprint = PartialDownloadFingerprint(object: remoteObject)
        let hasPartialData = fileManager.fileExists(atPath: dataURL.path)
        let storedFingerprint: PartialDownloadFingerprint?
        if let data = try? Data(contentsOf: metadataURL) {
            storedFingerprint = try? JSONDecoder().decode(
                PartialDownloadFingerprint.self,
                from: data
            )
        } else {
            storedFingerprint = nil
        }

        if hasPartialData, storedFingerprint?.safelyMatches(remoteObject) != true {
            try fileManager.removeItem(at: dataURL)
        }
        if !fileManager.fileExists(atPath: dataURL.path) {
            try? fileManager.removeItem(at: metadataURL)
        }

        let encoded = try JSONEncoder().encode(fingerprint)
        try encoded.write(to: metadataURL, options: .atomic)
    }

    private func buildRemoteManifest(
        source: MTPObject,
        topLevelName: String?,
        includeTopLevelName: Bool = true,
        client: LibMTPClient,
        cancellation: BridgeCancellation
    ) async throws -> [RemoteManifestEntry] {
        var result: [RemoteManifestEntry] = []
        var visited = Set<UInt32>()
        let rootName = FilenamePolicy.sanitized(topLevelName ?? source.name)

        func walk(_ object: MTPObject, components: [String]) async throws {
            if cancellation.isRequested { throw cancelledError() }
            guard visited.insert(object.id).inserted else { return }
            result.append(RemoteManifestEntry(object: object, relativeComponents: components))
            guard object.isFolder else { return }
            let children = try await client.listChildren(
                storageID: object.storageID,
                parentID: object.id
            ).sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            var usedNames = Set<String>()
            for child in children {
                let localName = uniqueLocalName(
                    FilenamePolicy.sanitized(child.name),
                    usedNames: &usedNames
                )
                try await walk(child, components: components + [localName])
            }
        }

        let rootComponents = includeTopLevelName ? [rootName] : []
        try await walk(source, components: rootComponents)
        return result
    }

    private func uniqueLocalName(_ proposed: String, usedNames: inout Set<String>) -> String {
        var index = 1
        var candidate = FilenamePolicy.sanitized(proposed)
        while !usedNames.insert(normalizedFilenameKey(candidate)).inserted {
            index += 1
            candidate = FilenamePolicy.uniqueName(proposed, index: index)
        }
        return candidate
    }

    private func normalizedFilenameKey(_ name: String) -> String {
        FilenamePolicy.collisionKey(name)
    }

    private func isLikelyComplete(remoteObject: MTPObject, localPath: String) -> Bool {
        guard !remoteObject.isFolder,
              let remoteDate = remoteObject.modificationDate,
              let values = try? URL(fileURLWithPath: localPath).resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              UInt64(max(0, values.fileSize ?? -1)) == remoteObject.size,
              let localDate = values.contentModificationDate else {
            return false
        }
        return abs(localDate.timeIntervalSince(remoteDate)) <= 2
    }

    private func isLikelyComplete(localURL: URL, remoteObject: MTPObject) -> Bool {
        guard let remoteDate = remoteObject.modificationDate,
              let values = try? localURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              UInt64(max(0, values.fileSize ?? -1)) == remoteObject.size,
              let localDate = values.contentModificationDate else {
            return false
        }
        return abs(localDate.timeIntervalSince(remoteDate)) <= 2
    }

    private func cancelledError() -> MTPClientError {
        MTPClientError(
            code: Int32(MTP_BRIDGE_ERROR_CANCELLED.rawValue),
            retryable: false,
            message: NSLocalizedString("transfer.cancelled", comment: "")
        )
    }

    private func setTotal(jobID: UUID, totalBytes: UInt64) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].totalBytes = totalBytes
        jobs[index].phase = .transferring
        jobs[index].updatedAt = Date()
        persistImmediately()
    }

    private func publishProgress(
        jobID: UUID,
        completedBytes: UInt64,
        totalBytes: UInt64,
        force: Bool = false
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - (lastProgressPublish[jobID] ?? 0) < 0.1 { return }
        lastProgressPublish[jobID] = now
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let speed = speedometers[jobID]?.record(bytes: completedBytes, at: now) ?? 0
        let effectiveTotal = max(jobs[index].totalBytes, totalBytes)
        jobs[index].completedBytes = effectiveTotal > 0
            ? min(completedBytes, effectiveTotal)
            : completedBytes
        jobs[index].totalBytes = effectiveTotal
        if effectiveTotal > 0, completedBytes >= effectiveTotal {
            jobs[index].phase = .finalizing
            jobs[index].bytesPerSecond = 0
        } else {
            jobs[index].phase = .transferring
            jobs[index].bytesPerSecond = speed
        }
        jobs[index].updatedAt = Date()
        persistThrottled(now: now)
    }

    private func updateState(
        jobID: UUID,
        state: TransferState,
        errorMessage: String? = nil
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = state
        jobs[index].errorMessage = errorMessage
        jobs[index].updatedAt = Date()
        if state != .running {
            jobs[index].bytesPerSecond = 0
            if state.isTerminal { jobs[index].phase = nil }
        }
        persistImmediately()
    }

    private func complete(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .completed
        jobs[index].completedBytes = max(jobs[index].completedBytes, jobs[index].totalBytes)
        jobs[index].bytesPerSecond = 0
        jobs[index].phase = nil
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
        persistImmediately()
        finishWaiter(jobID: jobID, result: .success(()))
    }

    private func fail(jobID: UUID, message: String) {
        updateState(jobID: jobID, state: .failed, errorMessage: message)
        finishWaiter(
            jobID: jobID,
            result: .failure(TransferCoordinatorError(message: message))
        )
    }

    private func handleDisconnectInterruption(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let message = NSLocalizedString("error.no_device_connected", comment: "")
        if ephemeralJobIDs.contains(jobID) {
            jobs[index].state = .failed
            jobs[index].errorMessage = message
            jobs[index].bytesPerSecond = 0
            jobs[index].phase = nil
            jobs[index].updatedAt = Date()
            persistImmediately()
            finishWaiter(
                jobID: jobID,
                result: .failure(TransferCoordinatorError(message: message))
            )
            return
        }

        // Persistent queue jobs pause instead of becoming cancelled. They resume
        // with a fresh cancellation token after the same phone reconnects.
        jobs[index].state = .queued
        jobs[index].attempt = 0
        jobs[index].errorMessage = nil
        jobs[index].bytesPerSecond = 0
        jobs[index].phase = nil
        jobs[index].updatedAt = Date()
        persistImmediately()
    }

    private func markPaused(jobID: UUID) {
        pauseRequestedJobIDs.remove(jobID)
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].state = .paused
        jobs[index].bytesPerSecond = 0
        jobs[index].phase = nil
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
        persistImmediately()
    }

    private func markCancelled(jobID: UUID) {
        updateState(jobID: jobID, state: .cancelled, errorMessage: nil)
        finishWaiter(jobID: jobID, result: .failure(CancellationError()))
    }

    private func finishWaiter(
        jobID: UUID,
        result: Result<Void, Error>
    ) {
        guard let continuation = completionWaiters.removeValue(forKey: jobID) else { return }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private var persistableJobs: [TransferJob] {
        jobs.filter { !ephemeralJobIDs.contains($0.id) }
    }

    private func persistThrottled(now: TimeInterval) {
        guard now - lastPersistTime >= 1 else { return }
        lastPersistTime = now
        store.save(persistableJobs)
    }

    private func persistImmediately() {
        lastPersistTime = ProcessInfo.processInfo.systemUptime
        store.save(persistableJobs)
    }
}
