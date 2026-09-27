#if DEBUG
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

    private static func has(_ argument: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }
}
#endif
