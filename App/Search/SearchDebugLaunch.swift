import AteKit
import Foundation

#if DEBUG
/// **The Search tab's starting state, for a drive** — `-ate-open search/<scope>?q=<words>` lands on
/// the tab with its segment and field filled; `filtered` starts with a demo set on (vegetarian, 4.0
/// and up, and with `window=custom|preset` a date window) and `filter` opens the filter sheet at
/// launch, so each state can be photographed without a finger (``DebugLaunch``).
enum SearchDebugLaunch {
    /// The segment and the words, when the launch opens Search.
    static var start: (scope: SearchScope, query: String)? {
        guard let route = DebugLaunch.route, case .search(let scope) = route.screen else { return nil }
        return (scope, route.value(.query) ?? "")
    }

    static var startingFilters: SearchFilters? {
        start != nil && DebugLaunch.has(.filtered)
            ? SearchFilters(minimumScore: 4.0, window: startingWindow)
            : nil
    }

    static var opensFilter: Bool { start != nil && DebugLaunch.has(.filter) }

    /// `window=custom` (round 6 stills): March to August 2026; `window=preset`: This year.
    private static var startingWindow: DateWindow {
        switch DebugLaunch.route?.value(.window) {
        case "preset": DateWindow.preset(.thisYear)
        case "custom": DateWindow(from: AteMonth(year: 2026, month: 3), to: AteMonth(year: 2026, month: 8))
        default: .all
        }
    }
}
#endif
