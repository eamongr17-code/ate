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
            if results.isEmpty, !model.isSearching, model.createQuery == nil {
                ContentUnavailableView.search(text: searchText)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                rowButton(row, index: index)
            }
            if let createQuery = model.createQuery {
                // §11.4: LAST row, and only when nothing here is case-insensitively equal to what
                // was typed. A `Button` rather than a bare `.onTapGesture`, like every sibling row —
                // §11.4's "never a top-level button" is about position, not about the control.
                Button {
                    Task {
                        if let picked = await model.createDish(named: createQuery) {
                            onSelect(picked)
                        }
                    }
                } label: {
                    SearchCreateRow(title: "Add “\(createQuery)” as a new dish", isBusy: model.isCreating)
                }
                .buttonStyle(.plain)
                .disabled(model.isCreating)
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
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "fork.knife",
                    description: Text(emptyDescription)
                )
                .listRowSeparator(.hidden)
            }
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
