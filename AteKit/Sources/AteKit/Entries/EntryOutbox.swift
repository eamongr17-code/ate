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

    /// After this many failed foregrounds the entry stops being retried automatically. It is still
    /// on the device and still in the journal — what stops is the app promising it will fix itself.
    public static let maximumAttempts = 8

    public var isExhausted: Bool { attempts >= Self.maximumAttempts }
}

/// The insert, kept as data rather than as a `NewEntry` so it survives being written to disk.
public struct QueuedInsert: Sendable, Hashable, Codable {
    public let id: UUID
    public let authorID: UUID
    public let body: String
    public let visibility: EntryVisibility
    public let restaurantID: UUID?
    public let createdAt: Date

    public init(_ entry: NewEntry) {
        self.id = entry.id
        self.authorID = entry.authorID
        self.body = entry.body
        self.visibility = entry.visibility
        self.restaurantID = entry.restaurantID
        self.createdAt = entry.createdAt
    }

    public var newEntry: NewEntry {
        NewEntry(id: id, authorID: authorID, body: body, visibility: visibility,
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

    public init(
        entries: any EntryService,
        analytics: @escaping AnalyticsRecorder = { _ in },
        containerName: String = "Entries"
    ) {
        self.entries = entries
        self.analytics = analytics
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
        for item in queue where item.isExhausted == false {
            var working = item
            do {
                try await push(&working)
            } catch {
                working.attempts += 1
                update(working)
                // The first failure is the one that told us we were offline; the rest of the queue
                // will fail the same way, so stop rather than burn attempts on all of them.
                if EntryWriteFailure.of(error).isRetryable { break }
                continue
            }
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

    /// One entry's outstanding work, in order. Each step is skipped when it is already done.
    private func push(_ item: inout QueuedEntry) async throws {
        if item.hasInserted == false {
            _ = try await entries.create(item.entry.newEntry)
            item.hasInserted = true
        }
        var remaining: [QueuedPhoto] = []
        for photo in item.pendingPhotos {
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
        if item.needsSort {
            let outcome = try await entries.sort(entryID: item.entry.id, force: false)
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
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        queue[index] = item
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
