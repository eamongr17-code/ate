#if DEBUG
import AteKit
import Foundation

/// **Launch arguments that open the Journal and the Feed in a state** — for a simulator drive, which
/// cannot be tapped from a shell. Debug only.
///
/// `-ate-journal-filtered` starts the Journal on Top rated, 4.0 and up; `-ate-journal-filter-open`
/// opens the filter sheet over it; `-ate-feed-location-open` opens the Feed's location sheet.
enum JournalDebugLaunch {
    static var startsFiltered: Bool { has("-ate-journal-filtered") }
    static var opensFilter: Bool { has("-ate-journal-filter-open") }
    static var opensFeedLocation: Bool { has("-ate-feed-location-open") }

    /// `-ate-r6-window custom|preset` (round 6 stills): a demo date window with the filter — March to
    /// August 2026 on the ruler, or This year.
    static var startingWindow: DateWindow {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ate-r6-window"), arguments.indices.contains(index + 1) else {
            return .all
        }
        switch arguments[index + 1] {
        case "preset": return DateWindow.preset(.thisYear)
        default: return DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8))
        }
    }

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}
#endif
