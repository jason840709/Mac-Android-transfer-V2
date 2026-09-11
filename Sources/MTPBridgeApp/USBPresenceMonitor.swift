import Foundation

/// Runs lightweight USB endpoint checks away from the main actor. A successful
/// enumeration must miss the connected endpoint twice before removal is
/// reported; enumeration errors are ignored rather than treated as unplugging.
final class USBPresenceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func start(
        candidate: MTPDeviceCandidate,
        onRemoval: @escaping @MainActor @Sendable () -> Void
    ) {
        stop()
        let monitorTask = Task.detached(priority: .utility) {
            var decision = USBPresenceDecision(requiredConsecutiveMisses: 2)
            while !Task.isCancelled {
                do {
                    let present = try await LibMTPClient.isUSBDevicePresent(candidate)
                    guard !Task.isCancelled else { return }
                    let removed = decision.observe(present ? .present : .missing)
                    if removed {
                        await onRemoval()
                        return
                    }
                } catch {
                    // A libusb enumeration failure is not proof that the phone
                    // was removed. Keep the last known state and retry.
                    _ = decision.observe(.probeFailed)
                }

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }

        lock.lock()
        task = monitorTask
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let existing = task
        task = nil
        lock.unlock()
        existing?.cancel()
    }

    deinit {
        stop()
    }
}
