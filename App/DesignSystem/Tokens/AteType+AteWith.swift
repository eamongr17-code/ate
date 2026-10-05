import SwiftUI

/// **"Ate with"'s type** (`design/rebuild/ate-with.html`) — the sizes its parts set that no older
/// style names.
extension AteTextStyle {
    /// The letter in the With key's 30pt avatar — `.a30`: Bricolage 800 at 13. Capped: it lives in a
    /// fixed disc.
    static let avatarInitialKey = AteTextStyle(
        voice: .display, size: 13, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .caption, maximumSize: 17
    )
    /// The handle in "with @jess" — `.meta b`: Bricolage 600 at 13, the meta line's own size.
    static let metaStrong = AteTextStyle(
        voice: .display, size: 13, weight: 600, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
}
