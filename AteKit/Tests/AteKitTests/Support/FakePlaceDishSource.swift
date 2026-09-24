import Foundation

@testable import AteKit

/// An in-memory stand-in for `place_summary` / `place_dishes` / `get_entries_at_place` and
/// `dish_summary` / `get_dish_reviews` / `is_dish_saved`, so the page stores can be driven without a
/// network — including the two things staging cannot reliably show: a scope that comes back empty,
/// and a review list long enough to page more than once.
///
/// It pages **for real** — the three-part `(is_mine, created_at, id)` comparison the RPC makes,
/// evaluated the same way — rather than slicing by index, which would pass even if the store
/// threaded the cursor wrongly.
final class FakePlaceDishSource: PlacePageReading, DishPageReading, @unchecked Sendable {
    struct Failure: Error, Equatable {
        let message: String
    }

    private let lock = NSLock()
    private var state = State()

    private struct State {
        var summaries: [UUID: PlaceSummary] = [:]
        var dishes: [UUID: [MenuDish]] = [:]
        var entries: [UUID: [EntryCard]] = [:]
        var dishSummaries: [UUID: DishSummary] = [:]
        var reviews: [UUID: [DishReview]] = [:]
        var saved: Set<UUID> = []
        var summaryFailure: Failure?
        var menuFailure: Failure?
        var reviewFailures = 0
        var reviewRequests: [DishReviewCursor?] = []
        var menuCursors: [MenuDishCursor?] = []
        var entryScopes: [PlaceEntryScope] = []
    }

    // MARK: - Seeding

    func seed(place: PlaceSummary, dishes: [MenuDish] = [], entries: [EntryCard] = []) {
        lock.withLock {
            state.summaries[place.restaurantID] = place
            state.dishes[place.restaurantID] = dishes
            state.entries[place.restaurantID] = entries
        }
    }

    func seed(dish: DishSummary, reviews: [DishReview] = []) {
        lock.withLock {
            state.dishSummaries[dish.dishID] = dish
            state.reviews[dish.dishID] = reviews
            if dish.isSaved { state.saved.insert(dish.dishID) }
        }
    }

    func failSummary(_ failure: Failure?) { lock.withLock { state.summaryFailure = failure } }
    func failMenu(_ failure: Failure?) { lock.withLock { state.menuFailure = failure } }
    func failReviews(times: Int) { lock.withLock { state.reviewFailures = times } }

    var reviewRequests: [DishReviewCursor?] { lock.withLock { state.reviewRequests } }
    var menuCursors: [MenuDishCursor?] { lock.withLock { state.menuCursors } }
    var entryScopes: [PlaceEntryScope] { lock.withLock { state.entryScopes } }

    // MARK: - PlacePageReading

    func placeSummary(restaurantID: UUID) async throws -> PlaceSummary {
        try lock.withLock {
            if let failure = state.summaryFailure { throw failure }
            guard let row = state.summaries[restaurantID] else {
                throw AteAPIError.notFound(table: "restaurants", id: restaurantID)
            }
            return row
        }
    }

    func placeDishes(
        restaurantID: UUID,
        after cursor: MenuDishCursor?,
        pageSize: Int
    ) async throws -> MenuDishPage {
        try lock.withLock {
            if let failure = state.menuFailure { throw failure }
            state.menuCursors.append(cursor)
            // Seeded rows are handed back in the order they were seeded — the fake stands in for
            // the server's ORDER BY, and the store must not reorder what it is given.
            let rows = state.dishes[restaurantID] ?? []
            let remaining = cursor.map { cursor in
                Array(rows.drop { $0.dishID != cursor.dishID }.dropFirst())
            } ?? rows
            return MenuDishPage(items: Array(remaining.prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    func entriesAtPlace(
        restaurantID: UUID,
        scope: PlaceEntryScope,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        lock.withLock {
            state.entryScopes.append(scope)
            let all = (state.entries[restaurantID] ?? [])
                .filter {
                    switch scope {
                    case .all: true
                    case .mine: $0.isMine
                    case .others: $0.isMine == false
                    }
                }
                .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            let remaining = all.drop {
                guard let cursor else { return false }
                return ($0.createdAt, $0.id.uuidString) >= (cursor.createdAt, cursor.id.uuidString)
            }
            return Page(items: Array(remaining.prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    // MARK: - DishPageReading

    func dishSummary(dishID: UUID) async throws -> DishSummary {
        try lock.withLock {
            if let failure = state.summaryFailure { throw failure }
            guard let row = state.dishSummaries[dishID] else {
                throw AteAPIError.notFound(table: "dishes", id: dishID)
            }
            return row
        }
    }

    func dishReviews(dishID: UUID, after cursor: DishReviewCursor?, pageSize: Int) async throws -> DishReviewPage {
        try lock.withLock {
            state.reviewRequests.append(cursor)
            if state.reviewFailures > 0 {
                state.reviewFailures -= 1
                throw Failure(message: "reviews fell over")
            }
            let ordered = (state.reviews[dishID] ?? []).sorted { Self.isOrderedBefore($0, $1) }
            let remaining = ordered.drop {
                guard let cursor else { return false }
                return Self.isOrderedBefore($0, cursor) == false
            }
            return DishReviewPage(items: Array(remaining.prefix(pageSize)), requestedLimit: pageSize)
        }
    }

    func isDishSaved(dishID: UUID) async throws -> Bool {
        lock.withLock { state.saved.contains(dishID) }
    }

    /// `(is_mine, created_at, id) DESC` — the row comparison `get_dish_reviews` makes.
    private static func isOrderedBefore(_ lhs: DishReview, _ rhs: DishReview) -> Bool {
        key(lhs.isMine, lhs.createdAt, lhs.reviewID) > key(rhs.isMine, rhs.createdAt, rhs.reviewID)
    }

    private static func isOrderedBefore(_ lhs: DishReview, _ cursor: DishReviewCursor) -> Bool {
        key(lhs.isMine, lhs.createdAt, lhs.reviewID) < key(cursor.isMine, cursor.createdAt, cursor.id)
    }

    // swiftlint:disable:next large_tuple
    private static func key(_ isMine: Bool, _ createdAt: Date, _ id: UUID) -> (Int, Date, String) {
        (isMine ? 1 : 0, createdAt, id.uuidString)
    }
}
