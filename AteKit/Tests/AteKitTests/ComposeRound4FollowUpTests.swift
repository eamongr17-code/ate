import Foundation
import Testing
@testable import AteKit

@Suite("Print it again carries the entry's 6s and chips")
struct ResortTokensTests {
    private let six = TagToken(offset: 9, length: 3)

    @Test("after a first sort that failed, the outbox's own tokens are sent")
    func fromTheOutbox() {
        let insert = QueuedInsert(NewEntry(
            id: UUID(), authorID: UUID(), body: "Tiramisu 6.0", restaurantID: nil, createdAt: Date()
        ))
        let queued = QueuedEntry(
            entry: insert, pendingPhotos: [], hasInserted: true,
            tagTokens: [TagToken(offset: 0, length: 2)], sixTokens: [six]
        )
        // The card has no lines yet — the sort failed — so only the outbox knows about the 6.
        let card = EntryCard(
            id: insert.id, authorID: insert.authorID, body: insert.body, orderNumber: 1, createdAt: Date()
        )
        let tokens = ResortTokens.resolve(queued: queued, card: card)
        #expect(tokens.sixes == [six])
        #expect(tokens.tags == [TagToken(offset: 0, length: 2)])
    }

    @Test("a sorted entry's 6 is rebuilt from its lines")
    func fromTheLines() {
        let card = EntryCard(
            id: UUID(), authorID: UUID(), body: "Tiramisu 6.0", orderNumber: 1, sortStatus: .sorted,
            createdAt: Date(),
            items: [EntryCard.Item(
                reviewID: UUID(), dishID: UUID(), dishName: "Tiramisu", score: .blownAway, position: 1,
                evidenceOffset: 9, evidenceLength: 3, mentionOffset: 0, mentionLength: 8
            )]
        )
        #expect(ResortTokens.resolve(queued: nil, card: card).sixes == [six])
    }

    @Test("nothing known, nothing sent")
    func empty() {
        #expect(ResortTokens.resolve(queued: nil, card: nil) == ResortTokens(tags: [], sixes: []))
    }
}

@Suite("Done does not wait forever on a slow photo")
struct LatePhotoTests {

    @Test("the wait gives up at its timeout, and returns at once when there is nothing to wait for")
    @MainActor
    func boundedWait() async {
        let clock = ContinuousClock()
        let start = clock.now
        let gaveUp = await BoundedWait.until(timeout: .milliseconds(200), poll: .milliseconds(20)) { false }
        #expect(gaveUp == false)
        #expect(clock.now - start >= .milliseconds(200))
        #expect(clock.now - start < .seconds(2))
        let ready = await BoundedWait.until(timeout: .seconds(5)) { true }
        #expect(ready)
        #expect(BoundedWait.pendingPhotos == .seconds(8))
    }

    private func request(photos: Int) -> NewEntryRequest {
        NewEntryRequest(
            id: UUID(), body: "The ragù 4.5", restaurantID: UUID(),
            photoPaths: (0..<photos).map { "/tmp/p\($0).jpg" }, createdAt: Date(), scoreCount: 1, secondsFromOpen: 3
        )
    }

    private func lateFile() throws -> String {
        let url = URL.temporaryDirectory.appending(path: "late-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8]).write(to: url)
        return url.path()
    }

    @Test("a late photo goes up at the next position when it can")
    func uploadsDirectly() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let entry = request(photos: 2)
        let landed = await submission.attachLate(entry, path: try lateFile(), position: 2)
        #expect(landed)
        #expect(service.uploads == ["\(entry.id) @2"])
        #expect(await outbox.queued(entryID: entry.id) == nil)
    }

    @Test("offline, it is queued in the outbox and attached when the outbox runs")
    func queuesWhenOffline() async throws {
        let service = UploadRecorder()
        service.failsUploads = true
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let entry = request(photos: 1)
        let landed = await submission.attachLate(entry, path: try lateFile(), position: 1)
        #expect(landed == false)
        let queued = try #require(await outbox.queued(entryID: entry.id))
        #expect(queued.hasInserted, "the entry is already saved — it is not inserted again")
        #expect(queued.needsSort == false)
        #expect(queued.pendingPhotos.map(\.position) == [1])

        service.failsUploads = false
        let finished = await outbox.run()
        #expect(finished == [entry.id])
        #expect(service.uploads == ["\(entry.id) @1"])
        #expect(service.inserts == 0)
    }

