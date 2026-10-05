import Foundation
import Supabase

/// The live ``CompanionTagging``: the 0058 RPCs, `search_people`, and two parties-only reads of
/// `entry_companions`.
public struct SupabaseCompanionTagging: CompanionTagging {
    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func tag(entryID: UUID, userID: UUID) async throws -> CompanionTagReceipt {
        let rows: [CompanionTagReceipt] = try await api.rpc("tag_ate_with", parameters: [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_user_id": .string(userID.uuidString.lowercased())
        ])
        guard let row = rows.first else { throw CompanionTagError.notFound }
        return row
    }

    public func untag(entryID: UUID, userID: UUID) async throws {
        try await api.callRPC("untag_ate_with", parameters: [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_user_id": .string(userID.uuidString.lowercased())
        ])
    }

    public func decline(companionID: UUID) async throws {
        try await api.callRPC("decline_ate_with", parameters: [
            "p_companion_id": .string(companionID.uuidString.lowercased())
        ])
    }

    public func myTag(onEntry entryID: UUID) async throws -> UUID? {
        let me = try await api.requireCurrentUserID()
        let rows: [TagRow] = try await api.supabase
            .from("entry_companions")
            .select("id")
            .eq("entry_id", value: entryID.uuidString.lowercased())
            .eq("companion_id", value: me.uuidString.lowercased())
            .neq("status", value: EntryCompanion.Status.declined.rawValue)
            .limit(1)
            .execute()
            .value
        return rows.first?.id
    }

    /// The viewer's own tags, newest first, with the person embedded — a blocked person's profile is
    /// invisible under RLS (0019), so their embed is `null` and they drop out here. (A block also
    /// withdraws pending tags between the pair, 0058.)
    public func recentCompanions(limit: Int) async throws -> [CompanionPerson] {
        let me = try await api.requireCurrentUserID()
        let rows: [RecentRow] = try await api.supabase
            .from("entry_companions")
            .select("created_at,person:profiles!companion_id(id,username,name,avatar_url)")
            .eq("tagger_id", value: me.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(Self.recentRows)
            .execute()
            .value
        return CompanionRecents.distinct(rows.compactMap { $0.person?.companion }, limit: limit)
    }

    public func searchPeople(_ query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<CompanionPerson> {
        var parameters: [String: AnyJSON] = ["p_query": .string(query), "p_limit": .integer(pageSize)]
        if case .person(let tier, let username, let id) = cursor {
            parameters["p_cursor_match_tier"] = .integer(tier)
            parameters["p_cursor_username"] = .string(username)
            parameters["p_cursor_user_id"] = .string(id.uuidString.lowercased())
        }
        let rows: [SearchPersonRow] = try await api.rpc("search_people", parameters: parameters)
        // The cursor is the last row OFF THE WIRE, the viewer included — dropping them first would
        // move the page boundary.
        let next = rows.count < pageSize ? nil : rows.last.map(SearchCursor.init)
        return SearchPage(rows: rows.filter { $0.isMe == false }.map(CompanionPerson.init), next: next)
    }

    /// Enough of the newest tags to find the people behind them.
    private static let recentRows = 40

    private struct TagRow: Decodable {
        let id: UUID
    }

    private struct RecentRow: Decodable {
        let person: RecentPerson?
    }

    private struct RecentPerson: Decodable {
        let id: UUID
        let username: String
        let name: String?
        let avatarURL: String?

        var companion: CompanionPerson {
            CompanionPerson(userID: id, handle: username, name: name, avatarURL: avatarURL)
        }

        enum CodingKeys: String, CodingKey {
            case id, username, name
            case avatarURL = "avatar_url"
        }
    }
}

/// The recents rule, shared by both implementations: newest first, each person once.
enum CompanionRecents {
    static func distinct(_ people: [CompanionPerson], limit: Int) -> [CompanionPerson] {
        var seen = Set<UUID>()
        return Array(people.filter { seen.insert($0.userID).inserted }.prefix(max(0, limit)))
    }
}
