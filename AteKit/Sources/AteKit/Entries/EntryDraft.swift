import Foundation

/// **An entry being written.** Kept client-local: an unsaved entry is not an entry, and syncing one
/// would put half-formed words in a table that only holds finished ones.
///
/// One draft, maximum. The composer is a single sheet with a single `+`, so a list of resumable
/// drafts would be a second inbox nobody asked for — opening the composer simply continues where the
/// person left off, with no prompt (design rule 1: nothing to explain, nothing to decide).
///
/// The `id` is the **entry's** id, minted here and carried all the way to the INSERT. That is what
/// makes the whole write path idempotent: a retry of an insert that already landed comes back as
/// `23505`, which the contract says to read as success.
public struct EntryDraft: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// The words and their tokens, verbatim.
    public var composition: EntryComposition
    /// Per entry, not per account.
    public var isPublic: Bool
    /// Set only when the person named or tapped a place (design rule 8). `nil` means the entry is
    /// written placeless and the sorter parks its plan.
    public var restaurantID: UUID?
    /// File names inside the draft's own photo directory, in the order they will be uploaded.
    /// Names, not URLs: a container path changes between launches, a file name does not.
    public var photoFiles: [String]
    /// When `+` was tapped — the start of `entry_saved(seconds_from_open:)`, the brief's
    /// entry-friction metric. Survives a relaunch, so an entry written over two sittings reports the
    /// honest number rather than a fresh zero.
    public var startedAt: Date
    public var savedAt: Date

    public init(
        id: UUID = UUID(),
        composition: EntryComposition = EntryComposition(),
        isPublic: Bool = true,
        restaurantID: UUID? = nil,
        photoFiles: [String] = [],
        startedAt: Date = Date(),
        savedAt: Date = Date()
    ) {
        self.id = id
        self.composition = composition
        self.isPublic = isPublic
        self.restaurantID = restaurantID
        self.photoFiles = photoFiles
        self.startedAt = startedAt
        self.savedAt = savedAt
    }

    /// At most five photos per entry (the composer's own cap; the column allows 24 positions).
    public static let photoLimit = 5
    /// A draft nobody came back to eventually stops being offered. Seven days, as the log draft was.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(savedAt) >= Self.lifetime
    }

    /// Worth resuming only if something was actually written. A draft holding an empty composition
    /// and no photos is indistinguishable from no draft, and offering it would resurrect a composer
    /// the person closed on purpose.
    public var hasContent: Bool {
        composition.isEmpty == false || photoFiles.isEmpty == false
    }

    public func secondsFromOpen(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }
}

/// One draft in, one draft out.
///
/// Deliberately synchronous and throwing-free: it is a small JSON file next to a folder of JPEGs, and
/// making it `async` would invite writing it off the main actor mid-dismissal — exactly when the app
/// is most likely to be suspended.
public protocol EntryDraftStoring: Sendable {
    /// The draft, or `nil` when there is none, it has expired, or it holds nothing.
    func load() -> EntryDraft?
    func save(_ draft: EntryDraft)
    /// Removes the draft and its staged photos. Safe to call with a stale id — it clears only when
    /// the id matches, so a late call from a composer that was already finished cannot delete the
    /// draft somebody started afterwards.
    func clear(draftID: UUID?)
    /// Where a draft's staged photos live. Created on demand.
    func photoDirectory(for draftID: UUID) -> URL
}
