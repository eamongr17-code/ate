import Foundation
import Testing
@testable import AteKit

/// A service that answers however a test needs it to, and remembers what it was asked.
private final class StubEntryService: EntryService, @unchecked Sendable {
    var createError: (any Error)?
    var sortError: (any Error)?
    var attachErrorAfter: Int?

    private(set) var created: [NewEntry] = []
    private(set) var attached: [EntryPhotoUpload] = []
    private(set) var sorted: [UUID] = []
    private let lock = NSLock()
    private var cards: [UUID: EntryCard] = [:]

    func viewer() async throws -> ViewerProfile { .preview }
    func authorID() async throws -> UUID { ViewerProfile.preview.id }

    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard {
        if let createError { throw createError }
        let card = EntryCard(
            id: entry.id, authorID: entry.authorID, body: entry.body,
            visibility: entry.visibility, restaurantID: entry.restaurantID,
            orderNumber: 1, createdAt: entry.createdAt
        )
        lock.withLock {
            created.append(entry)
            cards[entry.id] = card
        }
        return card
    }

    func attach(photo: EntryPhotoUpload) async throws {
        if let attachErrorAfter, lock.withLock({ attached.count }) >= attachErrorAfter {
            throw URLError(.notConnectedToInternet)
        }
        lock.withLock { attached.append(photo) }
    }

    @discardableResult
    func sort(entryID: UUID, force: Bool) async throws -> SortOutcome {
        if let sortError { throw sortError }
        lock.withLock { sorted.append(entryID) }
        return SortOutcome(entryID: entryID, status: .sorted, mode: "stub",
                           itemCount: 2, restaurantID: nil, didAttachPlace: true)
    }

    func entry(id: UUID) async throws -> EntryCard {
        try lock.withLock {
            guard let card = cards[id] else { throw AteAPIError.notFound(table: "entry_cards", id: id) }
            return card
        }
    }

    func journal(after cursor: PageCursor?, pageSize: Int) async throws -> Page<EntryCard> {
        Page(items: [], requestedLimit: pageSize)
    }

    func correctPlace(entryID: UUID, restaurantID: UUID) async throws -> EntryCard {
        try await entry(id: entryID)
    }
    func correctDish(reviewID: UUID, dishID: UUID?, dishName: String?) async throws {}
    func setVisibility(entryID: UUID, visibility: EntryVisibility) async throws {}
    func updateBody(entryID: UUID, body: String) async throws {}
}

@Suite("Entry submission")
struct EntrySubmissionTests {

    private func request(
        id: UUID = UUID(),
        body: String = "Tipo 00. The tagliatelle al ragù 4.5 was unreal.",
        restaurantID: UUID? = nil,
        photoPaths: [String] = []
    ) -> NewEntryRequest {
        NewEntryRequest(
            id: id, body: body, visibility: .public, restaurantID: restaurantID,
            photoPaths: photoPaths, createdAt: Date(timeIntervalSince1970: 1_789_000_000),
            scoreCount: 1, secondsFromOpen: 42
        )
    }

    private func outbox(_ entries: any EntryService) -> EntryOutbox {
        EntryOutbox(entries: entries, containerName: "Tests-\(UUID().uuidString)")
    }

    @Test("the words land first, alone — no photo and no sort before the entry exists")
    func wordsLandFirst() async {
        let service = StubEntryService()
        let submission = EntrySubmission(entries: service, outbox: outbox(service))

        let result = await submission.submit(request())

        #expect(service.created.count == 1)
        #expect(service.attached.isEmpty)
        #expect(service.sorted.isEmpty)
        #expect(result.card != nil)
        if case .saved = result {} else { Issue.record("expected .saved, got \(result)") }
    }

    @Test("a duplicate key is success — the id is ours, so the entry already landed")
    func duplicateKeyIsSuccess() async {
        let service = StubEntryService()
        // The Supabase service maps 23505 to success before this layer sees it; here the equivalent
        // is simply that a create which returns a card is a save.
        let submission = EntrySubmission(entries: service, outbox: outbox(service))
        let id = UUID()

        let first = await submission.submit(request(id: id))
        let second = await submission.submit(request(id: id))

        #expect(first.card?.id == id)
        #expect(second.card?.id == id)
    }

