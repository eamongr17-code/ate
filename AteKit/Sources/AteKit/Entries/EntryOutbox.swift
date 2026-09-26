import Foundation

/// One entry that has not finished landing, and exactly what is left to do to it.
///
/// Three steps, each idempotent, each recorded separately, because they fail independently: the
/// INSERT (a `23505` means it already landed), the photo uploads (upserted on `(entry_id, position)`)
/// and the sort (idempotent by contract). A retry does only what is still outstanding.
public struct QueuedEntry: Sendable, Hashable, Codable, Identifiable {
    public let entry: QueuedInsert
    /// Positions still to upload. The bytes live in the draft's photo directory, by file name.
    public var pendingPhotos: [QueuedPhoto]
    public var needsSort: Bool
    public var attempts: Int
    public var queuedAt: Date

    public var id: UUID { entry.id }

    public init(
        entry: QueuedInsert,
        pendingPhotos: [QueuedPhoto],
        needsSort: Bool = true,
        attempts: Int = 0,
        queuedAt: Date = Date()
    ) {
        self.entry = entry
        self.pendingPhotos = pendingPhotos
        self.needsSort = needsSort
        self.attempts = attempts
        self.queuedAt = queuedAt
    }

    /// Nothing left to do.
    public var isComplete: Bool { pendingPhotos.isEmpty && needsSort == false && hasInserted }

    /// Set once the INSERT has been accepted (including as a `23505`).
    public var hasInserted = false

    /// The composer's tag chips, for the sort this entry is still owed. Optional so a queue written
    /// before tags existed still reads.
    public var tagTokens: [TagToken]?

    /// The server refused rather than failed to answer. Retrying cannot help, so the queue stops
    /// immediately instead of burning eight foregrounds to arrive at the same place.
    public var isBlocked = false

    /// After this many failed foregrounds the entry stops being retried automatically. It is still
    /// on the device and still in the journal — what stops is the app promising it will fix itself.
    public static let maximumAttempts = 8

    public var isExhausted: Bool { attempts >= Self.maximumAttempts }

    /// The queue will not touch this again on its own. The entry needs a person to say "try again",
    /// which means it also needs somewhere to say so — see the entry page's not-printed state.
    public var isStuck: Bool { isBlocked || isExhausted }
}

/// The insert, kept as data rather than as a `NewEntry` so it survives being written to disk.
public struct QueuedInsert: Sendable, Hashable, Codable {
    public let id: UUID
    public let authorID: UUID
    public let body: String
    public let restaurantID: UUID?
    public let createdAt: Date

    public init(_ entry: NewEntry) {
        self.id = entry.id
        self.authorID = entry.authorID
        self.body = entry.body
        self.restaurantID = entry.restaurantID
        self.createdAt = entry.createdAt
    }

    public var newEntry: NewEntry {
        NewEntry(id: id, authorID: authorID, body: body,
                 restaurantID: restaurantID, createdAt: createdAt)
    }
}

public struct QueuedPhoto: Sendable, Hashable, Codable {
    public let position: Int
    /// Absolute path. The photos are already on disk from the composer; the queue only points at them.
    public let path: String

    public init(position: Int, path: String) {
        self.position = position
        self.path = path
    }
}

