import AteKit
import SwiftUI

/// **`DishSheet`** — "Which dish?". The correction for one line of a receipt.
///
/// The sorter names a dish from the person's own words; this is where the person says what it
/// actually was. A menu pick passes the dish's id, "Add as a new dish" passes the name — the two
/// halves of `correct_entry_dish`. Score and note are untouched either way: they are the person's,
/// and nothing here is allowed near them.
struct DishSheet: View {
    let directory: any PlaceDirectory
    let placeID: UUID?
    let placeName: String?
    let item: AteReceipt.Item
    /// `(dishID, dishName)` — exactly one is non-nil.
    let onPick: (UUID?, String?) -> Void

    @State private var query: String
    @State private var menu: [PlaceDish] = []
    @State private var pickedID: UUID?
    @Environment(\.dismiss) private var dismiss

    init(
        directory: any PlaceDirectory,
        placeID: UUID?,
        placeName: String?,
        item: AteReceipt.Item,
        onPick: @escaping (UUID?, String?) -> Void
    ) {
        self.directory = directory
        self.placeID = placeID
        self.placeName = placeName
        self.item = item
        self.onPick = onPick
        _query = State(initialValue: item.name)
    }

    var body: some View {
        AteSheet(
            title: "Which dish?",
            searchPrompt: "Search dishes",
            searchText: $query,
            primary: ("Done", commit)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if results.isEmpty == false {
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
        .task { await load() }
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
            HStack(spacing: AteMetrics.regular) {
                AteIcon.compose.view(size: 20)
                Text("Add as a new dish").ateText(.control)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 54)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .overlay(alignment: .top) { AteHairline() }
    }

    private var results: [PlaceDish] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.isEmpty == false else { return menu }
        return menu.filter { $0.name.lowercased().contains(needle) || $0.id == pickedID }
    }

    private func load() async {
        guard let placeID else { return }
        menu = (try? await directory.dishes(atPlace: placeID, limit: 50)) ?? []
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
