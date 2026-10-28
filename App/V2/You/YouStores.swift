import AteKit
import SwiftUI

/// **The You tab's stores**, made by its router the first time the tab is shown.
@MainActor
struct YouStores {
    /// Who you are, the three totals, the chart and your top dishes.
    let you: YouStore
    /// Your awards: the third band, and its page.
    let awards: AwardsStore

    init(services: AteServices) {
        let preferences = services.preferences
        you = YouStore(stats: services.stats) { preferences.gaveSix($0) }
        awards = AwardsStore(userID: nil, awards: services.awards)
    }
}
