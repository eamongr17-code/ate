import SwiftUI

// **Lists** (`design/rebuild/lists-notifications.html` §3): the list card and the list receipt.

extension AteTextStyle {
    /// A list card's count — `.lc .ct`: Bricolage 600 at 13, `line-height:1` (drawn at 72%).
    static let kitListCardCount = AteTextStyle(
        voice: .display, size: 13, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .footnote,
        maximumSize: 20
    )
    /// A list card's name — `.lc .nm`: Bricolage 800 at 27, `line-height:1.02`, `-.035em`, two lines.
    static let kitListCardName = AteTextStyle(
        voice: .display, size: 27, weight: 800, trackingEm: -0.035, lineHeight: 1.02, textStyle: .title2
    )
    /// The list receipt's head — `.h` at 25, `line-height:1.02`.
    static let kitListReceiptTitle = AteTextStyle(
        voice: .display, size: 25, weight: 800, trackingEm: -0.035, lineHeight: 1.02, textStyle: .title2,
        maximumSize: 25
    )
    /// A line's rank — `.rl .q`: DM Mono 500 at 11.
    static let kitListReceiptRank = AteTextStyle(
        voice: .mono, size: 11, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .caption2,
        maximumSize: 11
    )
    /// A line's dish — `.rl .n`: Bricolage 800 at 19, `line-height:1.1`, `-.03em`.
    static let kitListReceiptDish = AteTextStyle(
        voice: .display, size: 19, weight: 800, trackingEm: -0.03, lineHeight: 1.1, textStyle: .headline,
        maximumSize: 19
    )
    /// A line's score, printed like a price — `.rl .s`: Bricolage 800 at 21, `-.02em`.
    static let kitListReceiptScore = AteTextStyle(
        voice: .display, size: 21, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .headline,
        maximumSize: 21
    )
    /// The place under a line — `.rpl`: DM Mono 400 at 10, `line-height:1.2`, `.08em`, upper case.
    static let kitListReceiptPlace = AteTextStyle(
        voice: .mono, size: 10, weight: 400, trackingEm: 0.08, lineHeight: 1.2, textStyle: .caption2,
        maximumSize: 10, uppercase: true
    )
    /// The receipt's mono labels at the share picture's fixed size — `.lab`: DM Mono 11, `.08em`.
    static let kitListReceiptLabel = AteTextStyle(
        voice: .mono, size: 11, weight: 400, trackingEm: 0.08, lineHeight: 1.35, textStyle: .caption2,
        maximumSize: 11, uppercase: true
    )
}
