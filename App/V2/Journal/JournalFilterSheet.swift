import AteKit
import SwiftUI

/// **The Journal's one filter sheet** — and the Saved tab's, less the order: Sort as a segmented control,
/// the Rating's two-thumb range, the City as a native menu, and the Date's two-thumb range over
/// months. It edits a draft of the whole filter; the ink pill at the foot counts as you drag
/// ("Show 12 entries") and applies it.
struct JournalFilterSheet: View {
    let shelf: BrowseChip.Shelf
    let cities: [AteCity]
    let onShow: (BrowseFilters) -> Void

    @State private var draft: BrowseFilters
    @State private var live: LiveCount<BrowseFilters>
    @Environment(\.dismiss) private var dismiss

    init(
        shelf: BrowseChip.Shelf,
        initial: BrowseFilters,
        cities: [AteCity],
        count: @escaping @Sendable (BrowseFilters) async throws -> Int,
        onShow: @escaping (BrowseFilters) -> Void
    ) {
        self.shelf = shelf
        self.cities = cities
        self.onShow = onShow
        _draft = State(initialValue: initial)
        _live = State(initialValue: LiveCount(read: count))
    }

    var body: some View {
        AteSheetScaffold(
            title: "Filter",
            commit: .init(title: showTitle) {
                onShow(draft)
                dismiss()
            }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if shelf == .journal {
                    AteFilterGroup(icon: .arrowDownWideNarrow, title: "Sort", readout: nil) {
                        AteSegmentedControl(
                            options: JournalSort.allCases.map { AteSegment($0, $0.title) },
                            selection: $draft.sort,
                            identifier: "filter.sort"
                        )
                    }
                }
                AteFilterGroup(icon: .star, title: "Rating", readout: draft.band.summary) {
                    AteScoreRangeSlider(band: $draft.band)
                }
                AteFilterMenuRow(icon: .place, title: "City", value: cityTitle) {
                    ForEach(AteCityOption.cities(cities, keeping: draft.city)) { option in
                        Button(option.title) {
                            draft.city = option.id == AteCityOption.everywhereID ? nil : option.id
                        }
                    }
                }
                AteFilterGroup(icon: .calendar, title: "Date", readout: draft.window.title() ?? "Any time") {
                    AteMonthRangeSlider(window: $draft.window)
                }
            }
        }
        .onChange(of: draft, initial: true) { _, now in live.request(now) }
    }

    private var cityTitle: String {
        draft.city.map { AteCity.displayName(for: $0, in: cities) } ?? AteCityOption.everywhere.title
    }

    /// "Show 12 entries" on the Journal, "Show 3 dishes" on Saved — the noun alone until the count
    /// has answered.
    private var showTitle: String {
        let (one, many) = shelf == .journal ? ("entry", "entries") : ("dish", "dishes")
        guard let count = live.count else { return "Show \(many)" }
        return "Show \(count) \(count == 1 ? one : many)"
    }
}
