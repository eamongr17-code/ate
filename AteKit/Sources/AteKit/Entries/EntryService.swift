import Foundation
import Supabase

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
    /// The sorted entry as `get_entry_card` returns it, carried in the sort's own reply (0056) — what
    /// the receipt prints, with no re-read. `nil` when the server could not read it back (or an
    /// older server): then read it as before.
    public let card: EntryCard?

    public init(
        entryID: UUID,
        status: EntrySortStatus,
        mode: String,
        itemCount: Int,
        restaurantID: UUID?,
        didAttachPlace: Bool,
        card: EntryCard? = nil
    ) {
        self.entryID = entryID
        self.status = status
        self.mode = mode
        self.itemCount = itemCount
        self.restaurantID = restaurantID
        self.didAttachPlace = didAttachPlace
        self.card = card
    }
}

/// One photo on its way to storage.
public struct EntryPhotoUpload: Sendable, Hashable {
    public let entryID: UUID
    public let position: Int
    public let data: Data
    /// The object's own name, when the position cannot be it. A new entry's photos are named by
    /// position (`<entry>-<position>.jpg`, so a retried upload overwrites itself); an edit's added
    /// photos are not, because an existing photo may already own that name at another slot.
    public let name: String?

    public init(entryID: UUID, position: Int, data: Data, name: String? = nil) {
        self.entryID = entryID
        self.position = position
        self.data = data
        self.name = name
    }

    /// `<entry>-<position or name>.jpg`, under the author's folder.
    public func objectName() -> String {
        "\(entryID.uuidString.lowercased())-\(name ?? String(position)).jpg"
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

    /// The insert alone, with no read after it — so the sort can start the moment the words have
    /// landed. Same `23505` rule as ``create(_:)``.
    func insert(_ entry: NewEntry) async throws

    /// `sort-entry` `{health: true}` (0056): wakes the function when the composer opens, so Done does
    /// not pay a cold start. Fire and forget — it never throws and nothing waits on it.
    func warmUp() async

    /// Upload the bytes, then record the row. Idempotent on `(entry_id, position)`.
    func attach(photo: EntryPhotoUpload) async throws

    /// Ask the server to add structure. Idempotent; already-sorted entries come back untouched.
    /// `tagTokens` are the composer's tag chips, in scalars — the server attaches each to the dish
    /// it follows (contract #61).
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome

    /// The same, with the secret 6s (`six_tokens`, round 4): the score pills the person marked 6 on
    /// the slider. A service that cannot send them (a fake, the in-memory preview) falls back to the
    /// sort without — never an error.
    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?) async throws -> SortOutcome

    /// The same, with the author's diet codes turned off per dish (`diet_off_tokens`). A service
    /// that cannot send them falls back to the sort without — never an error.
    @discardableResult
    func sort(
        entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?, dietOffTokens: [DietOffToken]
    ) async throws -> SortOutcome

    /// One entry, freshly read — what the receipt is drawn from.
    func entry(id: UUID) async throws -> EntryCard

    /// How many 6s are left (`six_allowance`, 0091) — on an edit, `editing`'s own counted back in.
    /// `nil` when the service cannot say (a fake, the preview): no limit is drawn.
    func sixAllowance(editing entryID: UUID?) async throws -> SixAllowance?

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

    /// **The early sort** — `sort-entry` with `"preview": true`: the server plans, persists
    /// nothing, and caches the plan for the real sort after Done to reuse when the inputs match.
    func previewSort(_ input: EarlySortInput) async throws

    /// An edit keeping a photo that is already in storage, at `position` — the row, not the bytes.
    func attachExisting(entryID: UUID, position: Int, url: String) async throws

    /// An edit that removed photos: drops every photo row at or after `position`, and the removed
    /// objects (with their thumbnails) from storage.
    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws

    /// Delete one of your **own** entries: `delete_entry(p_entry_id)`, then its photos (and their
    /// `_t.jpg` thumbnails) out of storage. The server refuses anybody else's.
    @discardableResult
    func delete(entryID: UUID) async throws -> EntryDeletion

    /// When you ate it: `set_entry_date` (0063) moves `created_at`. Author only, never the future.
    func setEntryDate(entryID: UUID, eatenAt: Date) async throws

    /// `match-photos`: pair the entry's photos with its dishes, after the uploads and the sort (a
    /// re-sort rebuilds the lines, so after every one). Best effort: it never throws, and a miss
    /// leaves each dish drawing the entry's first photo, as before.
    func matchPhotos(entryID: UUID) async

    /// The same, only for an entry never matched (`unmatched_only`): asked when anyone opens a photo
    /// of an entry with no photo paired, so entries from before matching, or whose match failed, catch up.
    func matchPhotosIfNeverMatched(entryID: UUID) async

    /// The author's own pairing (`set_review_photo`, 0063): this photo is this dish, or no dish
    /// (`reviewID` nil). Matching never overrides it, and it outlives a re-sort: the next match puts
    /// it back on the line carrying that dish (0064).
    func setReviewPhoto(entryID: UUID, photoURL: String, reviewID: UUID?) async throws

    /// Which dish each photo is: photo URL → review id (0081). Several photos may name one dish;
    /// photos no dish holds are absent.
    func photoDishes(entryID: UUID) async throws -> [String: UUID]

