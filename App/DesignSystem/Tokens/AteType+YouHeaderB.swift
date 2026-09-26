import SwiftUI

/// The two sizes the **You header B** prototype asks for (``YouHeaderVariant``) — kept apart from
/// the ratified table in `AteType.swift` until Eamon picks A or B, so taking B out is deleting this
/// file.
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
