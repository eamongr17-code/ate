import SwiftUI

/// The two sizes of the **You header** — `you-header.html` A, Eamon 28 Oct: a 72pt avatar, a 30pt
/// handle. Their own file only because `AteType.swift` is at its length limit.
extension AteTextStyle {
    /// The handle at 30, beside the avatar.
    static let youHandleCompact = AteTextStyle(
        voice: .heading, size: 30, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title2
    )
    /// …and its 72pt avatar's letter.
    static let avatarMonogramCompact = AteTextStyle(
        voice: .display, size: 32, weight: 700, trackingEm: 0, lineHeight: 1.0,
        textStyle: .title2, maximumSize: 40
    )
}