    /// Every dish in each photo, with where it sits when the matcher placed it (0083): photo URL →
    /// its dishes. Photos no dish holds are absent.
    func photoDishTags(entryID: UUID) async throws -> [String: [PhotoDishTag]]

    /// ``photoDishTags(entryID:)`` for a screenful of entries in one read, so a photo opened from a
    /// list is named as it lands (24 Oct): entry → its pairs. Entries with none are absent.
    func photoDishTags(entryIDs: [UUID]) async throws -> [UUID: [String: [PhotoDishTag]]]

    /// The author's own pairing of one photo with several dishes (`set_photo_dishes`, 0083): exactly
    /// these lines, or none (No dish). Matching never overrides it, and it outlives a re-sort.
    func setPhotoDishes(entryID: UUID, photoURL: String, reviewIDs: [UUID]) async throws
}

public extension EntryService {
    /// A service with no server-side cache has nothing to warm.
    func previewSort(_ input: EarlySortInput) async throws {}

    /// A service with no limit to read draws none; the server still holds the rule.
    func sixAllowance(editing entryID: UUID?) async throws -> SixAllowance? { nil }

    func insert(_ entry: NewEntry) async throws {
        _ = try await create(entry)
    }

    /// A service with no cold start has nothing to wake.
    func warmUp() async {}

    func attachExisting(entryID: UUID, position: Int, url: String) async throws {
        throw EntryWriteFailure.rejected("attachExisting unsupported")
    }

    func removePhotos(entryID: UUID, fromPosition position: Int, removedURLs: [String]) async throws {
        throw EntryWriteFailure.rejected("removePhotos unsupported")
    }

    @discardableResult
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens)
    }

    @discardableResult
    func sort(
        entryID: UUID, force: Bool, tagTokens: [TagToken], scoreTokens: [TagToken]?, dietOffTokens: [DietOffToken]
    ) async throws -> SortOutcome {
        try await sort(entryID: entryID, force: force, tagTokens: tagTokens, scoreTokens: scoreTokens)
    }

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

    func setEntryDate(entryID: UUID, eatenAt: Date) async throws {
        throw EntryWriteFailure.rejected("setEntryDate is not supported here")
    }

    /// A service with no model has nothing to pair.
    func matchPhotos(entryID: UUID) async {}

    func matchPhotosIfNeverMatched(entryID: UUID) async { await matchPhotos(entryID: entryID) }

    func setReviewPhoto(entryID: UUID, photoURL: String, reviewID: UUID?) async throws {
        throw EntryWriteFailure.rejected("setReviewPhoto is not supported here")
    }

    func photoDishes(entryID: UUID) async throws -> [String: UUID] { [:] }

    /// One dish per photo, nowhere placed: a service that only knows the pairs.
    func photoDishTags(entryID: UUID) async throws -> [String: [PhotoDishTag]] {
        try await photoDishes(entryID: entryID).mapValues { [PhotoDishTag(reviewID: $0)] }
    }

    /// One read per entry: a service without a batched read.
    func photoDishTags(entryIDs: [UUID]) async throws -> [UUID: [String: [PhotoDishTag]]] {
        var out: [UUID: [String: [PhotoDishTag]]] = [:]
        for entryID in entryIDs {
            let tags = try await photoDishTags(entryID: entryID)
            if tags.isEmpty == false { out[entryID] = tags }
        }
        return out
    }

    /// One dish or none goes through the single pick; several need a service that holds them.
    func setPhotoDishes(entryID: UUID, photoURL: String, reviewIDs: [UUID]) async throws {
        guard reviewIDs.count <= 1 else { throw EntryWriteFailure.rejected("setPhotoDishes is not supported here") }
        try await setReviewPhoto(entryID: entryID, photoURL: photoURL, reviewID: reviewIDs.first)
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
    /// never got there" is retryable, and so is any answer that says "not now" rather than "no":
    /// a 5xx (a function cold-starting, a gateway hiccup), 408, 425, 429, or an expired session the
    /// next refresh fixes (audit 26 Oct, finding 12). A 4xx data refusal is not, and queueing it
    /// forever would be a silent promise the app cannot keep.
    public static func of(_ error: any Error) -> EntryWriteFailure {
        if let failure = error as? EntryWriteFailure { return failure }
        if let status = transientStatus(of: error) {
            return isTransient(status: status) ? .offline : .rejected(String(describing: error))
        }
        if case FunctionsError.relayError = error { return .offline }
        if let postgrest = error as? PostgrestError, ["PGRST301", "PGRST303"].contains(postgrest.code ?? "") {
            return .offline // the JWT expired: the next try carries a refreshed one
        }
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

    /// 5xx, request timeout, too early, too many requests.
    static func isTransient(status: Int) -> Bool {
        status >= 500 || status == 408 || status == 425 || status == 429
    }

    /// The HTTP status an error carries, from whichever client produced it.
    private static func transientStatus(of error: any Error) -> Int? {
        if let http = error as? HTTPError { return http.response.statusCode }
        if case FunctionsError.httpError(let code, _) = error { return code }
        if let storage = error as? StorageError, let code = storage.statusCode.flatMap(Int.init) { return code }
        if let photo = error as? PhotoStoreError { return photo.status }
        if case AuthError.api(_, _, _, let response) = error { return response.statusCode }
        return nil
    }
}
