import Foundation
import Testing
@testable import AteKit

private let tipo = EntryCard.Place(id: UUID(), name: "Tipo 00", address: "361 Little Bourke St")

private func card(_ status: EntrySortStatus, id: UUID = UUID(), place: EntryCard.Place? = tipo,
                  lines: Int = 1) -> EntryCard {
    EntryCard(
        id: id, authorID: UUID(), body: "The ragù 4.5.", restaurantID: place?.id, orderNumber: 142,
        sortStatus: status, createdAt: Date(timeIntervalSince1970: 1_789_000_000), place: place,
        items: (0..<lines).map { EntryCard.Item(reviewID: UUID(), dishID: UUID(), dishName: "Ragù",
                                                 score: Rating(exactly: 4.5), position: $0 + 1) }
    )
}

@Suite("Post holds on the sort, and the receipt enters whole")
struct PostHoldTests {

    @Test("a latch hands its value to a waiter already there, and to one that comes later")
    func latchDelivers() async {
        let latch = Latch<Int>()
        async let early = latch.value(before: .now + .seconds(5))
        try? await Task.sleep(for: .milliseconds(20))
        await latch.fulfil(7)
        await latch.fulfil(8)
        #expect(await early == 7)
        #expect(await latch.value(before: .now + .seconds(5)) == 7, "it arrives once")
    }

    @Test("a wait that reaches its deadline gives up with nothing, and the value still lands after")
    func latchDeadline() async {
        let latch = Latch<Int>()
        let started = ContinuousClock.now
        let missed = await latch.value(before: started + .milliseconds(60))
        #expect(missed == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        await latch.fulfil(3)
        #expect(await latch.value(before: .now) == 3, "giving up cancelled nothing")
    }

    @Test("a sort faster than the minimum still holds Posting… for the minimum")
    func holdsTheMinimum() async {
        let hold = PostHold(minimum: .milliseconds(150), maximum: .seconds(2))
        let latch = Latch<EntryCard?>()
        let sorted = card(.sorted)
        await latch.fulfil(sorted)
        let started = ContinuousClock.now
        let landed = await hold.wait(on: latch, from: started)
        #expect(ContinuousClock.now - started >= .milliseconds(150))
        #expect(landed == .some(sorted))
        #expect(await PostHold.outcome(landed) == .sorted)
    }

    @Test("a sort slower than the maximum lets the Summary come up without it")
    func givesUpAtTheMaximum() async {
        let hold = PostHold(minimum: .zero, maximum: .milliseconds(80))
        let latch = Latch<EntryCard?>()
        let started = ContinuousClock.now
        let landed = await hold.wait(on: latch, from: started)
        #expect(landed == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await PostHold.outcome(landed) == .late)
    }

    @Test("a sort that answers with nothing to print is its own outcome")
    @MainActor
    func unprinted() {
        #expect(PostHold.outcome(.some(nil)) == .unprinted, "the sort failed")
        #expect(PostHold.outcome(.some(card(.sorted, lines: 0))) == .unprinted, "no lines")
        #expect(PostHold.outcome(.some(card(.failed))) == .unprinted)
        #expect(PostHold.outcome(.some(card(.pending))) == .unprinted, "still pending is not printed")
    }

    @Test("the hold's milliseconds")
    func milliseconds() {
        let start = ContinuousClock.now
        #expect(PostHold.milliseconds(since: start, now: start + .milliseconds(1_234)) == 1_234)
        #expect(PostHold.milliseconds(since: start + .seconds(1), now: start) == 0)
    }

    @Test("the defaults: a beat of Posting…, never more than 3.5s")
    func defaults() {
        #expect(PostHold.standard.minimum == .milliseconds(700))
        #expect(PostHold.standard.maximum == .milliseconds(3500))
    }

    @Test("finish tells the hold the moment the sort answers, with the entry as it then stands")
    func finishReportsTheSort() async throws {
        let service = InMemoryEntryService()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let request = NewEntryRequest(
            id: UUID(), body: "Tagliatelle al ragù 4.5 was unreal.", restaurantID: tipo.id,
            photoPaths: [], createdAt: Date(), scoreCount: 1, secondsFromOpen: 12
        )
        guard case .saved = await submission.submit(request) else {
            Issue.record("the words should land")
            return
        }
        let latch = Latch<EntryCard?>()
        await submission.finish(entryID: request.id, photoPaths: [], sorted: { await latch.fulfil($0) })
        let heard = await latch.value(before: .now)
        let sorted = try #require(heard.flatMap { $0 })
        #expect(sorted.id == request.id)
        #expect(sorted.sortStatus == .sorted)
        #expect(sorted.items.map(\.dishName) == ["Tagliatelle al ragù"])
    }

    @Test("a sort whose entry cannot be read back reports nothing, rather than a stale row")
    func finishReportsNothing() async {
        let service = InMemoryEntryService()
        let outbox = EntryOutbox(entries: service, containerName: "Tests-\(UUID().uuidString)")
        let submission = EntrySubmission(entries: service, outbox: outbox)
        let latch = Latch<EntryCard?>()
        await submission.finish(entryID: UUID(), photoPaths: [], sorted: { await latch.fulfil($0) })
        let heard = await latch.value(before: .now)
        #expect(heard == .some(nil))
    }
}

@Suite("The Summary's receipt is on screen only once its shape is final")
@MainActor
struct SummaryReceiptTests {

    private func store(_ start: EntryCard, fetch: @escaping @Sendable (UUID) throws -> EntryCard) -> EntrySummaryStore {
        EntrySummaryStore(
            card: start, pollInterval: .zero, maxPolls: 3,
            actions: .init(fetch: { try fetch($0) }, correctPlace: { id, _ in card(.sorted, id: id) },
                           resort: { _ in })
        )
    }

