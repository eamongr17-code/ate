import Foundation
import Supabase

/// **The tagging half of "Ate with"** (0058): the author tags people on their own entry, takes them
/// off again, and a tagged person can take themselves off. Plus the two reads the picker needs.
///
/// One protocol, two implementations — Supabase, and memory for previews, tests and
/// `-ate-preview-data` — so the whole flow runs on a simulator before staging has 0058.
public protocol CompanionTagging: Sendable {
    /// `tag_ate_with` — idempotent: the existing row comes back, whatever its status.
    func tag(entryID: UUID, userID: UUID) async throws -> CompanionTagReceipt
    /// `untag_ate_with` — pending or accepted goes; a decline is sticky and stays.
    func untag(entryID: UUID, userID: UUID) async throws
    /// `decline_ate_with` — the tagged person taking themselves off somebody's entry.
    func decline(companionID: UUID) async throws
    /// The viewer's own tag on someone else's entry (`entry_companions.id`), if they are tagged on
    /// it and have not declined — what "Remove me" acts on. `nil` when they are not.
    func myTag(onEntry entryID: UUID) async throws -> UUID?
    /// The people the viewer has tagged most recently, newest first, each once. Bounded.
    func recentCompanions(limit: Int) async throws -> [CompanionPerson]
    /// Every handle on Ate (`search_people`), keyset-paged; never the viewer, never anyone blocked
    /// either way (RLS).
    func searchPeople(_ query: String, after cursor: SearchCursor?, pageSize: Int) async throws
        -> SearchPage<CompanionPerson>
}

/// What `tag_ate_with` returns.
public struct CompanionTagReceipt: Sendable, Hashable, Decodable {
    public let companionID: UUID
    public let entryID: UUID
    public let userID: UUID
    public let status: EntryCompanion.Status

    public init(companionID: UUID, entryID: UUID, userID: UUID, status: EntryCompanion.Status) {
        self.companionID = companionID
        self.entryID = entryID
        self.userID = userID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case status
        case companionID = "companion_id"
        case entryID = "entry_id"
        case userID = "user_id"
    }
}

/// The refusals the in-memory service raises — the same meanings as the server's codes.
public enum CompanionTagError: Error, Sendable, Equatable {
    /// `P0002`: no such entry (yet) or person.
    case notFound
    /// `54000`: six seats, or the day's budget.
    case limit
    /// `42501`: not your entry, or a block either way.
    case refused
    /// `22023`: yourself, or a placeless entry.
    case invalid
}

/// **What a failed tag deserves.** Tags never block a post, so the only question is whether to try
/// again later.
public enum CompanionTagFailure: Sendable, Equatable {
    /// The network, or an entry that has not landed yet (`P0002` — a tag queued behind an entry
    /// still in the outbox). Worth another go.
    case retry
    /// The server refused for a reason that will not change: the cap, a block, yourself. Dropped.
    case drop

    public static func of(_ error: any Error) -> CompanionTagFailure {
        if let tagError = error as? CompanionTagError {
            return tagError == .notFound ? .retry : .drop
        }
        if let postgrest = error as? PostgrestError {
            return postgrest.code == "P0002" ? .retry : .drop
        }
        return EntryWriteFailure.of(error).isRetryable ? .retry : .drop
    }
}
