import Foundation
import Supabase

/// **The Saved shelf's filters** (round 5, 0049): the Journal's score range, on the dish's
/// aggregate (`dish_score`, the number the shelf prints), and a city. The Journal's exact rule: no
/// bound is everything, any bound leaves the unscored out, and a top end on 5.0 is open.
public struct SavedDishFilter: Hashable, Sendable {
    public var band: ScoreBand
    /// A city slug (``AteCity/city``), or `nil` for everywhere.
    public var city: String?

    public init(band: ScoreBand = .all, city: String? = nil) {
        self.band = band
        self.city = city
    }

    public static let none = SavedDishFilter()

    public var isEmpty: Bool { band.isAll && city == nil }

    /// `search_saved`'s three filter arguments, `null` when unused.
    var parameters: [String: AnyJSON] {
        [
            "p_min_score": band.minScore.map { .double($0) } ?? .null,
            "p_max_score": band.maxScore.map { .double($0) } ?? .null,
            "p_city": city.map { .string($0) } ?? .null
        ]
    }

    /// Whether a saved dish belongs — what the in-memory shelf filters by.
    public func matches(_ dish: SavedDish) -> Bool {
        guard band.contains(dish.dishScore) else { return false }
        if let city, AteCity.slug(for: dish.restaurantCity) != city { return false }
        return true
    }
}

public extension DishSaving {
    /// The shelf, filtered. A reader without the 0049 read filters the whole shelf in memory and
    /// pages the result by the same `(saved_at, dish_id)` keyset — the in-memory drives and fakes.
    func savedDishesPage(
        after cursor: PageCursor?,
        pageSize: Int,
        filter: SavedDishFilter
    ) async throws -> Page<SavedDish> {
        guard filter.isEmpty == false else { return try await savedDishesPage(after: cursor, pageSize: pageSize) }
        var all: [SavedDish] = []
        var next: PageCursor?
        repeat {
            let page = try await savedDishesPage(after: next, pageSize: PageRequest.maximumLimit)
            all += page.items
            next = page.nextCursor
        } while next != nil
        let kept = all.filter(filter.matches)
        let start = cursor.flatMap { cursor in kept.firstIndex { $0.dishID == cursor.id }.map { $0 + 1 } } ?? 0
        return Page(items: Array(kept.dropFirst(start).prefix(pageSize)), requestedLimit: pageSize)
    }

    /// `my_saved_cities()` — the cities your saved dishes are in, most first. Derived from the
    /// shelf itself by a reader without the RPC.
    func mySavedCities() async throws -> [AteCity] {
        var names: [String?] = []
        var next: PageCursor?
        repeat {
            let page = try await savedDishesPage(after: next, pageSize: PageRequest.maximumLimit)
            names += page.items.map(\.restaurantCity)
            next = page.nextCursor
        } while next != nil
        return AteCity.counted(names)
    }
}

extension SaveClient {
    /// `search_saved(p_query: null, …, p_min_score, p_max_score, p_city)` (0049) — the whole shelf,
    /// filtered, in the shelf's own order. Unfiltered, the view read stays the one that runs.
    public func savedDishesPage(
        after cursor: PageCursor?,
        pageSize: Int,
        filter: SavedDishFilter
    ) async throws -> Page<SavedDish> {
        guard filter.isEmpty == false else { return try await savedDishesPage(after: cursor, pageSize: pageSize) }
        try await api.requireCurrentUserID()
        let limit = max(1, min(PageRequest.maximumLimit, pageSize))
        var parameters = filter.parameters
        parameters["p_query"] = .null
        parameters["p_limit"] = .integer(limit)
        parameters["p_cursor_saved_at"] = cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_dish_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null
        let rows: [SearchSavedRow] = try await api.rpc("search_saved", parameters: parameters)
        return Page(items: rows.map(SavedDish.init), requestedLimit: limit)
    }

    public func mySavedCities() async throws -> [AteCity] {
        try await api.rpc("my_saved_cities", parameters: [:])
    }
}
