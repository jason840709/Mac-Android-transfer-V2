import Foundation

struct MTPClientError: LocalizedError, Sendable {
    let code: Int32
    let retryable: Bool
    let message: String

    var errorDescription: String? { message }
    var isCancelled: Bool { code == Int32(MTP_BRIDGE_ERROR_CANCELLED.rawValue) }
}

final class BridgeCancellation: @unchecked Sendable {
    private let pointer: OpaquePointer

    init?() {
        guard let pointer = mtp_bridge_cancel_create() else { return nil }
        self.pointer = pointer
    }

    deinit {
        mtp_bridge_cancel_destroy(pointer)
    }

    func request() {
        mtp_bridge_cancel_request(pointer)
    }

    func reset() {
        mtp_bridge_cancel_reset(pointer)
    }

    var isRequested: Bool {
        mtp_bridge_cancel_is_requested(pointer)
    }

    fileprivate var rawPointer: OpaquePointer { pointer }
}

private final class ProgressBox: @unchecked Sendable {
    let callback: @Sendable (UInt64, UInt64) -> Void

    init(callback: @escaping @Sendable (UInt64, UInt64) -> Void) {
        self.callback = callback
    }
}

private let cProgressCallback: @convention(c) (
    UInt64,
    UInt64,
    UnsafeMutableRawPointer?
) -> Int32 = { completed, total, context in
    guard let context else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(context).takeUnretainedValue()
    box.callback(completed, total)
    return 0
}

