import SwiftUI

extension AteTextStyle {
    // The receipt's dishes (round 5: the dishes lead, the place is fine print). Bricolage — the
    // title face — not mono: they are the headline of what Ate printed.

    /// A dish on a receipt. 22pt/800, line-height 1.1.
    static let receiptLeadDish = AteTextStyle(
        voice: .heading, size: 22, weight: 800, trackingEm: -0.01, lineHeight: 1.1, textStyle: .title3
    )
    /// Its score, printed like a price. 24pt/800.
    static let receiptLeadScore = AteTextStyle(
        voice: .display, size: 24, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title3
    )
}
