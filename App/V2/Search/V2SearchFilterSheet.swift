import AteKit
import SwiftUI

/// **Search's one filter sheet** — every filter for the scope on screen: the rating and the months as
/// two-thumb sliders, the diet pills, and cuisine and city as native menus. Nothing applies until the
/// ink pill at the foot, which carries a live count of what the draft would leave ("Show 4 dishes").
struct V2SearchFilterSheet: View {
    let store: SearchStore

    @State private var draft: SearchFilters
    @State private var live: LiveCount<SearchFilters>
    @Environment(\.dismiss) private var dismiss

    init(store: SearchStore) {
        self.store = store
        _draft = State(initialValue: store.filters)
        _live = State(initialValue: LiveCount { [store] draft in
            guard let count = try await store.count(with: draft, cap: V2SearchFilterMetrics.countCap) else {
                throw V2SearchFilterMetrics.NoCount()
            }
            return count
        })
    }

    var body: some View {
        AteSheetScaffold(
            title: "Filter",
            commit: .init(title: commitTitle) {
                store.setFilters(draft)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                AteFilterGroup(icon: .star, title: "Rating", readout: draft.band.summary) {
                    AteScoreRangeSlider(band: $draft.band)
                }
                AteFilterGroup(icon: .calendar, title: "Date", readout: draft.window.title() ?? "Any time") {
                    AteMonthRangeSlider(window: $draft.window)
                }
                AteFilterGroup(icon: .diet, title: "Diet", readout: nil) {
                    HStack(spacing: V2SearchFilterMetrics.dietGap) {
                        ForEach(DietTag.allCases, id: \.self) { tag in
                            AteDietPill(tag: tag, isOn: draft.tags.contains(tag)) { toggle(tag) }
                        }
                    }
                }
                AteFilterMenuRow(icon: .dish, title: "Cuisine", value: draft.cuisineSummary ?? "Any") {
                    Button("Any") { setCuisine(nil) }
                    ForEach(store.cuisines) { cuisine in
                        Button(cuisine.cuisine) { setCuisine(cuisine.cuisine) }
                    }
                }
                AteFilterMenuRow(icon: .place, title: "City", value: cityTitle) {
                    Button("Everywhere") { draft.city = nil }
                    ForEach(store.cities) { city in
                        Button(city.name) { draft.city = city.city }
                    }
                }
            }
        }
        .onChange(of: draft, initial: true) { _, draft in live.request(draft) }
        .task { await store.loadCuisines() }
        .task { await store.loadCitiesIfNeeded() }
    }

    // MARK: - The draft

    private var cityTitle: String {
        guard let city = draft.city else { return "Everywhere" }
        return AteCity.displayName(for: city, in: store.cities)
    }

    /// The draft with `tag` flipped, everything else kept.
    private func toggle(_ tag: DietTag) {
        let tags = draft.tags.contains(tag) ? draft.tags.filter { $0 != tag } : draft.tags + [tag]
        draft = rebuilt(tags: tags)
    }

    /// One cuisine, or any: the menu is a single choice.
    private func setCuisine(_ cuisine: String?) {
        draft = rebuilt(cuisines: cuisine.map { [$0] } ?? [])
    }

    private func rebuilt(cuisines: [String]? = nil, tags: [DietTag]? = nil) -> SearchFilters {
        SearchFilters(
            cuisines: cuisines ?? draft.cuisines,
            tags: tags ?? draft.tags,
            minimumScore: draft.minimumScore,
            maximumScore: draft.maximumScore,
            city: draft.city,
            window: draft.window
        )
    }

    // MARK: - The pill

    /// "Show 4 dishes", "Show 50+ places" — or, with nothing typed to count, "Show dishes".
    private var commitTitle: String {
        let noun = V2SearchFilterMetrics.noun(for: store.scope)
        guard live.draft == draft, let count = live.count else { return "Show \(noun.plural)" }
        if count >= V2SearchFilterMetrics.countCap { return "Show \(count)+ \(noun.plural)" }
        return "Show \(count) \(count == 1 ? noun.singular : noun.plural)"
    }
}

enum V2SearchFilterMetrics {
    /// One page is read for the count; at the cap it reads "50+".
    static let countCap = 50
    /// Between the diet pills.
    static let dietGap: CGFloat = 6

    struct NoCount: Error {}

    static func noun(for scope: SearchScope) -> (singular: String, plural: String) {
        switch scope {
        case .dishes, .saved: ("dish", "dishes")
        case .places: ("place", "places")
        case .people: ("person", "people")
        }
    }
}
