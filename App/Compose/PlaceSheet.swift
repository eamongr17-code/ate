import AteKit
import SwiftUI

/// **`PlaceSheet`** — "Where was this?". The one place a place is chosen, shared by the composer's
/// Place key and the entry's receipt header, so the same action works identically in both.
///
/// Two sections, as `PlaceSheet.dc.html` draws them: **Best match**, which comes from the words
/// somebody typed, and **Nearby**, which comes from the phone — the one screen in the app that asks
/// for location, and only as this sheet opens. Design rule 8 is untouched by that: nearby rooms are
/// *listed*, never attached. A place lands on an entry because it was named or tapped, and a refused
/// permission costs exactly one section.
struct PlaceSheet: View {
    let directory: any PlaceDirectory
    /// Pre-filled with what the person already typed, when there is something to go on — the words,
    /// never a location.
    var initialQuery: String = ""
    var selected: UUID?
    let onPick: (PlaceRef) -> Void

    @State private var model: PlaceSearchModel?
    @State private var isAddingPlace = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(
            title: "Where was this?",
            searchPrompt: "Search places",
            searchText: Binding(
                get: { model?.query ?? initialQuery },
                set: { model?.query = $0 }
            ),
            primary: primary,
            isPrimaryBusy: model?.isResolving ?? false
        ) {
            if let model {
                content(model)
            }
        }
        .ateSurface()
        // `PlaceSheet.dc.html` is 716 of the page's 844.
        .presentationDetents([.height(AteScreen.sheetHeight(716))])
        .task {
            let model = model ?? PlaceSearchModel(
                directory: directory, query: initialQuery, selected: selected
            )
            self.model = model
            #if DEBUG
            if ComposerDebugLaunch.opensAddPlace { isAddingPlace = true }
            #endif
            await model.start()
        }
        .sheet(isPresented: $isAddingPlace) {
            AddPlaceSheet(directory: directory, suggestedName: model?.query ?? "") { place in
                isAddingPlace = false
                onPick(place)
            }
        }
    }

    /// "Use …" is there from the tap, and holds still until the row it names is real: a Google
    /// prediction resolves to a restaurant first, and a place with no row is never attached.
    private var primary: (title: String, action: () -> Void)? {
        guard let model, let picked = model.picked else { return nil }
        return ("Use \(picked.name)", {
            guard model.isResolving == false, let resolved = model.picked, resolved.id != nil else { return }
            onPick(resolved)
        })
    }

    @ViewBuilder
    private func content(_ model: PlaceSearchModel) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            if model.results.isEmpty == false {
                section(model.sectionTitle) {
                    ForEach(model.results) { suggestion in
                        row(suggestion, model: model)
                    }
                }
            }
            // Absent, not empty, when there is no permission — the design has no "turn on location"
            // copy and this screen is not the place to invent any.
            if model.nearby.isEmpty == false {
                section("Nearby") {
                    ForEach(model.nearby) { suggestion in
                        row(suggestion, model: model)
                    }
                    addPlaceRow
                }
            } else {
                addPlaceRow
            }
        }
    }

    private func row(_ suggestion: PlaceSuggestion, model: PlaceSearchModel) -> some View {
        AteListRow(
            title: suggestion.name,
            subtitle: suggestion.subtitle,
            leading: { AteIcon.place.view(size: 20) },
            trailing: {
                HStack(spacing: AteMetrics.regular) {
                    if let distance = suggestion.distance {
                        Text(distance)
                            .ateText(.meta)
                            .foregroundStyle(AtePalette.surface.muted)
                    }
                    AteRadioMark(isSelected: model.isSelected(suggestion))
                }
            },
            action: { Task { await model.pick(suggestion) } }
        )
        .accessibilityAddTraits(model.isSelected(suggestion) ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("row.\(suggestion.name)")
    }

    private var addPlaceRow: some View {
        Button {
            isAddingPlace = true
        } label: {
            VStack(spacing: 0) {
                AteHairline()
                HStack(spacing: AteMetrics.regular) {
                    AteIcon.compose.view(size: 20)
                    Text("Add a new place").ateText(.control)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 54)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("place.add")
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
                .padding(.top, AteMetrics.tight)
                .padding(.bottom, AteMetrics.snug)
            rows()
        }
    }
}

/// The sheet's searching, debounced, with the last query winning.
@MainActor
@Observable
final class PlaceSearchModel {
    var query: String {
        didSet {
            guard query != oldValue else { return }
            schedule()
        }
    }

    private(set) var results: [PlaceSuggestion] = []
    /// The rooms around the phone. Empty when the permission was never given — the section then
    /// simply is not drawn.
    private(set) var nearby: [PlaceSuggestion] = []
    private(set) var picked: PlaceRef?
    /// A tapped Google result is being turned into a restaurant row.
    private(set) var isResolving = false
    private(set) var isSearching = false
    /// True while the results are the empty-query default rather than a search.
    private(set) var isShowingRecents = true

    private let directory: any PlaceDirectory
    private let location = AteLocation()
    private var search: Task<Void, Never>?
    private var pickedSuggestionID: String?
    /// The place the entry already carries. It comes back marked and its "Use …" button is there
    /// from the first frame — a sheet that opens with nothing chosen makes the person re-pick the
    /// answer they already gave.
    private let selectedRestaurantID: UUID?

    /// Long enough that a fast typist costs one Places call rather than eight, short enough that it
    /// never feels like waiting.
    private static let debounce = Duration.milliseconds(280)

    init(directory: any PlaceDirectory, query: String = "", selected: UUID? = nil) {
        self.directory = directory
        self.query = query
        self.selectedRestaurantID = selected
    }

    var sectionTitle: String { isShowingRecents ? "Recent" : "Best match" }

    func isSelected(_ suggestion: PlaceSuggestion) -> Bool {
        if let pickedSuggestionID { return pickedSuggestionID == suggestion.id }
        return suggestion.restaurantID != nil && suggestion.restaurantID == selectedRestaurantID
    }

    func start() async {
        async let near: Void = loadNearby()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            await run()
        } else {
            await loadRecents()
        }
        await near
    }

    /// The one location ask in the app, made as the sheet opens. No permission, no section.
    private func loadNearby() async {
        guard let coordinate = await location.current() else { return }
        nearby = (try? await directory.nearby(
            latitude: coordinate.latitude, longitude: coordinate.longitude
        )) ?? []
    }

    /// Tapping a row resolves it there and then: a Google prediction becomes a real row, which is
    /// what `restaurant_id` on the entry has to be.
    func pick(_ suggestion: PlaceSuggestion) async {
        pickedSuggestionID = suggestion.id
        picked = PlaceRef(id: suggestion.restaurantID, name: suggestion.name)
        guard suggestion.restaurantID == nil else {
            isResolving = false
            return
        }
        isResolving = true
        let resolved = try? await directory.resolve(suggestion)
        // A later tap owns the pill now; this answer is for a row nobody is pointing at.
        guard pickedSuggestionID == suggestion.id else { return }
        isResolving = false
        // Failed to resolve: the row stays marked, but there is nothing real to attach, so the pill
        // goes rather than offering a place that would attach nothing.
        picked = resolved?.id == nil ? nil : resolved
        if picked == nil { pickedSuggestionID = nil }
    }

    private func schedule() {
        search?.cancel()
        search = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard Task.isCancelled == false else { return }
            await self?.run()
        }
    }

    private func run() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            await loadRecents()
            return
        }
        isSearching = true
        defer { isSearching = false }
        let found = (try? await directory.search(trimmed)) ?? []
        guard Task.isCancelled == false else { return }
        isShowingRecents = false
        results = found
        adoptSelected(from: found)
    }

    /// The place the entry already has, found in a result set — so its "Use …" button is live
    /// without a tap.
    private func adoptSelected(from suggestions: [PlaceSuggestion]) {
        guard picked == nil, let selectedRestaurantID,
              let match = suggestions.first(where: { $0.restaurantID == selectedRestaurantID })
        else { return }
        picked = PlaceRef(id: selectedRestaurantID, name: match.name)
    }

    private func loadRecents() async {
        let recent = (try? await directory.recents(limit: 5)) ?? []
        guard Task.isCancelled == false else { return }
        isShowingRecents = true
        results = recent
        adoptSelected(from: recent)
    }
}
