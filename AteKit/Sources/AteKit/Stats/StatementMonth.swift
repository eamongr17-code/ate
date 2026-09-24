import Foundation

/// **A month, as a statement is filed under it** — a year and a month number, and nothing else.
///
/// Deliberately **not a `Date`.** The server cuts months on local wall-clock boundaries (`p_tz`) and
/// hands the answer back as `"2026-09-01"`; parsed into a `Date` that is UTC midnight, and formatted
/// west of Greenwich it reads as *August*. A statement that renames itself depending on where you
/// stand is the bug this type exists to make impossible.
public struct StatementMonth: Sendable, Hashable, Codable, Identifiable, Comparable {
    public let year: Int
    /// 1…12.
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = min(12, max(1, month))
    }

    /// `"2026-09-01"` or `"2026-09"` — whatever the wire happens to carry.
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    /// The month containing an instant, in a given zone. How "this month" is decided on the client.
    public init(containing date: Date, in timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    /// `"2026-09"` — stable, sortable, and what an analytics parameter carries.
    public var key: String { String(format: "%04d-%02d", year, month) }

    public var id: String { key }

    /// What `monthly_statement(p_month …)` takes: the first of the month, ISO.
    public var parameter: String { "\(key)-01" }

    /// The statement's own title — "September". The month's NAME is the reader's locale's; which
    /// month it is, is not.
    public var title: String { Self.symbols[month - 1] }

    public static func < (lhs: StatementMonth, rhs: StatementMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    /// Encodes and decodes as the ISO first-of-month the server speaks, so a row and a parameter are
    /// the same string in both directions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let month = StatementMonth(iso: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a month: \(raw)"
            )
        }
        self = month
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(parameter)
    }

    /// Standalone names ("September", not "of September"), read once — a `DateFormatter` per row is
    /// the classic way a list scrolls badly.
    private static let symbols: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        return formatter.standaloneMonthSymbols ?? [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"
        ]
    }()
}

/// A month that has a statement, with how many orders are in it — `statement_months`.
public struct StatementMonthSummary: Sendable, Hashable, Codable, Identifiable {
    public let month: StatementMonth
    public let orders: Int

    public var id: String { month.key }

    public init(month: StatementMonth, orders: Int) {
        self.month = month
        self.orders = orders
    }
}

/// **The months you can actually turn to**, newest first.
///
/// Walking is over the months that *exist*, not over the calendar: a person who wrote nothing in
/// August goes September → July in one step rather than through an empty receipt. Design rule 4 —
/// a receipt is only ever printed where something was printed.
public struct StatementMonths: Sendable, Hashable {
    /// Newest first, deduplicated.
    public let months: [StatementMonth]

    public init(_ months: [StatementMonth]) {
        var seen = Set<String>()
        self.months = months
            .sorted(by: >)
            .filter { seen.insert($0.key).inserted }
    }

    public init(summaries: [StatementMonthSummary]) {
        self.init(summaries.map(\.month))
    }

    public var isEmpty: Bool { months.isEmpty }

    /// The month the You tab's statement row points at.
    public var newest: StatementMonth? { months.first }

    public func contains(_ month: StatementMonth) -> Bool {
        months.contains(month)
    }

    public func index(of month: StatementMonth) -> Int? {
        months.firstIndex(of: month)
    }

    /// The next one back in time, skipping months with nothing in them.
    public func older(than month: StatementMonth) -> StatementMonth? {
        months.first { $0 < month }
    }

    /// The next one forward.
    public func newer(than month: StatementMonth) -> StatementMonth? {
        months.last { $0 > month }
    }
}
