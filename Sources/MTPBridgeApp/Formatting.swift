import Foundation

extension UInt64 {
    var formattedBytes: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: self),
            countStyle: .file
        )
    }
}

extension Double {
    var formattedTransferSpeed: String {
        guard self > 0, self.isFinite else { return "" }
        let clamped = min(self, Double(UInt64.max))
        return UInt64(clamped).formattedBytes + "/s"
    }
}

extension MTPObject {
    var systemImageName: String {
        switch category {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .pdf: return "doc.richtext.fill"
        case .archive: return "archivebox.fill"
        case .document: return "doc.text.fill"
        case .application: return "app.badge.fill"
        case .other: return "doc.fill"
        }
    }

    var typeDisplayName: String {
        switch category {
        case .folder:
            return NSLocalizedString("file.type.folder", comment: "")
        case .image:
            return NSLocalizedString("file.type.image", comment: "")
        case .video:
            return NSLocalizedString("file.type.video", comment: "")
        case .audio:
            return NSLocalizedString("file.type.audio", comment: "")
        case .pdf:
            return NSLocalizedString("file.type.pdf", comment: "")
        case .archive:
            return NSLocalizedString("file.type.archive", comment: "")
        case .document:
            return NSLocalizedString("file.type.document", comment: "")
        case .application:
            return NSLocalizedString("file.type.application", comment: "")
        case .other:
            return filenameExtension.isEmpty
                ? NSLocalizedString("file.type.file", comment: "")
                : filenameExtension.uppercased()
        }
    }
}
