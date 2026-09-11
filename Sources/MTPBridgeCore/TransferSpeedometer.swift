import Foundation

public struct TransferSpeedometer: Sendable {
    private struct Sample: Sendable {
        var time: TimeInterval
        var bytes: UInt64
    }

    private var samples: [Sample] = []
    public var window: TimeInterval

    public init(window: TimeInterval = 3) {
        self.window = max(0.25, window)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func record(bytes: UInt64, at time: TimeInterval) -> Double {
        samples.append(Sample(time: time, bytes: bytes))
        let cutoff = time - window
        if let firstValid = samples.firstIndex(where: { $0.time >= cutoff }) {
            samples.removeFirst(firstValid)
        } else if samples.count > 1 {
            samples.removeFirst(samples.count - 1)
        }
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        let byteDelta = last.bytes >= first.bytes ? last.bytes - first.bytes : 0
        return Double(byteDelta) / (last.time - first.time)
    }
}
