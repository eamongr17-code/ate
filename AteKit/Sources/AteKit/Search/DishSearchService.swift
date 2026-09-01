import Foundation
import PostgREST
import Supabase

/// One page of a dish list. Not a keyset ``Page``: `dish_stats` is a view keyed on `dish_id` with no
/// `created_at`, and the order the picker needs (`review_count desc, score desc`) isn't a cursorable
/// stream anyway.
///
/// **Why offset paging is defensible here** (it is not, for the feed): a restaurant's menu is a
/// bounded, near-static set — nobody is inserting dishes into it while you scroll — and the order is
/// made *total* by the `dish_id` tiebreak, so a page boundary can't duplicate or drop a row inside
/// one picker session. The feed's problem (rows arriving at the head mid-scroll) doesn't exist here.
public struct DishListPage: Sendable {
    public let rows: [DishRowModel]
    /// Offset for the next page, or nil when this was the last one (a short read).
    public let nextOffset: Int?

    public init(rows: [DishRowModel], nextOffset: Int?) {
        self.rows = rows
        self.nextOffset = nextOffset
    }

    public var isLastPage: Bool { nextOffset == nil }
}

/// Everything the dish subjects of the picker need.
public protocol DishSearchProviding: Sendable {
    /// §11.3 "You've had here" — the viewer's prior reviews at this restaurant, deduped by dish.
    func history(restaurantID: UUID, limit: Int) async throws -> [DishRowModel]
    /// §11.3 "On the menu" — `review_count desc, score desc`, paginated.
    func menu(restaurantID: UUID, offset: Int, limit: Int) async throws -> DishListPage
    /// §11.3 (≥1 char) — the catalogue half of the filtered list.
    func filterMenu(restaurantID: UUID, query: String, limit: Int) async throws -> [DishRowModel]
    /// Search-tab Dishes scope, no query: the most-reviewed dishes anywhere.
    func popular(offset: Int, limit: Int) async throws -> DishListPage
    /// Search-tab Dishes scope, with a query.
    func searchAll(query: String, limit: Int) async throws -> [DishRowModel]
    /// §11.4/§6.3 — select-then-insert; an existing name silently resolves to its row.
    func resolveOrCreate(name: String, restaurantID: UUID) async throws -> PickedDish
}

public struct DishSearchService: DishSearchProviding {
    public static let defaultHistoryLimit = 5
    public static let defaultMenuPageSize = 20
    /// How many of the viewer's reviews to scan for the history section (see recents, same shape).
    static let historyScanPageSize = 60
    /// Hard cap on the "load every live dish here" read used by ``resolveOrCreate``. A restaurant's
    /// catalogue is bounded reference-ish data; the cap is a guard, not a pagination scheme.
    static let restaurantCatalogueCap = 500

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    // MARK: - History

    public func history(
        restaurantID: UUID,
        limit: Int = DishSearchService.defaultHistoryLimit
    ) async throws -> [DishRowModel] {
        let viewerID = try await api.requireCurrentUserID()
        let reviews = try await api.page(
            Review.self,
            request: PageRequest(limit: Self.historyScanPageSize)
        ) {
            $0.eq("reviewer_id", value: viewerID.uuidString)
                .eq("restaurant_id", value: restaurantID.uuidString)
        }.items

        let dishIDs = DishSearchRanking.historyDishIDs(from: reviews, limit: limit)
        guard !dishIDs.isEmpty else { return [] }

        let dishes = try await liveDishes(ids: dishIDs)
        let ownScores = DishSearchRanking.latestOwnScores(from: reviews)
        let stats = try await statsByDishID(for: dishes)

        // Order by the viewer's recency, not the fetch order. A dish that was merged away since the
        // review was written now carries its survivor's id, so its own score keys off the ORIGINAL
        // review's dish id — look both up.
        return dishes
            .map { dish in
                let own = ownScores[dish.id] ?? ownScores[dish.canonicalDishID]
                return DishRowModel(
                    dish: dish,
                    stats: stats[dish.canonicalDishID],
                    yourScore: own?.score,
                    yourLastReviewedAt: own?.at
                )
            }
            .sorted { ($0.yourLastReviewedAt ?? .distantPast) > ($1.yourLastReviewedAt ?? .distantPast) }
    }

