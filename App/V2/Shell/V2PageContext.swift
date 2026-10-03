import AteKit
import SwiftUI

/// **What every pushed page is handed**, besides its route's payload: the app (services, session,
/// gate, save action), where it was opened from, and the way to push the next page on the same tab.
/// One value, so a page that later needs one more thing reads it from here and the shell's
/// ``V2Destinations`` never changes.
@MainActor
struct V2PageContext {
    let app: AppModel
    /// The tab whose stack the page is on.
    let tab: V2Tab
    /// Where the page was opened from — its view event's `source`.
    let source: DetailSource
    private let push: (Route, DetailSource) -> Void

    init(app: AppModel, tab: V2Tab, source: DetailSource, push: @escaping (Route, DetailSource) -> Void) {
        self.app = app
        self.tab = tab
        self.source = source
        self.push = push
    }

    var services: AteServices { app.services }
    /// Asked before every write; a browser is asked to sign in instead.
    var gate: SessionGate { app.gate }
    /// The one save action (AGENTS.md rule 2).
    var saves: SaveAction { app.saves }

    /// Pushes another page on this tab's stack.
    func open(_ route: Route, from source: DetailSource = .unknown) {
        push(route, source)
    }
}
