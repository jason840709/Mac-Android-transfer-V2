import Foundation

/// Re-resolves a saved remote folder path against the current MTP session.
/// MTP object handles are session/device-state identifiers and may become stale
/// after USB mode changes, reconnects, or another MTP client briefly owned the
/// device. Folder names provide the stable breadcrumb needed to recover fresh
/// handles before a write.
public enum RemoteFolderPathResolver {
    public static func resolveParentID(
        destination: RemoteTransferDestination,
        rootObjectID: UInt32 = mtpRootObjectID,
        listChildren: (_ storageID: UInt32, _ parentID: UInt32) async throws -> [MTPObject]
    ) async throws -> UInt32? {
        guard let path = destination.parentPath else {
            // Parent object handles are session-bound. Legacy persisted uploads
            // without a breadcrumb must be restarted by the user instead of
            // replaying a captured handle from an older MTP session.
            return nil
        }
        guard !path.isEmpty else { return rootObjectID }

        var parentID = rootObjectID
        for component in path {
            let children = try await listChildren(destination.storageID, parentID)
            guard let folder = matchingFolder(named: component, in: children) else {
                return nil
            }
            parentID = folder.id
        }
        return parentID
    }

    public static func resolveBreadcrumbs(
        storageID: UInt32,
        names: [String],
        rootObjectID: UInt32 = mtpRootObjectID,
        listChildren: (_ storageID: UInt32, _ parentID: UInt32) async throws -> [MTPObject]
    ) async throws -> [RemoteFolder]? {
        guard !names.isEmpty else { return [] }

        var parentID = rootObjectID
        var resolved: [RemoteFolder] = []
        resolved.reserveCapacity(names.count)

        for component in names {
            let children = try await listChildren(storageID, parentID)
            guard let folder = matchingFolder(named: component, in: children) else {
                return nil
            }
            resolved.append(
                RemoteFolder(
                    storageID: storageID,
                    objectID: folder.id,
                    name: folder.name
                )
            )
            parentID = folder.id
        }
        return resolved
    }

    private static func matchingFolder(named name: String, in children: [MTPObject]) -> MTPObject? {
        if let exact = children.first(where: { $0.isFolder && $0.name == name }) {
            return exact
        }
        let key = FilenamePolicy.collisionKey(name)
        return children.first { $0.isFolder && FilenamePolicy.collisionKey($0.name) == key }
    }
}
