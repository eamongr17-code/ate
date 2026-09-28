import Foundation
import Supabase
import Testing

@testable import AteKit

/// **The staging smoke, the rest of the read surface** — every remaining read RPC the app calls, once,
/// through the app's own client, so a deployed signature that no longer binds the parameters the
/// client sends (or answers with a row it cannot decode) fails here rather than on a device.
///
/// Decode-only on purpose: empty is a legal answer for most of these (the contract account blocks
/// nobody and saves nothing). Behaviour lives in `supabase/tests/db/*.mjs`. Read-only; runs in parallel;
/// opt-in with `ATE_CONTRACT_TESTS=1` like ``ContractSmokeTests``.
@Suite("Contract smoke — staging reads", .enabled(if: StagingContract.isEnabled))
struct ContractSmokeReadsTests {
    static let melbourne = (latitude: -37.8136, longitude: 144.9631)

    func signedIn() async throws -> AteAPIClient {
        try await StagingContract.Backend.shared.client()
    }

    /// A card off the global feed with a place and a receipt: the ids the detail reads need.
    func someCard(_ client: AteAPIClient) async throws -> EntryCard {
        let page = try await EntryFeedClient(api: client)
            .feedPage(after: nil, pageSize: 10, includeOwn: false, area: nil, city: nil)
        return try #require(
            page.items.first { $0.place != nil && $0.items.isEmpty == false },
            "the staging feed holds no entry at a place with a receipt"
        )
    }

    // MARK: - Place, dish, entry, profile

    @Test("get_entries_at_place")
    func entriesAtPlace() async throws {
        let client = try await signedIn()
        let card = try await someCard(client)
        let place = try #require(card.place?.id)
        let page = try await PlacePageClient(api: client)
            .entriesAtPlace(restaurantID: place, scope: .all, after: nil, pageSize: 5)
        #expect(page.items.isEmpty == false)
    }

    @Test("get_dish_reviews")
    func dishReviews() async throws {
        let client = try await signedIn()
        let dish = try #require(try await someCard(client).items.first?.dishID)
        let page = try await DishPageClient(api: client).dishReviews(dishID: dish, after: nil, pageSize: 5)
        #expect(page.items.isEmpty == false)
    }

    @Test("get_entry_card")
    func entryCard() async throws {
        let client = try await signedIn()
        let card = try await someCard(client)
        #expect(try await SupabaseEntryService(api: client).entry(id: card.id).id == card.id)
    }

    @Test("get_entries_by_author")
    func entriesByAuthor() async throws {
        let client = try await signedIn()
        let card = try await someCard(client)
        let page = try await ProfileClient(api: client).entriesPage(authorID: card.authorID, after: nil, pageSize: 5)
        #expect(page.items.isEmpty == false)
    }

    // MARK: - Search

    @Test("search_places, search_dishes, search_people")
    func searchScopes() async throws {
        let client = try await signedIn()
        let card = try await someCard(client)
        let search = SearchClient(api: client)
        let placeName = try #require(card.place?.name)
        let dishName = try #require(card.items.first?.dishName)
        let places = try await search.places(query: String(placeName.prefix(4)), after: nil, pageSize: 5)
        #expect(places.rows.isEmpty == false)
        let dishes = try await search.dishes(query: String(dishName.prefix(4)), after: nil, pageSize: 5)
        #expect(dishes.rows.isEmpty == false)
        _ = try await search.people(query: "ate", after: nil, pageSize: 5)
    }

    @Test("search_saved and my_saved_cities")
    func saved() async throws {
        let client = try await signedIn()
        _ = try await SearchClient(api: client).savedDishes(matching: nil, after: nil, pageSize: 5)
        _ = try await SaveClient(api: client).mySavedCities()
    }

    @Test("nearby_places")
    func nearby() async throws {
        let origin = SearchOrigin(latitude: Self.melbourne.latitude, longitude: Self.melbourne.longitude)
        let search = SearchClient(api: try await signedIn())
        let page = try await search.nearbyPlaces(origin: origin, after: nil, pageSize: 5)
        #expect(page.rows.isEmpty == false, "staging holds Melbourne places with a location")
    }

    @Test("search_cuisines and search_cities")
    func searchPickers() async throws {
        let search = SearchClient(api: try await signedIn())
        #expect(try await search.cuisines().isEmpty == false)
        #expect(try await search.searchCities().isEmpty == false)
    }

    // MARK: - Feed pickers

    @Test("feed_areas, feed_cities and resolve_city")
    func feedPickers() async throws {
        let feed = EntryFeedClient(api: try await signedIn())
        #expect(try await feed.feedAreas(after: nil, limit: 5).isEmpty == false)
        #expect(try await feed.feedCities().isEmpty == false)
        let city = try await feed.resolveCity(latitude: Self.melbourne.latitude, longitude: Self.melbourne.longitude)
        #expect(city != nil, "the Melbourne CBD resolves to a city")
    }

    // MARK: - The viewer's own

    @Test("my_entry_places and my_entry_cities")
    func journalPickers() async throws {
        let journal = JournalQueryClient(api: try await signedIn())
        #expect(try await journal.myEntryPlaces().isEmpty == false, "ci@ate.test has entries at places")
        _ = try await journal.myEntryCities()
    }

    @Test("journal_days and my_entries_count")
    func journalCounts() async throws {
        let journal = JournalQueryClient(api: try await signedIn())
        let today = AteDay.containing(Date())
        let from = AteDay(year: today.year - 3, month: 1, day: 1)
        let days = try await journal.journalDays(from: from, to: today, matching: nil)
        let total = try await journal.myEntriesCount(JournalQuery())
        #expect(total > 0, "ci@ate.test has entries")
        var fours = JournalQuery()
        fours.band = ScoreBand.Preset.fourPlus.band
        let filtered = try await journal.journalDays(from: from, to: today, matching: fours)
        #expect(filtered.reduce(0) { $0 + $1.entries } <= days.reduce(0) { $0 + $1.entries })
        #expect(try await journal.myEntriesCount(fours) <= total)
    }

    @Test("my_blocks")
    func blocks() async throws {
        _ = try await AccountClient(api: try await signedIn()).blockedPeople(after: nil, pageSize: 5)
    }

    @Test("score_histogram and dishes_by_score")
    func ratings() async throws {
        let client = try await signedIn()
        let stats = StatsClient(api: client)
        let me = try await client.requireCurrentUserID()
        let histogram = try await stats.histogram(userID: me)
        let score = try #require(histogram.busiestScore, "ci@ate.test has scored lines")
        let page = try await stats.dishes(userID: me, score: score, after: nil, pageSize: 5)
        #expect(page.items.isEmpty == false)
    }
}
