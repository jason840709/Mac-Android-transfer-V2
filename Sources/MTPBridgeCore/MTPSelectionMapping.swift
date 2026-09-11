import Foundation

/// Keeps selection attached to stable MTP object identifiers while the visible
/// row order changes because of sorting or background metadata enrichment.
public enum MTPSelectionMapping {
    public static func rowIndexes(
        for selectedObjectIDs: Set<UInt32>,
        in objects: [MTPObject]
    ) -> IndexSet {
        IndexSet(
            objects.enumerated().compactMap { index, object in
                selectedObjectIDs.contains(object.id) ? index : nil
            }
        )
    }

    public static func objectIDs(
        at rowIndexes: IndexSet,
        in objects: [MTPObject]
    ) -> Set<UInt32> {
        Set(
            rowIndexes.compactMap { index in
                objects.indices.contains(index) ? objects[index].id : nil
            }
        )
    }
}
