import Foundation

/// **Photos that finished staging, merged into the cluster as it is now** — never a list
/// snapshotted when loading began. A library pick takes a while to load; a photo removed with a
/// long press in the meantime must stay removed (QA, round 3).
public enum StagedMerge {
    /// `current` with every `added` item it does not already hold appended, in order, up to `limit`.
    public static func appending<Item, ID: Hashable>(
        _ added: [Item], to current: [Item], id: (Item) -> ID, limit: Int
    ) -> [Item] {
        var merged = current
        var seen = Set(current.map(id))
        for item in added where merged.count < limit && seen.insert(id(item)).inserted {
            merged.append(item)
        }
        return merged
    }
}
