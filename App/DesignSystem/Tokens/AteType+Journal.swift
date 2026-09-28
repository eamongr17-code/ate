import SwiftUI

/// The round 7 Journal's own type — the month dividers, the chip sheets and the calendar — read off
/// the approved artboards (`Main`, `JournalScrolled`, `RatingChip`, `CalendarMonth`, `CalendarYear`).
/// Its own file only because `AteType.swift` is at its length limit.
extension AteTextStyle {
    /// A month's name over its entries, and at the head of the calendar: `.h` 34, `-1.2px`.
    static let monthTitle = AteTextStyle(
        voice: .display, size: 34, weight: 800, trackingEm: -0.035, lineHeight: 1.0, textStyle: .title
    )
    /// Beside it: "2026 · 14 ENTRIES" — DM Mono 12, `letter-spacing:.5px`, capitals.
    static let monthMeta = AteTextStyle(
        voice: .mono, size: 12, weight: 400, trackingEm: 0.04, lineHeight: 1.3,
        textStyle: .caption, maximumSize: 18, uppercase: true
    )
    /// The year after the month in the compact header: "August **2026**" — 20 at 600, muted.
    static let compactTitleYear = AteTextStyle(
        voice: .display, size: 20, weight: 600, trackingEm: -0.025, lineHeight: 1.0, textStyle: .headline,
        maximumSize: 26
    )
    /// A filter chip's label, and the chip sheets' pills: `.b` 15 at 600.
    static let chipLabel = AteTextStyle(
        voice: .display, size: 15, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .subheadline
    )
    /// A chip sheet's title: "Rating", `.h` 28, `-0.8px`.
    static let chipSheetTitle = AteTextStyle(
        voice: .display, size: 28, weight: 800, trackingEm: -0.029, lineHeight: 1.0, textStyle: .title
    )
    /// …and the choice it reads out on the right: "4.0 and up", 17 at 700.
    static let chipSheetValue = AteTextStyle(
        voice: .display, size: 17, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .body
    )
    /// The sheet's ink pill, "Show 23 entries": 17 at 700.
    static let chipSheetAction = AteTextStyle(
        voice: .display, size: 17, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .body
    )
    /// …and its Clear beside it: 17 at 600, muted.
    static let chipSheetClear = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .body
    )
    /// The numbers under a range slider's track: 14, muted.
    static let sliderLabel = AteTextStyle(
        voice: .display, size: 14, weight: 400, trackingEm: 0, lineHeight: 1.2, textStyle: .footnote,
        maximumSize: 18
    )
    /// The year beside the calendar's month: 17 at 600, muted.
    static let calendarYear = AteTextStyle(
        voice: .display, size: 17, weight: 600, trackingEm: 0, lineHeight: 1.2, textStyle: .body
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
    /// The ★5 / ★6 badge on a day: DM Mono 10, `line-height:16px`.
    static let calendarBadge = AteTextStyle(
        voice: .mono, size: 10, weight: 400, trackingEm: 0, lineHeight: 1.6, textStyle: .caption2,
        maximumSize: 13
    )
    /// A month's name over its dots in the year: 14 at 700.
    static let calendarMiniMonth = AteTextStyle(
        voice: .display, size: 14, weight: 700, trackingEm: 0, lineHeight: 1.2, textStyle: .footnote,
        maximumSize: 18
    )
    /// The year's legend: "A visit", "A 5.0", "A 6" — 13, muted.
    static let calendarLegend = AteTextStyle(
        voice: .display, size: 13, weight: 400, trackingEm: 0, lineHeight: 1.3, textStyle: .footnote
    )
}
