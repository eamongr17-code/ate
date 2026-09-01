import Foundation

/// Everything the dish and restaurant detail screens read, behind one protocol so the models are
/// testable without a network and previews can run on fixtures.
public protocol DetailDataSource: Sendable {
    /// The dish header, **after tombstone redirect** — callers get the survivor, never the
    /// merged-away row (data-model §4).
    func dishDetail(id: UUID) async throws -> DishDetailSnapshot
    /// One newest-first page of a dish's reviews.
    func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review>
    /// Author profiles for a page of reviews, in one round trip. Missing ids are simply absent.
    func authors(ids: [UUID]) async throws -> [User]
    /// The restaurant header plus its ranked dish list.
    func restaurantDetail(id: UUID) async throws -> RestaurantDetailSnapshot
}

/// The dish header. `stats` is Optional because `dish_stats` is a *view* — an absent row is
/// "unrated", the same product state as a `nil` score, and never an error.
public struct DishDetailSnapshot: Sendable, Hashable {
    /// The dish actually being shown: the survivor if the requested id was a merge tombstone.
    public let dish: Dish
    public let restaurant: Restaurant
    public let stats: DishStats?
    /// What the caller asked for, kept so the screen can tell it followed a redirect.
    public let requestedDishID: UUID

    public init(dish: Dish, restaurant: Restaurant, stats: DishStats?, requestedDishID: UUID? = nil) {
        self.dish = dish
        self.restaurant = restaurant
        self.stats = stats
        self.requestedDishID = requestedDishID ?? dish.id
    }

    public var wasRedirected: Bool { requestedDishID != dish.id }
    /// nil = unrated. The view renders `–/5`; it must never see a 0 here.
    public var score: Double? { stats?.score }
    public var reviewCount: Int { stats?.reviewCount ?? 0 }
    public var isRated: Bool { score != nil }
}

/// The restaurant header plus its menu. The rating comes straight off `restaurant_stats` —
/// it is the **mean of per-dish averages**, not the mean of reviews, and recomputing it client-side
/// from the dish list is the legacy client's bug (data-model §1.2).
public struct RestaurantDetailSnapshot: Sendable, Hashable {
    public let restaurant: Restaurant
    public let stats: RestaurantStats?
    public let dishes: [RankedDish]

    public init(restaurant: Restaurant, stats: RestaurantStats?, dishes: [RankedDish]) {
        self.restaurant = restaurant
        self.stats = stats
        self.dishes = dishes
    }

    public var avgRating: Double? { stats?.avgRating }
    public var reviewCount: Int { stats?.reviewCount ?? 0 }
    public var isRated: Bool { avgRating != nil }
}

// MARK: - Live implementation

/// The PostgREST-backed detail reads. Thin by design: it does the fetching and the tombstone hop,
/// and hands ordering/formatting to the pure types (``DishRanking``, ``ScoreFormat``).
public final class AteDetailClient: DetailDataSource {
    /// How many merge hops a read will follow before giving up. Read-time resolution is one hop by
    /// contract (a server job flattens chains, data-model §4); the extra hops are belt-and-braces
    /// for a chain caught mid-flatten, and the cap plus the visited set make a cycle impossible to
    /// hang on.
    static let maximumMergeHops = 4

    /// A restaurant's menu is bounded reference data, so it is read whole rather than paginated —
    /// but not *unboundedly* whole. If a real restaurant ever exceeds this, the list needs a
    /// cursor, not a bigger number.
    static let dishListLimit = 200

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func dishDetail(id: UUID) async throws -> DishDetailSnapshot {
        let dish = try await resolveDish(id: id)
        async let restaurant = api.fetchByID(Restaurant.self, id: dish.restaurantID)
        async let stats = api.findRow(DishStats.self) { $0.eq("dish_id", value: dish.id.uuidString) }
        return DishDetailSnapshot(
            dish: dish,
            restaurant: try await restaurant,
            stats: try await stats,
            requestedDishID: id
        )
    }

    /// Follows `merged_into_dish_id` to the surviving dish. A merged dish keeps its reviews' history
    /// but is not a destination: every link to it must land on the survivor.
    func resolveDish(id: UUID) async throws -> Dish {
        var dish = try await api.fetchByID(Dish.self, id: id)
        var visited: Set<UUID> = [dish.id]

        for _ in 0..<Self.maximumMergeHops {
            guard let successor = dish.mergedIntoDishID, !visited.contains(successor) else { break }
            dish = try await api.fetchByID(Dish.self, id: successor)
            visited.insert(dish.id)
        }
        return dish
    }

    public func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review> {
        try await api.page(Review.self, request: request) { $0.eq("dish_id", value: dishID.uuidString) }
    }

    public func authors(ids: [UUID]) async throws -> [User] {
        try await api.fetchByIDs(User.self, ids: ids)
    }

    public func restaurantDetail(id: UUID) async throws -> RestaurantDetailSnapshot {
        async let restaurant = api.fetchByID(Restaurant.self, id: id)
        async let stats = api.findRow(RestaurantStats.self) { $0.eq("restaurant_id", value: id.uuidString) }
        async let dishes = api.fetchAll(Dish.self) {
            $0.eq("restaurant_id", value: id.uuidString)
                .is("merged_into_dish_id", value: nil)
                .limit(Self.dishListLimit)
        }
        async let dishStats = api.fetchAll(DishStats.self) {
            $0.eq("restaurant_id", value: id.uuidString).limit(Self.dishListLimit)
        }

        return RestaurantDetailSnapshot(
            restaurant: try await restaurant,
            stats: try await stats,
            dishes: DishRanking.rank(dishes: try await dishes, stats: try await dishStats)
        )
    }
}

// MARK: - Default wiring

/// The app-wide live data source, resolved from the running bundle's environment (Debug → staging;
/// rule 5). It exists so `DishDetailView(dishID:)` is callable with nothing but an id from any call
/// site; anything that already holds an ``AteAPIClient`` should inject ``AteDetailClient`` directly.
public enum DetailDataSourceProvider {
    public static let live: any DetailDataSource = {
        guard let environment = try? AteEnvironment.resolve(bundle: .main) else {
            return UnconfiguredDetailDataSource()
        }
        return AteDetailClient(api: AteAPIClient(environment: environment))
    }()
}

/// Used only when the bundle has no usable configuration (an unfilled `Secrets.xcconfig`). It fails
/// every read loudly instead of pretending the catalogue is empty — a blank screen is the one
/// outcome that hides a misconfiguration.
struct UnconfiguredDetailDataSource: DetailDataSource {
    private var failure: any Error { AteEnvironment.ConfigurationError.missing(key: AteEnvironment.supabaseURLKey) }

    func dishDetail(id: UUID) async throws -> DishDetailSnapshot { throw failure }
    func reviews(dishID: UUID, request: PageRequest) async throws -> Page<Review> { throw failure }
    func authors(ids: [UUID]) async throws -> [User] { throw failure }
    func restaurantDetail(id: UUID) async throws -> RestaurantDetailSnapshot { throw failure }
}
