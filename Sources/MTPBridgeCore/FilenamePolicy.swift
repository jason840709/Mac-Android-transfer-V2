import Foundation

public enum FilenamePolicyError: Error, Equatable, Sendable {
    case empty
    case reserved
    case containsPathSeparator
    case containsControlCharacter
    case tooLong
}

public enum FilenamePolicy {
    public static let maximumUTF8Bytes = 240

    public static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FilenamePolicyError.empty }
        guard trimmed != ".", trimmed != ".." else { throw FilenamePolicyError.reserved }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            throw FilenamePolicyError.containsPathSeparator
        }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw FilenamePolicyError.containsControlCharacter
        }
        guard utf8Length(trimmed) <= maximumUTF8Bytes else {
            throw FilenamePolicyError.tooLong
        }
    }

    public static func sanitized(_ name: String, fallback: String = "Untitled") -> String {
        clipped(cleaned(name, fallback: fallback), maximumBytes: maximumUTF8Bytes)
    }

    /// The exact filename returned to Finder for an NSFilePromiseProvider. The
    /// extension is already part of the name and must never be appended again.
    public static func promisedFileName(_ name: String) -> String {
        sanitized(name)
    }

    /// Stable, locale-independent comparison key used to avoid case and Unicode
    /// collisions on common phone and Mac filesystems.
    public static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// A deterministic fixed-width token suitable for local sidecar filenames.
    /// This is not a cryptographic digest; the sidecar metadata performs the
    /// authoritative identity check before any partial data is reused.
    public static func stableToken(_ value: String) -> String {
        let bytes = Array(value.utf8)
        let first = fnv1a64(bytes, seed: 0xcbf29ce484222325)
        let second = fnv1a64(bytes.reversed(), seed: 0x84222325cbf29ce4)
        return paddedHex(first) + paddedHex(second)
    }

    /// Produces a collision-safe sibling name while keeping the extension and
    /// staying below the conservative MTP filename limit.
    public static func uniqueName(_ proposed: String, index: Int) -> String {
        let cleanedName = cleaned(proposed, fallback: "Untitled")
        guard index > 1 else {
            return clipped(cleanedName, maximumBytes: maximumUTF8Bytes)
        }

        let suffix = " (\(index))"
        let path = cleanedName as NSString
        var ext = path.pathExtension
        var stem = path.deletingPathExtension
        var extensionSuffix = ext.isEmpty ? "" : ".\(ext)"

        if utf8Length(suffix) + utf8Length(extensionSuffix) >= maximumUTF8Bytes {
            ext = ""
            extensionSuffix = ""
            stem = cleanedName
        }

        let budget = max(1, maximumUTF8Bytes - utf8Length(suffix) - utf8Length(extensionSuffix))
        stem = clipped(stem, maximumBytes: budget)
        if stem.isEmpty { stem = "Item" }
        return stem + suffix + extensionSuffix
    }

    public static func temporaryUploadName(finalName: String, token: UUID = UUID()) -> String {
        hiddenName(prefix: ".mtpbridge-upload", finalName: finalName, token: token)
    }

    public static func backupName(finalName: String, token: UUID = UUID()) -> String {
        hiddenName(prefix: ".mtpbridge-backup", finalName: finalName, token: token)
    }

    private static func hiddenName(prefix: String, finalName: String, token: UUID) -> String {
        let safeFinal = cleaned(finalName, fallback: "Untitled")
        let shortToken = token.uuidString.prefix(8).lowercased()
        let fixed = "\(prefix)-\(shortToken)-"

        let path = safeFinal as NSString
        var extensionSuffix = path.pathExtension.isEmpty ? "" : ".\(path.pathExtension)"
        var stem = path.deletingPathExtension
        if utf8Length(fixed) + utf8Length(extensionSuffix) + 1 > maximumUTF8Bytes {
            extensionSuffix = ""
            stem = safeFinal
        }

        let budget = max(1, maximumUTF8Bytes - utf8Length(fixed) - utf8Length(extensionSuffix))
        stem = clipped(stem, maximumBytes: budget)
        if stem.isEmpty { stem = "item" }
        return fixed + stem + extensionSuffix
    }

    private static func cleaned(_ name: String, fallback: String) -> String {
        var result = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty || result == "." || result == ".." {
            result = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.isEmpty || result == "." || result == ".." {
            result = "Untitled"
        }
        return result
    }

    private static func clipped(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = value
        while utf8Length(result) > maximumBytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    private static func paddedHex(_ value: UInt64) -> String {
        let raw = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - raw.count)) + raw
    }

    private static func utf8Length(_ value: String) -> Int {
        value.lengthOfBytes(using: String.Encoding.utf8)
    }
}
