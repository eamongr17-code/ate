import Foundation

/// Which draft, if any, an **open log sheet is currently holding** — so the §6.4 foreground retry
/// doesn't post a sitting out from under the person still editing it.
///
/// The defect this exists to prevent: resume a `needsPostRetry` draft into the sheet, background the
/// app, come back, and ``LogPostRetryRunner`` posts the sitting before the Post button is tapped.
/// The database survives that (client-side ids; a 23505 reads as success), but the funnel doesn't —
/// `log_posted` and `receipt_shown` both fire twice for one sitting, and those are the north-star
/// numbers. One sitting, one post, one pair of events.
///
/// Deliberately **in memory only**. A marker on disk would outlive the process that set it, and a
/// crashed sheet would strand a pending sitting forever — the precise failure §6.4 exists to stop.
/// Every degradation path here fails *open* (retry runs) rather than closed (retry never runs):
/// a lost marker costs at worst the duplicate-event bug we're fixing, a stuck marker would cost
/// someone their reviews.
public final class LogDraftCheckout: @unchecked Sendable {
    private let lock = NSLock()
    /// Draft id → the identity of the ticket holding it. Identity, not a reference: the registry
    /// must never keep a ticket (and its holder) alive.
    private var holders: [UUID: ObjectIdentifier] = [:]

    public init() {}

    /// Claims a draft for the caller. The claim lasts exactly as long as the returned ticket is
    /// held — including through an abnormal teardown, where nobody gets to run any cleanup and ARC
    /// releases it anyway.
    public func checkOut(_ draftID: UUID) -> LogDraftCheckoutTicket {
        let ticket = LogDraftCheckoutTicket(checkout: self, draftID: draftID)
        lock.withLock { holders[draftID] = ObjectIdentifier(ticket) }
        return ticket
    }

    public func isCheckedOut(_ draftID: UUID) -> Bool {
        lock.withLock { holders[draftID] != nil }
    }

    /// Released by the ticket. The identity check means a *superseded* ticket dying can't release
    /// the claim a newer one just took on the same draft.
    fileprivate func release(draftID: UUID, ticket: ObjectIdentifier) {
        lock.withLock {
            if holders[draftID] == ticket { holders[draftID] = nil }
        }
    }
}

/// A live claim on one draft. Hold it for as long as the draft is being edited; drop it to release.
///
/// There is no `release()` to forget: the claim ends when the ticket does. That is the whole design
/// — a sheet that is deallocated without ever running its dismissal path (swipe-dismissed, host
/// torn down, a crash inside the presentation) still hands the draft back.
public final class LogDraftCheckoutTicket: Sendable {
    private let checkout: LogDraftCheckout
    private let draftID: UUID

    fileprivate init(checkout: LogDraftCheckout, draftID: UUID) {
        self.checkout = checkout
        self.draftID = draftID
    }

    deinit {
        checkout.release(draftID: draftID, ticket: ObjectIdentifier(self))
    }
}
