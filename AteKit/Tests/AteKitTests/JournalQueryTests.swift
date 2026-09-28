import Foundation
import Supabase
import Testing
@testable import AteKit

/// The journal's filter and sort (contract #3), built against the in-memory mock.
@MainActor
@Suite("Journal filter and sort")
struct JournalQueryTests {
    @Test("the default query is the journal itself, and has no pills")
    func defaultQuery() {
        let query = JournalQuery()
        #expect(query.isDefault)
        #expect(query.pills.isEmpty)
        #expect(query.filterNames == "none")
    }

    @Test("active filters become pills in a fixed order, and each pill removes only itself")
    func pills() {
        let place = JournalPlace(restaurantID: JournalFixtures.tipo.id, name: "Tipo 00")
        let query = JournalQuery(sort: .top, place: place, minScore: 4, tag: .gf, period: .year(2026))
        #expect(query.pills.map(\.id) == ["sort", "place", "minScore", "tag", "period"])
        #expect(query.pills.map(\.title) == ["Top rated", "Tipo 00", "4.0+", "GF", "2026"])
        let withoutPlace = query.removing(.place(place))
        #expect(withoutPlace.place == nil)
        #expect(withoutPlace.minScore == 4 && withoutPlace.tag == .gf && withoutPlace.sort == .top)
        #expect(query.removing(.sort(.top)).sort == .newest)
        #expect(query.filterNames == "place,min_score,tag,period")
    }

    @Test("a minimum score reads the entry's best score, and an unscored entry never passes it")
    func minimumScore() {
        let query = JournalQuery(minScore: 4)
        #expect(query.matches(JournalFixtures.card(2026, 9, 1, scores: [3, 4.5]), calendar: JournalFixtures.utc))
        #expect(query.matches(JournalFixtures.card(2026, 9, 1, scores: [3.5]), calendar: JournalFixtures.utc) == false)
        #expect(query.matches(JournalFixtures.card(2026, 9, 1, scores: [nil]), calendar: JournalFixtures.utc) == false)
    }

    @Test("place, tag and period each narrow the list")
    func narrowing() {
        let utc = JournalFixtures.utc
        let place = JournalQuery(place: JournalPlace(restaurantID: JournalFixtures.lune.id, name: "Lune"))
        #expect(place.matches(JournalFixtures.card(2026, 9, 1, at: JournalFixtures.lune), calendar: utc))
        #expect(place.matches(JournalFixtures.card(2026, 9, 1, at: JournalFixtures.tipo), calendar: utc) == false)
        let tag = JournalQuery(tag: .v)
        #expect(tag.matches(JournalFixtures.card(2026, 9, 1, tags: [.v]), calendar: utc))
        #expect(tag.matches(JournalFixtures.card(2026, 9, 1), calendar: utc) == false)
        let month = JournalQuery(period: .month(year: 2026, month: 8))
        #expect(month.matches(JournalFixtures.card(2026, 8, 31), calendar: utc))
        #expect(month.matches(JournalFixtures.card(2026, 9, 1), calendar: utc) == false)
        #expect(JournalQuery(period: .year(2025)).matches(JournalFixtures.card(2025, 12, 31), calendar: utc))
    }

    @Test("top rated puts the unscored last; oldest runs forward in time")
    func ordering() {
        let unscored = JournalFixtures.card(2026, 9, 5, scores: [nil])
        let five = JournalFixtures.card(2026, 9, 1, scores: [5])
        let three = JournalFixtures.card(2026, 9, 3, scores: [3, nil])
        let top = JournalQuery(sort: .top).ordered([unscored, three, five])
        #expect(top.map(\.id) == [five.id, three.id, unscored.id])
        let oldest = JournalQuery(sort: .oldest).ordered([unscored, three, five])
        #expect(oldest.map(\.id) == [five.id, three.id, unscored.id])
        #expect(JournalSort.top.isChronological == false)
    }

    @Test("a period is sent as its first and last day, both inclusive — a leap February has 29")
    func periodDays() {
        let february = JournalPeriod.month(year: 2028, month: 2).days(calendar: JournalFixtures.utc)
        #expect(JournalQueryClient.day(february.from) == "2028-02-01")
        #expect(JournalQueryClient.day(february.to) == "2028-02-29")
        let year = JournalPeriod.year(2026).days(calendar: JournalFixtures.utc)
        #expect(JournalQueryClient.day(year.from) == "2026-01-01")
        #expect(JournalQueryClient.day(year.to) == "2026-12-31")
    }