    @Test("a late photo joins an entry already waiting in the outbox")
    func joinsTheQueuedEntry() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let insert = QueuedInsert(NewEntry(
            id: UUID(), authorID: UUID(), body: "x", restaurantID: nil, createdAt: Date()
        ))
        await outbox.enqueue(QueuedEntry(entry: insert, pendingPhotos: [QueuedPhoto(position: 0, path: "/a")]))
        await outbox.addLatePhoto(QueuedPhoto(position: 1, path: "/b"), to: insert)
        await outbox.addLatePhoto(QueuedPhoto(position: 1, path: "/b"), to: insert)
        #expect(await outbox.queued(entryID: insert.id)?.pendingPhotos.map(\.position) == [0, 1])
    }

    @Test("a late photo that cannot be read is counted, never silent")
    func unreadable() async {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let events = LateEventLog()
        let submission = EntrySubmission(entries: service, outbox: outbox, analytics: events.record)
        let landed = await submission.attachLate(request(photos: 0), path: "/nowhere/gone.jpg", position: 0)
        #expect(landed == false)
        #expect(events.names == ["entry_photo_failed"])
        #expect(EntryEvents.photoLate(count: 2).parameters == ["count": "2"])
    }

    @Test("a late photo queued before Done's own enqueue lands is merged in, never dropped")
    func lateBeforeEnqueue() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let insert = QueuedInsert(NewEntry(
            id: UUID(), authorID: UUID(), body: "x", restaurantID: nil, createdAt: Date()
        ))
        // 1. The 8s ran out with `create` still in flight; the late upload failed and queued itself.
        await outbox.addLatePhoto(QueuedPhoto(position: 2, path: "/late.jpg"), to: insert)
        // 2. …then `create` returned and Done's submit enqueued the entry's own work.
        await outbox.enqueue(QueuedEntry(
            entry: insert,
            pendingPhotos: [QueuedPhoto(position: 0, path: "/a.jpg"), QueuedPhoto(position: 1, path: "/b.jpg")],
            hasInserted: true, sixTokens: [TagToken(offset: 1, length: 3)]
        ))
        let queued = try #require(await outbox.queued(entryID: insert.id))
        #expect(queued.pendingPhotos.map(\.position) == [0, 1, 2], "the late photo survives the enqueue")
        #expect(queued.needsSort, "the entry's own sort is still owed")
        #expect(queued.sixTokens == [TagToken(offset: 1, length: 3)])
    }

    @Test("after a successful submit with a late photo, the draft's photo folder is gone")
    func folderEmptiesAfterUpload() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appending(path: "a.jpg")
        let late = folder.appending(path: "b.jpg")
        try Data([1]).write(to: first)
        try Data([2]).write(to: folder.appending(path: "a_t.jpg"))
        let entry = NewEntryRequest(
            id: UUID(), body: "The ragù 4.5", restaurantID: UUID(), photoPaths: [first.path()],
            createdAt: Date(), scoreCount: 1, secondsFromOpen: 3
        )
        _ = await submission.submit(entry)
        await submission.finish(entryID: entry.id, photoPaths: entry.photoPaths)
        // The late pick is written as the composer writes one: its folder made on the way (the first
        // upload already emptied and removed it).
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([3]).write(to: late)
        #expect(await submission.attachLate(entry, path: late.path(), position: 1))
        #expect(service.uploads == ["\(entry.id) @0", "\(entry.id) @1"])
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? []
        #expect(left.isEmpty, "left behind: \(left)")
        #expect(await outbox.queued(entryID: entry.id) == nil)
    }

    @Test("a queued photo that lands through the outbox takes its file with it")
    func outboxUploadClearsFile() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "c.jpg")
        try Data([1]).write(to: file)
        let insert = QueuedInsert(
            NewEntry(id: UUID(), authorID: UUID(), body: "x", restaurantID: nil, createdAt: Date())
        )
        await outbox.addLatePhoto(QueuedPhoto(position: 0, path: file.path()), to: insert)
        _ = await outbox.run()
        #expect(FileManager.default.fileExists(atPath: file.path()) == false)
        #expect(FileManager.default.fileExists(atPath: folder.path()) == false)
    }

    @Test("photos taken out before Done are pruned; the rest stay")
    func prune() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appending(path: "kept.jpg"))
        try Data([1]).write(to: folder.appending(path: "removed.jpg"))
        StagedFiles.prune(folder, keeping: ["kept.jpg"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()) == ["kept.jpg"])
        StagedFiles.prune(folder, keeping: [])
        #expect(FileManager.default.fileExists(atPath: folder.path()) == false)
    }

    @Test("Done clears the draft but keeps the photos its upload reads from")
    func draftKeepsPhotos() throws {
        let store = EntryDraftStore(containerName: "Tests-\(UUID().uuidString)")
        let draft = EntryDraft(composition: EntryComposition(plain: "ragù", spans: []))
        store.save(draft)
        let photo = store.photoDirectory(for: draft.id).appending(path: "a.jpg")
        try Data([1]).write(to: photo)
        store.clear(draftID: draft.id, keepingPhotos: true)
        #expect(store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: photo.path()))
        store.clear(draftID: nil)
        store.save(draft)
        store.clear(draftID: draft.id)
        #expect(FileManager.default.fileExists(atPath: photo.path()) == false)
    }
}

private final class LateEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var names: [String] { lock.withLock { log } }
    var record: AnalyticsRecorder { { [weak self] event in self?.lock.withLock { self?.log.append(event.name) } } }
}

/// Records uploads; can be made to fail them (offline).
private final class UploadRecorder: EntryService, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var insertCount = 0
    private var failing = false
    var uploads: [String] { lock.withLock { log } }
    var inserts: Int { lock.withLock { insertCount } }
    var failsUploads: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { UUID() }
    func create(_ entry: NewEntry) async throws -> EntryCard {
        lock.withLock { insertCount += 1 }
        return EntryCard(id: entry.id, authorID: entry.authorID, body: entry.body, orderNumber: 1, createdAt: Date())
    }
    func attach(photo: EntryPhotoUpload) async throws {
        if failsUploads { throw URLError(.notConnectedToInternet) }
        lock.withLock { log.append("\(photo.entryID) @\(photo.position)") }
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 0, restaurantID: nil, didAttachPlace: false
        )
    }
    func entry(id: UUID) async throws -> EntryCard {
        EntryCard(id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
    }
    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        Page(items: [], requestedLimit: pageSize)
    }
    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard { try await entry(id: entryID) }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func setTags(reviewID: UUID, tags: [DietTag]) async throws {}
    func updateBody(entryID: UUID, body: String) async throws {}
}
