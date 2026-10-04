import SwiftUI

// **A dish page's "More to explore" and "More like this"** (round 7, `DishExplore.dc.html`). The
// artboard sets none of these a `line-height`, so each is Bricolage's own `normal` — its 930/270
// ascender and descender, 1.2 of the size.

extension AteTextStyle {
    /// "More to explore", "More like this": `.b` 800 at 20, `letter-spacing:-0.4px`.
    static let exploreHeading = AteTextStyle(
        voice: .display, size: 20, weight: 800, trackingEm: -0.02, lineHeight: 1.2, textStyle: .title3
    )
    /// A tag chip's label: `.b` 600 at 14, no tracking.
    static let exploreChip = AteTextStyle(
        voice: .display, size: 14, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
}
