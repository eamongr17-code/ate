import AteKit
import SwiftUI

/// **`DishSheet`** — "Which dish?". The correction for one line of a receipt.
///
/// The sorter names a dish from the person's own words; this is where the person says what it
/// actually was. A menu pick passes the dish's id, "Add as a new dish" passes the name — the two
/// halves of `correct_entry_dish`. Score and note are untouched either way: they are the person's,
/// and nothing here is allowed near them.
///
/// Presented with ``SwiftUICore/View/ateDishSheet(item:directory:placeID:placeName:onPick:)``, which
/// reads the place's menu before it rises (round 5: it used to open on the add row, then jump).
struct DishSheet: View {
    let menu: DishMenu
    let placeName: String?
    let item: AteReceipt.Item
    /// `(dishID, dishName)` — exactly one is non-nil.
    let onPick: (UUID?, String?) -> Void

    @State private var query: String
    @State private var pickedID: UUID?
    @Environment(\.dismiss) private var dismiss

    init(
        menu: DishMenu,
        placeName: String?,
        item: AteReceipt.Item,
        onPick: @escaping (UUID?, String?) -> Void
    ) {
        self.menu = menu
        self.placeName = placeName
        self.item = item
        self.onPick = onPick
        _query = State(initialValue: item.name)
        // The line's current dish comes back marked, so the sheet opens on the answer it has.
        _pickedID = State(initialValue: menu.match(item.name))
    }

    var body: some View {
        AteSheet(
            title: "Which dish?",
            searchPrompt: "Search dishes",
            searchText: $query,
            primary: ("Done", commit),
            isLoading: menu.hasAnswered == false
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if menu.hasAnswered == false {
                    section
                    AteSheetSkeletonRows(count: 5)
                } else if results.isEmpty == false {
                    section
                    ForEach(results) { dish in
                        AteRadioRow(
                            title: dish.name,
                            subtitle: dish.peopleCount.map(Self.people),
                            isSelected: pickedID == dish.id
                        ) {
                            pickedID = dish.id
                            query = dish.name
                        }
                    }
                }
                addRow
            }
        }
        .ateSurface()
        .onChange(of: menu.hasAnswered) { _, _ in
            if pickedID == nil { pickedID = menu.match(item.name) }
        }
    }

    /// "At Tipo 00" — the design's own heading, and the only place the place is named here.
    @ViewBuilder
    private var section: some View {
        if let placeName {
            Text(verbatim: "At \(placeName)")
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
                .padding(.top, AteMetrics.tight)
                .padding(.bottom, AteMetrics.snug)
        }
    }

    private var addRow: some View {
        Button {
            onPick(nil, query.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteIcon.compose.view(size: 20)
                    Text("Add as a new dish").ateText(.control)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 54)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var results: [PlaceDish] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Nothing typed yet: the whole menu, as `DishSheet.dc.html` shows it. The field carries the
        // line's own name, and filtering by it would leave the one row the sorter already chose —
        // which is the answer this sheet exists to question.
        guard needle.isEmpty == false, needle != item.name.lowercased() else { return menu.dishes }
        return menu.dishes.filter { $0.name.lowercased().contains(needle) || $0.id == pickedID }
    }

    private func commit() {
        if let pickedID {
            onPick(pickedID, nil)
        } else {
            let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
            onPick(nil, name.isEmpty ? item.name : name)
        }
    }

    private static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }
}

extension View {
    /// **The dish sheet** for one line of an entry, its place's menu read before it rises (round 5).
    func ateDishSheet(
        item: Binding<EntryModel.Correcting?>,
        directory: any PlaceDirectory,
        placeID: @escaping @MainActor () -> UUID?,
        placeName: @escaping @MainActor () -> String?,
        onPick: @escaping (AteReceipt.Item, UUID?, String?) -> Void
    ) -> some View {
        modifier(DishSheetPresenter(
            item: item, directory: directory, placeID: placeID, placeName: placeName, onPick: onPick
        ))
    }
}

private struct DishSheetPresenter: ViewModifier {
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
                DishSheet(menu: menu, placeName: placeName(), item: correcting.item) { dishID, dishName in
                    onPick(correcting.item, dishID, dishName)
                }
            }
        })
    }
}
