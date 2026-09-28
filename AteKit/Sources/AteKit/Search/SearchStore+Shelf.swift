import Foundation

/// **The Saved scope's shelf, from Search** — the one scope whose rows can be taken away from here,
/// and the one that has to hear about a save made anywhere else.
extension SearchStore {

    /// The bookmark on a Saved row. The row leaves at the tap, like it does on the shelf, and comes
    /// back where it was if the unsave is refused. `perform` is the shared ``SaveAction``'s own
    /// unsave, so the round trip, the haptic and `save_toggled` are the shelf's, not a copy of them.
    public func unsave(_ dish: SavedDish, perform: () async -> Bool) async {
        let removed = removeSaved(dish.dishID)
        guard await perform() == false, let removed else { return }
        restoreSaved(removed.dish, at: removed.index)
    }

    @discardableResult
    private func removeSaved(_ dishID: UUID) -> (dish: SavedDish, index: Int)? {
        guard var state = states[.saved], case .saved(var dishes) = state.rows,
              let index = dishes.firstIndex(where: { $0.dishID == dishID }) else { return nil }
        let dish = dishes.remove(at: index)
        state.rows = .saved(dishes)
        if dishes.isEmpty, state.phase == .ready { state.phase = .empty }
        states[.saved] = state
        if scope == .saved { adopt(state) }
        return (dish, index)
    }

    private func restoreSaved(_ dish: SavedDish, at index: Int) {
        guard var state = states[.saved], case .saved(var dishes) = state.rows,
              dishes.contains(where: { $0.dishID == dish.dishID }) == false else { return }
        dishes.insert(dish, at: min(index, dishes.count))
        state.rows = .saved(dishes)
        state.phase = .ready
        states[.saved] = state
        if scope == .saved { adopt(state) }
    }
}

extension SearchStore: SavedDishObserving {
    /// An unsave anywhere takes the dish off this shelf too. A save anywhere makes the shelf stale
    /// rather than guessing where the new row sorts: it is read again the next time it is shown.
    public func savedDishChanged(dishID: UUID, isSaved: Bool) {
        if isSaved {
            states[.saved]?.answered = nil
        } else {
            removeSaved(dishID)
        }
    }
}
