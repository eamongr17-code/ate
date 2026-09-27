import Observation
import SwiftUI

/// **What the tab bar shows**, held by the shell and read by every tab root's bar.
///
/// An object rather than values handed down: each tab's content lives in its own hosting controller
/// under the `TabView`, and a tab that is not on screen when the selection changes is not re-built
/// with the new values — its bar kept showing the tab it was made on. Read through Observation, each
/// bar updates itself whatever its tab's content is doing.
@MainActor
@Observable
final class AteTabChrome {
    var current: AteTab
    /// At full size, or minimised by a scroll down on the current tab's root.
    var isExpanded = true
    /// The last switch of tabs, so the arriving bar's pill slides over from the tab just left.
    var arrival: AteTabArrival?
    /// Bumped when the minimised bar is tapped open, so the tab root's scroll tracker hears it.
    private(set) var expandRequest = 0
    /// The current tab root's compact header is floating over its list (round 6): the status-bar
    /// frost steps aside, so the header's own frost is the only one there.
    var isHeaderFloating = false

    init(current: AteTab) {
        self.current = current
    }

    /// The minimised bar tapped: whole again.
    func expand() {
        isExpanded = true
        expandRequest += 1
    }

    /// A tab chosen on the bar: its pill slides over, and the bar is whole.
    func select(_ tab: AteTab) {
        guard tab != current else { return }
        arrival = AteTabArrival(from: current, id: (arrival?.id ?? 0) + 1)
        current = tab
        isExpanded = true
        isHeaderFloating = false
    }
}
