import AteKit
import SwiftUI

/// **Add dishes** (`lists-notifications.html` C3) — your own dishes, to put on a list: close, the
/// title, the search pill, then one row per dish (photo or letter tile, the dish over its place, its
/// score token only when scored) with an ink tick. The foot pill counts and appends them in the
/// order picked. Dishes already on the list are left out; the list's room (100) caps the ticks.
struct ListPickerSheet: View {
    let list: ListStore
    let services: AteServices

    @State private var picker: ListPickerStore
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    init(list: ListStore, services: AteServices) {
        self.list = list
        self.services = services
        _picker = State(initialValue: ListPickerStore(
            service: services.lists, listID: list.listID, excluding: list.lines, room: list.remaining
        ))
    }

    var body: some View {
        AteSheetScaffold(
            title: ListsCopy.addDishes,
            searchPrompt: ListsCopy.searchPrompt,
            searchText: $query,
            commit: AteSheetCommit(
                title: picker.selection.isEmpty ? ListsCopy.addDishes : ListsCopy.addCount(picker.selection.count),
                isEnabled: picker.selection.isEmpty == false && list.isAdding == false,
                action: add
            )
        ) {
            rows
        }
        .onChange(of: query) { _, now in picker.setQuery(now) }
        .task { await picker.start() }
        .listsFailureAlert(failure: picker.failure ?? list.failure) {
            picker.clearFailure()
            list.clearFailure()
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch picker.phase {
        case .loading:
            VStack(spacing: 0) {
                ForEach(0..<ListsMetrics.skeletonRows, id: \.self) { _ in
                    AteSkeleton(kind: .dishRow)
                }
            }
        case .empty:
            AteEmptyState(
                line: picker.effectiveQuery == nil ? ListsCopy.emptyPicker : ListsCopy.noMatch,
                art: picker.effectiveQuery == nil ? .list : .search
            )
                .frame(minHeight: ListsMetrics.emptyMinimum)
        case .failed:
            AteEmptyState(line: ListsCopy.unreachable, art: .torn,
                pill: (ListsCopy.tryAgain, { Task { await picker.start() } }))
                .frame(minHeight: ListsMetrics.emptyMinimum)
        case .ready:
            let dishes = picker.rows
            let letters = DishLetter.neighbourly(dishes.map { ($0.dishID, $0.dishName) })
            LazyVStack(spacing: 0) {
                ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                    AtePickRow(
                        photo: .dish(letters[index], cover: dish.photoURL),
                        name: dish.dishName,
                        place: dish.restaurantName,
                        score: dish.score.map(AteScore.personal),
                        isSelected: picker.isSelected(dish),
                        isFirst: index == 0,
                        identifier: "lists.pick"
                    ) {
                        if picker.toggle(dish) { AteHaptics.tick() }
                    }
                    .task { await picker.loadMoreIfNeeded(after: dish) }
                }
            }
        }
    }

    private func add() {
        let picked = picker.selection
        guard picked.isEmpty == false else { return }
        AteHaptics.key()
        Task {
            await list.add(picked)
            // A refusal keeps the sheet up, said once in the alert.
            if list.failure == nil { dismiss() }
        }
    }
}
