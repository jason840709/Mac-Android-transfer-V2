import Foundation

public struct BrowserLocation: Codable, Hashable, Sendable {
    public var storageID: UInt32
    public var breadcrumbs: [RemoteFolder]

    public init(storageID: UInt32, breadcrumbs: [RemoteFolder]) {
        self.storageID = storageID
        self.breadcrumbs = breadcrumbs
    }
}

/// Finder-style linear browser history. Visiting a new location after going
/// back discards the obsolete forward branch.
public struct BrowserNavigationHistory: Sendable {
    public let maximumCount: Int
    public private(set) var entries: [BrowserLocation]
    public private(set) var currentIndex: Int?

    public init(maximumCount: Int = 100) {
        self.maximumCount = max(2, maximumCount)
        entries = []
        currentIndex = nil
    }

    public var current: BrowserLocation? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    public var canGoBack: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    public var canGoForward: Bool {
        guard let currentIndex else { return false }
        return currentIndex + 1 < entries.count
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        currentIndex = nil
    }

    public mutating func reset(to location: BrowserLocation) {
        entries = [location]
        currentIndex = 0
    }

    public mutating func visit(_ location: BrowserLocation) {
        if current == location { return }

        if let currentIndex, currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(location)
        currentIndex = entries.count - 1

        if entries.count > maximumCount {
            let overflow = entries.count - maximumCount
            entries.removeFirst(overflow)
            currentIndex = max(0, (currentIndex ?? 0) - overflow)
        }
    }

    public mutating func goBack() -> BrowserLocation? {
        guard canGoBack, let currentIndex else { return nil }
        self.currentIndex = currentIndex - 1
        return current
    }

    public mutating func goForward() -> BrowserLocation? {
        guard canGoForward, let currentIndex else { return nil }
        self.currentIndex = currentIndex + 1
        return current
    }

    /// Restores the cursor after the target folder failed to load. This keeps
    /// the visible location and the logical history index in sync.
    public mutating func restore(index: Int?) {
        guard let index, entries.indices.contains(index) else {
            currentIndex = entries.isEmpty ? nil : min(currentIndex ?? 0, entries.count - 1)
            return
        }
        currentIndex = index
    }
}
