import SwiftUI

// **The discover rethink's type** (`design/rebuild/discover.html`, 4 Oct): the sizes its new pieces set
// that no older style names. A kit view asks for a role here; it never writes a number into `.ateText`.

extension AteTextStyle {
    /// A pushed page's own large title — `.ptitle b`: Bricolage 800 at 36 (44 before 6 Oct),
    /// `letter-spacing:-.035em`, `line-height:1` (a category's name)…
    static let kitPageTitle = AteTextStyle(
        voice: .heading, size: 36, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// …and set at 30 (36 before 6 Oct) when the title is a phrase ("What you follow").
    static let kitPageTitleLong = AteTextStyle(
        voice: .heading, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .largeTitle
    )
    /// The ask card's question — `.h` at 26: Bricolage 800, `letter-spacing:-.035em`, `line-height:1`.
    static let kitAskTitle = AteTextStyle(
        voice: .heading, size: 26, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )
    /// A followed category's name — `.fr b`: 800 at 20, `line-height:1.1`, `letter-spacing:-.03em`.
    static let kitFollowName = AteTextStyle(
        voice: .heading, size: 20, weight: 800, trackingEm: -0.01, lineHeight: 1.1, textStyle: .title3
    )
    /// The end of the edition's row — `.endrow`: 600 at 17, `line-height:1`.
    static let kitEndRow = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: 0, lineHeight: 1.0, textStyle: .body
    )
    /// …and its count — `.endrow .c`: 500 at 15, muted.
    static let kitEndRowCount = AteTextStyle(
        voice: .display, size: 15, weight: 500, trackingEm: 0, lineHeight: 1.0, textStyle: .subheadline
    )
}