    @Test("sorted inside the hold: the receipt is there from the first frame")
    func sortedArrivesWhole() {
        let summary = store(card(.sorted)) { _ in card(.sorted) }
        #expect(summary.showsReceipt)
        #expect(summary.phase == .printed)
    }

    @Test("still sorting: no receipt at all — never a skeleton that grows into one")
    func pendingShowsNothing() {
        let summary = store(card(.pending)) { _ in card(.pending) }
        #expect(summary.showsReceipt == false)
    }

    @Test("a failed or empty print shows no receipt, and offers the re-print")
    func stalledShowsNothing() async {
        let failed = store(card(.failed)) { _ in card(.failed) }
        #expect(failed.showsReceipt == false)
        #expect(failed.phase == .stalled)
        let empty = store(card(.pending, lines: 0)) { _ in card(.sorted, lines: 0) }
        await empty.watch()
        #expect(empty.phase == .stalled)
        #expect(empty.showsReceipt == false)
    }

    @Test("the sort's own answer prints it at once, and only for this entry")
    func adoptPrints() {
        let id = UUID()
        let summary = store(card(.pending, id: id)) { _ in card(.pending, id: id) }
        summary.adopt(card(.sorted))
        #expect(summary.showsReceipt == false, "another entry's row is not this receipt")
        summary.adopt(card(.sorted, id: id, lines: 3))
        #expect(summary.phase == .printed)
        #expect(summary.card.items.count == 3)
        summary.adopt(card(.sorted, id: id, lines: 1))
        #expect(summary.card.items.count == 3, "once printed, it never changes shape")
    }

    @Test("once printed, failed reads can never take the receipt back to stalled")
    func printedNeverStalls() async {
        let id = UUID()
        let summary = EntrySummaryStore(
            card: card(.pending, id: id), pollInterval: .milliseconds(5), maxPolls: 6,
            actions: .init(
                fetch: { _ in throw URLError(.notConnectedToInternet) },
                correctPlace: { id, _ in card(.sorted, id: id) },
                resort: { _ in }
            )
        )
        async let watching: Void = summary.watch()
        try? await Task.sleep(for: .milliseconds(12))
        summary.adopt(card(.sorted, id: id))
        await watching
        #expect(summary.phase == .printed, "every read after it failed, and the watch gave up")
        #expect(summary.showsReceipt)
    }

    @Test("a sort the latch heard fail offers the re-print at once, and a late print can't undo a print")
    func sortFailedStallsAtOnce() {
        let id = UUID()
        let summary = store(card(.pending, id: id)) { _ in card(.pending, id: id) }
        summary.sortFailed()
        #expect(summary.phase == .stalled)
        #expect(summary.showsReceipt == false)
        let printed = store(card(.sorted, id: id)) { _ in card(.sorted, id: id) }
        printed.sortFailed()
        #expect(printed.phase == .printed)
    }

    @Test("a poll that left before the sort landed cannot put the receipt back to waiting")
    func stalePollLoses() async {
        let id = UUID()
        let summary = EntrySummaryStore(
            card: card(.pending, id: id), pollInterval: .zero, maxPolls: 3,
            actions: .init(
                fetch: { _ in
                    try await Task.sleep(for: .milliseconds(80))
                    return card(.pending, id: id)
                },
                correctPlace: { id, _ in card(.sorted, id: id) },
                resort: { _ in }
            )
        )
        async let watching: Void = summary.watch()
        try? await Task.sleep(for: .milliseconds(20))
        summary.adopt(card(.sorted, id: id))
        await watching
        #expect(summary.phase == .printed)
        #expect(summary.showsReceipt)
    }
}

@Suite("The hold and the entrance are counted")
struct PostEventsTests {
    @Test("entry_post_held carries the outcome and how long the pill held")
    func postHeld() {
        let event = EntryEvents.postHeld(outcome: .late, milliseconds: 3517)
        #expect(event.name == "entry_post_held")
        #expect(event.parameters == ["outcome": "late", "ms": "3517"])
    }

    @Test("summary_receipt_entered carries how long the band stood empty")
    func receiptEntered() {
        let id = UUID()
        let event = EntryEvents.summaryReceiptEntered(entryID: id, waitMilliseconds: -5)
        #expect(event.name == "summary_receipt_entered")
        #expect(event.parameters == ["entry_id": id.uuidString.lowercased(), "wait_ms": "0"])
    }
}

@Suite("The one quiet ask for photos")
struct PhotoAccessAskTests {
    @Test("asked only when never asked, and only over a printed receipt")
    func onlyOnce() {
        #expect(PhotoAccessAsk.shouldAsk(canAsk: true, isPrinted: true, isPresentingOther: false))
        #expect(PhotoAccessAsk.shouldAsk(canAsk: false, isPrinted: true, isPresentingOther: false) == false,
                "asked before, or refused")
        #expect(PhotoAccessAsk.shouldAsk(canAsk: true, isPrinted: false, isPresentingOther: false) == false,
                "never over a wait")
        #expect(PhotoAccessAsk.shouldAsk(canAsk: true, isPrinted: true, isPresentingOther: true) == false,
                "never over the share sheet or the place sheet")
    }

    @Test("its answer is counted")
    func counted() {
        let event = SuggestionEvents.photoAccessAsked(granted: false)
        #expect(event.name == "photo_access_asked")
        #expect(event.parameters == ["source": "summary", "granted": "false"])
    }
}
