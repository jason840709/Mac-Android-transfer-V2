import Foundation

private struct TransferQueueEnvelope: Codable {
    var schemaVersion: Int
    var jobs: [TransferJob]
}

struct TransferQueueStore {
    private let fileURL: URL
    private let backupDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("MTPBridge", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("transfers.json")
        backupDirectoryURL = directory.appendingPathComponent("StateBackups", isDirectory: true)
    }

    func load() -> [TransferJob] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        let decodedJobs: [TransferJob]
        let sourceSchemaVersion: Int?
        var shouldRewrite = false

        if let envelope = try? JSONDecoder().decode(TransferQueueEnvelope.self, from: data) {
            decodedJobs = envelope.jobs
            sourceSchemaVersion = envelope.schemaVersion
            if envelope.schemaVersion != TransferQueuePersistencePolicy.currentSchemaVersion {
                shouldRewrite = true
            }
        } else if let legacyJobs = try? JSONDecoder().decode([TransferJob].self, from: data) {
            decodedJobs = legacyJobs
            sourceSchemaVersion = nil
            shouldRewrite = true
            backupLegacyQueue(data)
        } else {
            // Unknown/corrupt queue formats are never executed. Keep the source
            // file untouched so a future recovery tool can inspect it.
            return []
        }

        var migrated: [TransferJob] = []
        migrated.reserveCapacity(decodedJobs.count)

        for job in decodedJobs {
            var recovered = job
            if TransferQueuePersistencePolicy.requiresUserRestart(
                job,
                sourceSchemaVersion: sourceSchemaVersion
            ) {
                recovered.state = .failed
                recovered.phase = nil
                recovered.errorMessage = NSLocalizedString(
                    "error.legacy_upload_requires_redrag",
                    comment: ""
                )
                recovered.bytesPerSecond = 0
                recovered.attempt = 0
                recovered.updatedAt = Date()
                shouldRewrite = true
            } else if job.state == .paused {
                recovered.phase = nil
                recovered.bytesPerSecond = 0
            } else if !job.state.isTerminal {
                recovered.state = .queued
                recovered.errorMessage = nil
                recovered.bytesPerSecond = 0
                recovered.attempt = 0
                recovered.phase = nil
            }
            migrated.append(recovered)
        }

        if shouldRewrite {
            save(migrated)
        }
        return migrated
    }

    func save(_ jobs: [TransferJob]) {
        do {
            let envelope = TransferQueueEnvelope(
                schemaVersion: TransferQueuePersistencePolicy.currentSchemaVersion,
                jobs: jobs
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Queue persistence is best effort; transfers continue in memory.
        }
    }

    private func backupLegacyQueue(_ data: Data) {
        do {
            try FileManager.default.createDirectory(
                at: backupDirectoryURL,
                withIntermediateDirectories: true
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "transfers-before-schema-v2-\(formatter.string(from: Date())).json"
            let destination = backupDirectoryURL.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
        } catch {
            // A failed backup must not cause an unsafe legacy job to run.
        }
    }
}