/// **The outbox.** An entry the person finished writing is theirs whether or not the network was
/// listening, so a failed write is queued rather than lost, and retried when the app comes back.
///
/// Reuses the *idea* the log-draft retry proved — client-minted ids make every step safe to repeat,
/// the queue survives a relaunch, and a run that changes nothing is a wasted round trip rather than
/// a duplicate — without reusing its code, which was shaped around a different write.
public actor EntryOutbox {
    private let entries: any EntryService
    private let storeURL: URL
    private let analytics: AnalyticsRecorder
    private var queue: [QueuedEntry]
    private var isRunning = false
    /// The entry a run is pushing right now, between its awaits.
    private var pushing: UUID?
    /// Entries forgotten because they were deleted. A run already holding one of them in its
    /// snapshot must neither push it nor write it back.
    private var forgotten: Set<UUID> = []
    /// Who is signed in now. **An entry is only ever pushed as its own author**: with somebody
    /// else signed in, another person's queued entry waits untouched for them — pushing it would be
    /// refused by RLS and marked blocked, or worse. Nil (tests) works every item.
    private let owner: (@Sendable () -> UUID?)?

    public init(
        entries: any EntryService,
        analytics: @escaping AnalyticsRecorder = { _ in },
        containerName: String = "Entries",
        owner: (@Sendable () -> UUID?)? = nil
    ) {
        self.entries = entries
        self.analytics = analytics
        self.owner = owner
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL.temporaryDirectory
        let root = support.appending(path: containerName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.storeURL = root.appending(path: "outbox.json", directoryHint: .notDirectory)
        self.queue = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONDecoder().decode([QueuedEntry].self, from: $0) } ?? []
    }

    public var pendingCount: Int { queue.count }

    /// Puts an entry in the queue, or updates the one already there.
    public func enqueue(_ item: QueuedEntry) {
        queue.removeAll { $0.id == item.id }
        queue.append(item)
        persist()
    }

    public func remove(entryID: UUID) {
        queue.removeAll { $0.id == entryID }
        persist()
    }

    /// **Before a delete.** The entry leaves the queue for good, and this waits out any push of it
    /// already in the air — so no queued photo re-uploads an orphan file, and no insert that timed
    /// out on the way in can land after `delete_entry` and resurrect the entry.
    ///
    /// Returns what was queued, so a delete the server refuses can put it back (``restore(_:)``).
    @discardableResult
    public func forget(entryID: UUID) async -> QueuedEntry? {
        forgotten.insert(entryID)
        let queued = queue.first { $0.id == entryID }
        queue.removeAll { $0.id == entryID }
        persist()
        while pushing == entryID {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return queued
    }

    /// The delete was refused: the entry still exists, so its unfinished work is owed again.
    public func restore(_ item: QueuedEntry?, entryID: UUID) {
        forgotten.remove(entryID)
        guard let item else { return }
        enqueue(item)
    }

    /// Records what the foreground save already managed, so a later run does not repeat it and does
    /// not forget what is still outstanding. An item with nothing left to do leaves the queue.
    public func recordProgress(entryID: UUID, uploadedPositions: Set<Int>, didSort: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == entryID }) else { return }
        var item = queue[index]
        item.pendingPhotos.removeAll { uploadedPositions.contains($0.position) }
        if didSort { item.needsSort = false }
        if item.isComplete {
            queue.remove(at: index)
        } else {
            queue[index] = item
        }
        persist()
    }

    /// Works the queue once. Safe to call spuriously: it no-ops while a run is in flight and on an
    /// empty queue, and every step it takes is idempotent.
    ///
    /// Returns the ids that finished, so the journal can show what has just become real.
    @discardableResult
    public func run() async -> [UUID] {
        guard isRunning == false, queue.isEmpty == false else { return [] }
        isRunning = true
        defer { isRunning = false }

        var landed: [UUID] = []
        for item in queue where item.isStuck == false && belongsToCurrentOwner(item) {
            guard forgotten.contains(item.id) == false else { continue }
            var working = item
            pushing = item.id
            defer { pushing = nil }
            do {
                try await push(&working)
            } catch {
                guard EntryWriteFailure.of(error).isRetryable else {
                    // A refusal is not a bad connection. Mark it and move on rather than counting
                    // eight foregrounds towards the same answer.
                    working.isBlocked = true
                    update(working)
                    continue
                }
                working.attempts += 1
                update(working)
                // The first failure is the one that told us we were offline; the rest of the queue
                // will fail the same way, so stop rather than burn attempts on all of them.
                break
            }
            // Deleted mid-push: it is not landed, and it is not coming back.
            guard forgotten.contains(working.id) == false else { continue }
            if working.isComplete {
                landed.append(working.id)
                queue.removeAll { $0.id == working.id }
            } else {
                update(working)
            }
        }
        persist()
        return landed
    }

    /// Whether an item is the signed-in person's to push.
    private func belongsToCurrentOwner(_ item: QueuedEntry) -> Bool {
        guard let owner else { return true }
        return owner() == item.entry.authorID
    }

    /// Drops everything one person had queued — their account has been deleted, and there is no
    /// longer anybody an entry of theirs could be pushed as.
    public func discard(authoredBy userID: UUID) {
        queue.removeAll { $0.entry.authorID == userID }
        persist()
    }

    /// Whether the queue has given up on an entry. The entry page asks, so a stuck entry says so on
    /// its own paper instead of sitting silently in a JSON file nobody opens.
    public func isStuck(entryID: UUID) -> Bool {
        queue.first { $0.id == entryID }?.isStuck ?? false
    }

    /// "Print it again": the person's own retry. Clears the give-up state and works the queue.
    @discardableResult
    public func retry(entryID: UUID) async -> [UUID] {
        guard let index = queue.firstIndex(where: { $0.id == entryID }),
              belongsToCurrentOwner(queue[index]) else { return [] }
        queue[index].isBlocked = false
        queue[index].attempts = 0
        persist()
        return await run()
    }

    /// One entry's outstanding work, in order. Each step is skipped when it is already done.
    private func push(_ item: inout QueuedEntry) async throws {
        if item.hasInserted == false {
            _ = try await entries.create(item.entry.newEntry)
            item.hasInserted = true
        }
        var remaining: [QueuedPhoto] = []
        for photo in item.pendingPhotos {
            // Deleted while this run was working it: stop, and upload nothing more.
            guard forgotten.contains(item.id) == false else { return }
            guard let data = try? Data(contentsOf: URL(filePath: photo.path)) else { continue }
            do {
                try await entries.attach(photo: EntryPhotoUpload(
                    entryID: item.entry.id, position: photo.position, data: data
                ))
            } catch {
                remaining.append(photo)
                throw error
            }
        }
        item.pendingPhotos = remaining
        if item.needsSort, forgotten.contains(item.id) == false {
            let outcome = try await entries.sort(
                entryID: item.entry.id, force: false, tagTokens: item.tagTokens ?? []
            )
            item.needsSort = false
            analytics(EntryEvents.sortCompleted(
                mode: outcome.mode,
                itemCount: outcome.itemCount,
                durationMilliseconds: 0,
                didAttachPlace: outcome.didAttachPlace
            ))
        }
    }

    private func update(_ item: QueuedEntry) {
        guard forgotten.contains(item.id) == false,
              let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        queue[index] = item
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
