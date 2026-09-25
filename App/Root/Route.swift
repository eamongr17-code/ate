import AteKit
import Foundation

/// **Everywhere the app can go.** One type, because a `NavigationStack`'s path is one type — and
/// because every screen that links somewhere should be linking to the same list of places.
///
/// Slice 1 built the entry page, `Suggestions` and a profile; slice 2 opened `place` and `dish`.
/// Every one of these is now reachable, which is why ``isBuilt`` is uniformly true — it stays as the
/// one place a not-yet-built destination would be declared dead, rather than being deleted and
/// re-invented the next time a link lands before its page does.
enum Route: Hashable {
    case entry(EntryRoute)
    /// `Suggestions` — recent photos, offered as sittings to write up.
    case suggestions
    /// Someone else's page. The viewer's own is the You tab.
    case profile(UUID)
    /// A place: what to order there, and the visits written at it.
    case place(UUID)
    /// One dish: its aggregate, and everything anybody has said about it.
    case dish(UUID)
    /// One bar of your own histogram, opened — the dishes you gave that score.
    case ratings(score: Double)
    /// A month, totalled and printed.
    case statement(StatementMonth)
    /// Settings and the four pages that hang off it. One case, because they are one branch of the
    /// app and the shell should not learn four new destinations to reach it.
    case settings(SettingsPage)

    /// Whether this destination exists yet.
    var isBuilt: Bool {
        switch self {
        case .entry, .suggestions, .profile, .place, .dish, .ratings, .statement, .settings: true
        }
    }

    var entryID: UUID? {
        switch self {
        case .entry(let route): route.entryID
        default: nil
        }
    }
}
