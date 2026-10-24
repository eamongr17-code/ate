import SwiftUI

// **The discover rethink's type** (`design/rebuild/discover.html`, 4 Oct): the sizes its new pieces set
// that no older style names. A kit view asks for a role here; it never writes a number into `.ateText`.

extension AteTextStyle {
    /// **A pushed page's header** (`page-headers.html`, 24 Oct): the name of the thing the page is
    /// about — a list, a place, a dish, a tag, a person — in Young Serif at 34, lines 1.05 apart, on
    /// up to three lines…
    static let pageHeaderTitle = AteTextStyle(
        voice: .heading, size: 34, weight: 800, trackingEm: -0.02, lineHeight: 1.05, textStyle: .largeTitle
    )
    /// …the one line under it in DM Sans at 15, muted…
    static let pageHeaderLine = AteTextStyle(
        voice: .display, size: 15, weight: 500, trackingEm: 0, lineHeight: 1.3, textStyle: .subheadline
    )
    /// …and the names on that line at 600, in ink (a list's people, a dish's place).
    static let pageHeaderStrong = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.3, textStyle: .subheadline
    )
    /// The ask card's question — `.h` at 26: Young Serif, `letter-spacing:-.035em`, `line-height:1`.
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
