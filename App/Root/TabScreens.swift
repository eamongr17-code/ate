import AteKit
import SwiftUI

/// **`Search`** — where the shell's routes meet the tab. The screen itself lives in `App/Search`;
/// this only says where each of its rows goes, and that every one of them goes there *from search*
/// (the `source` the place and dish pages report).
struct SearchScreen: View {
    let store: SearchStore
    let saves: SaveAction
    let open: (Route, DetailSource) -> Void

    var body: some View {
        SearchTabScreen(
            store: store,
            onPlace: { open(.place($0), .search) },
            onDish: { open(.dish($0), .search) },
            onProfile: { open(.profile($0), .search) },
            // The shelf's own unsave — the same round trip, haptic and `save_toggled` — attributed
            // to the surface it happened on.
            onUnsave: { await saves.unsaveFromShelf($0, source: .search) }
        )
    }
}
