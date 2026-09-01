import Foundation

/// What a foreground retry did, when it did anything.
public struct LogPostRetryResult: Sendable, Hashable {
    /// The rows that are now in the database — freshly inserted, or already there from the attempt
    /// that "failed" after committing.
    public let reviewIDs: [UUID]
    public let restaurantName: String
    public let dishCount: Int
    /// True when the batch was already complete server-side and this run only cleaned up the draft.
    public let wasAlreadyPosted: Bool

    public init(reviewIDs: [UUID], restaurantName: String, dishCount: Int, wasAlreadyPosted: Bool) {
        self.reviewIDs = reviewIDs
        self.restaurantName = restaurantName
        self.dishCount = dishCount
        self.wasAlreadyPosted = wasAlreadyPosted
    }
}

/// §6.4's other half: **"Leave with failed post: draft persists; one-shot auto-retry next
/// foreground."**
///
/// Writing the flag was never the feature — consuming it is. A sitting whose post failed is a set of
/// opinions the person believes they published; without this, the flag is a note nobody reads and
/// those reviews never exist. The app attaches this to its scene lifecycle (see
/// `PendingLogPostRetry` in the App target) so it runs once per foreground.
///
/// Safe to call spuriously, which is the point: it no-ops with no draft, with a draft that isn't
/// pending, and while a run is already in flight. Retrying is safe because the ids are the client's
/// — an insert that already landed comes back as a 23505 that ``ReviewPostingService`` reads as the
/// success it is, so the worst case is a wasted round trip, never a duplicate review.
public actor LogPostRetryRunner {
    private let drafts: any LogDraftStoring
    private let poster: any ReviewPosting
    private let currentUserID: @Sendable () async throws -> UUID
    private let telemetry: any LogTelemetrySink

    private var isRunning = false

    public init(
        drafts: any LogDraftStoring,
        poster: any ReviewPosting,
        currentUserID: @escaping @Sendable () async throws -> UUID,
        telemetry: any LogTelemetrySink = NoOpLogTelemetrySink()
    ) {
        self.drafts = drafts
        self.poster = poster
        self.currentUserID = currentUserID
        self.telemetry = telemetry
    }

    /// Returns the result when a pending sitting was completed, `nil` when there was nothing to do
    /// or the retry failed again (in which case the draft and its flag are left exactly as they
    /// were, ready for the next foreground).
    @discardableResult
    public func run(now: Date = Date()) async -> LogPostRetryResult? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        guard let draft = drafts.load(), draft.needsPostRetry else { return nil }
        let sitting = draft.sitting
        let attempt = draft.postAttempts + 1

        do {
            let reviewerID = try await currentUserID()
            let rows = SittingPost.rows(
                from: sitting,
                reviewerID: reviewerID,
                alreadyPosted: Set(draft.postedReviewIDs)
            )

            // Nothing left to send: the previous attempt landed every row and only the local draft
            // was left behind. Clearing it *is* the fix.
            guard !rows.isEmpty else {
                drafts.clear(draftID: draft.id)
                return LogPostRetryResult(
                    reviewIDs: draft.postedReviewIDs,
                    restaurantName: sitting.restaurant.name,
                    dishCount: sitting.dishes.count,
                    wasAlreadyPosted: true
                )
            }

            let inserted = try await poster.post(rows)
            let reviewIDs = draft.postedReviewIDs + inserted.map(\.id)

            // The funnel's `log_posted` never fired for this sitting — the first attempt failed. It
            // fires now, with the honest seconds-from-open (which includes the time spent away).
            telemetry.send(.posted(
                dishCount: sitting.dishes.count,
                hasNote: sitting.hasNote,
                hasPhoto: inserted.contains { $0.hasPhoto },
                secondsFromOpen: sitting.secondsFromOpen(now: now)
            ))
            drafts.clear(draftID: draft.id)

            return LogPostRetryResult(
                reviewIDs: reviewIDs,
                restaurantName: sitting.restaurant.name,
                dishCount: sitting.dishes.count,
                wasAlreadyPosted: false
            )
        } catch {
            // Keep the draft, keep the flag, count the attempt. Next foreground tries again; the
            // 7-day expiry is what eventually stops it.
            var kept = draft
            kept.postAttempts = attempt
            drafts.save(LogDraftPolicy.merged(existing: drafts.load(), updated: kept))
            telemetry.send(.postFailed(
                reason: LogPostFailureReason.of(error),
                dishCount: sitting.dishes.count,
                attempt: attempt
            ))
            return nil
        }
    }
}
