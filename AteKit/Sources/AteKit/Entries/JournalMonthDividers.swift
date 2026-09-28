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

    /// The divider's meta: "2026 · 14 ENTRIES", or with a filter on, "2026 · 6 OF 14" — the month's
    /// entries the filter keeps, of all of them. A count not yet read prints nothing after the year.
    public static func meta(year: Int, total: Int?, filtered: Int?, isFiltered: Bool) -> String {
        let yearText = String(year)
        guard let total else { return yearText }
        if isFiltered {
            guard let filtered else { return yearText }
            return "\(yearText) · \(filtered) OF \(total)"
        }
        return "\(yearText) · \(total) \(total == 1 ? "ENTRY" : "ENTRIES")"
    }
}