    // MARK: - Menu

    public func menu(
        restaurantID: UUID,
        offset: Int = 0,
        limit: Int = DishSearchService.defaultMenuPageSize
    ) async throws -> DishListPage {
        let stats: [DishStats] = try await api.fetchAll(DishStats.self) {
            $0.eq("restaurant_id", value: restaurantID.uuidString)
                .order("review_count", ascending: false)
                .order("score", ascending: false)  // nullsLast: unrated dishes trail
                .order("dish_id", ascending: false)  // total order ⇒ stable page boundaries
                .range(from: offset, to: offset + limit - 1)
        }
        return try await page(from: stats, limit: limit, offset: offset, withRestaurantNames: false)
    }

    public func filterMenu(
        restaurantID: UUID,
        query: String,
        limit: Int = DishSearchService.defaultMenuPageSize
    ) async throws -> [DishRowModel] {
        guard let pattern = PostgRESTPattern.contains(query) else { return [] }
        let dishes: [Dish] = try await api.fetchAll(Dish.self) {
            $0.eq("restaurant_id", value: restaurantID.uuidString)
                .is("merged_into_dish_id", value: nil)
                .ilike("name", pattern: pattern)
                .limit(limit)
        }
        let stats = try await statsByDishID(for: dishes)
        // Ranked client-side: PostgREST can't order a `dishes` filter by a `dish_stats` column, and
        // the set is capped at `limit`, so sorting it here is exact rather than approximate.
        return DishSearchRanking.menuOrder(
            dishes.map { DishRowModel(dish: $0, stats: stats[$0.canonicalDishID]) }
        )
    }

    // MARK: - Global dish scope (Search tab)

    public func popular(offset: Int = 0, limit: Int = DishSearchService.defaultMenuPageSize) async throws -> DishListPage {
        let stats: [DishStats] = try await api.fetchAll(DishStats.self) {
            $0.order("review_count", ascending: false)
                .order("score", ascending: false)
                .order("dish_id", ascending: false)
                .range(from: offset, to: offset + limit - 1)
        }
        return try await page(from: stats, limit: limit, offset: offset, withRestaurantNames: true)
    }

    public func searchAll(query: String, limit: Int = DishSearchService.defaultMenuPageSize) async throws -> [DishRowModel] {
        guard let pattern = PostgRESTPattern.contains(query) else { return [] }
        let dishes: [Dish] = try await api.fetchAll(Dish.self) {
            $0.is("merged_into_dish_id", value: nil)
                .ilike("name", pattern: pattern)
                .limit(limit)
        }
        let stats = try await statsByDishID(for: dishes)
        let names = try await restaurantNames(for: dishes)
        return DishSearchRanking.menuOrder(
            dishes.map {
                DishRowModel(
                    dish: $0,
                    stats: stats[$0.canonicalDishID],
                    restaurantName: names[$0.restaurantID]
                )
            }
        )
    }

    // MARK: - Create (§11.4, §6.3)

