import Foundation
import Testing
@testable import AteKit

/// **QA on #84, replayed.** Filters on the lists shown before typing, and near me that never gives
/// up on one bad read, never waits forever, and follows a later answer.
@MainActor
@Suite("Round 5 — QA fixes on #84")
struct Round5QAFixTests {

    // MARK: - 1. Filters with nothing typed

    @Test("a filter narrows Nearby with nothing typed — the pill never sits over unfiltered rows")
    func nearbyFiltered() async {
        let service = FakeSearchService()
        service.seed(nearby: [.fixture("Tipo 00", score: 4.6), .fixture("Etta", score: 3.9)])
        let store = SearchStore(service: service, scope: .places, pageSize: 10, debounce: .milliseconds(20))
        await store.setOrigin(SearchOrigin(latitude: -37.81, longitude: 144.96))
        #expect(store.rows.count == 2 && store.isShowingNearby)
        store.setFilters(SearchFilters(minimumScore: 4.5))
        await store.settle()
        // The fake cannot filter, and answers a filter it cannot apply with nothing (never with the
        // unfiltered rows): an empty list here is Nearby asked again, filtered.
        #expect(store.rows.isEmpty, "Nearby was read again with the filter")
    }

    @Test("a filter narrows the Saved shelf with nothing typed")
    func savedFiltered() async {
        let service = FakeSearchService()
        service.seed(saved: [.fixture("Ragù"), .fixture("Toast")])
        let store = SearchStore(service: service, scope: .saved, pageSize: 10, debounce: .milliseconds(20))
        await store.start()
        #expect(store.rows.count == 2)
        store.setFilters(SearchFilters(city: "melbourne"))
        await store.settle()
        #expect(store.rows.isEmpty, "the shelf was read again with the filter")
    }

    // MARK: - 2–4. Near me

    private final class Memory: AteKeyValueStore, @unchecked Sendable {
        var values: [String: String] = [:]
        func value(forKey key: String) -> String? { values[key] }
        func setValue(_ value: String?, forKey key: String) { values[key] = value }
    }

    /// `resolve_city`, scripted: fails while `failing`, answers the point's city (or the busiest
    /// with no point), and counts the calls.
    private final class Resolver: EntryFeedReading, @unchecked Sendable {
        var failing = false
        var calls = 0
        let melbourne = AteCity(city: "melbourne", name: "Melbourne", entryCount: 30)
        let geelong = AteCity(city: "geelong", name: "Geelong", isNearby: true)

        func feedPage(
            after cursor: PageCursor?, pageSize: Int, includeOwn: Bool, area: String?
        ) async throws -> Page<EntryCard> {
            Page(items: [], requestedLimit: pageSize)
        }
        func feedAreas(after cursor: FeedArea?, limit: Int) async throws -> [FeedArea] { [] }
        func resolveCity(latitude: Double?, longitude: Double?) async throws -> AteCity? {
            calls += 1
            if failing { throw URLError(.notConnectedToInternet) }
            return latitude == nil ? melbourne : geelong
        }
    }

    @Test("one failed read leaves near me unresolved, and the next read tries again")
    func failureIsNotAnAnswer() async {
        let reader = Resolver()
        reader.failing = true
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        model.locate = { (latitude: -38.1, longitude: 144.3) }
        await model.resolveNearMe(latitude: -38.1, longitude: 144.3)
        #expect(model.hasResolvedNearMe == false && model.nearMe == nil, "not Everywhere for the session")
        reader.failing = false
        #expect(await model.cityForFirstPage() == "geelong", "the next page asks again, and lands")
        #expect(model.hasResolvedNearMe)
    }

    @Test("a slow location: the first page waits about two seconds, reads the busiest city, then follows")
    func slowLocation() async {
        let reader = Resolver()
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        var reloads = 0
        model.onNearMeChanged = { reloads += 1 }
        model.locate = {
            try? await Task.sleep(for: .milliseconds(400))
            return (latitude: -38.1, longitude: 144.3)
        }
        let first = await model.cityForFirstPage(wait: .milliseconds(100))
        #expect(first == "melbourne", "the busiest city, not Everywhere")
        #expect(model.hasResolvedNearMe == false)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(model.city == "geelong" && model.isNearMe)
        #expect(reloads == 1, "the late answer reloads the feed it moved")
        #expect(model.cityForNextPage == "melbourne", "until then, pages keep the city they started with")
    }

    @Test("the last near me this phone had stands in before the busiest city")
    func lastKnown() async {
        let memory = Memory()
        let reader = Resolver()
        let first = FeedAreaModel(reader: reader, store: memory, owner: { nil })
        first.locate = { (latitude: -38.1, longitude: 144.3) }
        #expect(await first.cityForFirstPage() == "geelong")

        let next = FeedAreaModel(reader: reader, store: memory, owner: { UUID() })
        next.locate = {
            try? await Task.sleep(for: .milliseconds(400))
            return nil
        }
        #expect(await next.cityForFirstPage(wait: .milliseconds(50)) == "geelong")
        #expect(next.isNearMe, "and the chip still says near me")
    }

    @Test("a worked-out near me reads at once and asks again behind the page")
    func resolvedReadsAtOnce() async {
        let reader = Resolver()
        let model = FeedAreaModel(reader: reader, store: Memory(), owner: { nil })
        model.locate = { (latitude: -38.1, longitude: 144.3) }
        _ = await model.cityForFirstPage()
        let before = reader.calls
        #expect(await model.cityForFirstPage(wait: .zero) == "geelong")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(reader.calls == before + 1, "a pull to refresh (or near me picked again) retries")
    }

    // MARK: - 5. Clear

    @Test("the pills of a query built fresh carry nothing from before round 5")
    func freshQuery() {
        var query = JournalQuery(sort: .newest, city: nil)
        query.band = .all
        #expect(query.isDefault && query.hasFilters == false)
    }
}
