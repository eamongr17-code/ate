import Foundation
import Testing
@testable import AteKit

/// An entry service whose insert hangs (a slow connection) until the test lets it go, and which
/// counts the creates the outbox makes.
private final class SlowEntryService: EntryService, TestFake, @unchecked Sendable {
    private let lock = NSLock()
    private var creates = 0
    var created: Int { lock.withLock { creates } }

    func authorID() async throws -> UUID { ViewerProfile.preview.id }

    func insert(_ entry: NewEntry) async throws {
        try await Task.sleep(for: .seconds(30))
    }

    @discardableResult
    func create(_ entry: NewEntry) async throws -> EntryCard {
        lock.withLock { creates += 1 }
        return EntryCard(
            id: entry.id, authorID: entry.authorID, body: entry.body, orderNumber: 1, createdAt: entry.createdAt
        )
    }

    func sort(entryID: UUID, force: Bool, tagTokens: [TagToken]) async throws -> SortOutcome {
        SortOutcome(
            entryID: entryID, status: .sorted, mode: "stub", itemCount: 1, restaurantID: nil, didAttachPlace: false
        )
    }
}

private let tipo = EntryCard.Place(id: UUID(), name: "Tipo 00")

private func card(_ status: EntrySortStatus, id: UUID, lines: Int = 1) -> EntryCard {
    EntryCard(
        id: id, authorID: UUID(), body: "The ragù 4.5.", restaurantID: tipo.id, orderNumber: 142,
        sortStatus: status, createdAt: Date(timeIntervalSince1970: 1_789_000_000), place: tipo,
        items: (0..<lines).map { EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Ragù",
                                                 score: Rating(exactly: 4.5), position: $0 + 1) }
    )
}

@Suite("Receipt fallback: saved, and finished in the background")
struct ReceiptFallbackTests {
    @Test("each wait says the right line, and only an unfinished one offers Try again")
    func lines() {
        #expect(ReceiptFallback.on(.sorting, isQueued: false, isSlow: false) == nil, "a short wait says nothing")
        #expect(ReceiptFallback.on(.sorting, isQueued: false, isSlow: true) == .slow)
        #expect(ReceiptFallback.on(.stalled, isQueued: false, isSlow: false) == .unfinished)
        #expect(ReceiptFallback.on(.sorting, isQueued: true, isSlow: false) == .offline)
        #expect(ReceiptFallback.on(.stalled, isQueued: true, isSlow: true) == .offline)
        #expect(ReceiptFallback.on(.printed, isQueued: false, isSlow: true) == nil)
        #expect(ReceiptFallback.on(.needsPlace, isQueued: false, isSlow: true) == nil)
        #expect(ReceiptFallback.unfinished.offersRetry)
        #expect(ReceiptFallback.offline.offersRetry == false, "a retry offline could not work")
        #expect(ReceiptFallback.slow.offersRetry == false)
    }

    @Test("no line says print: people read it as paper (Eamon, 18 Oct)")
    func neverPrint() {
        let lines = ReceiptFallback.allCases.map(\.message)
            + [ReceiptFallback.entryPageMessage, ReceiptFallback.retryTitle]
        for line in lines {
            #expect(line.lowercased().contains("print") == false, "\(line)")
        }
        for kind in ReceiptFallback.allCases {
            #expect(kind.message.contains("close this"), "every sheet line says it can be closed")
        }
    }

    @Test("a save that runs past its patience is queued, not waited on, and keeps its place")
    func slowInsertQueues() async throws {
        let service = SlowEntryService()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox, insertPatience: .milliseconds(50))
        let request = NewEntryRequest(
            id: UUID(), body: "The ragù 4.5.", restaurantID: tipo.id, photoPaths: [],
            createdAt: Date(), scoreCount: 1, secondsFromOpen: 10, placeName: "Tipo 00"
        )
        let started = ContinuousClock.now
        let result = await submission.submit(request)
        #expect(ContinuousClock.now - started < .seconds(5), "the hanging insert was not waited out")
        guard case .queued(let card) = result else {
            Issue.record("expected queued, got \(result)")
            return
        }
        #expect(card.place?.name == "Tipo 00", "the stand-in still says where it was")
        let queued = try #require(await outbox.queued(entryID: request.id))
        #expect(queued.hasInserted == false)
        #expect(queued.needsSort)
    }

    @Test("the outbox leaves an entry the composer is finishing alone, then works it")
    func heldIsSkipped() async throws {
        let service = SlowEntryService()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let entry = NewEntry(id: UUID(), authorID: ViewerProfile.preview.id, body: "Ragù 4.5.",
                             restaurantID: nil, createdAt: Date())
        await outbox.enqueue(QueuedEntry(entry: QueuedInsert(entry), pendingPhotos: [], hasInserted: false))
        await outbox.hold(entryID: entry.id)
        _ = await outbox.run()
        #expect(service.created == 0, "held: no second writer beside the composer")
        await outbox.release(entryID: entry.id)
        let landed = await outbox.run()
        #expect(service.created == 1)
        #expect(landed == [entry.id])
    }

    @Test("a queued receipt does not poll a server that has not got it, and takes the row once it lands")
    @MainActor
    func queuedThenLanded() async {
        let id = UUID()
        let landed = LockedFlag()
        let summary = EntrySummaryStore(
            card: card(.pending, id: id, lines: 0), pollInterval: .zero, maxPolls: 3, isQueued: true,
            actions: .init(
                fetch: { _ in
                    guard landed.value else { throw URLError(.notConnectedToInternet) }
                    return card(.sorted, id: id)
                },
                correctPlace: { _, _ in card(.sorted, id: id) },
                resort: { _ in Issue.record("no re-sort while it is only on this phone") }
            )
        )
        await summary.watch()
        #expect(summary.phase == .sorting, "no give-up: nothing was asked")
        #expect(ReceiptFallback.on(summary.phase, isQueued: summary.isQueued, isSlow: true) == .offline)
        await summary.recheck()
        #expect(summary.isQueued, "a read that fails changes nothing")
        landed.set()
        await summary.recheck()
        #expect(summary.isQueued == false)
        #expect(summary.phase == .printed)
    }

    @Test("an unfinished receipt finishes from the background without Try again")
    @MainActor
    func stalledThenFinished() async {
        let id = UUID()
        let summary = EntrySummaryStore(
            card: card(.failed, id: id, lines: 0), pollInterval: .zero,
            actions: .init(fetch: { _ in card(.sorted, id: id) }, correctPlace: { _, _ in card(.sorted, id: id) },
                           resort: { _ in })
        )
        #expect(summary.phase == .stalled)
        await summary.recheck()
        #expect(summary.phase == .printed)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
