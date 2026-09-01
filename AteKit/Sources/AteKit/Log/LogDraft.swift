import Foundation

/// An abandoned sitting, kept **client-local** (§7). There is no server draft: an unposted sitting is
/// not a review, and syncing one would put half-formed opinions in a database that only stores
/// finished ones.
///
/// One draft, maximum. Starting a sitting somewhere else and giving it content silently replaces the
/// old one — a resume list is a second inbox nobody asked for.
public struct LogDraft: Sendable, Hashable, Codable, Identifiable {
    /// §7: staged photos live in a caches subdirectory keyed by this.
    public let id: UUID
    public var sitting: SittingState
    public var savedAt: Date
    /// §6.4: rows that already landed in a partially-failed post. A retry skips them, so the client
    /// ids make the whole thing idempotent.
    public var postedReviewIDs: [UUID]
    /// §6.4: "Leave with failed post: draft persists; one-shot auto-retry next foreground."
    public var needsPostRetry: Bool
    /// How many times this sitting has been sent. Carried on the draft so `log_post_failed(attempt:)`
    /// keeps counting across a relaunch instead of resetting to 1 every foreground.
    public var postAttempts: Int

    public init(
        id: UUID = UUID(),
        sitting: SittingState,
        savedAt: Date = Date(),
        postedReviewIDs: [UUID] = [],
        needsPostRetry: Bool = false,
        postAttempts: Int = 0
    ) {
        self.id = id
        self.sitting = sitting
        self.savedAt = savedAt
        self.postedReviewIDs = postedReviewIDs
        self.needsPostRetry = needsPostRetry
        self.postAttempts = postAttempts
    }

    /// §7: "Expiry 7 days."
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(savedAt) >= Self.lifetime
    }

    /// `log_draft_resumed(age_minutes)`.
    public func ageMinutes(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(savedAt) / 60))
    }

    /// The Continue row's second line, minus the relative time the view formats: "2 dishes".
    public var dishCountSummary: String {
        sitting.dishes.count == 1 ? "1 dish" : "\(sitting.dishes.count) dishes"
    }

    /// A draft is only worth keeping if something was actually composed (§7 `hasContent`).
    public var isWorthKeeping: Bool { sitting.hasContent || needsPostRetry }
}

/// The rules for *replacing* a draft — the ones that can't live in a call site, because the whole
/// point is that no call site gets to forget them.
public enum LogDraftPolicy {
    /// A save must never **downgrade** a pending retry.
    ///
    /// The defect this exists to prevent: a post fails (flag set, draft written), the person taps
    /// Cancel and chooses "Save draft", and that ordinary save — which knows nothing about the
    /// failed post — writes the same sitting back with `needsPostRetry = false`. The rows are then
    /// stranded forever: never posted, never retried, and the person was told they were saved.
    ///
    /// So the flag and the already-posted ids are *sticky*: they can only be cleared by the retry
    /// actually succeeding (which clears the whole draft), never by an unrelated save. The attempt
    /// count is likewise monotonic.
    public static func merged(existing: LogDraft?, updated: LogDraft) -> LogDraft {
        guard let existing, existing.id == updated.id else { return updated }
        var merged = updated
        merged.needsPostRetry = updated.needsPostRetry || existing.needsPostRetry
        merged.postAttempts = max(updated.postAttempts, existing.postAttempts)
        // Rows that landed stay recorded; forgetting one means posting it twice.
        let known = Set(updated.postedReviewIDs)
        merged.postedReviewIDs = updated.postedReviewIDs
            + existing.postedReviewIDs.filter { !known.contains($0) }
        return merged
    }
}

/// One draft in, one draft out. Deliberately synchronous and throwing: it is a small JSON file, and
/// making it `async` would invite writing it off the main actor mid-dismissal, which is exactly when
/// the app might be suspended.
public protocol LogDraftStoring: Sendable {
    func load() -> LogDraft?
    func save(_ draft: LogDraft)
    func clear(draftID: UUID?)
}

/// The real store: one JSON file in Application Support, staged photos in Caches.
///
/// Photos go to Caches on purpose — the system may reclaim them under pressure, and a resumed draft
/// that has lost its photo is a small disappointment, whereas a resumed draft that has lost its
/// *ratings* is a bug. The ratings are in the JSON.
public struct FileLogDraftStore: LogDraftStoring {
    private let fileURL: URL
    private let photoDirectory: URL

    public init(
        fileURL: URL? = nil,
        photoDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let support = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        self.fileURL = fileURL ?? support.appending(path: "ate-log-draft.json")
        self.photoDirectory = photoDirectory ?? caches.appending(path: "ate-log-drafts")
    }

    public func load() -> LogDraft? {
        guard let data = try? Data(contentsOf: fileURL),
              let draft = try? JSONDecoder.ate.decode(LogDraft.self, from: data)
        else { return nil }
        guard !draft.isExpired() else {
            clear(draftID: draft.id)
            return nil
        }
        return draft
    }

    public func save(_ draft: LogDraft) {
        guard let data = try? JSONEncoder.ate.encode(draft) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear(draftID: UUID?) {
        try? FileManager.default.removeItem(at: fileURL)
        if let draftID {
            try? FileManager.default.removeItem(at: photoDirectory(for: draftID))
        }
    }

    /// Where one draft's staged photos live. Created lazily by the caller that writes into it.
    public func photoDirectory(for draftID: UUID) -> URL {
        photoDirectory.appending(path: draftID.uuidString.lowercased())
    }
}

/// For previews and tests. `nonisolated(unsafe)` storage would be a lie under strict concurrency, so
/// this is an actor-free box with a lock.
public final class InMemoryLogDraftStore: LogDraftStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var draft: LogDraft?

    public init(draft: LogDraft? = nil) {
        self.draft = draft
    }

    public func load() -> LogDraft? {
        lock.withLock { draft.flatMap { $0.isExpired() ? nil : $0 } }
    }

    public func save(_ draft: LogDraft) {
        lock.withLock { self.draft = draft }
    }

    public func clear(draftID: UUID?) {
        lock.withLock { draft = nil }
    }
}

extension JSONEncoder {
    /// ISO-8601 dates, so a draft written by one build decodes in the next.
    static var ate: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var ate: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
