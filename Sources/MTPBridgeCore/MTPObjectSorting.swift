import Foundation

public enum MTPObjectSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case type
    case size
    case created
    case modified

    public var id: String { rawValue }
}

public enum MTPObjectCategory: Int, Codable, Sendable {
    case folder = 0
    case image
    case video
    case audio
    case pdf
    case archive
    case document
    case application
    case other
}

public extension MTPObject {
    var filenameExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var category: MTPObjectCategory {
        if isFolder { return .folder }
        switch filenameExtension {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "dng", "raw":
            return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "3gp":
            return .video
        case "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus":
            return .audio
        case "pdf":
            return .pdf
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .archive
        case "doc", "docx", "pages", "txt", "md", "rtf", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key":
            return .document
        case "apk", "aab":
            return .application
        default:
            return .other
        }
    }
}

public enum MTPObjectSorter {
    public static func sorted(
        _ objects: [MTPObject],
        by key: MTPObjectSortKey,
        ascending: Bool
    ) -> [MTPObject] {
        objects.sorted { lhs, rhs in
            // Keep folders together at the top, matching Finder's default browsing behavior.
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }

            switch key {
            case .name:
                return compareNames(lhs, rhs, ascending: ascending)

            case .type:
                if lhs.category != rhs.category {
                    return ascending
                        ? lhs.category.rawValue < rhs.category.rawValue
                        : lhs.category.rawValue > rhs.category.rawValue
                }
                if lhs.filenameExtension != rhs.filenameExtension {
                    let comparison = lhs.filenameExtension.localizedStandardCompare(rhs.filenameExtension)
                    return ordered(comparison, ascending: ascending)
                }
                return compareNames(lhs, rhs, ascending: ascending)

            case .size:
                if lhs.isFolder, rhs.isFolder {
                    return compareNames(lhs, rhs, ascending: ascending)
                }
                if lhs.size != rhs.size {
                    return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
                }
                return compareNames(lhs, rhs, ascending: ascending)

            case .created:
                return compareDates(
                    lhs.creationDate,
                    rhs.creationDate,
                    lhs: lhs,
                    rhs: rhs,
                    ascending: ascending
                )

            case .modified:
                return compareDates(
                    lhs.modificationDate,
                    rhs.modificationDate,
                    lhs: lhs,
                    rhs: rhs,
                    ascending: ascending
                )
            }
        }
    }

    private static func compareDates(
        _ lhsDate: Date?,
        _ rhsDate: Date?,
        lhs: MTPObject,
        rhs: MTPObject,
        ascending: Bool
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (left?, right?):
            if left != right { return ascending ? left < right : left > right }
            return compareNames(lhs, rhs, ascending: ascending)
        case (.some, .none):
            // Unknown dates remain at the bottom in both directions.
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return compareNames(lhs, rhs, ascending: ascending)
        }
    }

    private static func compareNames(
        _ lhs: MTPObject,
        _ rhs: MTPObject,
        ascending: Bool
    ) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            return ascending ? lhs.id < rhs.id : lhs.id > rhs.id
        }
        return ordered(comparison, ascending: ascending)
    }

    private static func ordered(_ comparison: ComparisonResult, ascending: Bool) -> Bool {
        ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}
