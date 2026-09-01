import Foundation
import Testing

@testable import AteKit

/// §6.4's failed-post recovery: the flag must survive every ordinary save, and something must
/// actually consume it. Both halves are asserted here, because a flag nobody reads and a flag that
/// gets erased are the same bug from the person's side — reviews they believe they posted, gone.
@Suite("Failed-post retry (§6.4)")
struct LogPostRetryTests {
    private static let restaurant = SittingRestaurant(
        id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
        name: "Chin Chin",
        suburb: "Melbourne"
    )
    private static let reviewer = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    private func ratedSitting(dishCount: Int = 2) -> SittingState {
        var state = SittingState(restaurant: Self.restaurant)
        for index in 0..<dishCount {
            state.add(dishID: UUID(), dishName: "Dish \(index)")
            state.setScore(Rating(rounding: 4), for: state.dishes[index].id)
        }
        return state
    }

    /// Records what it was asked to post, and can be told to fail.
    private final class FakePoster: ReviewPosting, @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[NewReview]] = []
        private let failure: (any Error)?

        init(failure: (any Error)? = nil) {
            self.failure = failure
        }

        var sentBatches: [[NewReview]] { lock.withLock { batches } }

        func post(_ rows: [NewReview]) async throws -> [Review] {
            lock.withLock { batches.append(rows) }
            if let failure { throw failure }
            let now = Date()
            return rows.map {
                Review(
                    id: $0.id,
                    reviewerID: $0.reviewerID,
                    dishID: $0.dishID,
                    restaurantID: $0.restaurantID,
                    score: $0.score,
                    note: $0.note,
                    photoURLString: $0.photoURLString,
                    createdAt: now,
                    updatedAt: now
                )
            }
        }
    }

    private func runner(
        drafts: any LogDraftStoring,
        poster: any ReviewPosting,
        telemetry: any LogTelemetrySink = NoOpLogTelemetrySink(),
        checkout: LogDraftCheckout = LogDraftCheckout()
    ) -> LogPostRetryRunner {
        LogPostRetryRunner(
            drafts: drafts,
            poster: poster,
            currentUserID: { Self.reviewer },
            telemetry: telemetry,
            checkout: checkout
        )
    }

    // MARK: - The flag must not be downgraded

    @Test("an ordinary 'save draft' after a failed post does NOT clear the retry flag")
    func ordinarySaveKeepsTheFlag() throws {
        let sitting = ratedSitting()
        let pending = LogDraft(sitting: sitting, needsPostRetry: true, postAttempts: 1)

        // Exactly the Cancel → "Save draft" path: same draft id, same sitting, no idea a post failed.
        let ordinarySave = LogDraft(id: pending.id, sitting: sitting, savedAt: Date())
        let merged = LogDraftPolicy.merged(existing: pending, updated: ordinarySave)

        #expect(merged.needsPostRetry, "the retry flag is sticky until the post succeeds")
        #expect(merged.postAttempts == 1, "the attempt count is monotonic")
    }

    @Test("rows that already landed are never forgotten by a later save")
    func postedIDsSurviveASave() {
        let sitting = ratedSitting()
        let landed = sitting.dishes[0].id
        let pending = LogDraft(sitting: sitting, postedReviewIDs: [landed], needsPostRetry: true)
        let ordinarySave = LogDraft(id: pending.id, sitting: sitting)

        let merged = LogDraftPolicy.merged(existing: pending, updated: ordinarySave)
        #expect(merged.postedReviewIDs == [landed], "forgetting a landed row means posting it twice")
    }

    @Test("a different sitting replaces the draft outright — stickiness is per draft, not global")
    func aNewSittingIsNotHauntedByTheOldOne() {
        let pending = LogDraft(sitting: ratedSitting(), needsPostRetry: true, postAttempts: 2)
        let fresh = LogDraft(sitting: ratedSitting(dishCount: 1))

        let merged = LogDraftPolicy.merged(existing: pending, updated: fresh)
        #expect(merged.needsPostRetry == false)
        #expect(merged.postAttempts == 0)
        #expect(merged.id == fresh.id)
    }

    // MARK: - ...and the store is what enforces that, not the caller

    @Test("a store save can't downgrade the retry flag, however the caller phrases it")
    func storeSaveEnforcesThePolicy() throws {
        let sitting = ratedSitting()
        let landed = sitting.dishes[0].id
        let pending = LogDraft(
            sitting: sitting,
            postedReviewIDs: [landed],
            needsPostRetry: true,
            postAttempts: 2
        )
        let store = InMemoryLogDraftStore()
        store.save(pending)

        // The bypass this guards: a future call site that writes a draft without knowing a post
        // failed. It doesn't have to know — the store applies the policy.
        store.save(LogDraft(id: pending.id, sitting: sitting, savedAt: Date()))

        let stored = try #require(store.load())
        #expect(stored.needsPostRetry, "the flag survives a save that knew nothing about it")
        #expect(stored.postAttempts == 2, "the attempt count is monotonic below the seam")
        #expect(stored.postedReviewIDs == [landed], "a landed row is never forgotten by a save")
    }

    @Test("the file store enforces it too — the policy is a property of the seam, not one class")
    func fileStoreEnforcesThePolicy() throws {
        let directory = URL.temporaryDirectory.appending(path: "ate-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileLogDraftStore(
            fileURL: directory.appending(path: "draft.json"),
            photoDirectory: directory.appending(path: "photos")
        )
        let sitting = ratedSitting()
        let pending = LogDraft(sitting: sitting, needsPostRetry: true, postAttempts: 1)

        store.save(pending)
        store.save(LogDraft(id: pending.id, sitting: sitting, savedAt: Date()))

        let stored = try #require(store.load())
        #expect(stored.needsPostRetry)
        #expect(stored.postAttempts == 1)
    }

    @Test("a save of a different sitting still replaces the draft outright")
    func storeSaveReplacesADifferentSitting() throws {
        let store = InMemoryLogDraftStore()
        store.save(LogDraft(sitting: ratedSitting(), needsPostRetry: true, postAttempts: 2))
        let fresh = LogDraft(sitting: ratedSitting(dishCount: 1))
        store.save(fresh)

        let stored = try #require(store.load())
        #expect(stored.id == fresh.id)
        #expect(stored.needsPostRetry == false, "stickiness is per draft, not a permanent condition")
    }

    // MARK: - The flag must be consumed

    @Test("the foreground retry posts the pending sitting once and clears the draft")
    func retryPostsAndClears() async throws {
        let sitting = ratedSitting()
        let store = InMemoryLogDraftStore(draft: LogDraft(sitting: sitting, needsPostRetry: true))
        let poster = FakePoster()
        let events = LogEventLog()

        let result = try #require(await runner(drafts: store, poster: poster, telemetry: events).run())

        #expect(poster.sentBatches.count == 1, "ONE batch, not one insert per dish")
        #expect(poster.sentBatches[0].map(\.id) == sitting.dishes.map(\.id))
        #expect(result.reviewIDs == sitting.dishes.map(\.id))
        #expect(result.wasAlreadyPosted == false)
        #expect(store.load() == nil, "a posted sitting is no longer a draft")
        // The funnel's log_posted never fired for this sitting; it fires now, not never.
        #expect(events.names.contains("log_posted"))
    }

    @Test("a second foreground after a successful retry does nothing at all")
    func retryIsOneShot() async {
        let store = InMemoryLogDraftStore(draft: LogDraft(sitting: ratedSitting(), needsPostRetry: true))
        let poster = FakePoster()
        let runner = runner(drafts: store, poster: poster)

        _ = await runner.run()
        let second = await runner.run()

        #expect(second == nil)
        #expect(poster.sentBatches.count == 1)
    }

    @Test("a draft with no pending post is left alone")
    func ignoresOrdinaryDrafts() async {
        let store = InMemoryLogDraftStore(draft: LogDraft(sitting: ratedSitting()))
        let poster = FakePoster()

        #expect(await runner(drafts: store, poster: poster).run() == nil)
        #expect(poster.sentBatches.isEmpty)
        #expect(store.load() != nil, "an ordinary draft is still resumable")
    }

    @Test("no draft at all is a no-op, not a round trip")
    func ignoresNoDraft() async {
        let poster = FakePoster()
        #expect(await runner(drafts: InMemoryLogDraftStore(), poster: poster).run() == nil)
        #expect(poster.sentBatches.isEmpty)
    }

    @Test("a batch that already landed sends nothing and just clears the draft")
    func idempotentAgainstAnAlreadyPostedBatch() async throws {
        // The nastiest shape of §6.4: the insert committed, the response never arrived.
        let sitting = ratedSitting()
        let store = InMemoryLogDraftStore(draft: LogDraft(
            sitting: sitting,
            postedReviewIDs: sitting.dishes.map(\.id),
            needsPostRetry: true
        ))
        let poster = FakePoster()

        let result = try #require(await runner(drafts: store, poster: poster).run())

        #expect(poster.sentBatches.isEmpty, "nothing left to send — re-posting would be the duplicate")
        #expect(result.wasAlreadyPosted)
        #expect(result.reviewIDs == sitting.dishes.map(\.id))
        #expect(store.load() == nil)
    }

    @Test("a retry that fails again keeps the draft, the flag, and counts the attempt")
    func failureKeepsEverything() async throws {
        let store = InMemoryLogDraftStore(draft: LogDraft(
            sitting: ratedSitting(),
            needsPostRetry: true,
            postAttempts: 1
        ))
        let events = LogEventLog()
        let poster = FakePoster(failure: URLError(.notConnectedToInternet))

        let result = await runner(drafts: store, poster: poster, telemetry: events).run()

        #expect(result == nil)
        let kept = try #require(store.load())
        #expect(kept.needsPostRetry, "still pending — the next foreground tries again")
        #expect(kept.postAttempts == 2)
        #expect(events.parameters(of: "log_post_failed")?["reason"] == "offline")
        #expect(events.parameters(of: "log_post_failed")?["attempt"] == "2")
    }

    // MARK: - ...but not out from under an open sheet

    @Test("a draft the open sheet is holding is left alone — one sitting, one log_posted")
    func skipsACheckedOutDraft() async throws {
        let draft = LogDraft(sitting: ratedSitting(), needsPostRetry: true)
        let store = InMemoryLogDraftStore(draft: draft)
        let poster = FakePoster()
        let checkout = LogDraftCheckout()
        let events = LogEventLog()

        let ticket = checkout.checkOut(draft.id)
        let result = await runner(
            drafts: store,
            poster: poster,
            telemetry: events,
            checkout: checkout
        ).run()

        #expect(result == nil)
        #expect(poster.sentBatches.isEmpty, "the person's own Post button is the one that counts")
        #expect(events.names.isEmpty, "no log_posted: firing it here would double-count the sitting")
        #expect(store.load() != nil, "the draft stays exactly as the sheet left it")
        withExtendedLifetime(ticket) {}
    }

    @Test("another sitting's draft is not blocked by an unrelated checkout")
    func onlyTheCheckedOutDraftIsSkipped() async throws {
        let store = InMemoryLogDraftStore(draft: LogDraft(sitting: ratedSitting(), needsPostRetry: true))
        let poster = FakePoster()
        let checkout = LogDraftCheckout()

        let ticket = checkout.checkOut(UUID())
        let result = await runner(drafts: store, poster: poster, checkout: checkout).run()

        #expect(result != nil)
        #expect(poster.sentBatches.count == 1)
        withExtendedLifetime(ticket) {}
    }

    @Test("once the sheet closes, the next foreground picks the draft back up")
    func proceedsAfterTheCheckoutIsReleased() async throws {
        let draft = LogDraft(sitting: ratedSitting(), needsPostRetry: true)
        let store = InMemoryLogDraftStore(draft: draft)
        let poster = FakePoster()
        let checkout = LogDraftCheckout()
        let runner = runner(drafts: store, poster: poster, checkout: checkout)

        var ticket: LogDraftCheckoutTicket? = checkout.checkOut(draft.id)
        #expect(await runner.run() == nil)

        ticket = nil  // the sheet dismissed
        #expect(ticket == nil)
        #expect(checkout.isCheckedOut(draft.id) == false)

        let result = try #require(await runner.run())
        #expect(result.reviewIDs.count == 2)
        #expect(store.load() == nil)
    }

    @Test("a sheet torn down without cleanup does not strand the draft forever")
    func abnormalTeardownReleasesTheCheckout() async throws {
        let draft = LogDraft(sitting: ratedSitting(), needsPostRetry: true)
        let checkout = LogDraftCheckout()

        // No `release()` call anywhere: the claim ends with the object that held it, which is what
        // a swipe-dismissed (or crashed) sheet does to its session model.
        do {
            let holder = SheetLikeHolder(ticket: checkout.checkOut(draft.id))
            #expect(checkout.isCheckedOut(draft.id))
            withExtendedLifetime(holder) {}
        }

        #expect(checkout.isCheckedOut(draft.id) == false, "a dead holder can't block §6.4 forever")

        let store = InMemoryLogDraftStore(draft: draft)
        let poster = FakePoster()
        #expect(await runner(drafts: store, poster: poster, checkout: checkout).run() != nil)
        #expect(poster.sentBatches.count == 1)
    }

    @Test("a superseded ticket dying does not release the claim that replaced it")
    func aStaleTicketCannotReleaseANewerClaim() {
        let draftID = UUID()
        let checkout = LogDraftCheckout()

        // The resume path: the Continue row holds the draft, then the restored session takes it.
        var offered: LogDraftCheckoutTicket? = checkout.checkOut(draftID)
        let session = checkout.checkOut(draftID)
        offered = nil

        #expect(offered == nil)
        #expect(checkout.isCheckedOut(draftID), "the session still has it")
        withExtendedLifetime(session) {}
    }
}

/// Stands in for the session model: something that merely *holds* a ticket and is then dropped
/// without anyone running a teardown path.
private final class SheetLikeHolder {
    let ticket: LogDraftCheckoutTicket

    init(ticket: LogDraftCheckoutTicket) {
        self.ticket = ticket
    }
}

/// Collects ``LogEvent``s so the funnel is asserted rather than eyeballed in a dashboard later.
final class LogEventLog: LogTelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LogEvent] = []

    var all: [LogEvent] { lock.withLock { events } }
    var names: [String] { all.map(\.name) }

    func send(_ event: LogEvent) {
        lock.withLock { events.append(event) }
    }

    func parameters(of name: String) -> [String: String]? {
        all.first { $0.name == name }?.parameters
    }
}
