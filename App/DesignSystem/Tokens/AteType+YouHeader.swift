import SwiftUI

/// The two sizes of the **You header** Eamon approved on 2026-09-26 (over `You.dc.html`'s 76pt
/// avatar and 32pt handle). Their own file only because `AteType.swift` is at its length limit.
extension AteTextStyle {
    /// The handle at 26, a step down from a profile's 32, because it now shares its row with the gear.
    static let youHandleCompact = AteTextStyle(
        voice: .display, size: 26, weight: 800, trackingEm: -0.03, lineHeight: 1.0, textStyle: .title2
    )
    /// …and its 56pt avatar's letter.
    static let avatarMonogramCompact = AteTextStyle(
        voice: .display, size: 25, weight: 800, trackingEm: 0, lineHeight: 1.0,
        textStyle: .title2, maximumSize: 32
    )
}
