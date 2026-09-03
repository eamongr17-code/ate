import AteKit
import SwiftUI

/// The dish subjects' list (§11.3, §11.4, §11.5).
///
/// Within a restaurant: "You've had here" then "On the menu", or one flat filtered list from the
/// first character. In the Search tab's global scope: "Most reviewed", and no create-fallback.
struct DishPickerList: View {
    let subject: SearchSubject
    let services: SearchServices
    let context: SearchContextName
    let searchText: String
    let onSelect: (PickedDish) -> Void
    /// Set true to ask the HOST to focus its search field. The field belongs to `.searchable`,
    /// which lives on ``SearchPicker``; `@FocusState` doesn't reach up, so the request travels down
    /// as a binding instead.
    @Binding var requestSearchFocus: Bool

    @State private var model: DishPickerModel
    @State private var hasAppliedKeyboardRule = false
    /// Parked by ``AddDishSheet`` and handed on once the sheet is actually gone.
    @State private var addedDish: PickedDish?

    init(
        subject: SearchSubject,
        services: SearchServices,
        context: SearchContextName,
        searchText: String,
        requestSearchFocus: Binding<Bool>,
        onSelect: @escaping (PickedDish) -> Void
    ) {
        _requestSearchFocus = requestSearchFocus
        self.subject = subject
        self.services = services
        self.context = context
        self.searchText = searchText
        self.onSelect = onSelect
        _model = State(initialValue: DishPickerModel(services: services, subject: subject))
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
                    Task { await model.retry() }
                }
            }
        }
        .listStyle(.plain)
        .task {
            model.markOpened(context: context)
            await model.loadDefaults()
            applyKeyboardRule()
        }
        .task(id: searchText) {
            guard !searchText.isEmpty else {
                await model.search("")
                return
            }
            try? await Task.sleep(for: SearchQueryPolicy.debounce)
            guard !Task.isCancelled else { return }
            await model.search(searchText)
        }
        // Delivered on DISMISS, not from inside the sheet: `onSelect` rewrites the Log flow's
        // navigation path, and a dismissal plus a push in the same run-loop turn resolves on a
        // device as "nothing happened" (the rule ``AddRestaurantSheet`` was fixed for).
        .sheet(item: $model.addDishRequest, onDismiss: deliverAddedDish) { request in
            AddDishSheet(request: request) { name in
                await model.createDish(named: name)
            } onAdded: { picked in
                addedDish = picked
            }
        }
    }

    private func deliverAddedDish() {
        guard let picked = addedDish else { return }
        addedDish = nil
        onSelect(picked)
    }

    /// §11.3 KEYBOARD RULE — auto-focus **only** if both default sections came back empty. Applied
    /// once: re-focusing after the user has dismissed the keyboard would be a fight, not a help.
    private func applyKeyboardRule() {
        guard !hasAppliedKeyboardRule else { return }
        hasAppliedKeyboardRule = true
        if model.shouldAutoFocusSearchField {
            requestSearchFocus = true
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func resultsSection(_ results: [DishRowModel]) -> some View {
        Section {
            if results.isEmpty, !model.isSearching {
                emptyResultsNotice
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                rowButton(row, index: index)
            }
            // §6: LAST row, always present — the gate now chooses the behaviour, not the existence.
            createRow
        } header: {
            sectionHeader("Results", isBusy: model.isSearching)
        }
    }

    /// §6 says the add row sits *beneath* the empty state, never instead of it. A full
    /// `ContentUnavailableView` in a list row is greedy, though: with the keyboard up it fills the
    /// visible list and pushes the row below the fold, which is how "add a dish doesn't work" got
    /// reported before. So the empty state keeps its words and gives up its height whenever there is
    /// a row underneath that must stay reachable.
    @ViewBuilder
    private var emptyResultsNotice: some View {
        if model.offersCreateFallback {
            Text("No dishes here match “\(searchText)”.")
                .font(Theme.Text.detail)
                .foregroundStyle(Theme.Color.textSecondary)
                .listRowSeparator(.hidden)
        } else {
            ContentUnavailableView.search(text: searchText)
                .listRowSeparator(.hidden)
        }
    }

    /// The standing add row (§6). Absent only in the Search tab's global Dishes scope, where a dish
    /// can't be created at all — you can't add a dish without saying where it is (§10).
    @ViewBuilder
    private var createRow: some View {
        if model.offersCreateFallback {
            Button(action: tapCreateRow) {
                SearchCreateRow(title: createRowTitle, isBusy: model.isCreating)
            }
            .buttonStyle(.plain)
            .disabled(model.isCreating)
        }
    }

    private var createRowTitle: LocalizedStringKey {
        guard let query = model.createRow.query else { return "Add a new dish" }
        return "Add “\(query)” as a new dish"
    }

    /// One tap, three outcomes (§6): create-and-select with no form, an empty form, or a pre-filled
    /// form that won't accept a name already taken here.
    private func tapCreateRow() {
        model.recordCreateRowTapped()
        switch model.createRow {
        case .direct(let name):
            Task {
                if let picked = await model.createDish(named: name) { onSelect(picked) }
            }
        case .empty:
            model.addDishRequest = AddDishRequest(name: "", existingNames: model.visibleNames)
        case .prefilled(let name, _):
            model.addDishRequest = AddDishRequest(name: name, existingNames: model.visibleNames)
        }
    }

    @ViewBuilder
    private var defaultSections: some View {
        if !model.hasLoadedDefaults {
            Section { SearchPlaceholderRows() }
        } else {
            if !model.history.isEmpty {
                Section {
                    ForEach(Array(model.history.enumerated()), id: \.element.id) { index, row in
                        rowButton(row, index: index)
                    }
                } header: {
                    sectionHeader("You've had here", isBusy: false)
                }
            }
            if !model.menu.isEmpty {
                Section {
                    ForEach(Array(model.menu.enumerated()), id: \.element.id) { index, row in
                        rowButton(row, index: index)
                            .task {
                                if index == model.menu.count - 1 {
                                    await model.loadMore()
                                }
                            }
                    }
                    if model.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    sectionHeader(menuSectionTitle, isBusy: false)
                }
            }
            if model.history.isEmpty, model.menu.isEmpty, model.failure == nil {
                Text(emptyDescription)
                    .font(Theme.Text.detail)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .listRowSeparator(.hidden)
            }
            // §6: under the defaults the add row is its own final, unheaded section — a row of
            // "You've had here" or "On the menu" it is not.
            Section { createRow }
        }
    }

    private var menuSectionTitle: LocalizedStringKey {
        subject.restaurantID == nil ? "Most reviewed" : "On the menu"
    }

    private var emptyDescription: LocalizedStringKey {
        subject.restaurantID == nil
            ? "Search for a dish by name."
            : "Type a dish name to add the first one."
    }

    private func sectionHeader(_ title: LocalizedStringKey, isBusy: Bool) -> some View {
        HStack(spacing: Theme.Spacing.snug) {
            Text(title)
            if isBusy {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func rowButton(_ row: DishRowModel, index: Int) -> some View {
        Button {
            onSelect(model.select(row, index: index))
        } label: {
            DishResultRow(row: row)
        }
        .buttonStyle(.plain)
    }
}
