import Foundation
import Supabase

/// **Searching your own journal** (`search_my_entries`, 0060): your entries whose words, place name or
/// a line's dish name contain the query — case- and accent-blind, so prefixes work. Never anyone
/// else's. The Journal's order and keyset, `(created_at, id)` DESC.
public protocol JournalSearching: Sendable {
    /// A query under two characters (once trimmed) answers nothing without asking; one over 100 is cut
    /// to 100 on the phone (the server refuses it).
    func searchMyEntries(_ query: String, after cursor: PageCursor?, limit: Int) async throws -> Page<EntryCard>
}

public extension JournalSearching {
    static var defaultPageSize: Int { 20 }
}

/// The query rule both implementations share: trimmed, at most 100 characters, `nil` under two.
enum JournalSearchQuery {
    static let maximumLimit = 50

    static func normalized(_ raw: String) -> String? { ListRules.query(raw) }
}

/// The live ``JournalSearching``.
public struct JournalSearchClient: JournalSearching {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func searchMyEntries(_ query: String, after cursor: PageCursor?, limit: Int) async throws
        -> Page<EntryCard> {
        guard let query = JournalSearchQuery.normalized(query) else { return Page(items: [], nextCursor: nil) }
        let clamped = min(JournalSearchQuery.maximumLimit, max(1, limit))
        let data = try await api.supabase
            .rpc("search_my_entries", params: Self.parameters(query: query, after: cursor, limit: clamped))
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        return Page(items: rows, requestedLimit: clamped)
    }

    /// Both halves of the keyset, or neither.
    static func parameters(query: String, after cursor: PageCursor?, limit: Int) -> [String: AnyJSON] {
        [
            "p_query": .string(query),
            "p_limit": .integer(limit),
            "p_cursor_created_at": cursor.map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null,
            "p_cursor_id": cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null
        ]
    }
}

#if DEBUG
/// **Journal search, in memory** — over the preview journal, by the server's rule: words, place name
/// or a dish name, case- and accent-blind substring, newest first on the `(created_at, id)` keyset.
public struct InMemoryJournalSearch: JournalSearching, InMemoryStandIn {
    private let entries: any EntryService

    public init(entries: any EntryService) {
        self.entries = entries
    }

    public func searchMyEntries(_ query: String, after cursor: PageCursor?, limit: Int) async throws
        -> Page<EntryCard> {
        guard let query = JournalSearchQuery.normalized(query) else { return Page(items: [], nextCursor: nil) }
        let needle = InMemoryLists.fold(query)
        let clamped = min(JournalSearchQuery.maximumLimit, max(1, limit))
        let matches = try await everything()
            .filter { Self.matches($0, needle) }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            .filter { card in
                guard let cursor else { return true }
                return (card.createdAt, card.id.uuidString) < (cursor.createdAt, cursor.id.uuidString)
            }
        return Page(items: Array(matches.prefix(clamped)), requestedLimit: clamped)
    }

    static func matches(_ card: EntryCard, _ needle: String) -> Bool {
        let haystacks = [card.body, card.place?.name ?? ""] + card.items.map(\.dishName)
        return haystacks.contains { InMemoryLists.fold($0).contains(needle) }
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
