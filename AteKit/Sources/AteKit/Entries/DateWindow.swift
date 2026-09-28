import Foundation
import Supabase

/// A calendar month — the date filter's unit (round 6).
public struct AteMonth: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        // Normalised, so `month` 0 or 13 rolls into the neighbouring year.
        let index = year * 12 + (month - 1)
        self.year = Int((Double(index) / 12).rounded(.down))
        self.month = index - self.year * 12 + 1
    }

    /// The month a moment falls in, in the reader's own calendar.
    public static func containing(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> AteMonth {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return AteMonth(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    public func adding(months: Int) -> AteMonth { AteMonth(year: year, month: month + months) }

    /// Months from `self` to `other` (positive when `other` is later).
    public func distance(to other: AteMonth) -> Int { (other.year - year) * 12 + (other.month - month) }

    public static func < (lhs: AteMonth, rhs: AteMonth) -> Bool { (lhs.year, lhs.month) < (rhs.year, rhs.month) }

    /// `2026-09-01` — the first day, as the contract's inclusive `date`.
    public var firstDay: String { String(format: "%04d-%02d-01", year, month) }

    /// `2026-09-30` — the last day, counted by the calendar (a February, a leap year).
    public func lastDay(calendar: Calendar = .autoupdatingCurrent) -> String {
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        let length = first.flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 31
        return String(format: "%04d-%02d-%02d", year, month, length)
    }

    /// "Sep", from the reader's locale.
    public func shortName(locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortStandaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
    }
}

/// **The date filter** (round 6, Eamon: "filters need to have a date range slider") — a run of whole
/// months, either end open. The Journal filters by the visit day (`my_entries`), Search by the visit
/// day of the lines it counts (0050: the numbers become the window's), Saved by the day a dish was
/// saved. The contract's rule everywhere: `p_from` / `p_to` inclusive days, `p_tz` the device's zone.
///
/// - `from` open is "from the beginning"; `to` open is "up to today". Both open is no filter.
public struct DateWindow: Hashable, Sendable {
    public var from: AteMonth?
    public var to: AteMonth?

    public init(from: AteMonth? = nil, to: AteMonth? = nil) {
        if let from, let to, to < from {
            self.from = to
            self.to = from
        } else {
            self.from = from
            self.to = to
        }
    }

    public static let all = DateWindow()
    public var isAll: Bool { from == nil && to == nil }

    /// How far back the month ruler reaches: two years, this month included.
    public static let span = 24

    // MARK: - The quick choices

    public enum Preset: String, CaseIterable, Sendable {
        case thisMonth, threeMonths, thisYear, all

        public var title: String {
            switch self {
            case .thisMonth: "This month"
            case .threeMonths: "3 mo"
            case .thisYear: "This year"
            case .all: "All"
            }
        }
    }

    public static func preset(
        _ preset: Preset, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent
    ) -> DateWindow {
        let current = AteMonth.containing(now, calendar: calendar)
        switch preset {
        case .thisMonth: return DateWindow(from: current)
        case .threeMonths: return DateWindow(from: current.adding(months: -2))
        case .thisYear: return DateWindow(from: AteMonth(year: current.year, month: 1))
        case .all: return .all
        }
    }

    /// Which quick choice this window is, if it is one.
    public func preset(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Preset? {
        Preset.allCases.first { DateWindow.preset($0, now: now, calendar: calendar) == self }
    }

    // MARK: - Reading it

    /// Whether a moment falls inside, in the reader's calendar.
    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let month = AteMonth.containing(date, calendar: calendar)
        if let from, month < from { return false }
        if let to, to < month { return false }
        return true
    }

    /// `p_from` / `p_to` / `p_tz` — only the ends that are set; nothing at all for no filter, so an
    /// unwindowed read is exactly the call it always was.
    public func parameters(
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: AnyJSON] {
        guard isAll == false else { return [:] }
        var parameters: [String: AnyJSON] = ["p_tz": .string(timeZone.identifier)]
        if let from { parameters["p_from"] = .string(from.firstDay) }
        if let to { parameters["p_to"] = .string(to.lastDay(calendar: calendar)) }
        return parameters
    }

    /// The pill, and the sheet's readout: a quick choice by its name, else the months — "Mar–Aug
    /// 2026", "Nov 2025–Feb 2026", "Since Mar 2026", "To Jun 2026". `nil` for no filter.
    public func title(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String? {
        if isAll { return nil }
        switch preset(now: now, calendar: calendar) {
        case .thisMonth: return "This month"
        case .threeMonths: return "Last 3 months"
        case .thisYear: return "This year"
        default: break
        }
        switch (from, to) {
        case let (from?, to?) where from == to:
            return "\(from.shortName()) \(from.year)"
        case let (from?, to?) where from.year == to.year:
            return "\(from.shortName())–\(to.shortName()) \(to.year)"
        case let (from?, to?):
            return "\(from.shortName()) \(from.year)–\(to.shortName()) \(to.year)"
        case let (from?, nil):
            return "Since \(from.shortName()) \(from.year)"
        case let (nil, to?):
            return "To \(to.shortName()) \(to.year)"
        default:
            return nil
        }
    }

    // MARK: - The ruler

    /// The ruler's months, oldest first, ending on the current one.
    public static func rulerMonths(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> [AteMonth] {
        let current = AteMonth.containing(now, calendar: calendar)
        return (0..<span).map { current.adding(months: $0 - span + 1) }
    }

    /// The window a pair of ruler stops describes: the first stop is open-ended backwards (all that
    /// came before), the last is open-ended forwards (up to today) — so the whole ruler is no filter.
    public static func fromRuler(lower: Int, upper: Int, months: [AteMonth]) -> DateWindow {
        guard months.isEmpty == false else { return .all }
        let low = max(0, min(lower, upper))
        let high = min(months.count - 1, max(lower, upper))
        return DateWindow(from: low == 0 ? nil : months[low], to: high == months.count - 1 ? nil : months[high])
    }

    /// Where this window's ends sit on the ruler (an open end is the ruler's own end; an end before
    /// the ruler starts clamps to it).
    public func rulerStops(months: [AteMonth]) -> (lower: Int, upper: Int) {
        guard let first = months.first, let last = months.last else { return (0, 0) }
        let lower = from.map { min(max(first.distance(to: $0), 0), months.count - 1) } ?? 0
        let upper = to.map { min(max(first.distance(to: $0), 0), months.count - 1) } ?? first.distance(to: last)
        return (lower, max(lower, upper))
    }
}
