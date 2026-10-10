import SwiftUI

/// The round 7 Journal's own type — the month dividers, the chip sheets and the calendar — read off
/// the approved artboards (`Main`, `JournalScrolled`, `RatingChip`, `CalendarMonth`, `CalendarYear`).
/// Its own file only because `AteType.swift` is at its length limit.
extension AteTextStyle {
    /// A month's name over its entries, and at the head of the calendar: `.h` 34, `-1.2px`.
    static let monthTitle = AteTextStyle(
        voice: .heading, size: 34, weight: 800, trackingEm: -0.02, lineHeight: 1.0, textStyle: .title
    )
    /// The numbers under a range slider's track: 14, muted.
    static let sliderLabel = AteTextStyle(
        voice: .display, size: 14, weight: 400, trackingEm: 0, lineHeight: 1.2, textStyle: .footnote,
        maximumSize: 18
    )
    /// The weekday initials over the grid: 12 at 600.
    static let calendarWeekday = AteTextStyle(
        voice: .display, size: 12, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .caption,
        maximumSize: 16
    )
    /// A day with nothing on it: 15, muted, centred in its square.
    static let calendarDay = AteTextStyle(
        voice: .display, size: 15, weight: 400, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline,
        maximumSize: 20
    )
    /// A day's number over its photo: 12 at 700, white.
    static let calendarDayOnPhoto = AteTextStyle(
        voice: .display, size: 12, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .caption,
        maximumSize: 16
    )
    /// A month's name over its dots in the year: 14 at 700.
    static let calendarMiniMonth = AteTextStyle(
        voice: .display, size: 14, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .footnote,
        maximumSize: 18
    )
}
