import Foundation
import Testing
@testable import AteKit

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

    private func draftFolder(in root: URL? = nil) throws -> URL {
        let base = root ?? URL.temporaryDirectory
        let folder = base.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func age(_ file: URL, hours: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-hours * 3600)], ofItemAtPath: file.path()
        )
    }

    @Test("QA 2: a pick on disk but not yet recorded is never pruned while young; the sweep takes old strays")
    func sweepSparesYoungFiles() throws {
        let root = URL.temporaryDirectory.appending(path: "Sweep-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = try draftFolder(in: root)
        let young = folder.appending(path: "just-written.jpg")
        let oldStray = folder.appending(path: "removed-before-done.jpg")
        let oldKept = folder.appending(path: "still-queued.jpg")
        for file in [young, oldStray, oldKept] { try Data([1]).write(to: file) }
        try age(oldStray, hours: 30)
        try age(oldKept, hours: 30)
        let removed = StagedFiles.sweep(root, keeping: [oldKept.path()])
        #expect(removed.count == 1)
        #expect(FileManager.default.fileExists(atPath: young.path()), "young and unrecorded: kept")
        #expect(FileManager.default.fileExists(atPath: oldKept.path()), "referenced: kept")
        #expect(FileManager.default.fileExists(atPath: oldStray.path()) == false, "old and unreferenced: swept")
    }

    @Test("editing an entry never sweeps a parked draft's photos, however old")
    func sweepKeepsTheParkedDraft() throws {
        let owner = UUID()
        let store = EntryDraftStore(containerName: "Tests-\(UUID().uuidString)", owner: { owner })
        let root = try #require(store.draftPhotosRoot)
        // A new-entry draft parked a day and a half ago, with a photo.
        var draft = EntryDraft(composition: EntryComposition(plain: "The ragù", spans: []))
        draft.photoFiles = ["parked.jpg"]
        store.save(draft)
        let parked = store.photoDirectory(for: draft.id).appending(path: "parked.jpg")
        try Data([1]).write(to: parked)
        try age(parked, hours: 36)
        // Now the composer is editing an entry: its own folder is the entry's, and it references
        // only that folder's files.
        let entryID = UUID()
        let editFolder = store.photoDirectory(for: entryID)
        let editing = editFolder.appending(path: "added.jpg")
        let stray = editFolder.appending(path: "removed-long-ago.jpg")
        try Data([2]).write(to: editing)
        try Data([3]).write(to: stray)
        try age(stray, hours: 36)
        let keep = Set([editing.path()]).union(store.draftReferencedPhotoPaths)
        StagedFiles.sweep(root, keeping: keep)
        #expect(FileManager.default.fileExists(atPath: parked.path()), "the parked draft keeps its photo")
        #expect(FileManager.default.fileExists(atPath: editing.path()))
        #expect(FileManager.default.fileExists(atPath: stray.path()) == false, "old and unreferenced: swept")
    }

    @Test("a recorded file stays until the server shows its row — an upload returning is not enough")
    func confirmNeedsTheRow() async throws {
        let ledger = StagedPhotoLedger(storeURL: nil)
        let folder = try draftFolder()
        let file = folder.appending(path: "a.jpg")
        try Data([1]).write(to: file)
        let entryID = UUID()
        await ledger.record(entryID: entryID, photos: [QueuedPhoto(position: 0, path: file.path())])
        let noRow = EntryCard(id: entryID, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date())
        #expect(await ledger.confirm(entryID: entryID, card: noRow).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path()))
        let withRow = EntryCard(
            id: entryID, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date(),
            photos: [EntryCard.Photo(url: "u", position: 0)]
        )
        #expect(await ledger.confirm(entryID: entryID, card: withRow) == [file.path()])
        #expect(FileManager.default.fileExists(atPath: file.path()) == false)
        #expect(await ledger.isConfirmed(file.path()))
    }

    @Test("QA 1: an edit whose upload failed midway retries with every file still there, and succeeds")
    func editRetryAfterFailedUpload() async throws {
        let service = UploadRecorder()
        service.failsPosition = 1
        let ledger = StagedPhotoLedger(storeURL: nil)
        let folder = try draftFolder()
        let first = folder.appending(path: "a.jpg")
        let second = folder.appending(path: "b.jpg")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        let entryID = UUID()
        let edit = EntryEdit(
            entryID: entryID, body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
            photos: [.added(path: first.path()), .added(path: second.path())]
        )
        await #expect(throws: (any Error).self) { try await edit.save(to: service, staged: ledger) }
        #expect(FileManager.default.fileExists(atPath: first.path()), "nothing deleted by a failed save")
        service.failsPosition = nil
        let card = try await edit.save(to: service, staged: ledger)
        #expect(card.photos.map(\.position).sorted() == [0, 1])
        #expect(FileManager.default.fileExists(atPath: first.path()) == false, "confirmed: gone")
        #expect(FileManager.default.fileExists(atPath: second.path()) == false)
        // A third attempt (the files are gone, already confirmed) skips rather than fails.
        _ = try await edit.save(to: service, staged: ledger)
    }

    @Test("QA 3: a pick that lands after an edit's 8s is not deleted by the edit, and follows it up")
    func editLatePickSurvives() async throws {
        let service = UploadRecorder()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let folder = try draftFolder()
        let kept = folder.appending(path: "a.jpg")
        try Data([1]).write(to: kept)
        let entryID = UUID()
        let edit = EntryEdit(
            entryID: entryID, body: "x", originalRestaurantID: nil, restaurantID: nil, tagTokens: [],
            photos: [.added(path: kept.path())]
        )
        _ = try await edit.save(to: service, staged: outbox.staged)
        // The late pick is written into the same folder after the edit saved.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let late = folder.appending(path: "late.jpg")
        try Data([2]).write(to: late)
        #expect(FileManager.default.fileExists(atPath: late.path()), "the edit leaves an unrecorded pick alone")
        let request = NewEntryRequest(
            id: entryID, body: "x", restaurantID: nil, photoPaths: [""], createdAt: Date(), scoreCount: 0,
            secondsFromOpen: 0
        )
        #expect(await submission.attachLate(request, path: late.path(), position: 1))
        #expect(service.uploads.last == "\(entryID) @1")
        #expect(FileManager.default.fileExists(atPath: late.path()) == false, "up, row confirmed, then gone")
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
private final class UploadRecorder: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var insertCount = 0
    private var failing = false
    private var failingPosition: Int?
    private var landed: [UUID: Set<Int>] = [:]
    /// One position that fails to upload (a mid-edit failure).
    var failsPosition: Int? {
        get { lock.withLock { failingPosition } }
        set { lock.withLock { failingPosition = newValue } }
    }
    var uploads: [String] { lock.withLock { log } }
    var inserts: Int { lock.withLock { insertCount } }
    var failsUploads: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func authorID() async throws -> UUID { UUID() }
    func updateBody(entryID: UUID, body: String) async throws {}
    func create(_ entry: NewEntry) async throws -> EntryCard {
        lock.withLock { insertCount += 1 }
        return EntryCard(id: entry.id, authorID: entry.authorID, body: entry.body, orderNumber: 1, createdAt: Date())
    }
    func attach(photo: EntryPhotoUpload) async throws {
        if failsUploads || failsPosition == photo.position { throw URLError(.notConnectedToInternet) }
        lock.withLock {
            log.append("\(photo.entryID) @\(photo.position)")
            landed[photo.entryID, default: []].insert(photo.position)
        }
    }
    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 0, restaurantID: nil, didAttachPlace: false
        )
    }
    /// The server's rows: a photo row for every position that landed.
    func entry(id: UUID) async throws -> EntryCard {
        let rows = lock.withLock { landed[id] ?? [] }
        return EntryCard(
            id: id, authorID: UUID(), body: "", orderNumber: 1, createdAt: Date(),
            photos: rows.sorted().map { EntryCard.Photo(url: "u\($0)", position: $0) }
        )
    }
}
