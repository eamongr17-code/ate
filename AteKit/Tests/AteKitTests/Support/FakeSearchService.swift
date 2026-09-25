import Foundation

@testable import AteKit

/// An in-memory stand-in for the Search tab's four reads, so the store can be driven without a
/// network — including the three things staging cannot show on demand: a query that finds nothing,
/// a backend that refuses, and a result set long enough to page.
///
/// It **records every call**, because most of what the store has to get right is about calls that
/// should not happen: a keystroke that was debounced away, a scope switch that re-read a page it
/// already had, a stale answer drawn over a newer one.
final class FakeSearchService: SearchReading, @unchecked Sendable {
    struct Failure: Error, Equatable {
        let message: String
    }

    struct Call: Equatable, Sendable {
        let scope: SearchScope
        let query: String?
        let offset: Int
    }

    private let lock = NSLock()
    private var state = State()

    private struct State {
        var places: [PlaceResult] = []
        var nearby: [PlaceResult] = []
        var dishes: [DishResult] = []
        var people: [PersonResult] = []
        var saved: [SavedDish] = []
        var calls: [Call] = []
        var failure: Failure?
        /// How long each scope's reads take — long enough to switch segments while one is in the air.
        var latency: [SearchScope: Duration] = [:]
    }

    // MARK: - Seeding

    func seed(
        places: [PlaceResult] = [],
        nearby: [PlaceResult] = [],
        dishes: [DishResult] = [],
        people: [PersonResult] = [],
        saved: [SavedDish] = []
    ) {
        lock.withLock {
            state.places = places
            state.nearby = nearby
            state.dishes = dishes
            state.people = people
            state.saved = saved
        }
    }

    func fail(_ failure: Failure?) { lock.withLock { state.failure = failure } }

    func setLatency(_ latency: Duration?, for scope: SearchScope) {
        lock.withLock { state.latency[scope] = latency }
    }

    /// Waits until a call matching `where` has been made — i.e. that request is now in the air.
    func waitForCall(where matches: @Sendable (Call) -> Bool) async {
        for _ in 0..<400 where calls.contains(where: matches) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var calls: [Call] { lock.withLock { state.calls } }
    var callCount: Int { lock.withLock { state.calls.count } }
    func calls(for scope: SearchScope) -> [Call] { calls.filter { $0.scope == scope } }

    // MARK: - SearchReading

    func nearbyPlaces(origin: SearchOrigin, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<PlaceResult> {
        let all = lock.withLock { state.nearby }
        let offset = Self.offset(after: cursor, in: all.map(\.id))
        try await record(Call(scope: .places, query: nil, offset: offset))
        return Self.page(all, offset: offset, pageSize: pageSize) { .nearby(distanceMeters: 0, id: $0.id) }
    }

    func places(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PlaceResult> {
        let all = lock.withLock { state.places.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        let offset = Self.offset(after: cursor, in: all.map(\.id))
        try await record(Call(scope: .places, query: query, offset: offset))
        return Self.page(all, offset: offset, pageSize: pageSize) {
            .place(matchTier: 0, reviewCount: 0, name: $0.name, id: $0.id)
        }
    }

    func dishes(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<DishResult> {
        let all = lock.withLock { state.dishes.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        let offset = Self.offset(after: cursor, in: all.map(\.id))
        try await record(Call(scope: .dishes, query: query, offset: offset))
        return Self.page(all, offset: offset, pageSize: pageSize) {
            .dish(matchTier: 0, reviewCount: 0, name: $0.name, id: $0.id)
        }
    }

    func people(query: String, after cursor: SearchCursor?, pageSize: Int) async throws -> SearchPage<PersonResult> {
        let all = lock.withLock { state.people.filter { $0.handle.localizedCaseInsensitiveContains(query) } }
        let offset = Self.offset(after: cursor, in: all.map(\.id))
        try await record(Call(scope: .people, query: query, offset: offset))
        return Self.page(all, offset: offset, pageSize: pageSize) {
            .person(matchTier: 0, username: $0.handle, id: $0.id)
        }
    }

    func savedDishes(matching query: String?, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<SavedDish> {
        let all = lock.withLock { state.saved }
            .filter { row in
                guard let query else { return true }
                return row.dishName.localizedCaseInsensitiveContains(query)
            }
            .sorted { ($0.savedAt, $0.dishID.uuidString) > ($1.savedAt, $1.dishID.uuidString) }
        let offset = Self.offset(after: cursor, in: all.map(\.id))
        try await record(Call(scope: .saved, query: query, offset: offset))
        return Self.page(all, offset: offset, pageSize: pageSize) { .saved(savedAt: $0.savedAt, dishID: $0.dishID) }
    }

    // MARK: - Machinery

    /// Records the call, holds it for the scope's latency, then fails it if told to.
    ///
    /// A cancel during the hold surfaces as `URLError(.cancelled)` — what URLSession, and so
    /// supabase-swift, actually throws — rather than Swift's `CancellationError`, because that is the
    /// one a store is most likely to mistake for a real failure.
    private func record(_ call: Call) async throws {
        let (failure, latency) = lock.withLock { () -> (Failure?, Duration?) in
            state.calls.append(call)
            return (state.failure, state.latency[call.scope])
        }
        if let latency {
            do {
                try await Task.sleep(for: latency)
            } catch {
                throw URLError(.cancelled)
            }
        }
        if let failure { throw failure }
    }

    /// Where a cursor resumes: just after the row whose id it carries.
    private static func offset(after cursor: SearchCursor?, in ids: [UUID]) -> Int {
        let id: UUID? = switch cursor {
        case .place(_, _, _, let id), .nearby(_, let id), .dish(_, _, _, let id), .person(_, _, let id): id
        case .saved(_, let dishID): dishID
        case nil: nil
        }
        guard let id, let index = ids.firstIndex(of: id) else { return 0 }
        return index + 1
    }

    /// The server's rule, not a convenience: a full page names the last row as the next cursor, and a
    /// short one is the end.
    private static func page<Row>(
        _ rows: [Row],
        offset: Int,
        pageSize: Int,
        cursor: (Row) -> SearchCursor
    ) -> SearchPage<Row> {
        let window = Array(rows.dropFirst(offset).prefix(pageSize))
        return SearchPage(rows: window, next: window.count < pageSize ? nil : window.last.map(cursor))
    }
}

// MARK: - Fixtures

extension PlaceResult {
    static func fixture(_ name: String, score: Double? = 4.3, id: UUID = UUID()) -> PlaceResult {
        PlaceResult(restaurantID: id, name: name, locality: "Carlton", score: score)
    }
}

extension DishResult {
    static func fixture(_ name: String, score: Double? = 4.6, place: String = "Tipo 00") -> DishResult {
        DishResult(
            dishID: UUID(),
            name: name,
            restaurantID: UUID(),
            restaurantName: place,
            restaurantLocality: "Melbourne",
            score: score,
            coverURLString: nil,
            peopleCount: 3
        )
    }
}

extension PersonResult {
    static func fixture(_ handle: String, name: String? = "Jess Okafor") -> PersonResult {
        PersonResult(userID: UUID(), handle: handle, name: name)
    }
}

extension SavedDish {
    static func fixture(
        _ name: String,
        place: String = "Chin Chin",
        score: Double? = 4.3,
        savedAt: Date = Date(timeIntervalSince1970: 1_789_776_000)
    ) -> SavedDish {
        SavedDish(
            dishID: UUID(),
            dishName: name,
            restaurantID: UUID(),
            restaurantName: place,
            restaurantCity: "Melbourne",
            dishScore: score,
            savedAt: savedAt
        )
    }
}
