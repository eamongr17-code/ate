import SwiftUI

// **The Feed's edition** (round 8, `Main.dc.html` / `Scrolled.dc.html`). Where the artboard sets no
// `line-height` the style takes the face's own `normal` (Bricolage and DM Mono both 1.2–1.3 of the
// size), which is what a single-line `Text` draws at by itself.

extension AteTextStyle {
    /// A section's name — "The Top Ate", "New to the record", a craving: 800 at 28, `-0.9px`, 1.02.
    static let feedSection = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.9 / 28, lineHeight: 1.02, textStyle: .title
    )
    /// "See all", the Near me chip, "You're caught up": 600 at 15.
    static let feedControl = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )

    // The cards and rows.

    /// A New to the record row's dish: 800 at 17, `-0.3px`.
    static let feedNewDish = AteTextStyle(
        voice: .display, size: 17, weight: 800, trackingEm: -0.3 / 17, lineHeight: 1.2, textStyle: .body
    )
    /// Its badge — `★6`, `★5`, `New`: mono 12, `0.3px`.
    static let feedBadge = AteTextStyle(
        voice: .mono, size: 12, weight: 400, trackingEm: 0.3 / 12, lineHeight: 1.3, textStyle: .caption,
        maximumSize: 16
    )
}
