import Foundation
import Supabase
import Testing
@testable import AteKit

/// Round 4, browse: the journal's filter and sort (contract #3, built against the in-memory mock),
/// neighbourly letter tiles, and the events both ship with.
@MainActor
@Suite("Browse round 4")
struct BrowseRound4Tests {

    // MARK: - Fixtures

    private static let tipo = EntryCard.Place(id: UUID(), name: "Tipo 00", locality: "CBD")
    private static let lune = EntryCard.Place(id: UUID(), name: "Lune", locality: "Fitzroy")

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// An entry on a given UTC day, at a place, with dishes scored as given (`nil` = unscored).
    private static func card(
        _ year: Int, _ month: Int, _ day: Int,
        at place: EntryCard.Place? = tipo,
        scores: [Double?] = [4],
        tags: [DietTag] = []
    ) -> EntryCard {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return EntryCard(
            id: UUID(),
            authorID: ViewerProfile.preview.id,
            body: "Words",
            restaurantID: place?.id,
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: date,
            place: place,
            items: scores.enumerated().map { index, score in
                EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Dish \(index)",
                               score: score.map { Rating(rounding: $0) }, position: index + 1, tags: tags)
            }
        )
    }

    // MARK: - The query

    @Test("the default query is the journal itself, and has no pills")
    func defaultQuery() {
        let query = JournalQuery()
        #expect(query.isDefault)
        #expect(query.pills.isEmpty)
        #expect(query.filterNames == "none")
    }

    @Test("active filters become pills in a fixed order, and each pill removes only itself")
    func pills() {
        let place = JournalPlace(restaurantID: Self.tipo.id, name: "Tipo 00")
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
        #expect(query.matches(Self.card(2026, 9, 1, scores: [3, 4.5]), calendar: Self.utc))
        #expect(query.matches(Self.card(2026, 9, 1, scores: [3.5]), calendar: Self.utc) == false)
        #expect(query.matches(Self.card(2026, 9, 1, scores: [nil]), calendar: Self.utc) == false)
    }

    @Test("place, tag and period each narrow the list")
    func narrowing() {
        let place = JournalQuery(place: JournalPlace(restaurantID: Self.lune.id, name: "Lune"))
        #expect(place.matches(Self.card(2026, 9, 1, at: Self.lune), calendar: Self.utc))
        #expect(place.matches(Self.card(2026, 9, 1, at: Self.tipo), calendar: Self.utc) == false)
        let tag = JournalQuery(tag: .v)
        #expect(tag.matches(Self.card(2026, 9, 1, tags: [.v]), calendar: Self.utc))
        #expect(tag.matches(Self.card(2026, 9, 1), calendar: Self.utc) == false)
        let month = JournalQuery(period: .month(year: 2026, month: 8))
        #expect(month.matches(Self.card(2026, 8, 31), calendar: Self.utc))
        #expect(month.matches(Self.card(2026, 9, 1), calendar: Self.utc) == false)
        #expect(JournalQuery(period: .year(2025)).matches(Self.card(2025, 12, 31), calendar: Self.utc))
    }

    @Test("top rated puts the unscored last; oldest runs forward in time")
    func ordering() {
        let unscored = Self.card(2026, 9, 5, scores: [nil])
        let five = Self.card(2026, 9, 1, scores: [5])
        let three = Self.card(2026, 9, 3, scores: [3, nil])
        let top = JournalQuery(sort: .top).ordered([unscored, three, five])
        #expect(top.map(\.id) == [five.id, three.id, unscored.id])
        let oldest = JournalQuery(sort: .oldest).ordered([unscored, three, five])
        #expect(oldest.map(\.id) == [five.id, three.id, unscored.id])
        #expect(JournalSort.top.isChronological == false)
    }

    @Test("a period is sent as its first and last day, both inclusive — a leap February has 29")
    func periodDays() {
        let february = JournalPeriod.month(year: 2028, month: 2).days(calendar: Self.utc)
        #expect(JournalQueryClient.day(february.from) == "2028-02-01")
        #expect(JournalQueryClient.day(february.to) == "2028-02-29")
        let year = JournalPeriod.year(2026).days(calendar: Self.utc)
        #expect(JournalQueryClient.day(year.from) == "2026-01-01")
        #expect(JournalQueryClient.day(year.to) == "2026-12-31")
    }

    @Test("a month marker prints the month's name and year")
    func periodTitle() {
        let title = JournalPeriod.month(year: 2026, month: 9)
            .title(locale: Locale(identifier: "en_AU"), calendar: Self.utc)
        #expect(title == "September 2026")
        #expect(JournalPeriod.year(2025).title() == "2025")
    }

    // MARK: - The wire

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

    // MARK: - The mock and the store

    private func journal(_ cards: [EntryCard]) -> (JournalStore, InMemoryEntryService) {
        let service = InMemoryEntryService(entries: cards)
        let store = JournalStore(
            entries: service, pageSize: 2, querying: InMemoryJournalQuery(entries: service, calendar: Self.utc)
        )
        return (store, service)
    }

    @Test("the mock pages a filtered list by its keyset, never repeating or skipping a row")
    func mockPaging() async throws {
        let cards = (1...5).map { Self.card(2026, 9, $0, scores: [Double($0)]) }
        let mock = InMemoryJournalQuery(entries: InMemoryEntryService(entries: cards), calendar: Self.utc)
        let query = JournalQuery(sort: .top)
        let first = try await mock.myEntries(query, after: nil, pageSize: 2)
        let second = try await mock.myEntries(query, after: first.nextCursor, pageSize: 2)
        let third = try await mock.myEntries(query, after: second.nextCursor, pageSize: 2)
        let ids = (first.items + second.items + third.items).map(\.id)
        #expect(ids == cards.reversed().map(\.id))
        #expect(third.nextCursor == nil)
        #expect(first.nextCursor?.score == 4)
    }

    @Test("the mock offers each place written at, busiest first")
    func mockPlaces() async throws {
        let cards = [Self.card(2026, 9, 1, at: Self.lune), Self.card(2026, 9, 2), Self.card(2026, 9, 3),
                     Self.card(2026, 9, 4, at: nil)]
        let places = try await InMemoryJournalQuery(entries: InMemoryEntryService(entries: cards)).myEntryPlaces()
        #expect(places.map(\.name) == ["Tipo 00", "Lune"])
        #expect(places.map(\.entryCount) == [2, 1])
    }

    @Test("applying a query re-reads from the top; clearing it returns to the plain journal")
    func storeApplies() async {
        let (store, _) = journal([
            Self.card(2026, 9, 1, at: Self.lune), Self.card(2026, 9, 2), Self.card(2026, 9, 3, at: Self.lune)
        ])
        await store.loadIfNeeded()
        #expect(store.entries.count == 2) // page size 2
        await store.apply(JournalQuery(place: JournalPlace(restaurantID: Self.lune.id, name: "Lune")))
        #expect(store.phase == .ready)
        #expect(store.entries.allSatisfy { $0.restaurantID == Self.lune.id })
        #expect(store.entries.count == 2)
        await store.apply(JournalQuery(minScore: 5))
        #expect(store.phase == .empty)
        await store.apply(JournalQuery())
        #expect(store.entries.count == 2)
        #expect(store.query.isDefault)
    }

    @Test("writing an entry puts a filter down, so the new entry is on the journal it lands on")
    func writingClearsTheFilter() async {
        let (store, _) = journal([Self.card(2026, 9, 1, at: Self.lune)])
        await store.loadIfNeeded()
        await store.apply(JournalQuery(tag: .vg))
        #expect(store.phase == .empty)
        let written = Self.card(2026, 9, 20)
        store.insert(written)
        #expect(store.query.isDefault)
        #expect(store.entries.first?.id == written.id)
        #expect(store.phase == .ready)
    }

    @Test("a store with no query seam ignores a filter rather than showing a wrong list")
    func noSeam() async {
        let store = JournalStore(entries: InMemoryEntryService(entries: [Self.card(2026, 9, 1)]))
        await store.loadIfNeeded()
        await store.apply(JournalQuery(minScore: 5))
        #expect(store.query.isDefault)
        #expect(store.entries.count == 1)
    }

    @Test("writing while a filtered page is still loading: the stale page cannot wipe the new entry")
    func insertSupersedesAFilteredLoad() async {
        let service = InMemoryEntryService(entries: [Self.card(2026, 9, 1, at: Self.lune)])
        let gate = GatedJournalQuery(entries: service)
        let store = JournalStore(entries: service, pageSize: 5, querying: gate)
        await store.loadIfNeeded()
        let lune = JournalQuery(place: JournalPlace(restaurantID: Self.lune.id, name: "Lune"))
        let filtering = Task { await store.apply(lune) }
        await gate.waitUntilAsked()
        // Written while the filtered page is on the wire — and not on the server yet.
        let written = Self.card(2026, 9, 20)
        store.insert(written)
        #expect(store.query.isDefault)
        await gate.open()
        await filtering.value
        for _ in 0..<50 where store.phase == .loading { await Task.yield() }
        #expect(store.entries.first?.id == written.id, "the entry just written is still on top")
        #expect(store.query.isDefault, "and the journal is not the filtered list")
    }

    @Test("an entry at a place the filter has never offered asks for the places again")
    func newPlaceReloadsPlaces() async {
        let service = InMemoryEntryService(entries: [Self.card(2026, 9, 1, at: Self.lune)])
        let places = CountingPlaces(places: [JournalPlace(restaurantID: Self.lune.id, name: "Lune")])
        let store = JournalStore(entries: service, querying: places)
        await store.loadIfNeeded()
        await store.loadPlaces()
        #expect(await places.asked == 1)
        store.insert(Self.card(2026, 9, 18, at: Self.lune))
        #expect(await places.asked == 1, "a place already offered asks nothing")
        await places.add(JournalPlace(restaurantID: Self.tipo.id, name: "Tipo 00"))
        store.insert(Self.card(2026, 9, 20, at: Self.tipo))
        for _ in 0..<100 where store.places.count < 2 { await Task.yield() }
        #expect(store.places.map(\.name) == ["Lune", "Tipo 00"])
    }

    // MARK: - The entry page's refresh (QA)

    @Test("gone is gone even over the card the page was drawn from; other failures keep the card")
    func refreshFailures() {
        let gone = AteAPIError.notFound(table: "entry_cards", id: UUID())
        #expect(EntryRefreshFailure(gone, hasCard: true) == .gone)
        #expect(EntryRefreshFailure(gone, hasCard: false) == .gone)
        #expect(EntryRefreshFailure(URLError(.timedOut), hasCard: true) == .keepCardAndRetry)
        #expect(EntryRefreshFailure(URLError(.timedOut), hasCard: false) == .unreachable)
        #expect(EntryRefreshFailure(URLError(.cancelled), hasCard: true) == .ignore)
        #expect(EntryRefreshFailure(CancellationError(), hasCard: false) == .ignore)
    }

    @Test("a bookmark heard before the refresh answers survives the older row, tags and all")
    func saveEditsOutliveOlderReads() {
        let read = Self.card(2026, 9, 1, tags: [.gf])
        let dish = read.items[0].dishID
        var edits = EntrySaveEdits()
        edits.note(dishID: dish, isSaved: true)
        let shown = edits.applied(to: read)
        #expect(shown.items[0].saved)
        #expect(shown.items[0].tags == [.gf], "a bookmark never strips a line's tags")
        #expect(EntrySaveEdits().applied(to: read) == read)
    }

    // MARK: - Letter tiles

    @Test("neighbouring letter tiles never share an accent, and a list always paints the same way")
    func neighbourlyTiles() {
        let ids = (0..<400).map { _ in UUID() }
        let indices = DishTileIdentity.paletteIndices(for: ids, count: 5)
        #expect(indices.count == ids.count)
        #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 != $1 })
        #expect(indices.allSatisfy { (0..<5).contains($0) })
        #expect(DishTileIdentity.paletteIndices(for: ids, count: 5) == indices)
    }

    @Test("a tile keeps its own accent unless the one above it already has it")
    func tilesKeepTheirOwn() {
        let ids = (0..<200).map { _ in UUID() }
        let own = ids.map { DishTileIdentity.paletteIndex(for: $0, count: 5) }
        let indices = DishTileIdentity.paletteIndices(for: ids, count: 5)
        #expect(indices.first == own.first)
        for position in 1..<ids.count where own[position] != indices[position - 1] {
            #expect(indices[position] == own[position])
        }
    }

    @Test("the same dish twice in a row still gets two accents")
    func sameDishTwice() {
        let id = UUID()
        let indices = DishTileIdentity.paletteIndices(for: [id, id, id], count: 5)
        #expect(indices[0] != indices[1] && indices[1] != indices[2])
    }

    // MARK: - Events

    @Test("journal_queried names the filters in use and never their values")
    func queriedEvent() {
        let event = BrowseEvents.journalQueried(
            JournalQuery(sort: .oldest, place: JournalPlace(restaurantID: UUID(), name: "Secret"), tag: .df),
            resultCount: 7
        )
        #expect(event.name == "journal_queried")
        #expect(event.parameters == ["sort": "oldest", "filters": "place,tag", "result_count": "7"])
        #expect(event.parameters.values.contains("Secret") == false)
    }

    @Test("the photo viewer, the one filter sheet and the entry page report what they need")
    func otherEvents() {
        #expect(BrowseEvents.photoPreviewOpened(photoCount: 3).parameters == ["photo_count": "3"])
        let journal = BrowseEvents.filterOpened(on: .journal)
        #expect(journal.name == "filter_opened" && journal.parameters == ["surface": "journal"])
        #expect(BrowseEvents.filterOpened(on: .search).parameters == ["surface": "search"])
        #expect(BrowseEvents.entryOpened(seeded: true).parameters == ["seeded": "true"])
    }

    // MARK: - Search's active pills (the same pills as the Journal)

    @Test("search filters become pills — each cuisine, each tag, the score — and each removes itself")
    func searchPills() {
        let filters = SearchFilters(cuisines: ["Italian", "Thai"], tags: [.v, .gf], minimumScore: 4)
        #expect(filters.pills.map(\.title) == ["Italian", "Thai", "GF", "V", "4.0+"])
        #expect(Set(filters.pills.map(\.id)).count == 5)
        let noThai = filters.removing(filters.pills[1])
        #expect(noThai.cuisines == ["Italian"] && noThai.tags == [.gf, .v] && noThai.minimumScore == 4)
        let noGF = filters.removing(filters.pills[2])
        #expect(noGF.tags == [.v])
        let noScore = filters.removing(filters.pills[4])
        #expect(noScore.minimumScore == nil && noScore.count == 4)
        #expect(SearchFilters.none.pills.isEmpty)
    }
}

/// A journal query that holds its first answer until the test lets it go — a filtered page "on the
/// wire" for as long as a test needs one.
private actor GatedJournalQuery: JournalQuerying {
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

    func myEntryPlaces() async throws -> [JournalPlace] { try await inner.myEntryPlaces() }

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

/// Places on demand, counting how often they were asked for.
private actor CountingPlaces: JournalQuerying {
    private var places: [JournalPlace]
    private(set) var asked = 0

    init(places: [JournalPlace]) { self.places = places }

    func add(_ place: JournalPlace) { places.append(place) }

    func myEntries(
        _ query: JournalQuery, after cursor: JournalCursor?, pageSize: Int
    ) async throws -> JournalQueryPage {
        JournalQueryPage(items: [], nextCursor: nil)
    }

    func myEntryPlaces() async throws -> [JournalPlace] {
        asked += 1
        return places
    }
}
