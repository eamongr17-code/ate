import Foundation

/// What Done hands over: the entry as the person wrote it, plus the two things the funnel needs.
public struct NewEntryRequest: Sendable, Hashable {
    public let id: UUID
    /// The words, verbatim. `""` is legal.
    public let body: String
    public let visibility: EntryVisibility
    /// Only when they named or tapped a place.
    public let restaurantID: UUID?
    /// Absolute paths to the staged JPEGs, in the order they print.
    public let photoPaths: [String]
    public let createdAt: Date
    public let scoreCount: Int
    public let secondsFromOpen: Int

    public init(
        id: UUID,
        body: String,
        visibility: EntryVisibility,
        restaurantID: UUID?,
        photoPaths: [String],
        createdAt: Date,
        scoreCount: Int,
        secondsFromOpen: Int
    ) {
        self.id = id
        self.body = body
        self.visibility = visibility
        self.restaurantID = restaurantID
        self.photoPaths = photoPaths
        self.createdAt = createdAt
        self.scoreCount = scoreCount
        self.secondsFromOpen = secondsFromOpen
    }
}

/// How far an entry got.
public enum EntrySubmissionResult: Sendable, Equatable {
    /// The words are on the server. The receipt may still be coming.
    case saved(EntryCard)
    /// The words could not be sent and are in the outbox. The card is a local stand-in so the
    /// journal shows the entry immediately — which is the promise, network or not.
    case queued(EntryCard)
    /// The server refused. Retrying will not help, and pretending otherwise would be a lie.
    case rejected(String)

    public var card: EntryCard? {
        switch self {
        case .saved(let card), .queued(let card): card
        case .rejected: nil
        }
    }
}

/// **The save path, as one testable sequence.**
///
/// Three steps in a fixed order, because that order *is* the product (design rule 9): the words land
/// first and alone, the photos follow, and only then does the server add structure. Nothing about
/// the receipt is allowed to delay the words.
///
/// Every step is idempotent — the id is the client's, photo rows upsert on `(entry_id, position)`,
/// and `sort-entry` is idempotent by contract — so anything that fails goes to ``EntryOutbox``
/// rather than being lost or double-written.
public struct EntrySubmission: Sendable {
    private let entries: any EntryService
    private let outbox: EntryOutbox
    private let analytics: AnalyticsRecorder
    private let now: @Sendable () -> Date

    public init(
        entries: any EntryService,
        outbox: EntryOutbox,
        analytics: @escaping AnalyticsRecorder = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.entries = entries
        self.outbox = outbox
        self.analytics = analytics
        self.now = now
    }

    /// Step one: the words. Returns as soon as they are accepted — photos and the sorter are
    /// ``finish(entryID:photoPaths:)``, and the entry is already in the journal by then.
    public func submit(_ request: NewEntryRequest) async -> EntrySubmissionResult {
        let authorID: UUID
        do {
            authorID = try await entries.authorID()
        } catch {
            return .rejected(String(describing: error))
        }
        let entry = NewEntry(
            id: request.id,
            authorID: authorID,
            body: request.body,
            visibility: request.visibility,
            restaurantID: request.restaurantID,
            createdAt: request.createdAt
        )

        do {
            let card = try await entries.create(entry)
            analytics(EntryEvents.saved(savedEvent(request, queued: false)))
            await outbox.enqueue(QueuedEntry(
                entry: QueuedInsert(entry),
                pendingPhotos: photos(of: request),
                hasInserted: true
            ))
            return .saved(card)
        } catch {
            let failure = EntryWriteFailure.of(error)
            guard failure.isRetryable else {
                if case .rejected(let message) = failure { return .rejected(message) }
                return .rejected(String(describing: error))
            }
            await outbox.enqueue(QueuedEntry(
                entry: QueuedInsert(entry),
                pendingPhotos: photos(of: request)
            ))
            analytics(EntryEvents.saved(savedEvent(request, queued: true)))
            return .queued(placeholder(for: entry, request: request))
        }
    }

    /// Steps two and three: the photos, then the sorter. Returns the entry as it now stands, or
    /// `nil` when nothing could be reached — in which case the outbox already has the rest.
    @discardableResult
    public func finish(entryID: UUID, photoPaths: [String]) async -> EntryCard? {
        var uploaded: Set<Int> = []
        for (position, path) in photoPaths.enumerated() {
            // A file that has gone (the system reclaimed the cache) is not a retryable failure —
            // count it as done rather than queueing an upload of nothing, forever.
            guard let data = try? Data(contentsOf: URL(filePath: path)) else {
                uploaded.insert(position)
                continue
            }
            do {
                try await entries.attach(photo: EntryPhotoUpload(
                    entryID: entryID, position: position, data: data
                ))
                uploaded.insert(position)
            } catch {
                break // the rest will fail the same way; the outbox has them.
            }
        }

        let startedAt = now()
        var didSort = false
        do {
            let outcome = try await entries.sort(entryID: entryID, force: false)
            didSort = true
            analytics(EntryEvents.sortCompleted(
                mode: outcome.mode,
                itemCount: outcome.itemCount,
                durationMilliseconds: Int(now().timeIntervalSince(startedAt) * 1000),
                didAttachPlace: outcome.didAttachPlace
            ))
        } catch {
            analytics(EntryEvents.sortFailed(reason: reason(for: error)))
        }
        await outbox.recordProgress(entryID: entryID, uploadedPositions: uploaded, didSort: didSort)
        return try? await entries.entry(id: entryID)
    }

    // MARK: - Pieces

    private func photos(of request: NewEntryRequest) -> [QueuedPhoto] {
        request.photoPaths.enumerated().map { QueuedPhoto(position: $0.offset, path: $0.element) }
    }

    private func savedEvent(_ request: NewEntryRequest, queued: Bool) -> EntryEvents.SavedEntry {
        EntryEvents.SavedEntry(
            photoCount: request.photoPaths.count,
            hasPlace: request.restaurantID != nil,
            scoreCount: request.scoreCount,
            isPublic: request.visibility.isPublic,
            secondsFromOpen: request.secondsFromOpen,
            wasQueued: queued
        )
    }

    /// What the journal shows for an entry that has not reached the server yet. `orderNumber` is 0
    /// because the server allocates it and we will not invent one — nothing on a slip prints it, and
    /// the entry page shows the not-yet-sorted state until the real row arrives.
    private func placeholder(for entry: NewEntry, request: NewEntryRequest) -> EntryCard {
        EntryCard(
            id: entry.id,
            authorID: entry.authorID,
            body: entry.body,
            visibility: entry.visibility,
            restaurantID: entry.restaurantID,
            restaurantSource: entry.restaurantID == nil ? nil : "user",
            orderNumber: 0,
            sortStatus: .pending,
            createdAt: entry.createdAt,
            isMine: true
        )
    }

    private func reason(for error: any Error) -> String {
        switch EntryWriteFailure.of(error) {
        case .offline: "offline"
        case .rejected: "rejected"
        }
    }
}

extension QueuedEntry {
    init(entry: QueuedInsert, pendingPhotos: [QueuedPhoto], hasInserted: Bool) {
        self.init(entry: entry, pendingPhotos: pendingPhotos)
        self.hasInserted = hasInserted
    }
}
