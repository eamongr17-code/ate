import Foundation

/// **The journal's month dividers** (round 7) — a large month name before the first entry of each
/// month, with the year and the month's count beside it. Only where the list runs through time: a
/// list ordered by score has no months to divide.
public enum JournalMonthDividers {
    /// The month each entry opens, keyed by the entry's id — the entries a divider goes above.
    /// Empty for an order that does not run through time.
    public static func dividers(
        for entries: [EntryCard],
        sort: JournalSort,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [UUID: AteMonth] {
        guard sort.isChronological else { return [:] }
        var dividers: [UUID: AteMonth] = [:]
        var previous: AteMonth?
        for entry in entries {
            let month = AteMonth.containing(entry.createdAt, calendar: calendar)
            if month != previous { dividers[entry.id] = month }
            previous = month
        }
        return dividers
    }

    /// The count beside the divider's year (DESIGN.md: sentence case, no dot separator — the view
    /// sets the two apart): "14 entries", "1 entry", or with a filter on "6 of 14" — the month's
    /// entries the filter keeps, of all of them. `nil` while the count has not been read.
    public static func count(total: Int?, filtered: Int?, isFiltered: Bool) -> String? {
        guard let total else { return nil }
        if isFiltered {
            guard let filtered else { return nil }
            return "\(filtered) of \(total)"
        }
        return "\(total) \(total == 1 ? "entry" : "entries")"
    }
}
