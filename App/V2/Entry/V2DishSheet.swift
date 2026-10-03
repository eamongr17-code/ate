import AteKit
import SwiftUI

/// **Fix a dish — "Which dish?"** When Ate matched your words to the wrong dish, a long press on that
/// row of your own entry says which dish it really was. It changes the dish's **name only**: the
/// score and the words are untouched.
///
/// Search, then the place's dishes with the current one marked, then "Add as a new dish" last.
/// Picking a row closes the sheet (`correct_entry_dish` with the dish's id; the add row passes the
/// name). The menu is the current sheet's (``DishMenu``), read before the sheet rises.
struct V2DishSheet: View {
    let menu: DishMenu
    let placeName: String?
    let item: AteReceipt.Item
    /// `(dishID, dishName)` — exactly one is non-nil.
    let onPick: (UUID?, String?) -> Void

    @State private var query: String
    @Environment(\.dismiss) private var dismiss

    init(menu: DishMenu, placeName: String?, item: AteReceipt.Item, onPick: @escaping (UUID?, String?) -> Void) {
        self.menu = menu
        self.placeName = placeName
        self.item = item
        self.onPick = onPick
        _query = State(initialValue: item.name)
    }

    var body: some View {
        AteSheetScaffold(title: "Which dish?", searchPrompt: "Search dishes", searchText: $query) {
            VStack(alignment: .leading, spacing: 0) {
                if let placeName, menu.hasAnswered == false || results.isEmpty == false {
                    AteSheetSectionLabel(title: "At \(placeName)")
                }
                if menu.hasAnswered == false {
                    AteSheetSkeletonRows(count: V2DishSheetMetrics.skeletonRows)
                } else {
                    ForEach(results) { dish in
                        AteChoiceRow(
                            title: dish.name,
                            subtitle: dish.peopleCount.map(Self.people),
                            isSelected: dish.id == current
                        ) {
                            pick(dishID: dish.id, name: nil)
                        }
                    }
                }
                AteAddRow(
                    title: "Add as a new dish",
                    isEnabled: trimmedQuery.isEmpty == false,
                    identifier: "dish.add"
                ) {
                    pick(dishID: nil, name: trimmedQuery)
                }
            }
        }
    }

    /// The line's current dish, marked so the sheet opens on the answer it has.
    private var current: UUID? { item.dishID ?? menu.match(item.name) }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nothing typed past the line's own name: the whole menu. Filtering by that name would leave the
    /// one row the sorter already chose — the answer this sheet exists to question.
    private var results: [PlaceDish] {
        let needle = trimmedQuery.lowercased()
        guard needle.isEmpty == false, needle != item.name.lowercased() else { return menu.dishes }
        return menu.dishes.filter { $0.name.lowercased().contains(needle) || $0.id == current }
    }

    private func pick(dishID: UUID?, name: String?) {
        AteHaptics.key()
        // Picking the dish it already is changes nothing.
        if let dishID, dishID == current {
            dismiss()
            return
        }
        onPick(dishID, name)
        dismiss()
    }

    private static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }
}

extension View {
    /// **The dish sheet** for one line of an entry, its place's menu read before it rises.
    func v2DishSheet(
        item: Binding<EntryModel.Correcting?>,
        directory: any PlaceDirectory,
        placeID: @escaping @MainActor () -> UUID?,
        placeName: @escaping @MainActor () -> String?,
        onPick: @escaping (AteReceipt.Item, UUID?, String?) -> Void
    ) -> some View {
        modifier(V2DishSheetPresenter(
            item: item, directory: directory, placeID: placeID, placeName: placeName, onPick: onPick
        ))
    }
}

private struct V2DishSheetPresenter: ViewModifier {
    @Binding var item: EntryModel.Correcting?
    let directory: any PlaceDirectory
    let placeID: @MainActor () -> UUID?
    let placeName: @MainActor () -> String?
    let onPick: (AteReceipt.Item, UUID?, String?) -> Void

    @State private var holder = AteSheetHolder<DishMenu>()

    func body(content: Content) -> some View {
        let holder = holder
        content.ateSheet(item: $item, name: "dish", prepare: { _ in
            let fresh = DishMenu(directory: directory, placeID: placeID())
            holder.value = fresh
            await fresh.load()
        }, content: { correcting in
            AteSheetHolderView(holder: holder) { menu in
                V2DishSheet(menu: menu, placeName: placeName(), item: correcting.item) { dishID, dishName in
                    onPick(correcting.item, dishID, dishName)
                }
            }
        })
    }
}

enum V2DishSheetMetrics {
    static let skeletonRows = 5
}
