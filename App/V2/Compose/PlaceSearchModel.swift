import AteKit
import SwiftUI

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
