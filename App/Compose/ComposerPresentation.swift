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
    }

    let id = UUID()
    let origin: Origin
    /// Photos the composer opens holding — a cluster picked on `Suggestions`. Identifiers, not
    /// images: the composer stages them itself, the same way the picker's are staged. Design rule 8
    /// is untouched — a photo brings its pixels and nothing else, never a place.
    var assetIdentifiers: [String] = []
    /// Set when the composer opens on words that already exist. Done then **rewrites that entry's
    /// body** rather than writing a new one — the one path in the app that touches `entries.body`
    /// after it has landed, and it is the author's own hand.
    var editing: EditingEntry?

    /// The entry being edited, carried whole so the composer does not have to fetch it back.
    struct EditingEntry: Hashable {
        let id: UUID
        let body: String
        let restaurantID: UUID?
        let placeName: String?
    }

    static func edit(_ card: EntryCard) -> ComposerPresentation {
        ComposerPresentation(
            origin: .entryEdit,
            editing: EditingEntry(
                id: card.id,
                body: card.body,
                restaurantID: card.restaurantID,
                placeName: card.place?.name
            )
        )
    }
}
