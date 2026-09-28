import SwiftUI

/// The chrome's own type (round 6). Its own file only because `AteType.swift` is at its length limit.
extension AteTextStyle {
    /// A tab root's name in its compact header, the one that comes back mid-scroll: the screen
    /// title's voice at 20.
    static let compactTitle = AteTextStyle(
        voice: .display, size: 20, weight: 800, trackingEm: -0.03, lineHeight: 1.0, textStyle: .headline,
        maximumSize: 26
    )
}
