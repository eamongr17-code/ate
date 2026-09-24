import Foundation
import PostgREST
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
/// Opt-in: set `ATE_CONTRACT_TESTS=1` to run (CI's contract job does; plain `swift test` skips it
/// so PR unit tests stay green through a staging outage).
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

    static var isEnabled: Bool { environmentValue("ATE_CONTRACT_TESTS") != nil }

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

/// Cursor walks and visibility writers are mutually exclusive within one test process.
///
/// Swift Testing runs suites in parallel. `blockingHidesThem` blocks a seeded author for four round
/// trips and `blocked_with()` hides that author's rows from every read while it holds — so a walk
/// running at the same moment loses rows that are back by the time it finishes, and no snapshot
/// taken before or after can tell that from a pager skipping them. Every walk and every test that
/// changes what the viewer can see runs inside this lock. Fair (FIFO) and never blocks a thread.
actor StagingExclusive {
    static let shared = StagingExclusive()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if held == false {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@Suite("Staging contract", .enabled(if: StagingContract.isEnabled), .serialized)
struct StagingContractTests {
    func client() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// How many `reviews` rows the signed-in viewer can actually read, from PostgREST's own
    /// `count=exact`. The walk tests use this instead of a floor copied off the seed: the same
    /// `reviews_select_visible` policy (0019) governs this count and the feed/diary select, so the
    /// number is the contract — "walked everything" stays true as staging grows.
    /// Every review id the viewer can read right now, in one request. Staging holds a few hundred
    /// rows; the 5,000 cap is far above that and fails loudly (not silently) if it is ever reached.
    func visibleReviewIDs(_ client: AteAPIClient) async throws -> Set<UUID> {
        struct IDRow: Decodable { let id: UUID }
        let rows: [IDRow] = try await client.supabase.from(Review.table).select("id")
            .range(from: 0, to: 4_999).execute().value
        try #require(rows.count < 5_000, "visibleReviewIDs hit its cap; page it")
        return Set(rows.map(\.id))
    }

    func visibleReviewCount(
        _ client: AteAPIClient,
        refine: @Sendable (PostgrestFilterBuilder) -> PostgrestFilterBuilder = { $0 }
    ) async throws -> Int {
        let response = try await refine(
            client.supabase.from(Review.table).select("id", head: true, count: .exact)
        ).execute()
        return try #require(response.count, "PostgREST returned no count header")
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

    @Test("reviews decode; every NON-NULL score is a legal half-step, and NULL is a legal score")
    func decodesReviews() async throws {
        let client = try await client()
        let page = try await client.page(Review.self, request: PageRequest(limit: 20))
        #expect(page.items.isEmpty == false)

        for review in page.items {
            if let score = review.score {
                #expect(Rating(exactly: score.value) != nil)
            }
            // Denormalised, trigger-maintained — present on every row.
            #expect(review.restaurantID != review.dishID)
        }

        // Both halves of the post-0018 contract, asked for by name rather than hoped for on page 1
        // (there are far more scored rows than unscored ones, so a plain page proves only one half).
        let scored = try await client.page(Review.self, request: PageRequest(limit: 5)) {
            $0.not("score", operator: .is, value: "null")
        }
        #expect(scored.items.isEmpty == false)
        for review in scored.items {
            // `Rating`'s own decode rejects anything off the half-step grid, so arriving here at all
            // is the assertion; this restates the range the DB CHECK still guarantees.
            let score = try #require(review.score)
            #expect(Rating(exactly: score.value) != nil)
        }

        // The row that turned CI red: `score` is NULLABLE since 0018 and staging really does serve
        // these. An unscored dish line is the NORMAL case — the user wrote about a dish and gave it
        // no number (DESIGN rule 7: never inferred), so a reader that can't decode it is broken, and
        // a seed without one stops testing the normal case.
        let unscored = try await client.page(Review.self, request: PageRequest(limit: 5)) {
            $0.is("score", value: nil)
        }
        #expect(unscored.items.isEmpty == false, "staging must hold an unscored review — it is the normal case")
        #expect(unscored.items.allSatisfy { $0.score == nil })
    }

    @Test("keyset paging walks reviews with no gaps and no repeats, across a timestamp tie")
    func keysetPagingIsTotal() async throws {
        try await StagingExclusive.shared.run {
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
        try await StagingExclusive.shared.run {
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

    @Test("the V1 global feed walks every review the viewer can read, once, embeds and all")
    func globalFeedWalksEverything() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let feed = GlobalFeedClient(api: client)

            // Two id snapshots bracket the walk. Staging is written to while CI runs (other contract
            // suites mint and delete rows; agents re-sort entries), so a single count taken up front is
            // neither a floor nor a ceiling: a row deleted mid-walk made "seen 138 >= total 139" fail
            // twice on 2026-09-24 with nothing wrong in the pager. What the walk owes is every row that
            // existed BOTH before and after it — the ids in both snapshots. Inserts above the cursor
            // and deletes below it fall out of that intersection by construction.
            let before = try await visibleReviewIDs(client)
            #expect(before.isEmpty == false, "an empty reviews table can't test a feed walk")

            // Small pages on purpose: the seed has nine clusters of reviews sharing a timestamp to the
            // microsecond, so a small page size guarantees several boundaries land inside a tie.
            let pageSize = 5
            var request: PageRequest? = PageRequest(limit: pageSize)
            var seen: [FeedEntry] = []
            var pages = 0
            // Derived from the count, so a growing staging can't silently truncate the walk into a pass.
            let pageCap = before.count / pageSize + 8

            while let current = request, pages < pageCap {
                let page = try await feed.feedPage(current)
                seen.append(contentsOf: page.items)
                request = current.next(after: page)
                pages += 1
            }

            #expect(request == nil, "the walk must end because the stream ran out, not because it hit the cap")
            let after = try await visibleReviewIDs(client)
            let stable = before.intersection(after)
            let seenIDs = Set(seen.map(\.id))
            let skipped = stable.subtracting(seenIDs)
            #expect(skipped.isEmpty, "the walk skipped rows that existed throughout: \(skipped)")
            #expect(seenIDs.count == seen.count, "the walk served a row twice")

            // Global, not follow-scoped: unlike get_feed, the viewer's own reviews are in it.
            #expect(seen.contains { $0.review.reviewerID == me })
            // And an unscored line item is renderable — the 0018 case that broke this very test. A row
            // with no number is a row, not an error.
            #expect(seen.contains { $0.review.score == nil }, "the feed must carry unscored reviews too")

            // The embeds are the whole point — a row without names is not renderable.
            for entry in seen {
                #expect(entry.dish.name.isEmpty == false)
                #expect(entry.restaurant.name.isEmpty == false)
                #expect(entry.author?.username.isEmpty == false)
                #expect(entry.dish.id == entry.review.dishID)
                #expect(entry.restaurant.id == entry.review.restaurantID)
                #expect(entry.author?.id == entry.review.reviewerID)
            }

            for (newer, older) in zip(seen, seen.dropFirst()) {
                let descending = newer.review.createdAt > older.review.createdAt
                    || (newer.review.createdAt == older.review.createdAt
                        && newer.id.uuidString > older.id.uuidString)
                #expect(descending, "\(newer.id) should sort before \(older.id)")
            }
        }
    }

    @Test("the feed refuses to serve an anonymous viewer an empty page")
    func globalFeedRequiresASession() async {
        let anon = GlobalFeedClient(api: AteAPIClient(supabase: StagingContract.makeClient()))
        // Without the session check this returns `[]` with a 200 and the UI says "no reviews yet".
        await #expect(throws: AteAPIError.notAuthenticated) {
            _ = try await anon.feedPage()
        }
    }

    @Test("the diary pages only the viewer's own reviews, newest first")
    func diaryIsScopedToTheViewer() async throws {
        try await StagingExclusive.shared.run {
            let client = try await client()
            let me = try await client.requireCurrentUserID()
            let diary = DiaryClient(api: client)

            // Same treatment as the feed: the viewer's own row count is the floor, so the walk can't
            // truncate into a pass as the demo account accumulates entries.
            let reviewerID = me.uuidString.lowercased()
            let mine = try await visibleReviewCount(client) { $0.eq("reviewer_id", value: reviewerID) }
            // The seeded demo account has reviews; an empty diary here would mean the filter (or RLS)
            // is wrong, not that the account is new.
            #expect(mine > 0)

            let pageSize = 5
            var request: PageRequest? = PageRequest(limit: pageSize)
            var seen: [FeedEntry] = []
            var pages = 0
            let pageCap = mine / pageSize + 8

            while let current = request, pages < pageCap {
                let page = try await diary.diaryPage(current)
                seen.append(contentsOf: page.items)
                request = current.next(after: page)
                pages += 1
            }

            #expect(request == nil, "the walk must end because the stream ran out, not because it hit the cap")
            #expect(seen.count >= mine)
            #expect(Set(seen.map(\.id)).count == seen.count)
            // The whole contract of this query, in one line.
            #expect(seen.allSatisfy { $0.review.reviewerID == me })
            // The diary is where an unscored line item lands first: you wrote about a dish and gave it no
            // number. Every one of them must page like any other row — counted, not sampled.
            let mineUnscored = try await visibleReviewCount(client) {
                $0.eq("reviewer_id", value: reviewerID).is("score", value: nil)
            }
            #expect(mineUnscored > 0, "the demo account must have an unscored review — it is the normal case since 0018")
            #expect(seen.filter { $0.review.score == nil }.count >= mineUnscored)

            for entry in seen {
                #expect(entry.dish.name.isEmpty == false)
                #expect(entry.restaurant.name.isEmpty == false)
            }

            for (newer, older) in zip(seen, seen.dropFirst()) {
                let descending = newer.review.createdAt > older.review.createdAt
                    || (newer.review.createdAt == older.review.createdAt
                        && newer.id.uuidString > older.id.uuidString)
                #expect(descending, "\(newer.id) should sort before \(older.id)")
            }

            // …and it is strictly a subset of the global feed, which is the same query minus the filter.
            let everything = try await GlobalFeedClient(api: client).feedPage(PageRequest(limit: 100))
            let mineInFeed = everything.items.filter { $0.review.reviewerID == me }.map(\.id)
            #expect(mineInFeed.allSatisfy { seen.map(\.id).contains($0) })
        }
    }

    @Test("the diary refuses to serve an anonymous viewer an empty page")
    func diaryRequiresASession() async {
        let anon = DiaryClient(api: AteAPIClient(supabase: StagingContract.makeClient()))
        // Otherwise a signed-out user is told *they* have logged nothing — about a person we can't name.
        await #expect(throws: AteAPIError.notAuthenticated) {
            _ = try await anon.diaryPage()
        }
    }
}