    @Test("offline queues the entry and still hands back a card for the journal")
    func offlineQueues() async {
        let service = StubEntryService()
        service.createError = URLError(.notConnectedToInternet)
        let queue = outbox(service)
        let submission = EntrySubmission(entries: service, outbox: queue)
        let id = UUID()

        let result = await submission.submit(request(id: id))

        guard case .queued(let card) = result else {
            Issue.record("expected .queued, got \(result)")
            return
        }
        #expect(card.id == id)
        #expect(card.sortStatus == .pending)
        // The server allocates the number; a local placeholder does not invent one.
        #expect(card.orderNumber == 0)
        #expect(await queue.pendingCount == 1)
    }

    @Test("a refusal is not queued — retrying a 42501 forever is a promise the app can't keep")
    func refusalIsNotQueued() async {
        let service = StubEntryService()
        service.createError = EntryWriteFailure.rejected("column not writable")
        let queue = outbox(service)
        let submission = EntrySubmission(entries: service, outbox: queue)

        let result = await submission.submit(request())

        if case .rejected = result {} else { Issue.record("expected .rejected, got \(result)") }
        #expect(await queue.pendingCount == 0)
    }

    @Test("finish sorts after the words, and reports the server's own mode and count")
    func finishSorts() async {
        let service = StubEntryService()
        let queue = outbox(service)
        var events: [AnalyticsEvent] = []
        let recorded = Mutex(events)
        let submission = EntrySubmission(
            entries: service, outbox: queue,
            analytics: { event in recorded.withLock { $0.append(event) } }
        )
        let id = UUID()
        _ = await submission.submit(request(id: id))

        await submission.finish(entryID: id, photoPaths: [])

        #expect(service.sorted == [id])
        events = recorded.withLock { $0 }
        let sortEvent = events.first { $0.name == "entry_sort_completed" }
        #expect(sortEvent?.parameters["mode"] == "stub")
        #expect(sortEvent?.parameters["items"] == "2")
        // Everything done, nothing outstanding.
        #expect(await queue.pendingCount == 0)
    }

    @Test("a sort that fails leaves the entry queued and says so")
    func sortFailureIsQueued() async {
        let service = StubEntryService()
        service.sortError = URLError(.timedOut)
        let queue = outbox(service)
        let recorded = Mutex([AnalyticsEvent]())
        let submission = EntrySubmission(
            entries: service, outbox: queue,
            analytics: { event in recorded.withLock { $0.append(event) } }
        )
        let id = UUID()
        _ = await submission.submit(request(id: id))

        await submission.finish(entryID: id, photoPaths: [])

        #expect(recorded.withLock { $0 }.contains { $0.name == "entry_sort_failed" })
        #expect(await queue.pendingCount == 1)
    }

    @Test("entry_saved carries the funnel's dimensions, including whether it was queued")
    func savedEventShape() async {
        let service = StubEntryService()
        let recorded = Mutex([AnalyticsEvent]())
        let submission = EntrySubmission(
            entries: service, outbox: outbox(service),
            analytics: { event in recorded.withLock { $0.append(event) } }
        )

        _ = await submission.submit(request(restaurantID: UUID(), photoPaths: ["/tmp/a.jpg"]))

        let event = recorded.withLock { $0 }.first { $0.name == "entry_saved" }
        #expect(event?.parameters["photo_count"] == "1")
        #expect(event?.parameters["has_place"] == "true")
        #expect(event?.parameters["score_count"] == "1")
        #expect(event?.parameters["visibility"] == "public")
        #expect(event?.parameters["seconds_from_open"] == "42")
        #expect(event?.parameters["queued"] == "false")
    }
}

/// A tiny lock-wrapped box, so a test's recorder is safe to call from any isolation.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
