import Foundation
import Supabase
import Testing

@testable import AteKit

/// Contract tests that decode **real rows from the staging project** (ARCHITECTURE.md, Testing
/// row). Unit tests prove we decode a payload we wrote down; only these prove the payload is still
/// what the server sends.
///
/// They talk to STAGING and nothing else — Debug/test paths never touch prod (rule 5). Credentials
/// are the committed publishable staging key (RLS is the security boundary) and a seeded demo
/// account; both are already in the repo (`Config/Secrets.example.xcconfig`, `supabase/seed.sql`),
/// which is what lets CI run this with no extra secret wiring, exactly like the existing
/// contract-vs-staging curl.
///
/// Set `ATE_SKIP_CONTRACT_TESTS=1` to run the suite offline.
enum StagingContract {
    static func environmentValue(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var url: URL {
        URL(string: environmentValue("SUPABASE_URL_STAGING") ?? "https://cvoitgoaosofkougmarn.supabase.co")!
    }
    static var key: String {
        environmentValue("SUPABASE_KEY_STAGING") ?? "sb_publishable_sMRFIanM38nujCu5o16Jeg_CWnDriNg"
    }
    static var email: String { environmentValue("ATE_STAGING_EMAIL") ?? "eamon@ate.test" }
    static var password: String { environmentValue("ATE_STAGING_PASSWORD") ?? "atedemo123" }

    static var isEnabled: Bool { environmentValue("ATE_SKIP_CONTRACT_TESTS") == nil }

    /// Session storage that lives and dies with the test run — the default is the Keychain, which
    /// a CI runner's test process has no business writing to.
    final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func store(key: String, value: Data) throws {
            lock.withLock { values[key] = value }
        }
        func retrieve(key: String) throws -> Data? {
            lock.withLock { values[key] }
        }
        func remove(key: String) throws {
            lock.withLock { _ = values.removeValue(forKey: key) }
        }
    }

    static func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: EphemeralAuthStorage(),
                    autoRefreshToken: false
                )
            )
        )
    }

    /// One signed-in client shared by the suite — sign-in is the slow part, and every test needs
    /// the same seeded viewer.
    actor Backend {
        static let shared = Backend()
        private var cached: AteAPIClient?

        func client() async throws -> AteAPIClient {
            if let cached { return cached }
            let supabase = makeClient()
            try await supabase.auth.signIn(email: email, password: password)
            let client = AteAPIClient(supabase: supabase)
            cached = client
            return client
        }
    }
}

