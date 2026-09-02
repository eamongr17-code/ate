import AteKit
import SwiftUI

/// The restaurant subject's list (§11.1, §11.2, §11.5).
///
/// Sections: empty query → Nearby, then Recent. Query ≥2 chars → **one flat Results section** in the
/// server's order. Never both, never a re-sort, never a flash to empty.
struct RestaurantPickerList: View {
    let services: SearchServices
    let context: SearchContextName
    let searchText: String
    let onSelect: (PickedRestaurant) -> Void

    @State private var model: RestaurantPickerModel
    @State private var location = SearchLocationProvider()
    @State private var isLocationHintDismissed = false
    /// Parked by ``AddRestaurantSheet`` and handed on once the sheet is actually gone.
    @State private var addedRestaurant: PickedRestaurant?

    init(
        services: SearchServices,
        context: SearchContextName,
        searchText: String,
        onSelect: @escaping (PickedRestaurant) -> Void
    ) {
        self.services = services
        self.context = context
        self.searchText = searchText
        self.onSelect = onSelect
        _model = State(initialValue: RestaurantPickerModel(services: services))
    }

    var body: some View {
        List {
            if let results = model.results {
                resultsSection(results)
            } else {
                defaultSections
            }

            if let failure = model.failure {
                SearchRetryRow(failure: failure) {
                    model.clearFailure()
                }
            }
        }
        .listStyle(.plain)
        .task {
            model.markOpened(context: context)
            // §6.1: the location prompt happens here — on first open of the picker, not at launch.
            await location.requestFix()
            await model.loadDefaults(origin: location.origin)
        }
        // Debounce AND stale-response guard in one: a new keystroke cancels the in-flight task, so a
        // slow answer for an abandoned query can never land on top of a newer one.
        .task(id: searchText) {
            guard !searchText.isEmpty else {
                await model.search("")
                return
            }
            try? await Task.sleep(for: SearchQueryPolicy.debounce)
            guard !Task.isCancelled else { return }
            await model.search(searchText, origin: location.origin)
        }
        // The selection is delivered on DISMISS, not from inside the sheet. `onSelect` is what the
        // Log flow uses to rewrite its navigation path; running it while the sheet was still going
        // away meant a dismissal and a push in the same turn of the run loop, which on a device
        // resolves as "nothing happened".
        .sheet(item: $model.addRestaurantRequest, onDismiss: deliverAddedRestaurant) { request in
            AddRestaurantSheet(name: request.name) { name, suburb, cuisine in
                await model.addManual(name: name, suburb: suburb, cuisine: cuisine)
            } onAdded: { picked in
                addedRestaurant = picked
            }
        }
    }

    private func deliverAddedRestaurant() {
        guard let picked = addedRestaurant else { return }
        addedRestaurant = nil
        onSelect(picked)
    }

    // MARK: - Sections

    @ViewBuilder
    private func resultsSection(_ results: [RestaurantRowModel]) -> some View {
        Section {
            // §11.5: the stock empty state — but NOT when the create row is there. A
            // `ContentUnavailableView` in a list row is greedy: on a phone with the keyboard up it
            // filled the visible list and pushed "Add “…” as a restaurant" below the fold, so the
            // one screen that offers the fallback looked like a dead end. The dish picker already
            // had this guard; the restaurant picker didn't, and that is the whole of
            // "add-restaurant doesn't work". The create row IS the empty state's action.
            if results.isEmpty, !model.isSearching, model.createQuery == nil {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                rowButton(row, index: index)
            }
            if let createQuery = model.createQuery {
                // A `Button`, like every other row: a bare `.onTapGesture` inside a `List` competes
                // with the list's own touch handling and gives the row no accessibility trait.
                // §11.2's "never a top-level button" is about *position* — it is still the last row.
                Button {
                    model.addRestaurantRequest = AddRestaurantRequest(name: createQuery)
                } label: {
                    SearchCreateRow(title: "Add “\(createQuery)” as a restaurant", isBusy: false)
                }
                .buttonStyle(.plain)
            }
        } header: {
            sectionHeader("Results", isBusy: model.isSearching)
        }
    }

    @ViewBuilder
    private var defaultSections: some View {
        if !model.hasLoadedDefaults {
            Section { SearchPlaceholderRows() }
        } else {
            if location.isDenied, !isLocationHintDismissed {
                locationHint
            }
            if !model.nearby.isEmpty {
                Section {
                    ForEach(Array(model.nearby.enumerated()), id: \.element.id) { index, row in
                        rowButton(row, index: index)
                    }
                } header: {
                    sectionHeader("Nearby", isBusy: false)
                }
            }
            if !model.recents.isEmpty {
                Section {
                    ForEach(Array(model.recents.enumerated()), id: \.element.id) { index, row in
                        rowButton(row, index: index)
                    }
                } header: {
                    sectionHeader("Recent", isBusy: false)
                }
            }
            if model.nearby.isEmpty, model.recents.isEmpty, model.failure == nil {
                ContentUnavailableView(
                    "Search for a place",
                    systemImage: "magnifyingglass",
                    description: Text("Start typing a restaurant name.")
                )
                .listRowSeparator(.hidden)
            }
        }
    }

    /// §6.1: one dismissible caption, never a nag, never a second permission prompt.
    private var locationHint: some View {
        HStack(spacing: Theme.Spacing.snug) {
            Label("Turn on location to see nearby places", systemImage: "location.slash")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer(minLength: Theme.Spacing.snug)
            Button {
                isLocationHintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ title: LocalizedStringKey, isBusy: Bool) -> some View {
        HStack(spacing: Theme.Spacing.snug) {
            Text(title)
            if isBusy {
                ProgressView().controlSize(.mini)
            }
        }
    }

    // MARK: - Rows

    private func rowButton(_ row: RestaurantRowModel, index: Int) -> some View {
        Button {
            Task {
                if let picked = await model.select(row, index: index) {
                    onSelect(picked)
                }
            }
        } label: {
            RestaurantResultRow(row: row, isResolving: model.resolvingRowID == row.id)
        }
        .buttonStyle(.plain)
        // §11.5: "Resolving: spinner on the tapped row only; second tap ignored." The rest of the
        // list stays interactive on purpose.
        .disabled(model.resolvingRowID == row.id)
    }
}

/// `sheet(item:)` needs an `Identifiable` payload; the create-fallback's is just the typed query.
/// A wrapper rather than a retroactive `String: Identifiable`, which would leak into every file.
struct AddRestaurantRequest: Identifiable, Hashable {
    let id = UUID()
    let name: String
}
