import SwiftUI

// **A dish page's "More to explore" and "More like this"** (round 7, `DishExplore.dc.html`). The
// artboard sets none of these a `line-height`, so each was the face's own `normal` (1.3 of the size
// in DM Sans, the face these were measured in; Radio Canada's own is 1.2); each style pins its own.

extension AteTextStyle {
    /// "More to explore", "More like this": `.b` 800 at 20, `letter-spacing:-0.4px`.
    static let exploreHeading = AteTextStyle(
        voice: .heading, size: 20, weight: 800, trackingEm: -0.01, lineHeight: 1.2, textStyle: .title3
    )
    /// A tag chip's label: `.b` 600 at 14, no tracking.
    static let exploreChip = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
}
