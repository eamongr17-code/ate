import Foundation

/// **What the entry page does when its read fails** (round 4). The page is often drawn from a card
/// it was handed, so a failed read is no longer always "nothing on the page".
public enum EntryRefreshFailure: Equatable, Sendable {
    /// The read was cut short (the page left the screen). Nothing to say; it runs again on return.
    case ignore
    /// Deleted, or its author blocked: the page says so **even over a card** — a stale card must
    /// never look live, bookmark, share and corrections and all.
    case gone
    /// Couldn't reach Ate, with nothing on the page: the retry state.
    case unreachable
    /// Couldn't reach Ate under a card: keep showing it, and try again quietly.
    case keepCardAndRetry

    public init(_ error: any Error, hasCard: Bool) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            self = .ignore
        } else if LoadFailure(error) == .gone {
            self = .gone
        } else {
            self = hasCard ? .keepCardAndRetry : .unreachable
        }
    }
}

/// **Bookmarks the page has heard about, kept over older reads** (round 4, QA c). A save broadcast
/// before the page's first refresh answers must not be undone by a row read before it landed:
/// every read is laid under the latest known state of each dish's bookmark.
public struct EntrySaveEdits: Sendable, Equatable {
    private var saved: [UUID: Bool] = [:]

    public init() {}

    public mutating func note(dishID: UUID, isSaved: Bool) { saved[dishID] = isSaved }

    public var isEmpty: Bool { saved.isEmpty }

    /// The read, with every bookmark the page has heard about written back over it.
    public func applied(to card: EntryCard) -> EntryCard {
        saved.reduce(card) { card, edit in
            card.items.contains { $0.dishID == edit.key && $0.saved != edit.value }
                ? card.settingSaved(dishID: edit.key, to: edit.value)
                : card
        }
    }
}
