import Foundation

/// Pure path mapping for Finder file promises. Finder has already combined the
/// promised filename with the drop directory before it calls the provider, so
/// the remote root maps to `exactDestinationURL` itself. Only descendants of a
/// promised folder are appended below that URL.
public enum FilePromiseDestinationLayout {
    public static func targetURL(
        exactDestinationURL: URL,
        relativeComponents: [String],
        isDirectory: Bool
    ) -> URL {
        guard relativeComponents.isEmpty == false else {
            return exactDestinationURL
        }

        return relativeComponents.enumerated().reduce(exactDestinationURL) { partial, pair in
            let (index, component) = pair
            let isFinalComponent = index == relativeComponents.count - 1
            return partial.appendingPathComponent(
                component,
                isDirectory: isFinalComponent ? isDirectory : true
            )
        }
    }
}
