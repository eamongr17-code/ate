import Foundation

/// How a sitting's date is *said*, decided here and worded by the view.
///
/// An enum rather than a string so the rule ("the two most recent days get names, everything else
/// gets a date") is testable without pinning a locale, and so the view stays free to localise.
public enum DiaryDayLabel: Hashable, Sendable {
    case today
    case yesterday
    /// Anything older: the view formats it `EEE d MMM` (§3.2).
    case date(Date)

    /// - Parameter date: the entry's `createdAt`, already clamped by
    ///   ``DiaryGrouping/displayDate(_:now:)`` — a future timestamp reads as "Today" (§10.2).
    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> DiaryDayLabel {
        let clamped = DiaryGrouping.displayDate(date, now: now)
        if calendar.isDate(clamped, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(clamped, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .date(clamped)
    }
}

/// The line under the large title: what your record adds up to (§3.1).
///
/// **What it deliberately doesn't do.** The designed line is "142 dishes · 38 places", and those are
/// totals over the *whole* diary — which the client only knows once it has paged to the end, because
/// there is no aggregate in the contract yet and the keyset pages are deliberately not counted
/// (`Page` infers the last page from a short read rather than paying for `count=exact` on every
/// query). So: when the whole diary is loaded the real counts are free and exact, and they are shown.
/// When it isn't, the line is **absent** rather than approximate — a record line that says "12
/// dishes · 3 places" to someone with four hundred entries is worse than no line, and "since Sep
/// 2026" derived from the oldest *loaded* row is the same lie in a different tense.
///
/// The moment the backend exposes a per-user aggregate, the `else` branch below fills in and the
/// line becomes unconditional. That is a one-function change, which is why it lives in one function.
public enum DiaryRecordLine {

    /// - Parameters:
    ///   - entries: everything currently loaded, newest first.
    ///   - hasReachedEnd: the stream is exhausted, so `entries` *is* the whole diary.
    /// - Returns: the record line, or `nil` when there is nothing trustworthy to say.
    public static func text(entries: [FeedEntry], hasReachedEnd: Bool) -> String? {
        guard hasReachedEnd, !entries.isEmpty else { return nil }
        let dishes = entries.count
        let places = Set(entries.map(\.restaurant.id)).count
        return "\(pluralised(dishes, "dish", "dishes")) · \(pluralised(places, "place", "places"))"
    }

    /// A month section's trailing count: "4 dishes".
    public static func dishCount(_ count: Int) -> String {
        pluralised(count, "dish", "dishes")
    }

    private static func pluralised(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
