import Foundation

struct BookmarkStore {
    static func makeBookmark(for url: URL) throws -> Data {
#if os(macOS)
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#else
        // The application target is macOS-only. This fallback keeps the transfer
        // coordinator type-checkable in cross-platform CI without weakening the
        // sandbox behavior used by the actual app.
        return Data(url.path.utf8)
#endif
    }

    static func makeWritableBookmark(for url: URL) throws -> Data {
#if os(macOS)
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#else
        return Data(url.path.utf8)
#endif
    }

    static func resolve(bookmark: Data?, fallbackPath: String) throws -> URL {
#if os(macOS)
        guard let bookmark else { return URL(fileURLWithPath: fallbackPath) }
        var stale = false
        return try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
#else
        return URL(fileURLWithPath: fallbackPath)
#endif
    }
}

final class ScopedURLAccess {
    let url: URL
    private var started: Bool

    init(url: URL) {
        self.url = url
#if os(macOS)
        started = url.startAccessingSecurityScopedResource()
#else
        started = false
#endif
    }

    func stop() {
        guard started else { return }
        started = false
#if os(macOS)
        url.stopAccessingSecurityScopedResource()
#endif
    }

    deinit {
        stop()
    }
}
