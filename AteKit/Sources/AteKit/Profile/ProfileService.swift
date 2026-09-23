import Foundation
import Supabase

/// **Somebody else's profile**, and the two things you can do about them.
///
/// Reading a profile and moderating it are one seam because they are one screen: the actions sheet
/// hangs off the header, and a block has to be able to tell the lists behind it to refetch.
public protocol ProfileReading: Sendable {
    /// The header: `profile_summary(p_user_id)`.
    func profile(id: UUID) async throws -> ProfileSummary
    /// Their entries: `get_entries_by_author`. RLS decides what is visible — your own call returns
    /// private entries too, a stranger's returns only public ones.
    func entriesPage(authorID: UUID, after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard>
    /// One-way in the table, enforced both ways by `blocked_with()`: after this, each of you is gone
    /// from every read the other makes. **Refetch every open list.**
    func block(userID: UUID) async throws
    func report(profileID: UUID, reason: String?, note: String?) async throws
    func report(entryID: UUID, reason: String?, note: String?) async throws
}

public struct ProfileClient: ProfileReading {
    /// `get_entries_by_author` clamps at 50, the same as the feed.
    public static let maximumPageSize = 50

    private let api: AteAPIClient

    public init(api: AteAPIClient) {
        self.api = api
    }

    public func profile(id: UUID) async throws -> ProfileSummary {
        let data = try await api.supabase
            .rpc("profile_summary", params: ["p_user_id": AnyJSON.string(id.uuidString.lowercased())])
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([ProfileSummary].self, from: data)
        // A blocked person's row is simply not there (contract, breaking change 2) — that is a
        // missing profile, not a network failure, and the screen says so rather than crashing on a
        // nil join.
        guard let row = rows.first else { throw AteAPIError.notFound(table: "profiles", id: id) }
        return row
    }

    public func entriesPage(
        authorID: UUID,
        after cursor: PageCursor?,
        pageSize: Int
    ) async throws -> Page<EntryCard> {
        try await api.requireCurrentUserID()
        let limit = min(Self.maximumPageSize, max(1, pageSize))
        var parameters: [String: AnyJSON] = [
            "p_author_id": .string(authorID.uuidString.lowercased()),
            "p_page_size": .integer(limit)
        ]
        parameters["p_cursor_created_at"] = cursor
            .map { .string(PostgRESTTimestamp.string(from: $0.createdAt)) } ?? .null
        parameters["p_cursor_id"] = cursor.map { .string($0.id.uuidString.lowercased()) } ?? .null

        let data = try await api.supabase
            .rpc("get_entries_by_author", params: parameters)
            .execute()
            .data
        let rows = try PostgRESTDate.decoder.decode([EntryCard].self, from: data)
        return Page(items: rows, requestedLimit: limit)
    }

    public func block(userID: UUID) async throws {
        try await api.callRPC("block_user", parameters: [
            "p_user_id": .string(userID.uuidString.lowercased())
        ])
    }

    public func report(profileID: UUID, reason: String?, note: String?) async throws {
        try await api.callRPC("report_profile", parameters: [
            "p_user_id": .string(profileID.uuidString.lowercased()),
            "p_reason": reason.map { AnyJSON.string($0) } ?? .null,
            "p_note": note.map { AnyJSON.string($0) } ?? .null
        ])
    }

    public func report(entryID: UUID, reason: String?, note: String?) async throws {
        try await api.callRPC("report_entry", parameters: [
            "p_entry_id": .string(entryID.uuidString.lowercased()),
            "p_reason": reason.map { AnyJSON.string($0) } ?? .null,
            "p_note": note.map { AnyJSON.string($0) } ?? .null
        ])
    }
}
