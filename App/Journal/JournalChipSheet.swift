import AteKit
import SwiftUI

/// **One chip's sheet** on the Journal or Saved (round 7): the Rating's two-thumb slider and its
/// presets (`RatingChip`), the Date's slider over months, the City's pills, the order as a list —
/// each in the same small fitted sheet (``AteChipSheet``) with its live "Show N entries".
///
/// It edits a draft of the whole filter and hands it back on Show; Clear puts its own dimension back
/// to nothing, in the draft.
struct JournalChipSheet: View {
    let chip: BrowseChip
    let shelf: BrowseChip.Shelf
    let cities: [AteCity]
    let areCitiesLoaded: Bool
    let onShow: (BrowseFilters) -> Void

    @State private var draft: BrowseFilters
    @State private var live: LiveCount<BrowseFilters>
    @Environment(\.dismiss) private var dismiss

    init(
        chip: BrowseChip,
        shelf: BrowseChip.Shelf,
        initial: BrowseFilters,
        cities: [AteCity],
        areCitiesLoaded: Bool,
        count: @escaping @Sendable (BrowseFilters) async throws -> Int,
        onShow: @escaping (BrowseFilters) -> Void
    ) {
        self.chip = chip
        self.shelf = shelf
        self.cities = cities
        self.areCitiesLoaded = areCitiesLoaded
        self.onShow = onShow
        _draft = State(initialValue: initial)
        _live = State(initialValue: LiveCount(read: count))
    }

    var body: some View {
        AteChipSheet(
            title: title,
            value: value,
            count: live.count,
            noun: shelf == .journal ? .entries : .dishes,
            onClear: { draft = draft.clearing(chip) },
            onShow: {
                onShow(draft)
                dismiss()
            },
            content: { content }
        )
        .onChange(of: draft, initial: true) { _, now in live.request(now) }
        .accessibilityIdentifier("chipsheet.\(chip.rawValue)")
    }

    private var title: String {
        switch chip {
        case .sort: "Sort"
        case .rating: "Rating"
        case .city: "City"
        case .date: "Date"
        }
    }

    private var value: String {
        switch chip {
        case .sort: draft.sort.title
        case .rating: draft.band.summary
        case .city: draft.city.map { AteCity.displayName(for: $0, in: cities) } ?? AteCityOption.everywhere.title
        case .date: draft.window.title() ?? "Any time"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch chip {
        case .rating:
            VStack(alignment: .leading, spacing: AteChipSheetMetrics.gap) {
                AteScoreRangeSlider(band: $draft.band)
                AteFlow(spacing: AteMetrics.snug) {
                    ForEach(ScoreBand.Preset.allCases, id: \.self) { preset in
                        AteFilterChoice(
                            title: preset.title, isOn: draft.band == preset.band, textStyle: .chipLabel
                        ) {
                            draft.band = preset.band
                        }
                        .accessibilityIdentifier("chipsheet.preset.\(preset.rawValue)")
                    }
                }
            }
        case .date:
            AteMonthRangeSlider(window: $draft.window)
        case .city:
            AteCityPicker(
                options: AteCityOption.cities(cities, keeping: draft.city),
                selection: draft.city ?? AteCityOption.everywhereID,
                title: nil,
                isLoading: areCitiesLoaded == false,
                textStyle: .chipLabel
            ) { option in
                draft.city = option.id == AteCityOption.everywhereID ? nil : option.id
            }
        case .sort:
            VStack(spacing: 0) {
                ForEach(JournalSort.allCases, id: \.self) { sort in
                    AteRadioRow(title: sort.title, isSelected: draft.sort == sort) { draft.sort = sort }
                }
            }
        }
    }
}
