import Foundation
import Testing
@testable import AteKit

/// The Journal and Saved's filter chips: what each chip says, what clearing one takes off, the live
/// "Show N entries" count behind every chip sheet, and the month dividers the list prints.
@MainActor
@Suite("Filter chips and month dividers")
struct FilterChipsTests {

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func card(_ year: Int, _ month: Int, _ day: Int) -> EntryCard {
        EntryCard(
            id: UUID(), authorID: ViewerProfile.preview.id, body: "Words", orderNumber: 1,
            createdAt: utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        )
    }

    // MARK: - The chips

    @Test("a chip at rest says its name; active, its value")
    func chipTitles() {
        let now = Self.utc.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        let rest = BrowseFilters()
        #expect(BrowseChip.allCases.map { rest.title(of: $0) } == ["Newest", "Rating", "City", "Date"])
        #expect(BrowseChip.allCases.allSatisfy { rest.isActive($0) == false })
        let set = BrowseFilters(
            sort: .top, band: ScoreBand.Preset.fourPlus.band, city: "melbourne",
            window: DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8))
        )
        #expect(set.title(of: .sort) == "Top rated")
        #expect(set.title(of: .rating) == "4.0+")
        #expect(set.title(of: .city) == "Melbourne")
        #expect(set.title(of: .city, cityName: "Melb") == "Melb")
        #expect(set.title(of: .date, now: now) == "Mar–Aug 2026")
        #expect(BrowseFilters(band: ScoreBand.Preset.sixes.band).title(of: .rating) == "6s only")
    }

    @Test("clearing a chip takes off its dimension alone")
    func clearing() {
        let set = BrowseFilters(sort: .oldest, band: ScoreBand.Preset.threePlus.band, city: "sydney",
                                window: DateWindow(from: AteMonth(year: 2026, month: 1)))
        #expect(set.clearing(.sort).sort == .newest && set.clearing(.sort).city == "sydney")
        #expect(set.clearing(.rating).band.isAll && set.clearing(.rating).sort == .oldest)
        #expect(set.clearing(.city).city == nil)
        #expect(set.clearing(.date).window.isAll)
    }

    @Test("the Journal's query and Saved's filter share the range, the city and the months")
    func shared() {
        let set = BrowseFilters(sort: .top, band: ScoreBand.Preset.fives.band, city: "melbourne")
        #expect(set.journalQuery.sort == .top && set.journalQuery.band == set.band)
        #expect(set.journalQuery.city == "melbourne" && set.journalQuery.place == nil)
        #expect(set.savedFilter == SavedDishFilter(band: set.band, city: "melbourne"))
        #expect(BrowseFilters(set.journalQuery) == set)
        #expect(BrowseChip.chips(on: .saved) == [.rating, .city, .date], "Saved has no order")
    }

    @Test("the chip events name the chip and the shelf, never the value")
    func events() {
        let event = BrowseEvents.chipOpened(.rating, on: .saved)
        #expect(event.name == "filter_chip_opened" && event.parameters == ["chip": "rating", "surface": "saved"])
        #expect(BrowseEvents.chipCleared(.city, on: .journal).name == "filter_chip_cleared")
    }

    // MARK: - The live count

    private actor Asked {
        var drafts: [Int] = []
        func note(_ draft: Int) { drafts.append(draft) }
    }

    @Test("the count follows the draft, asks once per pause, and remembers what it was told")
    func liveCount() async {
        let asked = Asked()
        let count = LiveCount<Int>(pause: .milliseconds(20)) { draft in
            await asked.note(draft)
            return draft * 10
        }
        count.request(1)
        count.request(2)
        count.request(3)
        await count.settle()
        #expect(count.count == 30 && count.draft == 3)
        #expect(await asked.drafts == [3], "a thumb passing stops asks only where it stops")
        count.request(4)
        await count.settle()
        count.request(3)
        #expect(count.count == 30, "a draft already asked about answers at once")
        #expect(await asked.drafts == [3, 4])
    }

    @Test("an in-memory journal counts what the query keeps")
    func inMemoryCount() async throws {
        let service = InMemoryEntryService(entries: [Self.card(2026, 9, 1), Self.card(2026, 8, 1)])
        let reader = InMemoryJournalQuery(entries: service, calendar: Self.utc)
        #expect(try await reader.myEntriesCount(JournalQuery()) == 2)
        #expect(try await reader.myEntriesCount(JournalQuery(window: AteMonth(year: 2026, month: 9).window)) == 1)
    }

    // MARK: - Month dividers

    @Test("a divider over the first entry of each month, only when the list runs through time")
    func dividers() {
        let entries = [Self.card(2026, 9, 20), Self.card(2026, 9, 2), Self.card(2026, 8, 30), Self.card(2025, 8, 1)]
        let dividers = JournalMonthDividers.dividers(for: entries, sort: .newest, calendar: Self.utc)
        #expect(dividers.count == 3)
        #expect(dividers[entries[0].id] == AteMonth(year: 2026, month: 9))
        #expect(dividers[entries[1].id] == nil)
        #expect(dividers[entries[2].id] == AteMonth(year: 2026, month: 8))
        #expect(dividers[entries[3].id] == AteMonth(year: 2025, month: 8), "the same month a year on is new")
        #expect(JournalMonthDividers.dividers(for: entries, sort: .top, calendar: Self.utc).isEmpty)
    }

    @Test("the divider's meta: the count, or with a filter the kept of the whole")
    func dividerMeta() {
        #expect(JournalMonthDividers.meta(year: 2026, total: 14, filtered: nil, isFiltered: false) == "2026 · 14 ENTRIES")
        #expect(JournalMonthDividers.meta(year: 2026, total: 1, filtered: nil, isFiltered: false) == "2026 · 1 ENTRY")
        #expect(JournalMonthDividers.meta(year: 2026, total: 14, filtered: 6, isFiltered: true) == "2026 · 6 OF 14")
        #expect(JournalMonthDividers.meta(year: 2026, total: nil, filtered: nil, isFiltered: false) == "2026")
        #expect(JournalMonthDividers.meta(year: 2026, total: 14, filtered: nil, isFiltered: true) == "2026")
    }
}

