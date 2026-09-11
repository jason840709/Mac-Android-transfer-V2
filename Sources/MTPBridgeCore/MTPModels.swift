import Foundation

public let mtpRootObjectID = UInt32.max

public struct MTPDeviceCandidate: Codable, Hashable, Identifiable, Sendable {
    public var busLocation: UInt32
    public var deviceNumber: UInt8
    public var vendorID: UInt16
    public var productID: UInt16
    public var vendor: String
    public var product: String

    public var id: String {
        "\(busLocation):\(deviceNumber):\(vendorID):\(productID)"
    }

    public init(
        busLocation: UInt32,
        deviceNumber: UInt8,
        vendorID: UInt16,
        productID: UInt16,
        vendor: String,
        product: String
    ) {
        self.busLocation = busLocation
        self.deviceNumber = deviceNumber
        self.vendorID = vendorID
        self.productID = productID
        self.vendor = vendor
        self.product = product
    }
}

public struct MTPDeviceInfo: Codable, Hashable, Sendable {
    public var manufacturer: String
    public var model: String
    public var serialNumber: String
    public var friendlyName: String
    public var deviceVersion: String
    public var supportsPartialDownload: Bool
    public var supportsPartialUpload: Bool
    public var supportsMove: Bool

    public var displayName: String {
        if !friendlyName.isEmpty { return friendlyName }
        if !model.isEmpty { return model }
        return manufacturer.isEmpty ? "Android" : manufacturer
    }

    public init(
        manufacturer: String,
        model: String,
        serialNumber: String,
        friendlyName: String,
        deviceVersion: String,
        supportsPartialDownload: Bool,
        supportsPartialUpload: Bool,
        supportsMove: Bool
    ) {
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber
        self.friendlyName = friendlyName
        self.deviceVersion = deviceVersion
        self.supportsPartialDownload = supportsPartialDownload
        self.supportsPartialUpload = supportsPartialUpload
        self.supportsMove = supportsMove
    }
}

public struct MTPDeviceIdentity: Codable, Hashable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var manufacturer: String
    public var model: String
    public var serialNumber: String

    public var hasStableSerialNumber: Bool {
        !serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(candidate: MTPDeviceCandidate, info: MTPDeviceInfo) {
        vendorID = candidate.vendorID
        productID = candidate.productID
        manufacturer = info.manufacturer
        model = info.model
        serialNumber = info.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(
        vendorID: UInt16,
        productID: UInt16,
        manufacturer: String,
        model: String,
        serialNumber: String
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.model = model
        self.serialNumber = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(candidate: MTPDeviceCandidate, info: MTPDeviceInfo) -> Bool {
        guard candidate.vendorID == vendorID, candidate.productID == productID else { return false }
        let currentSerial = info.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasStableSerialNumber {
            return !currentSerial.isEmpty &&
                currentSerial.precomposedStringWithCanonicalMapping ==
                serialNumber.precomposedStringWithCanonicalMapping
        }
        return FilenamePolicy.collisionKey(info.manufacturer) == FilenamePolicy.collisionKey(manufacturer) &&
            FilenamePolicy.collisionKey(info.model) == FilenamePolicy.collisionKey(model)
    }
}

public struct MTPStorage: Codable, Hashable, Identifiable, Sendable {
    public var id: UInt32
    public var name: String
    public var volumeIdentifier: String
    public var capacity: UInt64
    public var freeSpace: UInt64
    public var isReadOnly: Bool

    public var usedSpace: UInt64 { capacity >= freeSpace ? capacity - freeSpace : 0 }
    public var usedFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(max(Double(usedSpace) / Double(capacity), 0), 1)
    }

    public init(
        id: UInt32,
        name: String,
        volumeIdentifier: String,
        capacity: UInt64,
        freeSpace: UInt64,
        isReadOnly: Bool
    ) {
        self.id = id
        self.name = name
        self.volumeIdentifier = volumeIdentifier
        self.capacity = capacity
        self.freeSpace = freeSpace
        self.isReadOnly = isReadOnly
    }
}

public struct MTPObject: Codable, Hashable, Identifiable, Sendable {
    public var id: UInt32
    public var parentID: UInt32
    public var storageID: UInt32
    public var name: String
    public var size: UInt64
    public var creationDate: Date?
    public var modificationDate: Date?
    public var isFolder: Bool
    public var fileType: Int32

    public init(
        id: UInt32,
        parentID: UInt32,
        storageID: UInt32,
        name: String,
        size: UInt64,
        creationDate: Date? = nil,
        modificationDate: Date?,
        isFolder: Bool,
        fileType: Int32
    ) {
        self.id = id
        self.parentID = parentID
        self.storageID = storageID
        self.name = name
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isFolder = isFolder
        self.fileType = fileType
    }
}


public struct PartialDownloadFingerprint: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var storageID: UInt32
    public var objectID: UInt32
    public var name: String
    public var expectedSize: UInt64
    public var modificationDate: Date?

    public init(object: MTPObject) {
        version = Self.currentVersion
        storageID = object.storageID
        objectID = object.id
        name = object.name
        expectedSize = object.size
        modificationDate = object.modificationDate
    }

    public func safelyMatches(_ object: MTPObject, dateTolerance: TimeInterval = 2) -> Bool {
        guard version == Self.currentVersion,
              storageID == object.storageID,
              objectID == object.id,
              name == object.name,
              expectedSize == object.size,
              let storedDate = modificationDate,
              let currentDate = object.modificationDate else {
            return false
        }
        return abs(storedDate.timeIntervalSince(currentDate)) <= dateTolerance
    }
}

