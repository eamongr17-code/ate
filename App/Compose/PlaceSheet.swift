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
/// Presented with ``SwiftUICore/View/atePlaceSheet(isPresented:directory:initialQuery:selected:onPick:)``,
/// which reads its first rows before it rises (round 5: it used to open blank, then jump full).
struct PlaceSheet: View {
    let model: PlaceSearchModel
    let directory: any PlaceDirectory
    let onPick: (PlaceRef) -> Void

    @State private var isAddingPlace = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        AteSheet(
            title: "Where was this?",
            searchPrompt: "Search places",
            searchText: $model.query,
            primary: primary,
            isPrimaryBusy: model.isResolving,
            isLoading: model.isReady == false
        ) {
            content(model)
        }
        .ateSurface()
        .task {
            #if DEBUG
            if ComposerDebugLaunch.opensAddPlace { isAddingPlace = true }
            #endif
        }
        .sheet(isPresented: $isAddingPlace) {
            AddPlaceSheet(directory: directory, suggestedName: model.query) { place in
                // Both sheets go in ONE step (round 4, bug c): the place sheet is dismissed with
                // "New place" still on it, which takes the pair down together. Closing "New place"
                // first showed "Where was this?" for a beat before it went too.
                onPick(place)
                dismiss()
            }
        }
    }

    /// "Use …" is there from the tap, and holds still until the row it names is real: a Google
    /// prediction resolves to a restaurant first, and a place with no row is never attached.
    private var primary: (title: String, action: () -> Void)? {
        guard let picked = model.picked else { return nil }
        return ("Use \(picked.name)", {
            guard model.isResolving == false, let resolved = model.picked, resolved.id != nil else { return }
            onPick(resolved)
        })
    }

    @ViewBuilder
    private func content(_ model: PlaceSearchModel) -> some View {
        VStack(alignment: .leading, spacing: AteMetrics.sheetGap) {
            if model.hasResultsAnswered == false {
                // Went up before its first rows (past ``SheetReadiness/limit``): still rows, at the
                // sheet's full height, filled in without a move.
                AteSheetSkeletonRows(count: 5)
            } else if model.results.isEmpty == false {
                section(model.sectionTitle) {
                    ForEach(model.results) { suggestion in
                        row(suggestion, model: model)
                    }
                }
            }
            // Absent, not empty, when there is no permission — the design has no "turn on location"
            // copy and this screen is not the place to invent any.
            if model.hasNearbyAnswered == false {
                AteSheetSkeletonRows(count: 3)
            } else if model.nearby.isEmpty == false {
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

extension View {
    /// **The place sheet**, the one way it is presented — the composer's Place key, an entry's place
    /// line, the Summary's placeless receipt. A fresh search each time it opens, its first rows (the
    /// recent or best-match places, and those nearby) read before it rises, so it opens full rather
    /// than blank-then-jumping (round 5).
    func atePlaceSheet(
        isPresented: Binding<Bool>,
        directory: any PlaceDirectory,
        initialQuery: @escaping @MainActor () -> String = { "" },
        selected: @escaping @MainActor () -> UUID? = { nil },
        onPick: @escaping (PlaceRef) -> Void
    ) -> some View {
        modifier(PlaceSheetPresenter(
            isPresented: isPresented, directory: directory,
            initialQuery: initialQuery, selected: selected, onPick: onPick
        ))
    }
}

private struct PlaceSheetPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let directory: any PlaceDirectory
    let initialQuery: @MainActor () -> String
    let selected: @MainActor () -> UUID?
    let onPick: (PlaceRef) -> Void

    @State private var model: PlaceSearchModel?

    func body(content: Content) -> some View {
        let holder = $model
        content.ateSheet(isPresented: $isPresented, name: "place", prepare: {
            let fresh = PlaceSearchModel(directory: directory, query: initialQuery(), selected: selected())
            holder.wrappedValue = fresh
            await fresh.start()
        }, content: {
            if let model {
                PlaceSheet(model: model, directory: directory, onPick: onPick)
            }
        })
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
    /// Whether the first rows (recent places, or the best match for what was typed) have answered.
    private(set) var hasResultsAnswered = false
    /// Whether Nearby has answered — rooms, or none (no permission is an answer too).
    private(set) var hasNearbyAnswered = false

    /// Everything the sheet opens with is in hand.
    var isReady: Bool { hasResultsAnswered && hasNearbyAnswered }

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
        defer { hasNearbyAnswered = true }
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
        hasResultsAnswered = true
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
        hasResultsAnswered = true
        adoptSelected(from: recent)
    }
}