/// `MinimalEntry`: one dish and no other words prints the dish and its score once, in its row.
@Suite("Minimal entry")
struct MinimalEntryTests {
    private func card(_ body: String, dishes: [(String, Double?)], place: String? = "Neat maiden") -> EntryCard {
        EntryCard(
            id: UUID(), authorID: UUID(), body: body, orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            place: place.map { EntryCard.Place(id: UUID(), name: $0) },
            items: dishes.enumerated().map { index, dish in
                EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: dish.0,
                               score: dish.1.flatMap { Rating(exactly: $0) }, position: index + 1,
                               tags: dish.0 == "Apple pie" ? [.v] : [])
            }
        )
    }

    @Test("a dish, its tag and its score, and nothing else, echo the row")
    func echoes() {
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Apple pie V 3.5", dishes: [("Apple pie", 3.5)])))
        #expect(EntryBodyTokens.wordsEchoDishRows(card("apple pie 3.5.", dishes: [("Apple pie", 3.5)])))
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Burrata 4.0, tiramisu 3.5", dishes: [("Burrata", 4), ("Tiramisu", 3.5)])))
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Apple pie 3.5 Neat maiden", dishes: [("Apple pie", 3.5)])))
    }

    @Test("one word of their own and the words print")
    func ownWords() {
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Apple pie 3.5, again", dishes: [("Apple pie", 3.5)])) == false)
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Incredible pastry", dishes: [("Spanakopita", 3)])) == false)
        #expect(EntryBodyTokens.wordsEchoDishRows(card("", dishes: [("Apple pie", 3.5)])) == false)
        #expect(EntryBodyTokens.wordsEchoDishRows(card("Apple pie 4.5", dishes: [("Apple pie", 3.5)])) == false,
                "a number that is not the row's score is the person's own")
    }
}
