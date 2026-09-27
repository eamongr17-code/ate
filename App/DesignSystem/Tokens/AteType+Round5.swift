import SwiftUI

extension AteTextStyle {
    // Round 5 exploration (`-ate-r5-receipt A|B`): the share receipt led by its dishes.

    /// A — a dish leading the receipt, in the title face. 22pt.
    static let receiptLeadDish = AteTextStyle(
        voice: .display, size: 22, weight: 800, trackingEm: -0.03, lineHeight: 1.1, textStyle: .title3
    )
    /// A — its score, printed like a price. 24pt.
    static let receiptLeadScore = AteTextStyle(
        voice: .display, size: 24, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title3
    )
    /// B — a line item at the head of the ticket, larger. 16pt.
    static let receiptTicketLine = AteTextStyle(
        voice: .mono, size: 16, weight: 400, lineHeight: 1.6, textStyle: .callout, maximumSize: 24
    )
    /// B — its score. 16pt/500.
    static let receiptTicketScore = AteTextStyle(
        voice: .mono, size: 16, weight: 500, lineHeight: 1.6, textStyle: .callout, maximumSize: 24
    )
    /// B — the place, in the fine print under the lines. 13pt/500, uppercase.
    static let receiptTicketPlace = AteTextStyle(
        voice: .mono, size: 13, weight: 500, trackingEm: 0.04, lineHeight: 1.35,
        textStyle: .footnote, maximumSize: 18, uppercase: true
    )
}