actor LibMTPClient {
    private var session: OpaquePointer?
    private(set) var candidate: MTPDeviceCandidate?

    static func detectDevices() async throws -> [MTPDeviceCandidate] {
        try await Task.detached(priority: .userInitiated) {
            var error = mtp_bridge_error_t()
            mtp_bridge_error_init(&error)
            defer { mtp_bridge_error_clear(&error) }

            var list = mtp_bridge_device_list_t()
            let status = mtp_bridge_detect_devices(&list, &error)
            defer { mtp_bridge_device_list_clear(&list) }
            guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
                throw makeClientError(error, fallbackCode: status)
            }
            guard let items = list.items else { return [] }
            return (0..<Int(list.count)).map { index in
                let item = items[index]
                return MTPDeviceCandidate(
                    busLocation: item.bus_location,
                    deviceNumber: item.device_number,
                    vendorID: item.vendor_id,
                    productID: item.product_id,
                    vendor: string(item.vendor),
                    product: string(item.product)
                )
            }
        }.value
    }

    static func isUSBDevicePresent(_ candidate: MTPDeviceCandidate) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            var error = mtp_bridge_error_t()
            mtp_bridge_error_init(&error)
            defer { mtp_bridge_error_clear(&error) }

            var present = false
            let status = mtp_bridge_is_usb_device_present(
                candidate.busLocation,
                candidate.deviceNumber,
                candidate.vendorID,
                candidate.productID,
                &present,
                &error
            )
            guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
                throw makeClientError(error, fallbackCode: status)
            }
            return present
        }.value
    }

    func open(_ candidate: MTPDeviceCandidate) throws -> (MTPDeviceInfo, [MTPStorage]) {
        close()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }

        guard let newSession = mtp_bridge_open_device(
            candidate.busLocation,
            candidate.deviceNumber,
            &error
        ) else {
            throw Self.makeClientError(error, fallbackCode: Int32(MTP_BRIDGE_ERROR_CONNECTING.rawValue))
        }
        session = newSession
        self.candidate = candidate
        do {
            let info = try readDeviceInfo()
            let storages = try readStorages()
            return (info, storages)
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let session {
            mtp_bridge_close_device(session)
            self.session = nil
            candidate = nil
        }
    }

    func readDeviceInfo() throws -> MTPDeviceInfo {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }

        var info = mtp_bridge_device_info_t()
        let status = mtp_bridge_get_device_info(session, &info, &error)
        defer { mtp_bridge_device_info_clear(&info) }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        return MTPDeviceInfo(
            manufacturer: Self.string(info.manufacturer),
            model: Self.string(info.model),
            serialNumber: Self.string(info.serial_number),
            friendlyName: Self.string(info.friendly_name),
            deviceVersion: Self.string(info.device_version),
            supportsPartialDownload: info.supports_partial_download,
            supportsPartialUpload: info.supports_partial_upload,
            supportsMove: info.supports_move
        )
    }

    func readStorages() throws -> [MTPStorage] {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }

        var list = mtp_bridge_storage_list_t()
        let status = mtp_bridge_get_storages(session, &list, &error)
        defer { mtp_bridge_storage_list_clear(&list) }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        guard let items = list.items else { return [] }
        return (0..<Int(list.count)).map { index in
            let item = items[index]
            return MTPStorage(
                id: item.storage_id,
                name: Self.string(item.name),
                volumeIdentifier: Self.string(item.volume_identifier),
                capacity: item.capacity,
                freeSpace: item.free_space,
                isReadOnly: item.read_only
            )
        }
    }

    func listChildren(storageID: UInt32, parentID: UInt32) throws -> [MTPObject] {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }

        var list = mtp_bridge_object_list_t()
        let status = mtp_bridge_list_children(session, storageID, parentID, &list, &error)
        defer { mtp_bridge_object_list_clear(&list) }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        guard let items = list.items else { return [] }
        return (0..<Int(list.count)).map { index in
            let item = items[index]
            let creationDate = item.creation_time > 0
                ? Date(timeIntervalSince1970: TimeInterval(item.creation_time))
                : nil
            let modificationDate = item.modification_time > 0
                ? Date(timeIntervalSince1970: TimeInterval(item.modification_time))
                : nil
            return MTPObject(
                id: item.object_id,
                parentID: item.parent_id,
                storageID: item.storage_id,
                name: Self.string(item.name),
                size: item.size,
                creationDate: creationDate,
                modificationDate: modificationDate,
                isFolder: item.is_folder,
                fileType: item.file_type
            )
        }
    }

    func readCreationDate(objectID: UInt32, fileType: Int32) throws -> Date? {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }

        var timestamp: Int64 = 0
        let status = mtp_bridge_get_object_creation_time(
            session,
            objectID,
            fileType,
            &timestamp,
            &error
        )
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        return timestamp > 0
            ? Date(timeIntervalSince1970: TimeInterval(timestamp))
            : nil
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> UInt32 {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }
        var objectID: UInt32 = 0
        let status = name.withCString { namePointer in
            mtp_bridge_create_folder(session, namePointer, storageID, parentID, &objectID, &error)
        }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        return objectID
    }

    func renameObject(id: UInt32, to newName: String) throws {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }
        let status = newName.withCString { pointer in
            mtp_bridge_rename_object(session, id, pointer, &error)
        }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
    }

    func deleteObject(id: UInt32) throws {
        let session = try requireSession()
        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }
        let status = mtp_bridge_delete_object(session, id, &error)
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
    }

    func download(
        object: MTPObject,
        to temporaryURL: URL,
        allowResume: Bool = true,
        cancellation: BridgeCancellation,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) throws -> UInt64 {
        let session = try requireSession()
        let progressBox = ProgressBox(callback: progress)
        let context = Unmanaged.passRetained(progressBox).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }
        var resumedFrom: UInt64 = 0
        let status = temporaryURL.path.withCString { pathPointer in
            mtp_bridge_download_object(
                session,
                object.id,
                object.size,
                pathPointer,
                allowResume,
                8 * 1024 * 1024,
                cancellation.rawPointer,
                cProgressCallback,
                context,
                &resumedFrom,
                &error
            )
        }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        return resumedFrom
    }

    func uploadAtomic(
        localURL: URL,
        storageID: UInt32,
        parentID: UInt32,
        temporaryName: String,
        finalName: String,
        existingObjectID: UInt32?,
        backupName: String,
        cancellation: BridgeCancellation,
        progress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) throws -> UInt32 {
        let session = try requireSession()
        let progressBox = ProgressBox(callback: progress)
        let context = Unmanaged.passRetained(progressBox).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(context).release() }

        var error = mtp_bridge_error_t()
        mtp_bridge_error_init(&error)
        defer { mtp_bridge_error_clear(&error) }
        var objectID: UInt32 = 0
        let status = localURL.path.withCString { pathPointer in
            temporaryName.withCString { temporaryPointer in
                finalName.withCString { finalPointer in
                    backupName.withCString { backupPointer in
                        mtp_bridge_upload_file_atomic(
                            session,
                            pathPointer,
                            storageID,
                            parentID,
                            temporaryPointer,
                            finalPointer,
                            existingObjectID ?? 0,
                            backupPointer,
                            cancellation.rawPointer,
                            cProgressCallback,
                            context,
                            &objectID,
                            &error
                        )
                    }
                }
            }
        }
        guard status == Int32(MTP_BRIDGE_OK.rawValue) else {
            throw Self.makeClientError(error, fallbackCode: status)
        }
        return objectID
    }

    private func requireSession() throws -> OpaquePointer {
        guard let session else {
            throw MTPClientError(
                code: Int32(MTP_BRIDGE_ERROR_NO_DEVICE.rawValue),
                retryable: true,
                message: NSLocalizedString("error.no_open_device", comment: "")
            )
        }
        return session
    }

    private static func makeClientError(
        _ error: mtp_bridge_error_t,
        fallbackCode: Int32
    ) -> MTPClientError {
        MTPClientError(
            code: error.code == 0 ? fallbackCode : error.code,
            retryable: error.retryable,
            message: string(error.message).isEmpty
                ? NSLocalizedString("error.generic_mtp", comment: "")
                : string(error.message)
        )
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }
}
