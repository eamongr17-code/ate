import SwiftUI

/// **"Ate with"'s type** (`design/rebuild/ate-with.html`) — the sizes its parts set that no older
/// style names.
extension AteTextStyle {
    /// The letter in the With key's 30pt avatar — `.a30`: DM Sans 700 at 13. Capped: it lives in a
    /// fixed disc.
    static let avatarInitialKey = AteTextStyle(
        voice: .display, size: 13, weight: 700, trackingEm: 0, lineHeight: 1.0,
        textStyle: .caption, maximumSize: 17
    )
    /// The handle in "with @jess" — `.meta b`: DM Sans 600 at 13, the meta line's own size.
    static let metaStrong = AteTextStyle(
        voice: .display, size: 13, weight: 600, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
    /// A notification's sentence (`notifications-refined.html`, `.tx`): DM Sans 500 at 16.
    static let notificationLine = AteTextStyle(
        voice: .display, size: 16, weight: 500, trackingEm: -0.005, lineHeight: 1.3, textStyle: .callout
    )
    /// …and the names in it, `.tx b`: 700.
    static let notificationStrong = AteTextStyle(
        voice: .display, size: 16, weight: 700, trackingEm: -0.005, lineHeight: 1.3, textStyle: .callout
    )
}
