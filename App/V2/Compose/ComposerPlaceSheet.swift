import AteKit
import SwiftUI

/// **"Where was this?"** — the one place a place is chosen: the composer's Place key, a placeless
/// receipt, and an entry's place line, so the same action works identically in all three.
///
/// Search first; under it **Recent** (nothing typed) or **Best match**, then **Nearby** — the one
/// list in the app that asks for location, and only as this sheet opens. Nearby rooms are listed,
/// never attached. Tapping a row picks it and closes the sheet: there is no button (a Google
/// prediction is turned into a real row first, and a place with no row is never attached). "Add a
/// new place" is the last row, and opens a second sheet.
///
/// The search is the current sheet's (``PlaceSearchModel``): debounced, the last query wins, its
/// first rows read before the sheet rises.
struct V2PlaceSheet: View {
    let model: PlaceSearchModel
    let directory: any PlaceDirectory
    let onPick: (PlaceRef) -> Void

    @State private var isAddingPlace = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        AteSheetScaffold(
            title: "Where was this?",
            searchPrompt: "Search places",
            searchText: $model.query
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                if model.hasResultsAnswered == false {
                    AteSheetSkeletonRows(count: V2PlaceSheetMetrics.skeletonRows)
                } else if model.results.isEmpty == false {
                    group(model.sectionTitle, model.results)
                }
                if model.hasNearbyAnswered == false {
                    AteSheetSkeletonRows(count: V2PlaceSheetMetrics.nearbySkeletonRows)
                } else if model.nearby.isEmpty == false {
                    group("Nearby", model.nearby)
                }
                AteAddRow(title: "Add a new place", identifier: "place.add") { isAddingPlace = true }
            }
        }
        .sheet(isPresented: $isAddingPlace) {
            V2AddPlaceSheet(directory: directory, suggestedName: model.query) { place in
                // Both sheets go in one step: this one is dismissed with "New place" still on it,
                // which takes the pair down together.
                onPick(place)
                dismiss()
            }
        }
    }

    private func group(_ title: String, _ suggestions: [PlaceSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AteSheetSectionLabel(title: title)
            ForEach(suggestions) { suggestion in
                AteChoiceRow(
                    title: suggestion.name,
                    subtitle: suggestion.subtitle,
                    detail: suggestion.distance,
                    icon: .place,
                    isSelected: model.isSelected(suggestion)
                ) {
                    pick(suggestion)
                }
            }
        }
    }

    /// A tap resolves the row there and then, and closes the sheet once it is a real place.
    private func pick(_ suggestion: PlaceSuggestion) {
        AteHaptics.key()
        Task {
            await model.pick(suggestion)
            guard let picked = model.picked, picked.id != nil else {
                AteHaptics.refused()
                return
            }
            onPick(picked)
            dismiss()
        }
    }
}

/// **"New place"** — somewhere Google does not have, which in a launch market of small Melbourne
/// rooms is not an edge case. Name, Suburb, Street; the tick adds it (`add_manual_restaurant`).
struct V2AddPlaceSheet: View {
    let directory: any PlaceDirectory
    var suggestedName = ""
    let onAdded: (PlaceRef) -> Void

    @State private var name = ""
    @State private var suburb = ""
    @State private var street = ""
    @State private var isSaving = false
    @State private var failed = false

    var body: some View {
        AteSheetScaffold(
            title: "New place",
            primary: AteSheetPrimary(
                icon: .check,
                label: "Add place",
                isEnabled: trimmed(name).isEmpty == false,
                isBusy: isSaving,
                action: add
            )
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
                AteFieldPill(label: "Name", text: $name)
                AteFieldPill(label: "Suburb", text: $suburb)
                AteFieldPill(label: "Street", text: $street, prompt: "Optional")
            }
        }
        .onAppear { if name.isEmpty { name = suggestedName } }
        .alert(ActionFailure.addPlace.title, isPresented: $failed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let named = trimmed(name)
        guard named.isEmpty == false, isSaving == false else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            guard let place = try? await directory.add(name: named, suburb: trimmed(suburb), street: trimmed(street)),
                  place.id != nil else {
                failed = true
                return
            }
            onAdded(place)
        }
    }
}

extension View {
    /// **The place sheet**, the one way it is presented: a fresh search each time it opens, its first
    /// rows (recent or best-match places, and those nearby) read before it rises, so it opens full.
    func v2PlaceSheet(
        isPresented: Binding<Bool>,
        directory: any PlaceDirectory,
        initialQuery: @escaping @MainActor () -> String = { "" },
        selected: @escaping @MainActor () -> UUID? = { nil },
        onPick: @escaping (PlaceRef) -> Void
    ) -> some View {
        modifier(V2PlaceSheetPresenter(
            isPresented: isPresented, directory: directory,
            initialQuery: initialQuery, selected: selected, onPick: onPick
        ))
    }
}

private struct V2PlaceSheetPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let directory: any PlaceDirectory
    let initialQuery: @MainActor () -> String
    let selected: @MainActor () -> UUID?
    let onPick: (PlaceRef) -> Void

    @State private var holder = AteSheetHolder<PlaceSearchModel>()

    func body(content: Content) -> some View {
        let holder = holder
        content.ateSheet(isPresented: $isPresented, name: "place", prepare: {
            let fresh = PlaceSearchModel(directory: directory, query: initialQuery(), selected: selected())
            holder.value = fresh
            await fresh.start()
        }, content: {
            AteSheetHolderView(holder: holder) { model in
                V2PlaceSheet(model: model, directory: directory, onPick: onPick)
            }
        })
    }
}

enum V2PlaceSheetMetrics {
    static let skeletonRows = 5
    static let nearbySkeletonRows = 3
}
