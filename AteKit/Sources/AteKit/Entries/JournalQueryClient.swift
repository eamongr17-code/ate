import Foundation
import Supabase

/// **The journal's filter and sort, live** (round 4 contract #3).
///
/// `my_entries` (0043) answers with the viewer's own entry ids in the asked-for order, each with the
/// `created_at` and `best_score` the keyset needs; the rows themselves are read from `entry_cards` —
/// the one card shape every list decodes — and put back in that order. The cursor is the last *id
/// row's* fields, not the last card's, so an entry deleted between the two reads cannot stall paging.
/// Dates are the visit's calendar day in the device's own zone (`p_tz`).
public struct JournalQueryClient: JournalQuerying {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func myEntries(
        _ query: JournalQuery,
        after cursor: JournalCursor?,
        pageSize: Int
    ) async throws -> JournalQueryPage {
        let parameters = Self.parameters(for: query, after: cursor, pageSize: pageSize)
        let data = try await api.supabase.rpc("my_entries", params: parameters).execute().data
        let rows = try Self.decodeRows(data)
        guard rows.isEmpty == false else { return JournalQueryPage(items: [], nextCursor: nil) }
        let cards = try await self.cards(rows.map(\.id))
        // A row the view no longer serves (deleted between the two reads) is simply absent; the
        // page is still short-read-terminated on the ids, not on what survived.
        let byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = rows.compactMap { byID[$0.id] }
        let next = rows.count < pageSize ? nil : rows.last.map {
            JournalCursor(createdAt: $0.createdAt, id: $0.id, score: $0.bestScore)
        }
        return JournalQueryPage(items: ordered, nextCursor: next)
    }

    public func myEntryCities() async throws -> [AteCity] {
        let data = try await api.supabase.rpc("my_entry_cities").execute().data
        return try JSONDecoder().decode([AteCity].self, from: data)
    }

    /// `journal_days` (0053): your days with an entry between two dates, inclusive, in the device's
    /// zone — narrowed by a query's filters when one is given.
    public func journalDays(from: AteDay, to: AteDay, matching query: JournalQuery?) async throws -> [JournalDayCount] {
        let parameters = Self.daysParameters(from: from, to: to, matching: query)
        let data = try await api.supabase.rpc("journal_days", params: parameters).execute().data
        return try JSONDecoder().decode([JournalDayCount].self, from: data)
    }

    /// `my_entries_count` (round 7): `my_entries`' own filters, counted.
    public func myEntriesCount(_ query: JournalQuery) async throws -> Int {
        let parameters = Self.countParameters(for: query)
        let data = try await api.supabase.rpc("my_entries_count", params: parameters).execute().data
        return try Self.decodeCount(data)
    }

    public func myEntryPlaces() async throws -> [JournalPlace] {
        let data = try await api.supabase.rpc("my_entry_places").execute().data
        return try JSONDecoder().decode([JournalPlace].self, from: data)
    }

    // MARK: - Wire

    /// The RPC's arguments. Every filter is sent, `null` when unused, so one signature serves all.
    static func parameters(
        for query: JournalQuery,
        after cursor: JournalCursor?,
        pageSize: Int,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [String: AnyJSON] {
        var parameters: [String: AnyJSON] = [
            "p_sort": .string(query.sort.rawValue),
            "p_tz": .string(timeZone.identifier),
            "p_limit": .integer(pageSize),
            "p_restaurant_id": query.place.map { .string($0.restaurantID.uuidString.lowercased()) } ?? .null,
            "p_min_score": query.minScore.map { .double($0) } ?? .null,
            "p_tag": query.tag.map { .string($0.rawValue) } ?? .null,
            "p_from": .null,
            "p_to": .null
        ]
        // Round 5 (0047): the top of the score range (open at 5.0, so never sent there) and a city.
        parameters["p_max_score"] = query.maxScore.map { .double($0) } ?? .null
        parameters["p_city"] = query.city.map { .string($0) } ?? .null
        // Round 6: the date window — the same `p_from` / `p_to` the old month filter used, days
        // inclusive, in the device's zone.
        if query.window.isAll == false {
            let window = query.window.parameters(timeZone: timeZone)
            parameters["p_from"] = window["p_from"] ?? .null
            parameters["p_to"] = window["p_to"] ?? .null
        }
        if let period = query.period {
            let days = period.days()
            parameters["p_from"] = .string(Self.day(days.from))
            parameters["p_to"] = .string(Self.day(days.to))
        }
        parameters["p_cursor_created_at"] = cursor.map {
            .string(PostgRESTTimestamp.string(from: $0.createdAt))
        } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null
        // Top's keyset carries the score, `null` once the list is into its unscored tail.
        parameters["p_cursor_best_score"] = cursor?.score.map { .double($0) } ?? .null
        return parameters
    }

    /// `my_entries_count`'s arguments: exactly `my_entries`' filters — no order, cursor or limit.
    static func countParameters(for query: JournalQuery, timeZone: TimeZone = .autoupdatingCurrent) -> [String: AnyJSON] {
        let filterKeys: Set<String> = [
            "p_min_score", "p_max_score", "p_city", "p_from", "p_to", "p_tz", "p_restaurant_id", "p_tag"
        ]
        return parameters(for: query, after: nil, pageSize: 1, timeZone: timeZone).filter { filterKeys.contains($0.key) }
    }

    /// `journal_days`' arguments: the range, the zone, and `my_entries`' filters (0053's trailing
    /// params) — never the query's own months, which the range stands in for.
    static func daysParameters(
        from: AteDay, to: AteDay, matching query: JournalQuery?, timeZone: TimeZone = .autoupdatingCurrent
    ) -> [String: AnyJSON] {
        var parameters: [String: AnyJSON] = [:]
        if let query {
            var filters = query
            filters.window = .all
            filters.period = nil
            let filterKeys: Set<String> = ["p_min_score", "p_max_score", "p_city", "p_restaurant_id", "p_tag"]
            parameters = Self.parameters(for: filters, after: nil, pageSize: 1, timeZone: timeZone)
                .filter { filterKeys.contains($0.key) }
        }
        parameters["p_from"] = .string(from.string)
        parameters["p_to"] = .string(to.string)
        parameters["p_tz"] = .string(timeZone.identifier)
        return parameters
    }

    /// A scalar RPC answers with the bare number (`14`); tolerate a one-row array too.
    static func decodeCount(_ data: Data) throws -> Int {
        if let count = try? JSONDecoder().decode(Int.self, from: data) { return count }
        struct Row: Decodable { let count: Int }
        if let rows = try? JSONDecoder().decode([Row].self, from: data), let first = rows.first { return first.count }
        return try JSONDecoder().decode([Int].self, from: data).first ?? 0
    }

    /// `2026-09-01` — a Postgres `date`.
    static func day(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    /// `(id, created_at, best_score)`, in order. Microsecond timestamps, so the keyset's
    /// `created_at` half matches the row it came from exactly (``PostgRESTDate``).
    static func decodeRows(_ data: Data) throws -> [Row] {
        try PostgRESTDate.decoder.decode([Row].self, from: data)
    }

    struct Row: Decodable, Equatable {
        let id: UUID
        let createdAt: Date
        /// `NULL` when no line of the entry is scored.
        let bestScore: Double?

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
            case bestScore = "best_score"
        }
    }

    private func cards(_ ids: [UUID]) async throws -> [EntryCard] {
        let data = try await api.supabase
            .from(EntryCard.table)
            .select(EntryCard.columns)
            .in("id", values: ids.map { $0.uuidString.lowercased() })
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
    }
}
