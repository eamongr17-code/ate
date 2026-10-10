import AteKit
import SwiftUI

/// **One tab's navigation** — its stack (`[Route]`), its stores, and scroll-to-top on a re-tap.
///
/// `Stores` is the tab's own state (the Journal's entries, the Feed's edition …), built the first
/// time the tab is shown rather than at launch: a person who never opens Search never pays for it.
/// Each tab's `Stores` is its flow's own type (`JournalStores`, `V2FeedStores` …), made from the
/// services by the shell; the flow fills it in without touching the shell.
@MainActor
@Observable
final class TabRouter<Stores>: V2TabRouting {
    let tab: V2Tab
    var path: [Route] = []
    /// Bumped by a re-tap of the tab while its root is showing — the root scrolls to its top.
    private(set) var scrollToTop = 0
    /// Where each pushed page was opened from — its view event's `source`.
    private(set) var sources: [Route: DetailSource] = [:]

    @ObservationIgnored private let makeStores: @MainActor () -> Stores
    @ObservationIgnored private var built: Stores?

    init(tab: V2Tab, path: [Route] = [], stores: @escaping @MainActor () -> Stores) {
        self.tab = tab
        self.path = path
        self.makeStores = stores
    }

    /// The tab's stores, built on first use.
    var stores: Stores {
        if let built { return built }
        let made = makeStores()
        built = made
        return made
    }

    /// The tab came on screen: its stores exist from here on.
    func shown() { _ = stores }

    func open(_ route: Route, from source: DetailSource = .unknown) {
        guard route.isBuilt else { return }
        // A page already on the stack is gone back to, never pushed again: a dish's page opens your
        // entry, whose score opens the dish… and back would have been fifty swipes home (Eamon,
        // 10 Oct).
        if let index = path.lastIndex(of: route) {
            path.removeSubrange(path.index(after: index)...)
            return
        }
        sources[route] = source
        path.append(route)
    }

    /// The tab's own item, tapped while it is the current tab: a pushed stack goes back to its root
    /// (the system's own behaviour), and a root already showing scrolls to its top.
    func reselected() {
        if path.isEmpty {
            scrollToTop += 1
        } else {
            path.removeAll()
        }
    }
}

/// What the shell asks of a router whatever its tab's stores are — so the four routers, each with
/// its own `Stores`, can be picked out by tab.
@MainActor
protocol V2TabRouting: AnyObject {
    var tab: V2Tab { get }
    var path: [Route] { get }
    func shown()
    func open(_ route: Route, from source: DetailSource)
    func reselected()
}
