import AteKit
import SwiftUI

/// **The Saved tab's stores**, made by its router the first time the tab is shown. The shelf itself
/// is the app's (``AppModel/savedDishes``), because a save made anywhere marks it; the tab holds it
/// rather than making its own.
@MainActor
struct SavedStores {
    let saved: SavedDishesStore

    init(app: AppModel) {
        saved = app.savedDishes
    }
}
