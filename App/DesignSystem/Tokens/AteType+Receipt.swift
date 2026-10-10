import SwiftUI

extension AteTextStyle {
    // The receipt (10 Oct, Eamon: one receipt, simpler, built for a small space). Drawn at 200 wide:
    // scaled up on screen, read at a third of a story's width as a sticker.

    /// A dish on the receipt. 17pt heading face.
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
}
