import Foundation

/// The insert payload, exactly as `integration-design.md` writes it — and no more. `authenticated`
/// may write only these columns on `entries`; anything else is a `42501`.
///
/// No `visibility`: every entry is public (Eamon, 2026-09-25) and the server forces it (0033).
public struct NewEntry: Sendable, Hashable, Encodable {
    /// Client-minted. INSERT, never upsert: the trigger consumes an order number, and a conflicting
    /// upsert would burn one.
    public let id: UUID
    public let authorID: UUID
    public let body: String
    /// Only when the person TAPPED a place. Sending it stamps `restaurant_source = 'user'`, which
    /// the sorter will not overwrite.
    public let restaurantID: UUID?
    /// When they wrote it. Sent so an entry written offline keeps its own time.
    public let createdAt: Date

    public init(
        id: UUID,
        authorID: UUID,
        body: String,
        restaurantID: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.authorID = authorID
        self.body = body
        self.restaurantID = restaurantID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, body
        case authorID = "author_id"
        case restaurantID = "restaurant_id"
        case createdAt = "created_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(authorID, forKey: .authorID)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(restaurantID, forKey: .restaurantID)
        try container.encode(PostgRESTTimestamp.string(from: createdAt), forKey: .createdAt)
    }
}

/// What the sorter came back with. `mode` is the server's own word (`stub` | `model`) and is never
/// inferred, so the day model mode is switched on, both live in the same funnel series.
public struct SortOutcome: Sendable, Hashable {
    public let entryID: UUID
    public let status: EntrySortStatus
    public let mode: String
    public let itemCount: Int
    public let restaurantID: UUID?
    /// True when the entry arrived placeless and the sorter found the place in the words.
    public let didAttachPlace: Bool

    public init(
        entryID: UUID,
        status: EntrySortStatus,
        mode: String,
        itemCount: Int,
        restaurantID: UUID?,
        didAttachPlace: Bool
    ) {
        self.entryID = entryID
        self.status = status
        self.mode = mode
        self.itemCount = itemCount
        self.restaurantID = restaurantID
        self.didAttachPlace = didAttachPlace
    }
}

/// One photo on its way to storage.
public struct EntryPhotoUpload: Sendable, Hashable {
    public let entryID: UUID
    public let position: Int
    public let data: Data

    public init(entryID: UUID, position: Int, data: Data) {
        self.entryID = entryID
        self.position = position
        self.data = data
    }
}

/// **Everything the core loop does to an entry.**
///
/// One protocol, two implementations: Supabase, and an in-memory one that previews, tests and a
/// simulator drive run against. That seam is what lets the whole loop — write, sort, receipt,
/// journal — be driven before the new tables exist anywhere.
///
/// Deliberately *not* a repository of everything: the feed, saves, profiles and search are their own
/// surfaces and their own milestone.
public protocol EntryService: Sendable {
    /// The signed-in person, for the receipt's signature.
    func viewer() async throws -> ViewerProfile

    /// Who is writing. Separate from ``viewer()`` because the insert needs only the id and must not
    /// need the network to get it — an entry written offline still has an author.
    func authorID() async throws -> UUID

    /// The words land first, alone. A `23505` means the entry already landed — the id is ours, so
    /// that is success, not a conflict.
    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard

    /// Upload the bytes, then record the row. Idempotent on `(entry_id, position)`.
    func attach(photo: EntryPhotoUpload) async throws

    /// Ask the server to add structure. Idempotent; already-sorted entries come back untouched.
    /// `tagTokens` are the composer's tag chips, in scalars — the server attaches each to the dish
    /// it follows (contract #61).
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome

    /// One entry, freshly read — what the receipt is drawn from.
    func entry(id: UUID) async throws -> EntryCard

    /// The journal: your own entries, newest first, keyset-paginated.
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard>

    /// Corrections — the user's, always.
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws
    /// A dish line's dietary tags, as a whole set (`[]` clears them). Owner-only.
    func setTags(reviewID: UUID, tags: [DietTag]) async throws

    /// The person editing their **own** words. The only path that writes `entries.body`, and it is
    /// theirs: the server never rewrites it (data-model landmine 6).
    func updateBody(entryID: UUID, body: String) async throws

    /// Delete one of your **own** entries: `delete_entry(p_entry_id)`, then its photos (and their
    /// `_t.jpg` thumbnails) out of storage. The server refuses anybody else's.
    @discardableResult
    func delete(entryID: UUID) async throws -> EntryDeletion
}

public extension EntryService {
    /// A sort with no tag chips — a re-sort, a correction, an edit.
    @discardableResult
    func sort(entryID: UUID, force: Bool) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: [])
    }

    /// A seam that does not delete refuses, rather than pretending it did.
    @discardableResult
    func delete(entryID: UUID) async throws -> EntryDeletion {
        throw EntryWriteFailure.rejected("delete is not supported here")
    }

    /// The handle alone, when that is all a caller needs.
    func currentHandle() async -> String? {
        try? await viewer().username
    }
}

/// Why a write could not be made right now, as the app has to treat it.
public enum EntryWriteFailure: Error, Equatable, Sendable {
    /// No network, or the server never answered. The entry belongs in the outbox.
    case offline
    /// The server answered and refused. Retrying will not help.
    case rejected(String)

    /// Whether the thing that just failed is worth trying again later.
    public var isRetryable: Bool { self == .offline }

    /// The one classification the whole write path shares. A `URLError` that means "the request
    /// never got there" is retryable; a PostgREST refusal is not, and queueing it forever would be
    /// a silent promise the app cannot keep.
    public static func of(_ error: any Error) -> EntryWriteFailure {
        if let failure = error as? EntryWriteFailure { return failure }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .timedOut, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .internationalRoamingOff,
                 .secureConnectionFailed, .requestBodyStreamExhausted:
                return .offline
            default:
                return .rejected(urlError.localizedDescription)
            }
        }
        if error is CancellationError { return .offline }
        return .rejected(String(describing: error))
    }
}
