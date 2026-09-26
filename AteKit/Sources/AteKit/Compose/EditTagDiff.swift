import Foundation

/// **What an edit did to an entry's tag chips**, against the chips it opened with.
///
/// Opening an edit rebuilds the receipt's own chips into the words (``EntryBodyTokens``), so "the
/// words carry tag chips" says nothing about whether the person touched them. Forcing a re-sort for
/// every tagged entry rebuilt every uncorrected line — a typo fix wiped hand corrections (QA, round
/// 3). So chips are compared by **identity** (a token keeps its id through every edit):
///
/// - a chip whose id was not there at the start is **new** → the sort is forced, carrying the chips;
/// - a starting chip that is gone was **removed** → its line's tag set is PATCHed without it
///   (`setTags`), never a forced re-sort.
public struct EditTagDiff: Sendable, Equatable {
    /// One line's tag set after the edit.
    public struct Removal: Sendable, Equatable {
        public let reviewID: UUID
        public let remaining: [DietTag]
    }

    public let hasNewTags: Bool
    public let removals: [Removal]

    public init(original: EntryComposition, current: EntryComposition, items: [EntryCard.Item]) {
        let before = original.spans.filter { $0.token.tag != nil }.map(\.token)
        let now = Set(current.spans.filter { $0.token.tag != nil }.map(\.token.id))
        let beforeIDs = Set(before.map(\.id))
        hasNewTags = now.contains { beforeIDs.contains($0) == false }

        var removed: [UUID: Set<DietTag>] = [:]
        for token in before where now.contains(token.id) == false {
            guard let dishID = token.dishID, let tag = token.tag else { continue }
            removed[dishID, default: []].insert(tag)
        }
        removals = items.compactMap { item in
            guard let gone = removed[item.dishID], gone.isDisjoint(with: item.tags) == false else { return nil }
            return Removal(reviewID: item.reviewID, remaining: item.tags.filter { gone.contains($0) == false })
        }
    }
}
