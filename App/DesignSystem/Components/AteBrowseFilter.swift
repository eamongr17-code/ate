import AteKit
import SwiftUI

/// **What the one filter sheet edits** (round 5): an order (the Journal and its Saved shelf only),
/// a score range, and a city. Eamon: "Filters are too complex. They should just allow a range
/// setting, and place should only be filterable by city, not by individual restaurant."
struct AteBrowseFilterDraft: Hashable {
    var sort: JournalSort = .newest
    var band: ScoreBand = .all
    var city: String?
}

/// **The one filter sheet** — the Journal's, Saved's and Search's alike: the order as a segment
/// (where the list has one), the score range, and the city. Nothing is applied until Done.
///
/// Two layouts are on the table (``JSExplore/filterSheet``):
/// - **A** — the slider (ink span, ringed thumbs, the two ends as score tokens) and the cities as
///   radio rows;
/// - **B** — the ruler (half-step ticks on a butter band) and the cities as a wrap of pills.
struct AteBrowseFilterSheet: View {
    let cities: [AteCity]
    let showsSort: Bool
    let onDone: (AteBrowseFilterDraft) -> Void

    @State private var draft: AteBrowseFilterDraft
    private let variant = JSExplore.filterSheet

    init(
        initial: AteBrowseFilterDraft,
        cities: [AteCity],
        showsSort: Bool,
        onDone: @escaping (AteBrowseFilterDraft) -> Void
    ) {
        self.cities = cities
        self.showsSort = showsSort
        self.onDone = onDone
        _draft = State(initialValue: initial)
    }

    var body: some View {
        AteFilterSheet {
            if showsSort {
                AteSegments(
                    options: JournalSort.allCases.map { AteSegment($0, $0.title) },
                    selection: $draft.sort
                )
            }
            AteScoreRange(band: $draft.band, style: variant == .b ? .ruler : .slider)
            if cities.isEmpty == false {
                AteCityPicker(
                    options: [.everywhere] + cities.map { AteCityOption(id: $0.city, title: $0.name) },
                    selection: draft.city ?? AteCityOption.everywhereID,
                    style: variant == .b ? .pills : .rows
                ) { option in
                    draft.city = option.id == AteCityOption.everywhereID ? nil : option.id
                }
            }
        } onDone: {
            onDone(draft)
        }
    }
}
