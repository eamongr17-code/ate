import Foundation
import Testing

@testable import AteKit

/// The diary's shape, as arithmetic (§3.2, §10).
///
/// Every case here is one a person hits in a normal week of eating: two dishes at one table, the
/// same place for lunch and dinner, a long night, a page boundary landing mid-sitting. They are
/// asserted on the pure grouping function rather than driven through a `List`, which is the point of
/// the function existing.
@Suite("Diary grouping")
struct DiaryGroupingTests {

    // MARK: - Fixtures

    /// Melbourne, pinned. Grouping is a *local* calendar question, so a test that ran in UTC and
    /// passed would be telling us nothing about the users it was designed for.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return calendar
    }

    private static func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private static let tipo = FeedEntry.RestaurantSummary(id: UUID(), name: "Tipo 00", city: "Carlton")
    private static let lune = FeedEntry.RestaurantSummary(id: UUID(), name: "Lune", city: "Fitzroy")

    private static func entry(
        _ name: String,
        at date: Date,
        restaurant: FeedEntry.RestaurantSummary = tipo,
        id: UUID = UUID()
    ) -> FeedEntry {
        let dishID = UUID()
        return FeedEntry(
            review: Review(
                id: id,
                reviewerID: UUID(),
                dishID: dishID,
                restaurantID: restaurant.id,
                score: Rating(exactly: 4.5)!,
                createdAt: date,
                updatedAt: date
            ),
            dish: FeedEntry.DishSummary(id: dishID, name: name),
            restaurant: restaurant
        )
    }

    private func sittings(_ entries: [FeedEntry]) -> [DiarySitting] {
        DiaryGrouping.sittings(from: entries, calendar: Self.calendar)
    }

    // MARK: - The rule

    @Test("Dishes at one table are one sitting")
    func oneSitting() {
        let result = sittings([
            Self.entry("Tiramisu", at: Self.date(12, 20, 40)),
            Self.entry("Bucatini", at: Self.date(12, 20, 5))
        ])

        #expect(result.count == 1)
        #expect(result[0].dishCount == 2)
        #expect(result[0].isMultiDish)
        #expect(result[0].restaurant.name == "Tipo 00")
        // The block is identified by its newest member, and dated by it.
        #expect(result[0].newestAt == Self.date(12, 20, 40))
    }

    @Test("A single dish is a sitting like any other — no special case")
    func singleDishSitting() {
        let result = sittings([Self.entry("Bucatini", at: Self.date(12, 20))])

        #expect(result.count == 1)
        #expect(result[0].dishCount == 1)
        #expect(!result[0].isMultiDish)
    }

    @Test("A different restaurant always breaks the sitting, however close in time")
    func differentRestaurantSplits() {
        let result = sittings([
            Self.entry("Cruffin", at: Self.date(12, 20, 30), restaurant: Self.lune),
            Self.entry("Bucatini", at: Self.date(12, 20, 25))
        ])

        #expect(result.count == 2)
        #expect(result.map(\.restaurant.name) == ["Lune", "Tipo 00"])
    }

    @Test("§10.4 the same restaurant twice in a day is two blocks, not one")
    func sameRestaurantTwiceInADay() {
        let result = sittings([
            Self.entry("Tiramisu", at: Self.date(12, 20, 10)),   // dinner
            Self.entry("Bucatini", at: Self.date(12, 19, 55)),   // dinner
            Self.entry("Panino", at: Self.date(12, 13, 5)),      // lunch, same place
            Self.entry("Arancini", at: Self.date(12, 12, 50))    // lunch
        ])

        #expect(result.count == 2)
        #expect(result.map(\.dishCount) == [2, 2])
        #expect(result[0].entries.map(\.dish.name) == ["Tiramisu", "Bucatini"])
        #expect(result[1].entries.map(\.dish.name) == ["Panino", "Arancini"])
    }

    @Test("The window is measured from the group's newest member, not from its neighbour")
    func windowIsFromNewestNotNeighbour() {
        // Three rows 80 minutes apart each: neighbour-chaining would make this one 160-minute
        // "sitting". Measured from the newest, the third row falls out.
        let result = sittings([
            Self.entry("Third", at: Self.date(12, 22, 0)),
            Self.entry("Second", at: Self.date(12, 20, 40)),
            Self.entry("First", at: Self.date(12, 19, 20))
        ])

        #expect(result.count == 2)
        #expect(result[0].entries.map(\.dish.name) == ["Third", "Second"])
        #expect(result[1].entries.map(\.dish.name) == ["First"])
    }

    @Test("Exactly 90 minutes is still the same sitting; a minute more is not")
    func windowBoundary() {
        let onTheLine = sittings([
            Self.entry("Late", at: Self.date(12, 21, 30)),
            Self.entry("Early", at: Self.date(12, 20, 0))
        ])
        #expect(onTheLine.count == 1)

        let overTheLine = sittings([
            Self.entry("Late", at: Self.date(12, 21, 31)),
            Self.entry("Early", at: Self.date(12, 20, 0))
        ])
        #expect(overTheLine.count == 2)
    }

    @Test("§10.1 a late sitting that crosses local midnight is two blocks")
    func midnightSplitsInLocalTime() {
        // 23:40 and 00:20 are 40 minutes apart — inside the window — but different days to the
        // person who ate them, and the diary's spine is days.
        let result = sittings([
            Self.entry("Nightcap", at: Self.date(13, 0, 20)),
            Self.entry("Dinner", at: Self.date(12, 23, 40))
        ])

        #expect(result.count == 2)
    }

    // MARK: - Paging (§10.3)

    @Test("§10.3 a sitting split across a page boundary regroups when the next page appends")
    func splitSittingRegroupsOnAppend() {
        // A three-dish sitting cut by a page that ends after its first dish.
        let all = [
            Self.entry("Tiramisu", at: Self.date(12, 20, 40)),
            Self.entry("Bucatini", at: Self.date(12, 20, 20)),
            Self.entry("Arancini", at: Self.date(12, 20, 0)),
            Self.entry("Cruffin", at: Self.date(11, 9, 0), restaurant: Self.lune)
        ]

        let firstPage = sittings(Array(all.prefix(1)))
        #expect(firstPage.count == 1)
        #expect(firstPage[0].dishCount == 1)

        let bothPages = sittings(all)
        #expect(bothPages.count == 2)
        #expect(bothPages[0].dishCount == 3)
        #expect(bothPages[0].entries.map(\.dish.name) == ["Tiramisu", "Bucatini", "Arancini"])
        // The grown block keeps the identity it had when it was one row, so the list updates the
        // block rather than replacing it.
        #expect(bothPages[0].id == firstPage[0].id)
    }

    // MARK: - Months

    @Test("Months section the sittings, newest first, with their dish counts")
    func monthSections() {
        let months = DiaryGrouping.months(
            from: [
                Self.entry("Tiramisu", at: Self.date(12, 20, 40)),
                Self.entry("Bucatini", at: Self.date(12, 20, 20)),
                Self.entry("Cruffin", at: Self.date(3, 9, 0), restaurant: Self.lune),
                Self.entry("Panino", at: Self.date(28, 13, 0, month: 8))
            ],
            calendar: Self.calendar,
            now: Self.date(20, 12)
        )

        #expect(months.map(\.id) == [
            DiaryMonth.Key(year: 2026, month: 9),
            DiaryMonth.Key(year: 2026, month: 8)
        ])
        #expect(months[0].dishCount == 3)
        #expect(months[0].sittings.count == 2)
        #expect(months[1].dishCount == 1)
    }

    @Test("§10.2 a future timestamp lands in today's month, not a phantom one ahead")
    func futureDateClampsToNow() {
        let now = Self.date(12, 12)
        let months = DiaryGrouping.months(
            from: [Self.entry("Time traveller", at: Self.date(4, 12, month: 11))],
            calendar: Self.calendar,
            now: now
        )

        #expect(months.count == 1)
        #expect(months[0].id == DiaryMonth.Key(year: 2026, month: 9))
    }

    @Test("Empty in, empty out — no section for nothing")
    func emptyInput() {
        #expect(DiaryGrouping.months(from: [], calendar: Self.calendar).isEmpty)
        #expect(sittings([]).isEmpty)
    }

    // MARK: - Day labels

    @Test("The two most recent days are named; older ones are dated")
    func dayLabels() {
        let now = Self.date(12, 18)
        #expect(DiaryDayLabel.of(Self.date(12, 9), now: now, calendar: Self.calendar) == .today)
        #expect(DiaryDayLabel.of(Self.date(11, 21), now: now, calendar: Self.calendar) == .yesterday)
        #expect(
            DiaryDayLabel.of(Self.date(10, 21), now: now, calendar: Self.calendar)
                == .date(Self.date(10, 21))
        )
        // §10.2 again, at the label: a skewed clock reads as today, never as a date in the future.
        #expect(DiaryDayLabel.of(Self.date(20, 9), now: now, calendar: Self.calendar) == .today)
    }

    // MARK: - Record line

    @Test("The record line counts dishes and distinct places — only once the diary is all loaded")
    func recordLine() {
        let entries = [
            Self.entry("Tiramisu", at: Self.date(12, 20, 40)),
            Self.entry("Bucatini", at: Self.date(12, 20, 20)),
            Self.entry("Cruffin", at: Self.date(3, 9, 0), restaurant: Self.lune)
        ]

        #expect(DiaryRecordLine.text(entries: entries, hasReachedEnd: true) == "3 dishes · 2 places")
        // Mid-stream the totals would be a claim about rows nobody has read yet.
        #expect(DiaryRecordLine.text(entries: entries, hasReachedEnd: false) == nil)
        #expect(DiaryRecordLine.text(entries: [], hasReachedEnd: true) == nil)
    }

    @Test("One of a thing is singular, in the record line and in a month header")
    func singularCounts() {
        let one = [Self.entry("Bucatini", at: Self.date(12, 20))]
        #expect(DiaryRecordLine.text(entries: one, hasReachedEnd: true) == "1 dish · 1 place")
        #expect(DiaryRecordLine.dishCount(1) == "1 dish")
        #expect(DiaryRecordLine.dishCount(4) == "4 dishes")
    }
}
