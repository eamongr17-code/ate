#if DEBUG
import Foundation

/// **The journal's filter and sort, in memory** — the round 4 contract's mock, for previews, tests
/// and `-ate-preview-data` drives while `my_entries` is not live. Debug only.
///
/// It reads the whole journal through the service it wraps and filters and orders it with the
/// query's own rules (``JournalQuery/matches(_:calendar:)``, ``JournalQuery/ordered(_:)``), then
/// pages the result by its keyset exactly as the server will — never by offset.
public struct InMemoryJournalQuery: JournalQuerying {
    private let entries: any EntryService
    private let calendar: Calendar

    public init(entries: any EntryService, calendar: Calendar = .autoupdatingCurrent) {
        self.entries = entries
        self.calendar = calendar
    }

    public func myEntries(
        _ query: JournalQuery,
        after cursor: JournalCursor?,
        pageSize: Int
    ) async throws -> JournalQueryPage {
        let ordered = query.ordered(try await everything().filter { query.matches($0, calendar: calendar) })
        let start: Int
        if let cursor {
            guard let index = ordered.firstIndex(where: { $0.id == cursor.id }) else {
                return JournalQueryPage(items: [], nextCursor: nil)
            }
            start = index + 1
        } else {
            start = 0
        }
        let page = Array(ordered.dropFirst(start).prefix(pageSize))
        return JournalQueryPage(items: page, requestedLimit: pageSize)
    }

    public func journalDays(from: AteDay, to: AteDay) async throws -> [JournalDayCount] {
        JournalDayCount.grouping(try await everything(), from: from, to: to, calendar: calendar)
    }

    public func myEntriesCount(_ query: JournalQuery) async throws -> Int {
        try await everything().filter { query.matches($0, calendar: calendar) }.count
    }

    public func myEntryCities() async throws -> [AteCity] {
        AteCity.counted(try await everything().map { $0.place?.city })
    }

    public func myEntryPlaces() async throws -> [JournalPlace] {
        var counts: [UUID: (place: EntryCard.Place, count: Int)] = [:]
        for card in try await everything() {
            guard let place = card.place else { continue }
            counts[place.id, default: (place, 0)].count += 1
        }
        return counts.values
            .map {
                JournalPlace(restaurantID: $0.place.id, name: $0.place.name,
                             locality: $0.place.locality, entryCount: $0.count)
            }
            .sorted { ($0.entryCount, $1.name) > ($1.entryCount, $0.name) }
    }

    private func everything() async throws -> [EntryCard] {
        var all: [EntryCard] = []
        var cursor: PageCursor?
        repeat {
            let page = try await entries.journal(after: cursor, pageSize: 100)
            all.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil
        return all
    }
}
#endif
