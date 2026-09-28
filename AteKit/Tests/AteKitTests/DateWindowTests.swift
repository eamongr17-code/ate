import Foundation
import Testing
@testable import AteKit

@Suite("The date window")
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
