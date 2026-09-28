import Foundation

/// **"What to order", as the server ranks it since 0051** — the contract suites' oracle.
///
/// By the printed score (one decimal) descending, a 6 above every 5; ties by review count
/// descending; then name (case-insensitive); then id. Unscored dishes follow every scored one,
/// ordered the same way among themselves. `MenuDish.isRankedBefore` states the same rule for the in-memory stand-in.
enum MenuOrder {
    struct Key {
        let score: Double?
        let reviewCount: Int
        let name: String
        let id: UUID
    }

    static func isOrderedBefore(_ lhs: Key, _ rhs: Key) -> Bool {
        let left = lhs.score ?? -1, right = rhs.score ?? -1
        if left != right { return left > right }
        if lhs.reviewCount != rhs.reviewCount { return lhs.reviewCount > rhs.reviewCount }
        let byName = lhs.name.lowercased().compare(rhs.name.lowercased())
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    /// True when every adjacent pair is in order (a tie on every key cannot happen: ids differ).
    static func isRanked(_ keys: [Key]) -> Bool {
        zip(keys, keys.dropFirst()).allSatisfy { isOrderedBefore($0, $1) }
    }
}