@Suite("Staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct StagingContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    @Test("anon reads return [] rather than failing — the RLS gate, and the empty-feed trap")
    func anonReadsAreEmpty() async throws {
        // Mirrors the CI curl check. Worth owning in Swift too: because RLS is deny-by-default for
        // anon, a signed-out client gets a *successful empty page*, never an error. Every
        // "why is the feed blank" bug is this.
        let anon = AteAPIClient(supabase: StagingContract.makeClient())
        #expect(anon.isSignedIn == false)

        let restaurants = try await anon.fetchAll(Restaurant.self) { $0.limit(1) }
        #expect(restaurants.isEmpty)

        await #expect(throws: AteAPIError.notAuthenticated) {
            try await anon.requireCurrentUserID()
        }
    }

    @Test("signing in yields a session whose user id matches a profile row")
    func sessionMatchesProfile() async throws {
        let client = try await client()
        let userID = try await client.requireCurrentUserID()
        let me = try await client.fetchByID(User.self, id: userID)
        #expect(me.id == userID)
        #expect(me.username.isEmpty == false)
        #expect(me.isDeactivated == false)
    }

    @Test("restaurants decode with the exact column list we request")
    func decodesRestaurants() async throws {
        // A renamed/dropped column makes this a 400 from PostgREST, not a silent nil.
        let restaurants = try await client().fetchAll(Restaurant.self) { $0.limit(10) }
        #expect(restaurants.isEmpty == false)

        for restaurant in restaurants {
            #expect(restaurant.name.isEmpty == false)
            // The 0014 two-way CHECK, verified on live data.
            #expect((restaurant.source == RestaurantSource.places) == (restaurant.googlePlaceID != nil))
        }
    }

    @Test("dishes decode, including the merge tombstone column")
    func decodesDishes() async throws {
        let client = try await client()
        let page = try await client.page(Dish.self, request: PageRequest(limit: 10))
        #expect(page.items.isEmpty == false)

        for dish in page.items {
            #expect(dish.name.isEmpty == false)
            #expect(dish.canonicalDishID == dish.mergedIntoDishID ?? dish.id)
        }

        // A dish's restaurant must resolve — dishes are always inside a catalogue restaurant.
        let dish = try #require(page.items.first)
        let restaurant = try await client.fetchByID(Restaurant.self, id: dish.restaurantID)
        #expect(restaurant.id == dish.restaurantID)
    }

    @Test("reviews decode and every score is a legal half-step")
    func decodesReviews() async throws {
        let page = try await client().page(Review.self, request: PageRequest(limit: 20))
        #expect(page.items.isEmpty == false)

        for review in page.items {
            #expect(Rating(exactly: review.score.value) != nil)
            // Denormalised, trigger-maintained — present on every row.
            #expect(review.restaurantID != review.dishID)
        }
    }

    @Test("keyset paging walks reviews with no gaps and no repeats, across a timestamp tie")
    func keysetPagingIsTotal() async throws {
        let client = try await client()
        // Page size 2 over a seed that has three reviews sharing one microsecond timestamp — the
        // case where a created_at-only cursor loops or skips.
        var request: PageRequest? = PageRequest(limit: 2)
        var seen: [Review] = []

        while let current = request, seen.count < 12 {
            let page = try await client.page(Review.self, request: current)
            seen.append(contentsOf: page.items)
            request = current.next(after: page)
        }

        #expect(seen.count >= 4)
        #expect(Set(seen.map(\.id)).count == seen.count)  // no row served twice
        // Strictly descending on the composite key — the total order the cursor relies on.
        for (newer, older) in zip(seen, seen.dropFirst()) {
            let isDescending = newer.createdAt > older.createdAt
                || (newer.createdAt == older.createdAt && newer.id.uuidString > older.id.uuidString)
            #expect(isDescending, "\(newer.id) should sort before \(older.id)")
        }
    }

    @Test("a scoped page reads only that dish's reviews")
    func scopedPaging() async throws {
        let client = try await client()
        let anyReview = try #require(try await client.page(Review.self, request: PageRequest(limit: 1)).items.first)

        let dishPage = try await client.page(Review.self, request: PageRequest(limit: 50)) {
            $0.eq("dish_id", value: anyReview.dishID.uuidString)
        }
        #expect(dishPage.items.isEmpty == false)
        #expect(dishPage.items.allSatisfy { $0.dishID == anyReview.dishID })
    }

    @Test("dish_stats keeps the unrated dish at NULL, not 0")
    func dishStatsNullScore() async throws {
        let client = try await client()

        let rated = try await client.fetchAll(DishStats.self) { $0.not("score", operator: .is, value: "null").limit(5) }
        #expect(rated.isEmpty == false)
        #expect(rated.allSatisfy { ($0.score ?? 0) > 0 })
        #expect(rated.allSatisfy { $0.reviewCount > 0 })

        // The trap the brief names: staging really does serve these rows.
        let unrated = try await client.fetchAll(DishStats.self) { $0.is("score", value: nil).limit(5) }
        #expect(unrated.isEmpty == false)
        #expect(unrated.allSatisfy { $0.score == nil && $0.reviewCount == 0 && $0.isRated == false })

        // The view keys on dish_id, not id — proves AteRecord.primaryKeyColumn.
        let one = try #require(rated.first)
        #expect(try await client.fetchByID(DishStats.self, id: one.dishID).dishID == one.dishID)
    }

    @Test("restaurant_stats rating really is the mean of per-dish averages")
    func restaurantStatsIsMeanOfDishAverages() async throws {
        let client = try await client()
        let stats = try await client.fetchAll(RestaurantStats.self) {
            $0.not("avg_rating", operator: .is, value: "null").limit(3)
        }
        #expect(stats.isEmpty == false)

        for restaurant in stats {
            let dishes = try await client.fetchAll(DishStats.self) {
                $0.eq("restaurant_id", value: restaurant.restaurantID.uuidString)
            }
            let scores: [Double] = dishes.compactMap(\.score)  // unrated dishes excluded from the mean
            let total: Double = scores.reduce(0, +)
            let mean: Double = total / Double(scores.count)
            let expected: Double = (mean * 10).rounded() / 10
            #expect(restaurant.avgRating == expected)
            // NOT the flat mean of all reviews — that is the legacy client's selector bug.
            let dishReviewTotal: Int = dishes.reduce(into: 0) { $0 += $1.reviewCount }
            #expect(restaurant.reviewCount == dishReviewTotal)
        }

        let unrated = try await client.fetchAll(RestaurantStats.self) { $0.is("avg_rating", value: nil).limit(1) }
        #expect(unrated.first?.avgRating == nil)
    }

    @Test("get_feed pages through the RPC cursor")
    func feedRPCPages() async throws {
        let client = try await client()
        let me = try await client.requireCurrentUserID()

        let page: Page<Review> = try await client.rpcPage(
            Review.self, function: "get_feed", request: PageRequest(limit: 3)
        )
        // The seeded viewer follows other demo accounts, so the following-only feed is non-empty.
        #expect(page.items.isEmpty == false)
        // get_feed is following-only BY DESIGN: own posts are unioned client-side (data-model §5).
        #expect(page.items.allSatisfy { $0.reviewerID != me })

        if let cursor = page.nextCursor {
            let second: Page<Review> = try await client.rpcPage(
                Review.self, function: "get_feed", request: PageRequest(limit: 3, after: cursor)
            )
            #expect(Set(second.items.map(\.id)).isDisjoint(with: Set(page.items.map(\.id))))
        }
    }
}
