import AteKit
import SwiftUI

/// **What the one filter sheet edits** (round 5): an order (the Journal only), a score range, and a
/// city. Eamon: "Filters are too complex. They should just allow a range setting, and place should
/// only be filterable by city, not by individual restaurant."
struct AteBrowseFilterDraft: Hashable {
    var sort: JournalSort = .newest
    var band: ScoreBand = .all
    /// A city slug, or `nil` for everywhere.
    var city: String?
}

/// **The one filter sheet** — the Journal's, Saved's and Search's alike: the order as a segment
/// (where the list has one), the score range as the ruler, and the city as the one picker's pills.
/// Nothing is applied until Done.
struct AteBrowseFilterSheet: View {
    let cities: [AteCity]
    /// Whether ``cities`` has answered — until it has, the sheet stands at full height with still
    /// pills where they will be (#83).
    let areCitiesLoaded: Bool
    let showsSort: Bool
    let onDone: (AteBrowseFilterDraft) -> Void

    @State private var draft: AteBrowseFilterDraft

    init(
        initial: AteBrowseFilterDraft,
        cities: [AteCity],
        areCitiesLoaded: Bool = true,
        showsSort: Bool,
        onDone: @escaping (AteBrowseFilterDraft) -> Void
    ) {
        self.cities = cities
        self.areCitiesLoaded = areCitiesLoaded
        self.showsSort = showsSort
        self.onDone = onDone
        _draft = State(initialValue: initial)
    }

    var body: some View {
        AteFilterSheet(isLoading: areCitiesLoaded == false) {
            if showsSort {
                AteSegments(
                    options: JournalSort.allCases.map { AteSegment($0, $0.title) },
                    selection: $draft.sort
                )
            }
            AteScoreRange(band: $draft.band)
            // Everywhere and the current choice, at the least — a list that has not arrived yet (or
            // failed) still lets a city be taken off.
            AteCityPicker(
                options: AteCityOption.cities(cities, keeping: draft.city),
                selection: draft.city ?? AteCityOption.everywhereID,
                isLoading: areCitiesLoaded == false
            ) { option in
                draft.city = option.id == AteCityOption.everywhereID ? nil : option.id
            }
        } onDone: {
            onDone(draft)
        }
    }
}
