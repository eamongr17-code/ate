import Foundation

/// One visit: the dishes you rated at one restaurant, in one go.
///
/// A sitting is a **client-side reading of the review stream**, not a stored thing — there is no
/// `sittings` table and there is deliberately not going to be one (the log flow's ``SittingState``
/// posts n rows and disappears). What makes the diary read as a record of *eating* rather than a
/// list of ratings is that those n rows are drawn back together on the way out.
///
/// Grouping rule (§3.2): consecutive entries in the newest-first stream belong to the same sitting
/// when they share `restaurant.id`, fall on the same **local** calendar day, and were created within
/// ``window`` of the group's newest member. Consecutive is load-bearing — a sitting is a contiguous
/// run, so eating at the same place twice in one day is two blocks, which is the truth.
public struct DiarySitting: Identifiable, Hashable, Sendable {
    /// How far back from a group's newest member a row can be and still be the same visit.
    public static let window: TimeInterval = 90 * 60

    public let restaurant: FeedEntry.RestaurantSummary
    /// Newest first, the order they arrived in.
    public let entries: [FeedEntry]

    public init(restaurant: FeedEntry.RestaurantSummary, entries: [FeedEntry]) {
        self.restaurant = restaurant
        self.entries = entries
    }

    /// The newest entry's review id. Stable across an append that *grows* the block (a sitting split
    /// over a page boundary regroups when the next page lands), so SwiftUI keeps the row identity
    /// instead of animating a whole block out and back in.
    public var id: UUID { entries.first?.id ?? restaurant.id }

    /// The visit's clock: its newest member.
    public var newestAt: Date { entries.first?.review.createdAt ?? .distantPast }

    /// Drives the "Part of a sitting" line on the entry view and the `is_multi_dish_sitting` param.
    public var isMultiDish: Bool { entries.count > 1 }

    public var dishCount: Int { entries.count }
}

/// A month of the diary — the native `Section` the sittings sit in.
public struct DiaryMonth: Identifiable, Hashable, Sendable {
    /// Year + month in the *local* calendar. A `Date` would make two rows in the same month
    /// different sections; a formatted string would make September 2025 and September 2026 the same.
    public struct Key: Hashable, Sendable, Comparable {
        public let year: Int
        public let month: Int

        public init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        public static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.year, lhs.month) < (rhs.year, rhs.month)
        }
    }

    public let id: Key
    public let sittings: [DiarySitting]

    public init(id: Key, sittings: [DiarySitting]) {
        self.id = id
        self.sittings = sittings
    }

    /// How many dishes the month holds — the section header's trailing count.
    public var dishCount: Int { sittings.reduce(0) { $0 + $1.dishCount } }

    /// A date inside the month, for the view to format ("September 2026"). Formatting stays in the
    /// view layer so it follows the reader's locale, not a hardcoded one baked in here.
    public var representativeDate: Date { sittings.first?.newestAt ?? .distantPast }
}

/// The pure function behind the diary's shape. Lives here — not in the store, not in the view — so
/// the page-boundary and same-day-twice cases are asserted as arithmetic rather than driven through
/// a `List`.
public enum DiaryGrouping {

    /// Groups a newest-first run of entries into months of sittings.
    ///
    /// Cheap enough to run on every append (O(n), one pass) — which is exactly the contract §3.2
    /// asks for: a sitting split across a page boundary must *regroup* when the next page lands, so
    /// nothing here may be memoised per page.
    ///
    /// - Parameters:
    ///   - entries: newest first. Not re-sorted: the stream's order is the server's total order on
    ///     `(created_at, id)`, and re-deriving it here would let a client-side tiebreak disagree
    ///     with the keyset cursor.
    ///   - calendar: `.current` in the app. Injected so the tests can pin a timezone.
    ///   - now: clamps future timestamps (§10.2) — a clock-skewed row belongs to today, not to a
    ///     phantom month ahead of the reader.
    public static func months(
        from entries: [FeedEntry],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [DiaryMonth] {
        let sittings = self.sittings(from: entries, calendar: calendar)
        guard !sittings.isEmpty else { return [] }

        var months: [DiaryMonth] = []
        var current: [DiarySitting] = []
        var currentKey: DiaryMonth.Key?

        for sitting in sittings {
            let key = monthKey(for: displayDate(sitting.newestAt, now: now), calendar: calendar)
            if key != currentKey {
                if let currentKey { months.append(DiaryMonth(id: currentKey, sittings: current)) }
                currentKey = key
                current = []
            }
            current.append(sitting)
        }
        if let currentKey { months.append(DiaryMonth(id: currentKey, sittings: current)) }
        return months
    }

    /// The grouping rule on its own, without the month sectioning.
    public static func sittings(
        from entries: [FeedEntry],
        calendar: Calendar = .current
    ) -> [DiarySitting] {
        var result: [DiarySitting] = []
        var current: [FeedEntry] = []

        for entry in entries {
            guard let newest = current.first else {
                current = [entry]
                continue
            }
            if belongsToSameSitting(entry, as: newest, calendar: calendar) {
                current.append(entry)
            } else {
                result.append(DiarySitting(restaurant: newest.restaurant, entries: current))
                current = [entry]
            }
        }
        if let newest = current.first {
            result.append(DiarySitting(restaurant: newest.restaurant, entries: current))
        }
        return result
    }

    /// Same restaurant, same local day, within the window of the group's newest member.
    ///
    /// Measured against the group's **newest** rather than the previous row on purpose: chaining off
    /// neighbours would let a long tail of 89-minute gaps stretch one "sitting" across an evening.
    private static func belongsToSameSitting(
        _ entry: FeedEntry,
        as newest: FeedEntry,
        calendar: Calendar
    ) -> Bool {
        guard entry.restaurant.id == newest.restaurant.id else { return false }
        let gap = newest.review.createdAt.timeIntervalSince(entry.review.createdAt)
        guard gap >= 0, gap <= DiarySitting.window else { return false }
        return calendar.isDate(entry.review.createdAt, inSameDayAs: newest.review.createdAt)
    }

    /// §10.2: a `created_at` in the future is a skewed clock, not a plan. It reads as now.
    public static func displayDate(_ date: Date, now: Date = Date()) -> Date {
        min(date, now)
    }

    private static func monthKey(for date: Date, calendar: Calendar) -> DiaryMonth.Key {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return DiaryMonth.Key(year: parts.year ?? 0, month: parts.month ?? 0)
    }
}