public struct RemoteFolder: Codable, Hashable, Sendable {
    public var storageID: UInt32
    public var objectID: UInt32
    public var name: String

    public init(storageID: UInt32, objectID: UInt32, name: String) {
        self.storageID = storageID
        self.objectID = objectID
        self.name = name
    }
}

public enum TransferDirection: String, Codable, Hashable, Sendable {
    case upload
    case download
}

public enum TransferPhase: String, Codable, Hashable, Sendable {
    case preparing
    case transferring
    case finalizing
}

public enum TransferState: String, Codable, Hashable, Sendable {
    case queued
    case preparing
    case running
    case retrying
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

public struct LocalTransferSource: Codable, Hashable, Sendable {
    public var path: String
    public var securityScopedBookmark: Data?
    public var preferredRemoteName: String?

    public init(
        path: String,
        securityScopedBookmark: Data?,
        preferredRemoteName: String? = nil
    ) {
        self.path = path
        self.securityScopedBookmark = securityScopedBookmark
        self.preferredRemoteName = preferredRemoteName
    }
}

public enum LocalTransferPlacement: String, Codable, Hashable, Sendable {
    /// The stored path is a directory and the transfer engine creates a named
    /// top-level item inside it. This is used by the normal Download command.
    case insideDirectory

    /// The stored path is the exact item URL supplied by Finder to an
    /// NSFilePromiseProvider. The remote root must be written to this URL
    /// directly, without appending the promised filename a second time.
    case exactItem
}

public struct LocalTransferDestination: Codable, Hashable, Sendable {
    public var directoryPath: String
    public var securityScopedBookmark: Data?
    public var preferredTopLevelName: String?

    /// Optional for backward-compatible decoding of transfer queues created by
    /// versions before 0.6.0. A missing value retains the historical normal
    /// download behavior.
    public var placement: LocalTransferPlacement?

    public init(
        directoryPath: String,
        securityScopedBookmark: Data?,
        preferredTopLevelName: String? = nil,
        placement: LocalTransferPlacement? = nil
    ) {
        self.directoryPath = directoryPath
        self.securityScopedBookmark = securityScopedBookmark
        self.preferredTopLevelName = preferredTopLevelName
        self.placement = placement
    }

    public var effectivePlacement: LocalTransferPlacement {
        placement ?? .insideDirectory
    }
}

public struct RemoteTransferDestination: Codable, Hashable, Sendable {
    public var storageID: UInt32
    public var parentObjectID: UInt32

    /// Folder names from the storage root to the intended upload destination.
    /// New jobs persist this path so a reconnect can re-resolve fresh MTP object
    /// handles instead of replaying a handle captured from an older session.
    /// Nil is kept for decoding queues created by older builds.
    public var parentPath: [String]?

    public init(
        storageID: UInt32,
        parentObjectID: UInt32,
        parentPath: [String]? = nil
    ) {
        self.storageID = storageID
        self.parentObjectID = parentObjectID
        self.parentPath = parentPath
    }
}

public enum TransferRequest: Codable, Hashable, Sendable {
    case upload(source: LocalTransferSource, destination: RemoteTransferDestination)
    case download(source: MTPObject, destination: LocalTransferDestination)
}

public struct TransferJob: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var request: TransferRequest
    public var deviceIdentity: MTPDeviceIdentity?
    public var displayName: String
    public var direction: TransferDirection
    public var state: TransferState
    public var phase: TransferPhase?
    public var completedBytes: UInt64
    public var totalBytes: UInt64
    public var bytesPerSecond: Double
    public var attempt: Int
    public var maxAttempts: Int
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    public init(
        id: UUID = UUID(),
        request: TransferRequest,
        deviceIdentity: MTPDeviceIdentity? = nil,
        displayName: String,
        direction: TransferDirection,
        state: TransferState = .queued,
        phase: TransferPhase? = nil,
        completedBytes: UInt64 = 0,
        totalBytes: UInt64 = 0,
        bytesPerSecond: Double = 0,
        attempt: Int = 0,
        maxAttempts: Int = 4,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.request = request
        self.deviceIdentity = deviceIdentity
        self.displayName = displayName
        self.direction = direction
        self.state = state
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
