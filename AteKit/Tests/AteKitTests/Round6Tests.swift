import Foundation
import Supabase
import Testing
@testable import AteKit

@Suite("Round 6 — your top dishes")
struct TopDishesTests {
    private static func dish(_ name: String, _ score: Double, id: UUID = UUID()) -> ScoredDish {
        ScoredDish(
            reviewID: UUID(), dishID: id, dishName: name, restaurantID: UUID(), restaurantName: "Somewhere",
            score: score, createdAt: Date(timeIntervalSince1970: 1_789_000_000), coverURL: nil
        )
    }

    private static func histogram(_ counts: [Double: Int]) -> ScoreHistogram {
        ScoreHistogram(counts.map { ScoreBucket(score: $0.key, dishCount: $0.value, reviewCount: $0.value) })
    }

    @Test("only the bars at 4.0 and up that hold a dish are read, best first — a 6 leads")
    func scores() {
        let chart = Self.histogram([6: 1, 5: 2, 4.5: 0, 4: 3, 3.5: 9])
        #expect(TopDishes.scores(in: chart) == [6, 5, 4])
        #expect(TopDishes.scores(in: Self.histogram([3: 4])).isEmpty, "nothing middling makes the list")
        #expect(TopDishes.scores(in: .empty).isEmpty)
        #expect(TopDishes.scores(in: nil) == [6, 5, 4.5, 4], "no chart: every score a top dish can have")
    }

    @Test("four at most, best score first, one tile per dish, reading no further than needed")
    func read() async {
        let pasta = UUID()
        let asked = Asked()
        let pages: [Double: [ScoredDish]] = [
            6: [Self.dish("Prawn spaghetti", 6)],
            5: [Self.dish("Pasta", 5, id: pasta), Self.dish("Pasta again", 5, id: pasta), Self.dish("Toast", 5)],
            4.5: [Self.dish("Cake", 4.5), Self.dish("Pie", 4.5)],
            4: [Self.dish("Soup", 4)]
        ]
        let picked = await TopDishes.read(scores: [6, 5, 4.5, 4]) { score in
            asked.note(score)
            return pages[score] ?? []
        }
        #expect(picked?.map(\.dishName) == ["Prawn spaghetti", "Pasta", "Toast", "Cake"])
        #expect(asked.scores == [6, 5, 4.5], "4.0 is never read once four are in hand")
    }

    /// The scores a read was asked for, from a `@Sendable` page reader.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Double] = []
        var scores: [Double] { lock.withLock { asked } }
        func note(_ score: Double) { lock.withLock { asked.append(score) } }
    }

    @Test("a failed read is skipped; all of them failing is no answer, not an empty section")
    func failures() async {
        struct Nope: Error {}
        let partly = await TopDishes.read(scores: [6, 5]) { score in
            if score == 6 { throw Nope() }
            return [Self.dish("Toast", 5)]
        }
        #expect(partly?.map(\.dishName) == ["Toast"])
        let none = await TopDishes.read(scores: [6, 5]) { _ in throw Nope() }
        #expect(none == nil)
        let nothing = await TopDishes.read(scores: []) { _ in [] }
        #expect(nothing == [], "nothing at 4.0 and up: no section")
    }
}

@Suite("Round 6 — the date window")
struct DateWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne") ?? .current
        return calendar
    }
    /// 28 Sep 2026, midday in Melbourne.
    private let now = Date(timeIntervalSince1970: 1_790_560_800)

    @Test("months roll over years both ways, and count the days of their own length")
    func months() {
        #expect(AteMonth(year: 2026, month: 13) == AteMonth(year: 2027, month: 1))
        #expect(AteMonth(year: 2026, month: 0) == AteMonth(year: 2025, month: 12))
        #expect(AteMonth(year: 2026, month: 3).adding(months: -24) == AteMonth(year: 2024, month: 3))
        #expect(AteMonth(year: 2028, month: 2).lastDay(calendar: calendar) == "2028-02-29")
        #expect(AteMonth(year: 2026, month: 9).firstDay == "2026-09-01")
    }

    @Test("the wire: inclusive days and the device's zone, and nothing at all for no window")
    func parameters() {
        let zone = TimeZone(identifier: "Australia/Melbourne") ?? .current
        #expect(DateWindow.all.parameters(timeZone: zone, calendar: calendar).isEmpty)
        let window = DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8))
        let parameters = window.parameters(timeZone: zone, calendar: calendar)
        #expect(parameters["p_from"] == .string("2026-03-01"))
        #expect(parameters["p_to"] == .string("2026-08-31"))
        #expect(parameters["p_tz"] == .string("Australia/Melbourne"))
        #expect(DateWindow(from: AteMonth(year: 2026, month: 3)).parameters(timeZone: zone)["p_to"] == nil,
                "an open end is simply not sent")
    }

    @Test("quick choices: named when they are one, and the ends reversed when set backwards")
    func presets() {
        let thisYear = DateWindow.preset(.thisYear, now: now, calendar: calendar)
        #expect(thisYear == DateWindow(from: AteMonth(year: 2026, month: 1)))
        #expect(thisYear.preset(now: now, calendar: calendar) == .thisYear)
        #expect(thisYear.title(now: now, calendar: calendar) == "This year")
        #expect(DateWindow.preset(.threeMonths, now: now, calendar: calendar).from == AteMonth(year: 2026, month: 7))
        let backwards = DateWindow(from: AteMonth(year: 2026, month: 8), to: AteMonth(year: 2026, month: 3))
        #expect(backwards.from == AteMonth(year: 2026, month: 3))
        #expect(DateWindow.preset(.all, now: now) == .all)
    }

    @Test("the ruler: two years to this month, both ends open, the whole of it no filter")
    func ruler() {
        let months = DateWindow.rulerMonths(now: now, calendar: calendar)
        #expect(months.count == 24)
        #expect(months.last == AteMonth(year: 2026, month: 9))
        #expect(months.first == AteMonth(year: 2024, month: 10))
        #expect(DateWindow.fromRuler(lower: 0, upper: 23, months: months) == .all)
        let window = DateWindow.fromRuler(lower: 17, upper: 22, months: months)
        #expect(window == DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8)))
        let stops = window.rulerStops(months: months)
        #expect(stops.lower == 17 && stops.upper == 22)
        let whole = DateWindow.all.rulerStops(months: months)
        #expect(whole.lower == 0 && whole.upper == 23)
        #expect(DateWindow(from: AteMonth(year: 2020, month: 1)).rulerStops(months: months).lower == 0,
                "an end before the ruler clamps to it")
    }

    @Test("a window's title and its filters: the Journal's pill, Search's pill, Saved's day")
    func wiring() {
        let window = DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8))
        #expect(window.title(now: now, calendar: calendar) == "Mar–Aug 2026")
        var query = JournalQuery(window: window)
        #expect(query.hasFilters && query.pills.map(\.id) == ["window"])
        query = query.removing(.window(window))
        #expect(query.isDefault)
        let search = SearchFilters(window: window)
        #expect(search.isEmpty == false && search.pills.map(\.id) == ["window"])
        #expect(search.parameters["p_from"] == .string("2026-03-01"))
        let shelf = SavedDishFilter(window: window)
        #expect(shelf.isEmpty == false && shelf.parameters["p_to"] != nil)
    }
}
