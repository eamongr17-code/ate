import Foundation
import Testing
@testable import AteKit

/// The journal's calendar: `journal_days` as data, the month grid, the counts under a month and
/// over a year, the store that keeps them, and a day's tap landing the list on that day.
@MainActor
@Suite("Journal calendar")
struct JournalCalendarTests {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_AU")
        return calendar
    }

    private static func card(
        _ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
        scores: [Double?] = [4], photo: String? = nil
    ) -> EntryCard {
        let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        return EntryCard(
            id: UUID(),
            authorID: ViewerProfile.preview.id,
            body: "Words",
            orderNumber: 1,
            sortStatus: .sorted,
            createdAt: date,
            photos: photo.map { [EntryCard.Photo(url: $0, position: 0)] } ?? [],
            items: scores.enumerated().map { index, score in
                EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Dish \(index)",
                               score: score.flatMap { Rating(exactly: $0) }, position: index + 1)
            }
        )
    }

    // MARK: - The wire

    @Test("a journal_days row decodes: the day as a date, a null best score, a 6")
    func decoding() throws {
        let json = Data("""
        [{"day":"2026-09-16","entries":2,"best_score":6,"cover_url":"https://x/y.jpg"},
         {"day":"2026-09-17","entries":1,"best_score":null,"cover_url":null}]
        """.utf8)
        let rows = try JSONDecoder().decode([JournalDayCount].self, from: json)
        #expect(rows[0].day == AteDay(year: 2026, month: 9, day: 16))
        #expect(rows[0].mark == .six && rows[0].coverURL == "https://x/y.jpg")
        #expect(rows[1].bestScore == nil && rows[1].mark == .visit)
        #expect(AteDay("2026-02-30x") != nil && AteDay("nope") == nil)
    }

    @Test("my_entries_count takes my_entries' filters and nothing else")
    func countParameters() throws {
        var query = JournalQuery(sort: .top, city: "melbourne", window: AteMonth(year: 2026, month: 9).window)
        query.band = ScoreBand.Preset.fourPlus.band
        let parameters = JournalQueryClient.countParameters(for: query, timeZone: TimeZone(identifier: "Australia/Melbourne")!)
        #expect(Set(parameters.keys) == ["p_min_score", "p_max_score", "p_city", "p_from", "p_to", "p_tz",
                                          "p_restaurant_id", "p_tag"])
        #expect(parameters["p_min_score"] == .double(4) && parameters["p_max_score"] == .null)
        #expect(parameters["p_from"] == .string("2026-09-01") && parameters["p_to"] == .string("2026-09-30"))
        #expect(try JournalQueryClient.decodeCount(Data("14".utf8)) == 14)
        #expect(try JournalQueryClient.decodeCount(Data(#"[{"count":3}]"#.utf8)) == 3)
    }

    // MARK: - The month grid

    @Test("the grid is Monday first, whole weeks, blanks around the month")
    func grid() {
        // 1 September 2026 is a Tuesday: one blank before it; the 30th is a Wednesday: four after.
        let september = JournalCalendar.grid(for: AteMonth(year: 2026, month: 9), calendar: Self.utc)
        #expect(september.count == 35)
        #expect(september[0] == nil && september[1] == AteDay(year: 2026, month: 9, day: 1))
        #expect(september.compactMap { $0 }.count == 30)
        // February 2028 is a leap month starting on a Tuesday.
        let february = JournalCalendar.grid(for: AteMonth(year: 2028, month: 2), calendar: Self.utc)
        #expect(february.compactMap { $0 }.last == AteDay(year: 2028, month: 2, day: 29))
        #expect(february.count.isMultiple(of: 7))
        #expect(JournalCalendar.weekdayInitials(locale: Locale(identifier: "en_AU")) == ["M", "T", "W", "T", "F", "S", "S"])
    }

    @Test("a day is marked by its best score: 6 brick, 5.0 butter, anything else a visit")
    func marks() {
        #expect(JournalDayMark(bestScore: 6) == .six)
        #expect(JournalDayMark(bestScore: 5) == .five)
        #expect(JournalDayMark(bestScore: 4.5) == .visit)
        #expect(JournalDayMark(bestScore: nil) == .visit, "unscored is a visit, never a guess")
    }

    @Test("the lines under a month and beside a year, zero parts left out")
    func summaries() {
        let days = [
            JournalDayCount(day: AteDay(year: 2026, month: 9, day: 2), entries: 3, bestScore: 5),
            JournalDayCount(day: AteDay(year: 2026, month: 9, day: 7), entries: 1, bestScore: 5),
            JournalDayCount(day: AteDay(year: 2026, month: 9, day: 16), entries: 2, bestScore: 6),
            JournalDayCount(day: AteDay(year: 2026, month: 9, day: 19), entries: 5, bestScore: nil)
        ]
        let summary = JournalCalendarSummary(days)
        #expect(summary.monthLine == "11 VISITS · 2 FIVE-STARS · 1 SIX")
        #expect(summary.yearLine == "11 VISITS · 2 ★5 · 1 ★6")
        #expect(JournalCalendarSummary(visits: 1).monthLine == "1 VISIT")
    }

    // MARK: - Deriving the days

    @Test("a reader without journal_days groups the entries by day: count, best, newest cover")
    func grouping() async throws {
        let cards = [
            Self.card(2026, 9, 16, hour: 9, scores: [4], photo: "morning"),
            Self.card(2026, 9, 16, hour: 20, scores: [6, 3], photo: "evening"),
            Self.card(2026, 9, 17, scores: [nil]),
            Self.card(2026, 8, 31, scores: [5])
        ]
        let rows = JournalDayCount.grouping(
            cards, from: AteDay(year: 2026, month: 9, day: 1), to: AteDay(year: 2026, month: 9, day: 30),
            calendar: Self.utc
        )
        #expect(rows.map(\.day.day) == [16, 17])
        #expect(rows[0].entries == 2 && rows[0].bestScore == 6 && rows[0].coverURL == "evening")
        #expect(rows[1].bestScore == nil && rows[1].coverURL == nil)
    }

    // MARK: - The store

    @Test("the store reads a year once, totals a month, and counts a filtered month")
    func store() async {
        let service = InMemoryEntryService(entries: [
            Self.card(2026, 9, 2, scores: [5]), Self.card(2026, 9, 2, scores: [3]),
            Self.card(2026, 9, 16, scores: [6]), Self.card(2026, 8, 20, scores: [2]),
            Self.card(2025, 3, 1, scores: [4])
        ])
        let store = JournalCalendarStore(querying: InMemoryJournalQuery(entries: service, calendar: Self.utc),
                                         calendar: Self.utc)
        let september = AteMonth(year: 2026, month: 9)
        #expect(store.total(of: september) == nil, "nothing until the year answers")
        await store.loadYear(2026)
        #expect(store.total(of: september) == 3)
        #expect(store.total(of: AteMonth(year: 2026, month: 7)) == 0)
        #expect(store.summary(of: september) == JournalCalendarSummary(visits: 3, fives: 1, sixes: 1))
        #expect(store.summary(ofYear: 2026).visits == 4)
        #expect(store.day(AteDay(year: 2026, month: 9, day: 2))?.entries == 2)

        var query = JournalQuery()
        query.band = ScoreBand.Preset.fourPlus.band
        await store.loadFilteredCount(september, query: query)
        #expect(store.filteredCount(of: september, query: query) == 2)

        await store.loadFirstYear()
        #expect(store.firstYear == 2025)
    }

    // MARK: - A day's tap

    @Test("a day off the loaded pages is read on to, and lands on its first entry")
    func revealReadsOn() async {
        let cards = (1...30).map { Self.card(2026, 9, 30 - $0 + 1) } // 30 Sep … 1 Sep, one a day
        let service = InMemoryEntryService(entries: cards)
        let store = JournalStore(entries: service, pageSize: 5, calendar: Self.utc)
        await store.loadIfNeeded()
        #expect(store.entries.count == 5)
        let landing = await store.reveal(AteDay(year: 2026, month: 9, day: 3))
        #expect(landing.map { AteDay.containing($0.createdAt, calendar: Self.utc) } == AteDay(year: 2026, month: 9, day: 3))
        #expect(store.entries.count >= 28)
    }

    @Test("a day with nothing on it lands on the nearest entry past it; top-rated has no days")
    func revealNearest() async {
        let service = InMemoryEntryService(entries: [
            Self.card(2026, 9, 20), Self.card(2026, 9, 10), Self.card(2026, 9, 1)
        ])
        let store = JournalStore(entries: service, calendar: Self.utc,
                                 querying: InMemoryJournalQuery(entries: service, calendar: Self.utc))
        await store.loadIfNeeded()
        let landing = await store.reveal(AteDay(year: 2026, month: 9, day: 15))
        #expect(landing.map { AteDay.containing($0.createdAt, calendar: Self.utc).day } == 10)
        await store.apply(JournalQuery(sort: .top))
        #expect(await store.reveal(AteDay(year: 2026, month: 9, day: 15)) == nil)
    }

    @Test("writing, replacing or deleting counts as a local change")
    func localChanges() async {
        let service = InMemoryEntryService(entries: [Self.card(2026, 9, 20)])
        let store = JournalStore(entries: service, calendar: Self.utc)
        await store.loadIfNeeded()
        let before = store.localChanges
        let fresh = Self.card(2026, 9, 21)
        store.insert(fresh)
        store.remove(entryID: fresh.id)
        #expect(store.localChanges == before + 2)
    }

    @Test("the calendar's events: which view, how it was reached, where a day landed")
    func events() {
        let opened = BrowseEvents.calendarOpened(.year, via: .pinch)
        #expect(opened.name == "calendar_opened" && opened.parameters == ["level": "year", "via": "pinch"])
        #expect(BrowseEvents.calendarDayOpened(exact: false).parameters == ["landed": "nearest"])
    }
}
