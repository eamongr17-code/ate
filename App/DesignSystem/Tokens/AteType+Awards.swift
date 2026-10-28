import SwiftUI

/// **Plate awards' type** (`design/rebuild/plate-awards-screens.html`): the award's name in Young
/// Serif, everything else in DM Sans.
extension AteTextStyle {
    /// The award's name under the takeover's plate. 38pt.
    static let awardTakeoverTitle = AteTextStyle(
        voice: .heading, size: 38, weight: 800, trackingEm: -0.01, lineHeight: 1.05, textStyle: .largeTitle
    )
    /// The dish line under the name. 17pt.
    static let awardLine = AteTextStyle(
        voice: .display, size: 17, weight: 400, lineHeight: 1.4, textStyle: .body
    )
    /// The day it was earned. 14pt.
    static let awardDate = AteTextStyle(
        voice: .display, size: 14, weight: 400, lineHeight: 1.3, textStyle: .subheadline
    )
    /// A grid cell's name and its day. 14pt/600 and 12.5pt.
    static let awardCellName = AteTextStyle(
        voice: .display, size: 14, weight: 600, lineHeight: 1.25, textStyle: .footnote
    )
    static let awardCellDate = AteTextStyle(
        voice: .display, size: 12.5, weight: 400, lineHeight: 1.3, textStyle: .caption
    )
    /// "Your first 25 dishes" over the mosaic. 22pt.
    static let awardSection = AteTextStyle(
        voice: .heading, size: 22, weight: 800, trackingEm: -0.01, lineHeight: 1.2, textStyle: .title3
    )
    /// The story card's name and line, drawn at the card's own scale (1080 wide).
    static let awardStoryTitle = AteTextStyle(
        voice: .heading, size: 96, weight: 800, trackingEm: -0.01, lineHeight: 1.05, textStyle: .largeTitle,
        maximumSize: 96
    )
    static let awardStoryLine = AteTextStyle(
        voice: .display, size: 44, weight: 400, lineHeight: 1.35, textStyle: .body, maximumSize: 44
    )
    static let awardStoryDate = AteTextStyle(
        voice: .display, size: 34, weight: 400, lineHeight: 1.3, textStyle: .body, maximumSize: 34
    )
}
