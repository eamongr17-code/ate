#if DEBUG
import AteKit
import Foundation

/// **The Journal's and the Feed's starting state, for a drive** — which cannot be tapped from a shell
/// (``DebugLaunch``).
///
/// `-ate-open journal?filtered` starts the Journal on Rating 4.0 and up (`RatingChip`); `&filter`
/// opens the Rating chip's sheet over it; `-ate-open saved` lands on the Saved shelf;
/// `-ate-open feed?location` opens the Feed's location sheet.
enum JournalDebugLaunch {
    static var startsFiltered: Bool { DebugLaunch.route?.screen == .journal && DebugLaunch.has(.filtered) }
    static var opensFilter: Bool { DebugLaunch.route?.screen == .journal && DebugLaunch.has(.filter) }
    static var opensSaved: Bool { DebugLaunch.route?.screen == .saved }
    static var opensFeedLocation: Bool { DebugLaunch.has(.location) }
}
#endif
