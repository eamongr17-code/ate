import AteKit
import SwiftUI

/// **Where the rebuilt app opens** — the one place it reads a Debug launch (`-ate-open <route>`,
/// ``DebugLaunch``), so no screen under `App/V2/` carries an `#if DEBUG`. Phase 2b knows the tabs
/// and the composer; each flow adds the pages it builds.
enum V2Launch {
    struct Start: Equatable {
        var tab: V2Tab = .journal
        var composes = false
        /// Pages already pushed on the opening tab: how the screen snapshots (`ScreenSnapshotTests`)
        /// open a place or an entry on a real tab stack.
        var path: [Route] = []
    }

    static var start: Start {
        #if DEBUG
        guard let route = DebugLaunch.route else { return Start() }
        switch route.screen {
        case .feed: return Start(tab: .feed)
        case .saved: return Start(tab: .saved)
        case .you: return Start(tab: .you)
        case .composer: return Start(composes: true)
        default: return Start()
        }
        #else
        return Start()
        #endif
    }
}
