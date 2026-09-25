import Foundation

/// **The composer's score slider, as a state machine** — when it is open, on which pill, and when it
/// goes away.
///
/// Pure, because the ways it went wrong are all about *time* and *order*, which a screenshot never
/// shows: a panel that stayed up because the finger's drag was cancelled rather than lifted, a tap
/// on the words that had no path to close it at all, and — once a lift waits half a second before
/// closing — a stale close landing on a panel that has since been reopened on another pill.
///
/// The rules:
/// - **Open** on a pill (the Score key's new one, or a pill tapped). Opening again moves it.
/// - **Slide** changes the value live; the pill in the words follows it (the host writes it back).
/// - **Finish** (the finger lifts) leaves the panel up for ``settleDelay``, then closes it — unless
///   anything happened in between. Every finish is numbered, and only the latest may close.
/// - **Dismiss** closes it now, from any state: a tap anywhere outside the panel, any other key,
///   Done, dictation. The value is already in the words, so there is nothing to commit.
public struct ScoreSlider: Equatable, Sendable {
    /// What the open panel is showing.
    public struct Session: Equatable, Sendable, Identifiable {
        /// The token being scored.
        public let id: UUID
        /// The words just before the pill, as the panel's title.
        public var dishName: String
        public var rating: Rating?
        /// The finger has lifted and the panel is on its way out.
        public var isSettling: Bool
    }

    /// How long the panel stays up after the finger lifts, so the number that was set is seen.
    public static let settleDelay: Duration = .milliseconds(500)

    public private(set) var session: Session?
    /// Bumped by every finish. A settle only closes the panel if it carries the latest one.
    private var finishCount = 0

    public init() {}

    public var isOpen: Bool { session != nil }

    /// Opens the panel on a pill — or moves it there, cancelling any close already on its way.
    public mutating func open(tokenID: UUID, dishName: String, rating: Rating?) {
        finishCount += 1
        session = Session(id: tokenID, dishName: dishName, rating: rating, isSettling: false)
    }

    /// The finger moved. Returns true when the value actually changed, so the host rewrites the pill
    /// once per half-step and not once per point of travel. Touching the panel again while it is
    /// settling keeps it up.
    @discardableResult
    public mutating func slide(to rating: Rating) -> Bool {
        guard var current = session else { return false }
        if current.isSettling {
            finishCount += 1
            current.isSettling = false
        }
        let changed = current.rating != rating
        current.rating = rating
        session = current
        return changed
    }

    /// The finger lifted on `rating`. Returns the ticket the host hands back to ``settle(_:)`` after
    /// ``settleDelay``; `nil` if there is no panel to settle.
    public mutating func finish(at rating: Rating) -> Int? {
        guard session != nil else { return nil }
        slide(to: rating)
        finishCount += 1
        session?.isSettling = true
        return finishCount
    }

    /// The delay after a finish ran out. Closes the panel only if nothing has happened since that
    /// finish — no new slide, no reopen, no other finish. Returns true if it closed.
    @discardableResult
    public mutating func settle(_ ticket: Int) -> Bool {
        guard ticket == finishCount, session?.isSettling == true else { return false }
        session = nil
        return true
    }

    /// Closes the panel now. Always works, from any state.
    public mutating func dismiss() {
        finishCount += 1
        session = nil
    }

    /// The words changed under the panel. If the pill it is scoring has gone — deleted, undone — the
    /// panel has nothing left to score and closes.
    @discardableResult
    public mutating func retain(onlyIfPresentIn tokenIDs: Set<UUID>) -> Bool {
        guard let session, tokenIDs.contains(session.id) == false else { return false }
        dismiss()
        return true
    }
}
