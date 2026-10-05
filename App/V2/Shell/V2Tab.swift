import SwiftUI

/// **The new tab bar's items**: the four places, and `+` — a tab in the bar's detached trailing slot
/// (the one iOS 26 gives a search-role tab) that presents the composer and is never selected.
enum V2Tab: String, CaseIterable, Identifiable, Hashable {
    case journal, feed, saved, you
    case compose

    var id: String { rawValue }

    /// The four places, in bar order.
    static let places: [V2Tab] = [.journal, .feed, .saved, .you]

    var title: String {
        switch self {
        case .journal: "Journal"
        case .feed: "Feed"
        case .saved: "Saved"
        case .you: "You"
        case .compose: "New entry"
        }
    }

    var icon: AteIcon {
        switch self {
        case .journal: .journal
        case .feed: .feed
        case .saved: .save
        case .you: .you
        case .compose: .compose
        }
    }
}
