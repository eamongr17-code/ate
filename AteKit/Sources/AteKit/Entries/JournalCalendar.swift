import Foundation
import Observation

/// **The journal's calendar, as data** — a month's grid of days (Monday first, as the approved
/// artboard draws it) and the counts printed under a month or over a year. Pure, so a leap year, a
/// month that starts on a Sunday and a 6 on the last day are testable without a screen.
public enum JournalCalendar {
    /// Weeks run Monday to Sunday (`CalendarMonth`: "M T W T F S S").
    public static let weekdayCount = 7

    /// The month's cells, row by row: `nil` for the blanks before the 1st and after the last day.
    /// Always whole weeks.
    public static func grid(for month: AteMonth, calendar: Calendar = .autoupdatingCurrent) -> [AteDay?] {
        let (first, last) = month.days(calendar: calendar)
        // `weekday` is 1 for Sunday; Monday-first puts Monday at 0 and Sunday at 6.
        let weekday = calendar.component(.weekday, from: first.start(in: calendar))
        let leading = (weekday + 5) % weekdayCount
        var cells: [AteDay?] = Array(repeating: nil, count: leading)
        cells += (1...last.day).map { AteDay(year: month.year, month: month.month, day: $0) }
        let trailing = (weekdayCount - cells.count % weekdayCount) % weekdayCount
        return cells + Array(repeating: nil, count: trailing)
    }

    /// The weekday initials over the grid, Monday first, from the reader's locale.
    public static func weekdayInitials(locale: Locale = .autoupdatingCurrent) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == weekdayCount else { return ["M", "T", "W", "T", "F", "S", "S"] }
        return Array(symbols[1...]) + [symbols[0]]
    }
}

/// What a stretch of the calendar adds up to: visits (entries), the days whose best was a 5.0, and the
/// days whose best was a 6.
public struct JournalCalendarSummary: Sendable, Hashable {
    public var visits = 0
    public var fives = 0
    public var sixes = 0

    public init(visits: Int = 0, fives: Int = 0, sixes: Int = 0) {
        self.visits = visits
        self.fives = fives
        self.sixes = sixes
    }

    public init(_ days: some Sequence<JournalDayCount>) {
        for day in days {
            visits += day.entries
            switch day.mark {
            case .five: fives += 1
            case .six: sixes += 1
            case .visit: break
            }
        }
    }

    /// Under a month: "11 VISITS · 2 FIVE-STARS · 1 SIX". A zero part is left out.
    public var monthLine: String {
        var parts = [Self.counted(visits, "VISIT", "VISITS")]
        if fives > 0 { parts.append(Self.counted(fives, "FIVE-STAR", "FIVE-STARS")) }
        if sixes > 0 { parts.append(Self.counted(sixes, "SIX", "SIXES")) }
        return parts.joined(separator: " · ")
    }

    /// Beside a year: "96 VISITS · 14 ★5 · 3 ★6".
    public var yearLine: String {
        var parts = [Self.counted(visits, "VISIT", "VISITS")]
        if fives > 0 { parts.append("\(fives) ★5") }
        if sixes > 0 { parts.append("\(sixes) ★6") }
        return parts.joined(separator: " · ")
    }

    private static func counted(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

/// **The journal's days** (round 7): `journal_days` read a year at a time and kept, for the calendar's
/// month and year views and the month dividers' totals. Reads are joined, never repeated; a write
/// or a delete makes the whole of it stale (``invalidate()``).
@MainActor
@Observable
public final class JournalCalendarStore {
    public private(set) var days: [AteDay: JournalDayCount] = [:]
    /// The years that have answered.
    public private(set) var loadedYears: Set<Int> = []
    /// The first year with an entry in it, once known — how far back the calendar pages.
    public private(set) var firstYear: Int?
    /// Filtered month counts ("6 OF 14"), keyed by the month and the query that counted them.
    public private(set) var filteredCounts: [MonthCountKey: Int] = [:]

    public struct MonthCountKey: Hashable, Sendable {
        public let month: AteMonth
        public let query: JournalQuery
    }

    @ObservationIgnored private let querying: (any JournalQuerying)?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var reads: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var countReads: Set<MonthCountKey> = []
    @ObservationIgnored private var generation = 0

    public init(querying: (any JournalQuerying)?, calendar: Calendar = .autoupdatingCurrent) {
        self.querying = querying
        self.calendar = calendar
    }

    // MARK: - Reading

    /// The year's days, read once (`force` reads a stale year again). A read already on its way is
    /// joined.
    public func loadYear(_ year: Int, force: Bool = false) async {
        if let read = reads[year] {
            await read.value
            return
        }
        guard force || loadedYears.contains(year) == false, let querying else { return }
        let from = AteDay(year: year, month: 1, day: 1)
        let to = AteDay(year: year, month: 12, day: 31)
        let generationAtStart = generation
        let read = Task {
            guard let rows = try? await querying.journalDays(from: from, to: to) else { return }
            guard generationAtStart == generation else { return }
            // The year is replaced whole: a day whose last entry was deleted leaves with it.
            days = days.filter { $0.key.year != year }
            for row in rows { days[row.day] = row }
            loadedYears.insert(year)
        }
        reads[year] = read
        await read.value
        reads[year] = nil
    }

    /// The first year you wrote in — the oldest entry's (`my_entries` oldest first, one row).
    public func loadFirstYear() async {
        guard firstYear == nil, let querying else { return }
        let oldest = try? await querying.myEntries(JournalQuery(sort: .oldest), after: nil, pageSize: 1)
        if let first = oldest?.items.first {
            firstYear = calendar.component(.year, from: first.createdAt)
        }
    }

    /// A month divider's filtered count — how many of the month's entries `query` keeps.
    public func loadFilteredCount(_ month: AteMonth, query: JournalQuery) async {
        var counted = query
        counted.sort = .newest
        counted.window = month.window
        let key = MonthCountKey(month: month, query: query)
        guard filteredCounts[key] == nil, countReads.contains(key) == false, let querying else { return }
        countReads.insert(key)
        defer { countReads.remove(key) }
        let generationAtStart = generation
        guard let count = try? await querying.myEntriesCount(counted), generationAtStart == generation else { return }
        filteredCounts[key] = count
    }

    /// Something was written or deleted: every count may be wrong. What is on screen stays until
    /// the fresh reads land, so nothing blinks.
    public func invalidate() {
        generation += 1
        filteredCounts = [:]
        reads = [:]
        countReads = []
        let years = loadedYears
        Task {
            await loadFirstYear()
            for year in years.sorted(by: >) { await loadYear(year, force: true) }
        }
    }

    // MARK: - Asking

    public func day(_ day: AteDay) -> JournalDayCount? { days[day] }

    /// The days of a month that have an entry, in order.
    public func days(in month: AteMonth) -> [JournalDayCount] {
        days.values.filter { $0.day.calendarMonth == month }.sorted { $0.day < $1.day }
    }

    /// A month's total entries — `nil` until its year has answered.
    public func total(of month: AteMonth) -> Int? {
        guard loadedYears.contains(month.year) else { return nil }
        return days(in: month).reduce(0) { $0 + $1.entries }
    }

    public func filteredCount(of month: AteMonth, query: JournalQuery) -> Int? {
        filteredCounts[MonthCountKey(month: month, query: query)]
    }

    public func summary(of month: AteMonth) -> JournalCalendarSummary {
        JournalCalendarSummary(days(in: month))
    }

    public func summary(ofYear year: Int) -> JournalCalendarSummary {
        JournalCalendarSummary(days.values.filter { $0.day.year == year })
    }
}
