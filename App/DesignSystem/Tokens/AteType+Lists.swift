import SwiftUI

// **Lists** (`design/rebuild/lists-playlists.html`, `lists-notifications.html` §3): the cover and the receipt.

extension AteTextStyle {
    /// A cover's name where the list has no photo — `.cov.gen b`: Bricolage 800 at 22, `line-height:1`,
    /// `-.035em`…
    static let kitListCoverName = AteTextStyle(
        voice: .heading, size: 22, weight: 800, trackingEm: -0.01, lineHeight: 1.0, textStyle: .title3,
        maximumSize: 22
    )
    /// …and at 34 on the list's own page.
    static let kitListCoverNameHero = AteTextStyle(
        voice: .heading, size: 34, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title,
        maximumSize: 34
    )
    /// A shelf tile's name — `.tile b`: Bricolage 600 at 16, `line-height:1.2`, `-.01em`.
    static let kitListTileName = AteTextStyle(
        voice: .display, size: 16, weight: 600, trackingEm: -0.01, lineHeight: 1.2, textStyle: .callout
    )
    /// The list page's name under its cover — `.hero .nm`: Bricolage 800 at 28, `line-height:1.05`.
    static let kitListHeroName = AteTextStyle(
        voice: .heading, size: 28, weight: 800, trackingEm: -0.02, lineHeight: 1.05, textStyle: .title
    )
    /// The handle under it — `.hero .by`: Bricolage 600 at 15.
    static let kitListByline = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.3, textStyle: .subheadline
    )
    /// A row's place in the list — `.tr .tn`: DM Mono 500 at 13, muted.
    static let kitListTrackRank = AteTextStyle(
        voice: .mono, size: 13, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .footnote,
        maximumSize: 18
    )
    /// The list receipt's head — `.h` at 25, `line-height:1.02`.
    static let kitListReceiptTitle = AteTextStyle(
        voice: .heading, size: 25, weight: 800, trackingEm: -0.02, lineHeight: 1.02, textStyle: .title2,
        maximumSize: 25
    )
    /// A line's rank — `.rl .q`: DM Mono 500 at 11.
    static let kitListReceiptRank = AteTextStyle(
        voice: .mono, size: 11, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .caption2,
        maximumSize: 11
    )
    /// A line's dish — `.rl .n`: Bricolage 800 at 19, `line-height:1.1`, `-.03em`.
    static let kitListReceiptDish = AteTextStyle(
        voice: .heading, size: 19, weight: 800, trackingEm: -0.01, lineHeight: 1.1, textStyle: .headline,
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
