import AteKit
import SwiftUI

/// **The entry slip** — one anatomy for the Journal, the Feed, a profile and a place's visits: the
/// byline (Feed, place visits), the dish rows, the words, the tilted photo cluster, the foot line —
/// on flat paper with Edge B. The existing ``EntrySlip``, with each surface's rules applied here once
/// rather than by every caller:
///
/// - **Journal** — no byline, no bookmarks, the full caption, the day at the foot.
/// - **Feed** — the byline, a bookmark on every dish, the tighter density, two lines of words, and
///   **no words at all past two dishes** (``SlipAnatomy``).
/// - **Profile** — bookmarks, two lines, the age at the foot.
/// - **Place visit** — the byline ("You" on yours), bookmarks, and no foot line: the page is the place.
struct AteEntrySlip: View {
    enum Surface: Equatable {
        case journal, feed, profile, placeVisit
    }

    let slip: AteSlip
    var surface: Surface = .journal
    var onOpen: (() -> Void)?
    var onProfile: (() -> Void)?
    var onSave: ((AteSlip.Dish) -> Void)?
    var onPlace: ((UUID) -> Void)?
    var onDish: ((AteSlip.Dish) -> Void)?
    var identifier = "journal.slip"

    var body: some View {
        EntrySlip(
            slip: Self.shaped(slip, for: surface),
            onOpen: onOpen,
            onProfile: onProfile,
            onSave: surface == .journal ? nil : onSave,
            onPlace: onPlace,
            onDish: onDish,
            identifier: identifier
        )
    }

    /// The slip as `surface` prints it.
    static func shaped(_ slip: AteSlip, for surface: Surface) -> AteSlip {
        var shaped = slip
        let anatomy: SlipAnatomy.Surface = switch surface {
        case .journal: .journal
        case .feed, .placeVisit: .feed
        case .profile: .profile
        }
        if SlipAnatomy.showsWords(on: anatomy, dishCount: slip.dishes.count) == false {
            shaped.words = EntryComposition(plain: "", spans: [])
        }
        shaped.wordsLineLimit = SlipAnatomy.wordsLineLimit(on: anatomy)
        switch surface {
        case .journal:
            shaped.byline = nil
        case .feed:
            shaped.density = .tight
        case .profile:
            shaped.byline = nil
        case .placeVisit:
            shaped.density = .tight
            shaped.place = nil
            shaped.placeID = nil
            shaped.suburb = nil
        }
        return shaped
    }
}
