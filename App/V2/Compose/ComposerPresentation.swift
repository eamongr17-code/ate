import AteKit
import Foundation

/// How the composer was opened, and with what. One value, so a door can never present without the
/// thing it was opened with.
struct ComposerPresentation: Identifiable, Hashable {
    /// Which affordance opened it. A closed set: an unlabelled entry point reads as zero in the
    /// funnel, and `entry_composer_opened(source:)` is the first step of it.
    enum Origin: String, Hashable {
        case tabBar = "tab_bar"
        case journalEmpty = "journal_empty"
        case entryEdit = "entry_edit"
        case photoSuggestion = "photo_suggestion"
        case onboarding
    }

    let id = UUID()
    let origin: Origin
    /// Photos the composer opens holding — a cluster picked on `Suggestions`. Identifiers, not
    /// images: the composer stages them itself, the same way the picker's are staged. Design rule 8
    /// is untouched — a photo brings its pixels and nothing else, never a place.
    var assetIdentifiers: [String] = []
    /// A place the person TAPPED before the composer opened — a nearby chip on a photo sitting. The
    /// composer opens with it on the Place key. Never set from a location alone (design rule 8).
    var place: PlaceRef?
    /// Set when the composer opens on words that already exist. Done then **rewrites that entry's
    /// body** rather than writing a new one — the one path in the app that touches `entries.body`
    /// after it has landed, and it is the author's own hand.
    var editing: EditingEntry?
    /// **Ate with**: the tag (`entry_companions.id`) being answered. Set, the sheet opens the
    /// prefilled scoring face (``AteWithRespondFace``) instead of the words — the tagger's place and
    /// dishes, read live — and its tick posts the person's OWN entry (`respond_ate_with`). `origin`
    /// is not read on this path.
    var respondingTo: UUID?

    /// The entry being edited, carried whole so the composer does not have to fetch it back.
    struct EditingEntry: Hashable {
        let id: UUID
        let body: String
        let restaurantID: UUID?
        let placeName: String?
        /// The words with their score pills and tag chips rebuilt from the receipt's own lines
        /// (`EntryBodyTokens`: the server's offsets, verified) — not plain digits.
        var composition: EntryComposition
        /// The photos the entry has, by position — loaded into the composer so they can be kept,
        /// removed, or added to.
        var photos: [EntryCard.Photo] = []
        /// The receipt's lines, so a chip deleted during the edit clears its own line's tag.
        var items: [EntryCard.Item] = []
        /// Who it was eaten with, as the author sees them (pending included) — the With key opens
        /// holding them, and Done sends the difference.
        var companions: [EntryCompanion] = []
    }

    /// Answering an "Ate with" tag: the composer, prefilled from the tag.
    static func respond(to companionID: UUID) -> ComposerPresentation {
        ComposerPresentation(origin: .tabBar, respondingTo: companionID)
    }

    static func edit(_ card: EntryCard) -> ComposerPresentation {
        ComposerPresentation(
            origin: .entryEdit,
            editing: EditingEntry(
                id: card.id,
                body: card.body,
                restaurantID: card.restaurantID,
                placeName: card.place?.name,
                composition: EntryBodyTokens.composition(for: card),
                photos: card.photos.sorted { $0.position < $1.position },
                items: card.items,
                companions: card.companions
            )
        )
    }
}
