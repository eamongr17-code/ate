import AteKit
import SwiftUI

/// Where an entry is opened from — and, when it was opened from a card, the card itself.
///
/// The card is what makes the page instant: a Journal, Feed, Profile or Place slip already holds the
/// whole row, so the page draws from it on the push and only *refreshes* from the server. It is a
/// payload, not part of the route's identity — two pushes of one entry are the same route to
/// `NavigationStack` and `path.contains`, whatever snapshot each carried.
struct EntryRoute: Hashable, Identifiable {
    let entryID: UUID
    var card: EntryCard?

    init(entryID: UUID, card: EntryCard? = nil) {
        self.entryID = entryID
        self.card = card
    }

    /// Opened from a card: the page draws from it at once.
    init(_ card: EntryCard) {
        self.init(entryID: card.id, card: card)
    }

    var id: UUID { entryID }

    static func == (lhs: EntryRoute, rhs: EntryRoute) -> Bool { lhs.entryID == rhs.entryID }
    func hash(into hasher: inout Hasher) { hasher.combine(entryID) }
}

extension Route {
    /// The entry a card opens, carrying the card so the page never starts blank.
    static func entry(_ card: EntryCard) -> Route { .entry(EntryRoute(card)) }
}
