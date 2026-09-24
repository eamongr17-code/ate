import AteKit
import Foundation

/// **Everywhere the app can go.** One type, because a `NavigationStack`'s path is one type — and
/// because every screen that links somewhere should be linking to the same list of places.
///
/// Slice 1 builds the entry page, `Suggestions` and a profile. `place` and `dish` are the links the
/// design already draws (a slip's place line, a saved row) and they are **dead on purpose** until
/// slice 2: `isBuilt` is false, ``AteNavigator`` refuses to push them, and nothing happens. A
/// placeholder screen saying "coming soon" would be helper copy, which design rule 1 forbids, and a
/// half-built page is worse than a link that waits.
enum Route: Hashable {
    case entry(EntryRoute)
    /// `Suggestions` — recent photos, offered as sittings to write up.
    case suggestions
    /// Someone else's page. The viewer's own is the You tab.
    case profile(UUID)
    /// Slice 2.
    case place(UUID)
    /// Slice 2.
    case dish(UUID)
    /// One bar of your own histogram, opened — the dishes you gave that score.
    case ratings(score: Double)
    /// A month, totalled and printed.
    case statement(StatementMonth)

    /// Whether this destination exists yet.
    var isBuilt: Bool {
        switch self {
        case .entry, .suggestions, .profile, .ratings, .statement: true
        case .place, .dish: false
        }
    }

    var entryID: UUID? {
        switch self {
        case .entry(let route): route.entryID
        default: nil
        }
    }
}
