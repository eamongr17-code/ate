import AteKit
import SwiftUI

/// **The You tab's stores**, made by its router the first time the tab is shown.
@MainActor
struct YouStores {
    /// Who you are, the three totals, the chart and your top dishes.
    let you: YouStore

    init(services: AteServices) {
        you = YouStore(stats: services.stats)
    }
}
