import Foundation
import Supabase
import Testing

@testable import AteKit

/// **The staging smoke test** — one live decode per surface the app calls, through the app's OWN
/// clients and model types, against the real staging project.
///
/// Behaviour (ordering, keysets, RLS, aggregates, filters) is pinned in `supabase/tests/db/*.mjs`,
/// which applies the whole migration chain to an in-process Postgres on every backend PR. What only a
/// live server can prove is that the DEPLOYED functions still bind the parameters the app sends and
/// still answer with rows the app's decoders accept — so that is all this checks. Read-only: no
/// writes, no walks, no lock; it signs in as the dedicated `ci@ate.test` (see ``StagingContract``).
///
/// Opt-in (`ATE_CONTRACT_TESTS=1`): CI runs it after the unit tests on backend PRs and on main.
@Suite("Contract smoke — staging", .enabled(if: StagingContract.isEnabled))
struct ContractSmokeTests {
    static let melbourne = TimeZone(identifier: "Australia/Melbourne")!

    func signedIn() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    func anon() -> AteAPIClient {
        AteAPIClient(supabase: StagingContract.makeClient())
    }

    /// A card from the global feed that has a place and a receipt — the fixture for the detail reads.
    func someCard(_ client: AteAPIClient) async throws -> EntryCard {
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 10, includeOwn: false, area: nil, city: nil)
        return try #require(
            page.items.first { $0.place != nil && $0.items.isEmpty == false },
            "the staging feed holds no entry at a place with a receipt"
        )
    }

    @Test("sign-in: the contract account gets a session")
    func signIn() async throws {
        let client = try await signedIn()
        #expect(client.isSignedIn)
        _ = try await client.requireCurrentUserID()
    }

    @Test("get_entry_feed: a signed-in page, then the next page off its cursor")
    func feed() async throws {
        let feed = EntryFeedClient(api: try await signedIn())
        let first = try await feed.feedPage(after: nil, pageSize: 3, includeOwn: false, area: nil, city: nil)
        #expect(first.items.isEmpty == false, "the empty-feed trap")
        let cursor = try #require(first.nextCursor)
        let second = try await feed.feedPage(after: cursor, pageSize: 3, includeOwn: false, area: nil, city: nil)
        #expect(Set(second.items.map(\.id)).isDisjoint(with: first.items.map(\.id)))
    }

    @Test("get_entry_feed: anon browse reads the feed (0034)")
    func anonFeed() async throws {
        let client = anon()
        #expect(client.isSignedIn == false)
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 5, includeOwn: false, area: nil, city: nil)
        #expect(page.items.isEmpty == false)
        #expect(page.items.allSatisfy { $0.isMine == false })
    }

    @Test("place_summary decodes for a place off the feed")
    func placeSummary() async throws {
        let client = try await signedIn()
        let place = try #require(try await someCard(client).place)
        let summary = try await PlacePageClient(api: client).placeSummary(restaurantID: place.id)
        #expect(summary.restaurantID == place.id)
    }

    @Test("place_dishes decodes the menu")
    func placeDishes() async throws {
        let client = try await signedIn()
        let place = try #require(try await someCard(client).place)
        let menu = try await PlacePageClient(api: client).placeDishes(restaurantID: place.id, after: nil)
        #expect(menu.items.isEmpty == false, "a place with a receipt has a menu")
    }

    @Test("dish_summary decodes for a dish off the feed")
    func dishSummary() async throws {
        let client = try await signedIn()
        let dish = try #require(try await someCard(client).items.first?.dishID)
        let summary = try await DishPageClient(api: client).dishSummary(dishID: dish)
        #expect(summary.dishID == dish)
    }

    @Test("search_all binds its two parameters and answers with the seven columns")
    func searchAll() async throws {
        let client = try await signedIn()
        let place = try #require(try await someCard(client).place)
        let rows: [SearchAllRow] = try await client.rpc(
            "search_all",
            parameters: ["p_query": .string(String(place.name.prefix(4))), "p_limit_per_kind": .integer(8)]
        )
        #expect(rows.isEmpty == false)
        #expect(rows.allSatisfy { ["place", "dish", "person"].contains($0.kind) })
    }

    @Test("my_entries: the contract account's journal, through the Journal's client")
    func myEntries() async throws {
        let page = try await JournalQueryClient(api: try await signedIn())
            .myEntries(JournalQuery(), after: nil, pageSize: 5)
        #expect(page.items.isEmpty == false, "ci@ate.test has seeded entries — run seed.mjs --ci-account")
        #expect(page.items.allSatisfy { $0.isMine })
    }

    @Test("profile_summary: the viewer's own header")
    func profileSummary() async throws {
        let client = try await signedIn()
        let me = try await client.requireCurrentUserID()
        let summary = try await ProfileClient(api: client).profile(id: me)
        #expect(summary.userID == me)
        #expect(summary.isMe)
    }

    @Test("statement_months + monthly_statement: the newest statement decodes for the month asked")
    func monthlyStatement() async throws {
        let client = try await signedIn()
        let stats = StatsClient(api: client)
        let me = try await client.requireCurrentUserID()
        let newest = try #require(
            try await stats.months(userID: me, timeZone: Self.melbourne, after: nil, limit: 1).first,
            "ci@ate.test has no statement months — run seed.mjs --ci-account"
        )
        let statement = try await stats.statement(userID: me, month: newest.month, timeZone: Self.melbourne)
        #expect(statement.month == newest.month)
        #expect(statement.orders == newest.orders)
    }

    /// The early sort's request, exactly as the app encodes it, stopped at the server's own input
    /// check: a body one character over `PREVIEW_MAX_BODY` is refused 422 "body too long" BEFORE the
    /// rate limit, the cache or the model. So this proves the function is deployed, takes the app's
    /// session and reads the app's `body` key, and never spends an Anthropic call. What a preview does
    /// with a real draft is pinned in `supabase/functions/sort-entry/entry_flow_test.ts`.
    @Test("sort-entry preview: deployed, authorised, reads the app's request — never reaches the model")
    func previewSort() async throws {
        let client = try await signedIn()
        let place = try #require(try await someCard(client).place?.id)
        let input = EarlySortInput(body: String(repeating: "a", count: 10_001), tagTokens: [], restaurantID: place)
        do {
            try await SupabaseEntryService(api: client).previewSort(input)
            Issue.record("a body over the preview limit was accepted — the model may have been called")
        } catch let FunctionsError.httpError(code, data) {
            let reply = String(bytes: data, encoding: .utf8) ?? ""
            #expect(code == 422, "expected the input check, got \(code): \(reply)")
            #expect(reply.contains("too long"), "the server did not read the app's `body` key: \(reply)")
        }
    }

    /// The row the app's place picker decodes from `search_all` (PlaceDirectoryClient).
    struct SearchAllRow: Decodable, Sendable {
        let kind: String
        let id: String
        let title: String
        let subtitle: String?
    }
}