    @Test("a month marker prints the month's name and year")
    func periodTitle() {
        let title = JournalPeriod.month(year: 2026, month: 9)
            .title(locale: Locale(identifier: "en_AU"), calendar: JournalFixtures.utc)
        #expect(title == "September 2026")
        #expect(JournalPeriod.year(2025).title() == "2025")
    }

    @Test("my_entries is sent every filter, nulls for the unused ones, and the keyset cursor")
    func wireParameters() {
        let placeID = UUID(uuidString: "B7E00000-0000-4000-8000-000000000001")!
        let place = JournalPlace(restaurantID: placeID, name: "Tipo 00")
        let cursor = JournalCursor(
            createdAt: Date(timeIntervalSince1970: 1_789_812_840),
            id: UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!,
            score: 4.5
        )
        let parameters = JournalQueryClient.parameters(
            for: JournalQuery(sort: .top, place: place, minScore: 4),
            after: cursor, pageSize: 30
        )
        #expect(parameters["p_sort"] == .string("top"))
        #expect(parameters["p_limit"] == .integer(30))
        #expect(parameters["p_restaurant_id"] == .string("b7e00000-0000-4000-8000-000000000001"))
        #expect(parameters["p_min_score"] == .double(4))
        #expect(parameters["p_tag"] == .null)
        #expect(parameters["p_from"] == .null)
        #expect(parameters["p_to"] == .null)
        #expect(parameters["p_cursor_id"] == .string("a7e00000-0000-4000-8000-000000000142"))
        #expect(parameters["p_cursor_best_score"] == .double(4.5))
        #expect(parameters["p_tz"] == .string(TimeZone.autoupdatingCurrent.identifier))
        let first = JournalQueryClient.parameters(for: JournalQuery(), after: nil, pageSize: 30)
        #expect(first["p_cursor_created_at"] == .null && first["p_cursor_id"] == .null)
    }

    @Test("my_entries rows decode with the keyset's fields, a null best score included")
    func rowShapes() throws {
        let id = UUID(uuidString: "A7E00000-0000-4000-8000-000000000142")!
        let text = "a7e00000-0000-4000-8000-000000000142"
        let json = #"[{"id":"\#(text)","created_at":"2026-09-19T10:14:00.240956+00:00","best_score":4.5},"#
            + #"{"id":"\#(text)","created_at":"2026-09-18T10:14:00+00:00","best_score":null}]"#
        let rows = try JournalQueryClient.decodeRows(Data(json.utf8))
        #expect(rows.map(\.id) == [id, id])
        #expect(rows.map(\.bestScore) == [4.5, nil])
        #expect(PostgRESTTimestamp.string(from: rows[0].createdAt) == "2026-09-19T10:14:00.240956Z")
    }

    @Test("my_entry_places decodes the contract's columns")
    func placesDecode() throws {
        let json = #"[{"restaurant_id":"b7e00000-0000-4000-8000-000000000001","name":"Tipo 00","#
            + #""locality":"CBD","entry_count":3}]"#
        let places = try JSONDecoder().decode([JournalPlace].self, from: Data(json.utf8))
        #expect(places.first?.name == "Tipo 00")
        #expect(places.first?.entryCount == 3)
        #expect(places.first?.locality == "CBD")
    }

    private func journal(_ cards: [EntryCard]) -> (JournalStore, InMemoryEntryService) {
        let service = InMemoryEntryService(entries: cards)
        let store = JournalStore(
            entries: service, pageSize: 2,
            querying: InMemoryJournalQuery(entries: service, calendar: JournalFixtures.utc)
        )
        return (store, service)
    }

    @Test("the mock pages a filtered list by its keyset, never repeating or skipping a row")
    func mockPaging() async throws {
        let cards = (1...5).map { JournalFixtures.card(2026, 9, $0, scores: [Double($0)]) }
        let mock = InMemoryJournalQuery(entries: InMemoryEntryService(entries: cards), calendar: JournalFixtures.utc)
        let query = JournalQuery(sort: .top)
        let first = try await mock.myEntries(query, after: nil, pageSize: 2)
        let second = try await mock.myEntries(query, after: first.nextCursor, pageSize: 2)
        let third = try await mock.myEntries(query, after: second.nextCursor, pageSize: 2)
        let ids = (first.items + second.items + third.items).map(\.id)
        #expect(ids == cards.reversed().map(\.id))
        #expect(third.nextCursor == nil)
        #expect(first.nextCursor?.score == 4)
    }

