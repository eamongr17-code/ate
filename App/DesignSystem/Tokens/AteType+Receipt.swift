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

extension AteTextStyle {
    // The share sticker (10 Oct, Eamon: simpler than the receipt, built for a small space). The same
    // faces as the receipt, a step down in size and up in weight of presence: it is read at a third
    // of the screen's width.

    /// A dish on the sticker. 17pt heading face.
    static let shareSlipDish = AteTextStyle(
        voice: .heading, size: 17, weight: 800, trackingEm: -0.01, lineHeight: 1.15, textStyle: .body,
        maximumSize: 17
    )
    /// Its score, printed like a price. 18pt/800.
    static let shareSlipScore = AteTextStyle(
        voice: .display, size: 18, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .body,
        maximumSize: 18
    )
    /// The one line of fine print, and the signature. DM Mono 10, uppercase.
    static let shareSlipLabel = AteTextStyle(
        voice: .mono, size: 10, weight: 400, trackingEm: 0.08, lineHeight: 1.35, textStyle: .caption2,
        maximumSize: 10, uppercase: true
    )
    /// A dish tag's name. 15pt heading face.
    static let shareTagName = AteTextStyle(
        voice: .heading, size: 15, weight: 800, trackingEm: -0.01, lineHeight: 1.1, textStyle: .body,
        maximumSize: 15
    )
    /// …and its score, in the butter capsule. 13pt/800.
    static let shareTagScore = AteTextStyle(
        voice: .display, size: 13, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .body,
        maximumSize: 13
    )
}
