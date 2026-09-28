import Foundation

@testable import AteKit

/// An in-memory `dish_tags` / `similar_dishes` / `dishes_by_tag`, so the explore stores can be driven
/// without a network. It pages **for real** — `dishes_by_tag`'s keyset comparison, evaluated the way
/// the RPC makes it — so a store that threaded its cursor wrongly would fail, not slide by on an index.
///
/// Defaults to nothing at all: a dish with no tags and nothing like it.
final class FakeDishExplore: DishExploreReading, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var tags: [UUID: [DishTag]] = [:]
    private var similar: [UUID: [SimilarDish]] = [:]
    private var byTag: [String: [SimilarDish]] = [:]
    private var failsTags = false
    private var failsSimilar = false
    private var tagPageFailures = 0
    private(set) var tagCursors: [TagDishCursor?] = []
    private(set) var tagCities: [String?] = []
    private(set) var similarLimits: [Int] = []

    func seed(dishID: UUID, tags: [DishTag] = [], similar: [SimilarDish] = []) {
        lock.withLock {
            self.tags[dishID] = tags
            self.similar[dishID] = similar
        }
    }

    func seed(tag kind: DishTag.Kind, slug: String, dishes: [SimilarDish]) {
        lock.withLock { byTag["\(kind.rawValue):\(slug)"] = dishes }
    }

    func failTags(_ fails: Bool) { lock.withLock { failsTags = fails } }
    func failSimilar(_ fails: Bool) { lock.withLock { failsSimilar = fails } }
    func failTagPages(times: Int) { lock.withLock { tagPageFailures = times } }

    func dishTags(dishID: UUID) async throws -> [DishTag] {
        try lock.withLock {
            if failsTags { throw Failure() }
            return tags[dishID] ?? []
        }
    }

    func similarDishes(dishID: UUID, limit: Int) async throws -> [SimilarDish] {
        try lock.withLock {
            similarLimits.append(limit)
            if failsSimilar { throw Failure() }
            return Array((similar[dishID] ?? []).prefix(limit))
        }
    }

    func dishesByTag(
        kind: DishTag.Kind,
        slug: String,
        city: String?,
        after cursor: TagDishCursor?,
        pageSize: Int
    ) async throws -> TagDishPage {
        try lock.withLock {
            tagCursors.append(cursor)
            tagCities.append(city)
            if tagPageFailures > 0 {
                tagPageFailures -= 1
                throw Failure()
            }
            let rows = (byTag["\(kind.rawValue):\(slug)"] ?? [])
                .sorted { TagDishCursor.isBefore($0.tagCursor, $1.tagCursor) }
            let remaining = cursor.map { cursor in
                rows.filter { TagDishCursor.isBefore(cursor, $0.tagCursor) }
            } ?? rows
            return TagDishPage(items: Array(remaining.prefix(pageSize)), requestedLimit: pageSize)
        }
    }
}
