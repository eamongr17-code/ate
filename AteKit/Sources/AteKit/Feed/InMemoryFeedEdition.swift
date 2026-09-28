#if DEBUG
import Foundation

/// **The Feed's edition, in memory** (`-ate-preview-data`) — derived from the same seeded entries the
/// feed, the dish pages and the tag pages draw, so a preview drive walks from The Top Ate to a dish,
/// and from a craving shelf's See all to its tag page, without a backend. The server's rules, stated
/// small: The Top Ate is the catalogue best first (photographed first within a score); Because you
/// loved is `similar_dishes` of the viewer's best dish; New to the record is what was written since.
extension InMemorySocialService: FeedEditionReading {

    public func topAte(city: String?, limit: Int) async throws -> [TopAteLine] {
        let rows = exploreCatalogue(in: city)
            .filter { $0.row.score != nil }
            .sorted { lhs, rhs in
                if lhs.row.score != rhs.row.score { return (lhs.row.score ?? 0) > (rhs.row.score ?? 0) }
                if (lhs.row.coverURLString != nil) != (rhs.row.coverURLString != nil) {
                    return lhs.row.coverURLString != nil
                }
                return TagDishCursor.isBefore(lhs.row.tagCursor, rhs.row.tagCursor)
            }
            .prefix(max(1, limit))
        return rows.enumerated().map { index, candidate in
            TopAteLine(rank: index + 1, dish: feedDish(candidate))
        }
    }

    public func becauseYouLoved(city: String?, limit: Int) async throws -> LovedShelf? {
        let mine = visibleEntriesEverywhere().filter(\.isMine)
            .flatMap { entry in entry.items.map { (entry.createdAt, $0) } }
        let loved = mine.filter { ($0.1.score?.value ?? 0) >= 5 }.max { $0.0 < $1.0 }
            ?? mine.max { ($0.1.score?.value ?? 0) < ($1.1.score?.value ?? 0) }
        guard let anchor = loved?.1 else { return nil }
        let catalogue = exploreCatalogue(in: city)
        let logged = Set(mine.map(\.1.dishID))
        let tags = catalogue.first { $0.row.dishID == anchor.dishID }?.tags
            ?? exploreCatalogue().first { $0.row.dishID == anchor.dishID }?.tags ?? []
        let byID = Dictionary(catalogue.map { ($0.row.dishID, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = DishSimilarity.rank(catalogue, like: tags, excluding: anchor.dishID)
            .filter { logged.contains($0.dishID) == false }
            .prefix(max(1, limit))
            .compactMap { byID[$0.dishID].map(feedDish) }
        guard rows.isEmpty == false else { return nil }
        return LovedShelf(anchorDishID: anchor.dishID, anchorName: anchor.dishName, dishes: Array(rows))
    }

    public func newToRecord(city: String?, since: Date, limit: Int) async throws -> [NewDish] {
        let catalogue = exploreCatalogue(in: city)
        let byID = Dictionary(catalogue.map { ($0.row.dishID, $0) }, uniquingKeysWith: { lhs, _ in lhs })
        let recent = visibleEntriesEverywhere()
            .filter { $0.isMine == false && $0.createdAt > since }
            .flatMap { entry in entry.items.map { (entry.createdAt, $0) } }
        var seen: Set<UUID> = []
        return recent.compactMap { at, item -> NewDish? in
            guard let candidate = byID[item.dishID], seen.insert(item.dishID).inserted else { return nil }
            let score = item.score?.value ?? 0
            let kind: NewDish.Kind = score >= 6 ? .six : score >= 5 ? .five : .new
            return NewDish(kind: kind, dish: feedDish(candidate), at: at)
        }
        .prefix(max(1, limit))
        .map { $0 }
    }

    public func myCravings() async throws -> [Craving] { cravings }

    public func cravingOptions() async throws -> [CravingOption] {
        let catalogue = exploreCatalogue()
        var seen: Set<String> = []
        let tags = catalogue.flatMap(\.tags).filter { $0.kind == .style || $0.kind == .cuisine }
        return tags.compactMap { tag -> CravingOption? in
            guard seen.insert(tag.id).inserted else { return nil }
            let craving = Craving(kind: tag.kind, slug: tag.slug, label: tag.label)
            return CravingOption(craving: craving, group: tag.kind == .style ? .dishes : .cuisines)
        }
        .sorted { ($0.group == .dishes ? 0 : 1, $0.craving.title) < ($1.group == .dishes ? 0 : 1, $1.craving.title) }
    }

    public func setCravings(_ cravings: [Craving]) async throws -> [Craving] {
        var seen: Set<String> = []
        self.cravings = Array(cravings.filter { seen.insert($0.id).inserted }.prefix(CravingPicker.maximum))
        return self.cravings
    }

    public func cravingDishes(_ craving: Craving, city: String?, limit: Int) async throws -> [FeedDish] {
        exploreCatalogue(in: city)
            .filter { $0.tags.contains { $0.kind == craving.kind && $0.slug == craving.slug } }
            .sorted { TagDishCursor.isBefore($0.row.tagCursor, $1.row.tagCursor) }
            .prefix(max(1, limit))
            .map(feedDish)
    }

    /// A catalogue row as the edition's RPCs send it: the suburb its tag names, the viewer's bookmark.
    private func feedDish(_ candidate: DishSimilarity.Candidate) -> FeedDish {
        let row = candidate.row
        return FeedDish(
            dishID: row.dishID,
            name: row.name,
            restaurantID: row.restaurantID,
            restaurantName: row.restaurantName,
            suburb: visibleEntriesEverywhere().lazy.compactMap(\.place)
                .first { $0.id == row.restaurantID }?.locality,
            score: row.score,
            reviewCount: row.reviewCount,
            coverURLString: row.coverURLString,
            isSaved: isSaved(dishID: row.dishID)
        )
    }
}
#endif
