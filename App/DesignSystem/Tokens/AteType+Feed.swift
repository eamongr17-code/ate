import SwiftUI

// **The Feed's edition** (round 8, `Main.dc.html` / `Scrolled.dc.html`). Where the artboard sets no
// `line-height` the style takes the face's own `normal` (DM Sans and DM Mono both about 1.3 of the
// size), which is what a single-line `Text` draws at by itself.

extension AteTextStyle {
    /// A section's name — "The Top Ate", "New to the record", a craving: 800 at 24 (28 before 6 Oct),
    /// tracked as `-0.9px` was at 28, 1.02.
    static let feedSection = AteTextStyle(
        voice: .heading, size: 24, weight: 800, trackingEm: -0.02, lineHeight: 1.02, textStyle: .title
    )
    /// "See all", the Near me chip, "You're caught up": 600 at 15.
    static let feedControl = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
}