    /// Select-then-insert, never upsert: `dishes_identity_uq` is a *partial* index and PostgREST's
    /// `on_conflict` can only target a total one — pointing an upsert at it is the 0014 outage.
    ///
    /// The select is done on the client with ``DishDedup`` rather than as an `ilike` filter, so the
    /// "is this the same dish?" rule has exactly one implementation and no pattern-escaping surface.
    /// A losing race on the insert (23505) is not an error: §6.3 says a name collision resolves to
    /// the existing row silently, so we re-read and return it.
    public func resolveOrCreate(name: String, restaurantID: UUID) async throws -> PickedDish {
        let key = DishNameKey(name)
        guard !key.isEmpty else { throw AteAPIError.notFound(table: Dish.table, id: restaurantID) }
        let viewerID = try await api.requireCurrentUserID()

        let catalogue = try await liveCatalogue(restaurantID: restaurantID)
        if let existing = DishDedup.match(name: name, in: catalogue) {
            return PickedDish(existing)
        }

        // Store the name as typed (trimmed): `lower(name)` is the identity, the display string keeps
        // the user's capitalisation.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await api.insert(
                NewDish(name: trimmed, restaurantID: restaurantID, createdByUserID: viewerID),
                into: Dish.self
            )
            return PickedDish(created, wasCreated: true)
        } catch {
            guard isUniqueViolation(error) else { throw error }
            let after = try await liveCatalogue(restaurantID: restaurantID)
            guard let existing = DishDedup.match(name: name, in: after) else { throw error }
            return PickedDish(existing)
        }
    }

    struct NewDish: Encodable, Sendable {
        let name: String
        let restaurantID: UUID
        let createdByUserID: UUID

        enum CodingKeys: String, CodingKey {
            case name
            case restaurantID = "restaurant_id"
            case createdByUserID = "created_by_user_id"
        }
    }

    /// Postgres `unique_violation`. PostgREST surfaces it as a `PostgrestError` with code `23505`.
    func isUniqueViolation(_ error: any Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }

    // MARK: - Hydration

    private func liveCatalogue(restaurantID: UUID) async throws -> [Dish] {
        try await api.fetchAll(Dish.self) {
            $0.eq("restaurant_id", value: restaurantID.uuidString)
                .is("merged_into_dish_id", value: nil)
                .limit(Self.restaurantCatalogueCap)
        }
    }

    /// Fetch by id and **follow merge tombstones** (data-model §4). A dish referenced by an old
    /// review may have been merged away since; the picker must show — and hand back — the survivor.
    private func liveDishes(ids: [UUID]) async throws -> [Dish] {
        let first = try await api.fetchByIDs(Dish.self, ids: ids)
        let survivorIDs = first.compactMap(\.mergedIntoDishID).filter { id in
            !first.contains { $0.id == id }
        }
        guard !survivorIDs.isEmpty else { return dedupedLive(first, order: ids) }
        let survivors = try await api.fetchByIDs(Dish.self, ids: Array(Set(survivorIDs)))
        return dedupedLive(first + survivors, order: ids)
    }

    /// Replaces tombstones with their survivors, drops any survivor we couldn't fetch, and dedups —
    /// two merged dishes can collapse onto one row.
    private func dedupedLive(_ dishes: [Dish], order: [UUID]) -> [Dish] {
        let byID = Dictionary(dishes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        var out: [Dish] = []
        for id in order + dishes.map(\.id) {
            guard let dish = byID[id] else { continue }
            let canonical = byID[dish.canonicalDishID] ?? dish
            guard !canonical.isTombstoned, seen.insert(canonical.id).inserted else { continue }
            out.append(canonical)
        }
        return out
    }

    private func statsByDishID(for dishes: [Dish]) async throws -> [UUID: DishStats] {
        guard !dishes.isEmpty else { return [:] }
        let stats = try await api.fetchByIDs(DishStats.self, ids: dishes.map(\.canonicalDishID))
        return Dictionary(stats.map { ($0.dishID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func restaurantNames(for dishes: [Dish]) async throws -> [UUID: String] {
        let ids = Array(Set(dishes.map(\.restaurantID)))
        guard !ids.isEmpty else { return [:] }
        let restaurants = try await api.fetchByIDs(Restaurant.self, ids: ids)
        return Dictionary(restaurants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Turns a ranked page of stats into rows, preserving the server's order.
    private func page(
        from stats: [DishStats],
        limit: Int,
        offset: Int,
        withRestaurantNames: Bool
    ) async throws -> DishListPage {
        guard !stats.isEmpty else { return DishListPage(rows: [], nextOffset: nil) }
        let dishes = try await api.fetchByIDs(Dish.self, ids: stats.map(\.dishID))
        let byID = Dictionary(dishes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = withRestaurantNames ? try await restaurantNames(for: dishes) : [:]

        let rows = stats.compactMap { stat -> DishRowModel? in
            guard let dish = byID[stat.dishID] else { return nil }
            return DishRowModel(
                dish: dish,
                stats: stat,
                restaurantName: withRestaurantNames ? names[dish.restaurantID] : nil
            )
        }
        return DishListPage(rows: rows, nextOffset: stats.count < limit ? nil : offset + stats.count)
    }
}
