#if DEBUG
import Foundation

/// **A dish page's "More to explore" and "More like this", in memory** (`-ate-preview-data`) — derived
/// from the same seeded entries the feed and the dish pages draw, so a preview drive can walk from a
/// dish to one like it and on to a tag's page without a backend.
///
/// The server makes the tags when a dish is logged; here they are made from the dish's place (its
/// cuisine, suburb and city) and a small table of styles for the seeded dishes, standing in for what
/// the sorter pulls out of the words. Debug only, in both directions.
extension InMemorySocialService: DishExploreReading {

    public func dishTags(dishID: UUID) async throws -> [DishTag] {
        guard let dish = exploreCatalogue().first(where: { $0.row.dishID == dishID }) else {
            throw AteAPIError.notFound(table: "dishes", id: dishID)
        }
        return DishTagOrder.explore(dish.tags)
    }

    public func similarDishes(dishID: UUID, limit: Int) async throws -> [SimilarDish] {
        let catalogue = exploreCatalogue()
        guard let dish = catalogue.first(where: { $0.row.dishID == dishID }) else { return [] }
        return Array(DishSimilarity.rank(catalogue, like: dish.tags, excluding: dishID).prefix(max(1, limit)))
    }

    public func dishesByTag(
        kind: DishTag.Kind,
        slug: String,
        after cursor: TagDishCursor?,
        pageSize: Int
    ) async throws -> TagDishPage {
        let rows = exploreCatalogue()
            .filter { $0.tags.contains { $0.kind == kind && $0.slug == slug } }
            .map(\.row)
            .sorted { TagDishCursor.isBefore($0.tagCursor, $1.tagCursor) }
        let remaining = cursor.map { cursor in rows.filter { TagDishCursor.isBefore(cursor, $0.tagCursor) } } ?? rows
        return TagDishPage(items: Array(remaining.prefix(max(1, pageSize))), requestedLimit: pageSize)
    }

    // MARK: - Machinery

    /// Every dish the seeded entries mention, aggregated the way `dish_summary` does, with its tags.
    private func exploreCatalogue() -> [DishSimilarity.Candidate] {
        let lines = visibleEntriesEverywhere().flatMap { entry in entry.items.map { (entry: entry, item: $0) } }
        return Dictionary(grouping: lines, by: \.item.dishID).compactMap { dishID, rows in
            guard let first = rows.first, let place = first.entry.place else { return nil }
            let scores = rows.compactMap(\.item.score?.value)
            let average = scores.isEmpty ? nil : ((scores.reduce(0, +) / Double(scores.count)) * 10).rounded() / 10
            let row = SimilarDish(
                dishID: dishID,
                name: first.item.dishName,
                restaurantID: place.id,
                restaurantName: place.name,
                score: average,
                reviewCount: rows.count,
                coverURLString: rows.compactMap { $0.entry.photos.first?.url }.first
            )
            return DishSimilarity.Candidate(row: row, tags: Self.previewTags(dish: first.item.dishName, place: place))
        }
    }

    /// What the server would have tagged a seeded dish with.
    static func previewTags(dish: String, place: EntryCard.Place) -> [DishTag] {
        var tags = (previewStyles[dish] ?? []).map { DishTag(kind: .style, slug: $0, label: $0) }
        if let cuisine = place.cuisine {
            tags.append(DishTag(kind: .cuisine, slug: cuisine.lowercased(), label: cuisine))
        }
        // City-qualified, and none when the suburb is the city's own centre — as 0053 makes them.
        if let suburb = place.locality, let city = place.city, suburb != "CBD" {
            let slug = "\(suburb)-\(city)".lowercased().replacingOccurrences(of: " ", with: "-")
            tags.append(DishTag(kind: .suburb, slug: slug, label: suburb))
        }
        if let city = place.city {
            tags.append(DishTag(kind: .city, slug: city.lowercased(), label: city))
        }
        return tags
    }

    /// The sorter's styles for the seeded dishes (`InMemorySocialSeed`), 1–3 each, lowercase.
    private static let previewStyles: [String: [String]] = [
        "Prawn spaghetti": ["pasta", "seafood"],
        "Tiramisu": ["dessert"],
        "Tagliatelle al ragù": ["pasta", "handmade"],
        "Penne alla vodka": ["pasta"],
        "Cheeseburger": ["burger"],
        "Salmon roll": ["sushi", "seafood"],
        "Wagyu nigiri": ["sushi"],
        "Raspberry cake": ["dessert", "cake"],
        "Miso soup": ["soup"],
        "Rigatoni": ["pasta"], "Bucatini": ["pasta"], "Anolini": ["pasta"], "Tortellini": ["pasta"],
        "Cannelloni": ["pasta"], "Tagliolini": ["pasta"], "Spaghettini": ["pasta"], "Maccheroni": ["pasta"],
        "Tortelloni": ["pasta"], "Cappellini": ["pasta"], "Lumaconi": ["pasta"], "Conchiglioni": ["pasta"],
        "Ditalini": ["pasta"], "Tubettini": ["pasta"], "Pennoni": ["pasta"], "Manicotti": ["pasta"]
    ]
}

/// **`similar_dishes`' rule (0053), stated for the in-memory stand-in**: weighted tag overlap — style
/// 8, cuisine 4, suburb 2, city 1 — then score (unscored last), then reviews. A dish must share a
/// style or the cuisine to count: a shared suburb or city alone does not make it "like" this one.
/// The server's ranking is the real one; this keeps a preview drive honest to it.
public enum DishSimilarity {
    public struct Candidate: Sendable, Hashable {
        public let row: SimilarDish
        public let tags: [DishTag]

        public init(row: SimilarDish, tags: [DishTag]) {
            self.row = row
            self.tags = tags
        }
    }

    public static func weight(_ kind: DishTag.Kind) -> Int {
        switch kind {
        case .style: 8
        case .cuisine: 4
        case .suburb: 2
        case .city: 1
        case .diet: 0
        }
    }

    public static func rank(_ candidates: [Candidate], like tags: [DishTag], excluding dishID: UUID) -> [SimilarDish] {
        let wanted = Set(tags.map(\.id))
        let scored = candidates.compactMap { candidate -> (SimilarDish, Int)? in
            guard candidate.row.dishID != dishID else { return nil }
            let shared = candidate.tags.filter { wanted.contains($0.id) }
            guard shared.contains(where: { $0.kind == .style || $0.kind == .cuisine }) else { return nil }
            return (candidate.row, shared.map { weight($0.kind) }.reduce(0, +))
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return TagDishCursor.isBefore(lhs.0.tagCursor, rhs.0.tagCursor)
            }
            .map(\.0)
    }
}
#endif
