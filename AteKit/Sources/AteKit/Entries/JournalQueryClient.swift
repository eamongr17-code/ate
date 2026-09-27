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
        // Round 5, pending the backend lane's contract: sent only when set, so every call the live
        // function already answers is unchanged.
        if let maxScore = query.maxScore { parameters["p_max_score"] = .double(maxScore) }
        if let city = query.city { parameters["p_city"] = .string(city) }
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
