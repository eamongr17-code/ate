import Foundation

/// A calendar day — the unit of `journal_days` and of the calendar's tiles: `2026-09-12`, a Postgres
/// `date` in the device's own zone. No time, so a day never slides across midnight in transit.
public struct AteDay: Hashable, Sendable, Comparable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `2026-09-12`, as the wire carries it. `nil` for anything that is not one.
    public init?(_ string: String) {
        let parts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The day a moment falls on, in the reader's own calendar.
    public static func containing(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> AteDay {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return AteDay(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var calendarMonth: AteMonth { AteMonth(year: year, month: month) }

    /// Midnight at the start of the day, in `calendar`.
    public func start(in calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public static func < (lhs: AteDay, rhs: AteDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let day = AteDay(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(string)"))
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

public extension AteMonth {
    /// The month's first and last day.
    func days(calendar: Calendar = .autoupdatingCurrent) -> (first: AteDay, last: AteDay) {
        let first = AteDay(year: year, month: month, day: 1)
        let length = calendar.date(from: DateComponents(year: year, month: month, day: 1))
            .flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 31
        return (first, AteDay(year: year, month: month, day: length))
    }

    /// The window that is exactly this month — what a month divider's filtered count asks about.
    var window: DateWindow { DateWindow(from: self, to: self) }

    /// "September", from the reader's locale.
    func name(locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneMonthSymbols
        return symbols.indices.contains(month - 1) ? symbols[month - 1] : String(month)
    }
}

/// **One day of your journal** — a row of `journal_days(p_from, p_to, p_tz)`: how many entries you
/// wrote that day, the best score on any of them (`nil` when none was scored; may be the secret 6),
/// and a photo to put on the calendar's tile.
public struct JournalDayCount: Sendable, Hashable, Decodable {
    public let day: AteDay
    public let entries: Int
    public let bestScore: Double?
    public let coverURL: String?

    public init(day: AteDay, entries: Int, bestScore: Double? = nil, coverURL: String? = nil) {
        self.day = day
        self.entries = entries
        self.bestScore = bestScore
        self.coverURL = coverURL
    }

    enum CodingKeys: String, CodingKey {
        case day, entries
        case bestScore = "best_score"
        case coverURL = "cover_url"
    }

    /// What the calendar marks the day with.
    public var mark: JournalDayMark { JournalDayMark(bestScore: bestScore) }
}

/// **How a day stands out on the calendar**: a 6 (brick ring, ★6), a 5.0 (butter ring, ★5), or
/// simply a visit. Scores are never inferred — an unscored day is a plain visit.
public enum JournalDayMark: Sendable, Hashable {
    case visit, five, six

    public init(bestScore: Double?) {
        switch bestScore {
        case let score? where score >= ScoreBand.six: self = .six
        case let score? where score >= ScoreBand.topScore: self = .five
        default: self = .visit
        }
    }
}

public extension JournalQuerying {
    /// A reader without `journal_days` (the fakes, the in-memory drive) derives it from the entries
    /// themselves: every entry in the range that the query keeps, grouped by its day in the reader's
    /// calendar.
    func journalDays(from: AteDay, to: AteDay, matching query: JournalQuery?) async throws -> [JournalDayCount] {
        var filtered = query ?? JournalQuery()
        filtered.sort = .newest
        filtered.window = DateWindow(from: from.calendarMonth, to: to.calendarMonth)
        var cards: [EntryCard] = []
        var cursor: JournalCursor?
        repeat {
            let page = try await myEntries(filtered, after: cursor, pageSize: 100)
            cards += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return JournalDayCount.grouping(cards, from: from, to: to)
    }

    /// …and counts by reading the query through (a fake's list is short).
    func myEntriesCount(_ query: JournalQuery) async throws -> Int {
        var count = 0
        var cursor: JournalCursor?
        repeat {
            let page = try await myEntries(query, after: cursor, pageSize: 100)
            count += page.items.count
            cursor = page.nextCursor
        } while cursor != nil
        return count
    }
}

public extension JournalDayCount {
    /// Entries grouped by their day — the rows `journal_days` would answer for them, oldest first.
    /// The cover is the newest entry's first photo; the best score the day's best.
    static func grouping(
        _ cards: [EntryCard],
        from: AteDay,
        to: AteDay,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [JournalDayCount] {
        var byDay: [AteDay: [EntryCard]] = [:]
        for card in cards {
            let day = AteDay.containing(card.createdAt, calendar: calendar)
            guard day >= from, day <= to else { continue }
            byDay[day, default: []].append(card)
        }
        return byDay.keys.sorted().map { day in
            let cards = (byDay[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            let cover = cards.lazy
                .compactMap { $0.photos.sorted { $0.position < $1.position }.first?.url }
                .first
            return JournalDayCount(
                day: day,
                entries: cards.count,
                bestScore: cards.compactMap(\.bestScore).max(),
                coverURL: cover
            )
        }
    }
}