    @Test("applying a query re-reads from the top; clearing it returns to the plain journal")
    func storeApplies() async {
        let (store, _) = journal([
            JournalFixtures.card(2026, 9, 1, at: JournalFixtures.lune), JournalFixtures.card(2026, 9, 2),
            JournalFixtures.card(2026, 9, 3, at: JournalFixtures.lune)
        ])
        await store.loadIfNeeded()
        #expect(store.entries.count == 2) // page size 2
        await store.apply(JournalQuery(place: JournalPlace(restaurantID: JournalFixtures.lune.id, name: "Lune")))
        #expect(store.phase == .ready)
        #expect(store.entries.allSatisfy { $0.restaurantID == JournalFixtures.lune.id })
        #expect(store.entries.count == 2)
        await store.apply(JournalQuery(minScore: 5))
        #expect(store.phase == .empty)
        await store.apply(JournalQuery())
        #expect(store.entries.count == 2)
        #expect(store.query.isDefault)
    }

    @Test("writing an entry puts a filter down, so the new entry is on the journal it lands on")
    func writingClearsTheFilter() async {
        let (store, _) = journal([JournalFixtures.card(2026, 9, 1, at: JournalFixtures.lune)])
        await store.loadIfNeeded()
        await store.apply(JournalQuery(tag: .vg))
        #expect(store.phase == .empty)
        let written = JournalFixtures.card(2026, 9, 20)
        store.insert(written)
        #expect(store.query.isDefault)
        #expect(store.entries.first?.id == written.id)
        #expect(store.phase == .ready)
    }

    @Test("a store with no query seam ignores a filter rather than showing a wrong list")
    func noSeam() async {
        let store = JournalStore(entries: InMemoryEntryService(entries: [JournalFixtures.card(2026, 9, 1)]))
        await store.loadIfNeeded()
        await store.apply(JournalQuery(minScore: 5))
        #expect(store.query.isDefault)
        #expect(store.entries.count == 1)
    }

    @Test("writing while a filtered page is still loading: the stale page cannot wipe the new entry")
    func insertSupersedesAFilteredLoad() async {
        let service = InMemoryEntryService(entries: [JournalFixtures.card(2026, 9, 1, at: JournalFixtures.lune)])
        let gate = GatedJournalQuery(entries: service)
        let store = JournalStore(entries: service, pageSize: 5, querying: gate)
        await store.loadIfNeeded()
        let lune = JournalQuery(place: JournalPlace(restaurantID: JournalFixtures.lune.id, name: "Lune"))
        let filtering = Task { await store.apply(lune) }
        await gate.waitUntilAsked()
        // Written while the filtered page is on the wire — and not on the server yet.
        let written = JournalFixtures.card(2026, 9, 20)
        store.insert(written)
        #expect(store.query.isDefault)
        await gate.open()
        await filtering.value
        for _ in 0..<50 where store.phase == .loading { await Task.yield() }
        #expect(store.entries.first?.id == written.id, "the entry just written is still on top")
        #expect(store.query.isDefault, "and the journal is not the filtered list")
    }

    @Test("the pills of a query built fresh carry nothing from before round 5")
    func freshQuery() {
        var query = JournalQuery(sort: .newest, city: nil)
        query.band = .all
        #expect(query.isDefault && query.hasFilters == false)
    }
}

/// A journal query that holds its first answer until the test lets it go — a filtered page "on the
/// wire" for as long as a test needs one.
private actor GatedJournalQuery: JournalQuerying, TestFake {
    private let inner: InMemoryJournalQuery
    private var isOpen = false
    private var asked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var askWaiters: [CheckedContinuation<Void, Never>] = []

    init(entries: any EntryService) {
        inner = InMemoryJournalQuery(entries: entries)
    }

    func myEntries(
        _ query: JournalQuery, after cursor: JournalCursor?, pageSize: Int
    ) async throws -> JournalQueryPage {
        asked = true
        askWaiters.forEach { $0.resume() }
        askWaiters = []
        if isOpen == false { await withCheckedContinuation { waiting.append($0) } }
        return try await inner.myEntries(query, after: cursor, pageSize: pageSize)
    }

    func waitUntilAsked() async {
        if asked { return }
        await withCheckedContinuation { askWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
