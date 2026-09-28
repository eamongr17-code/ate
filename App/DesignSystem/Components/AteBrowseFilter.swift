import AteKit
import SwiftUI

/// **What Search's filter sheet edits**: a score range, a city and a run of months. (The Journal and
/// Saved filter by chips since round 7 — ``AteFilterChipRow``; Search keeps its one sheet for now.)
struct AteBrowseFilterDraft: Hashable {
    var band: ScoreBand = .all
    /// A city slug, or `nil` for everywhere.
    var city: String?
    /// The months — the visit day of the lines Search counts.
    var window: DateWindow = .all
}

/// **Search's filter sheet** — the score range and the months as the chip sheets' two-thumb sliders
/// (round 7: the ruler is gone), and the city as the one picker's pills. Nothing is applied until
/// Done.
struct AteBrowseFilterSheet: View {
    let cities: [AteCity]
    /// Whether ``cities`` has answered — until it has, the sheet stands at full height with still
    /// pills where they will be (#83).
    let areCitiesLoaded: Bool
    let onDone: (AteBrowseFilterDraft) -> Void

    @State private var draft: AteBrowseFilterDraft

    init(
        initial: AteBrowseFilterDraft,
        cities: [AteCity],
        areCitiesLoaded: Bool = true,
        onDone: @escaping (AteBrowseFilterDraft) -> Void
    ) {
        self.cities = cities
        self.areCitiesLoaded = areCitiesLoaded
        self.onDone = onDone
        _draft = State(initialValue: initial)
    }

    var body: some View {
        AteFilterSheet(isLoading: areCitiesLoaded == false) {
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                header("Score", value: draft.band.title ?? "Any", identifier: "filter.score.value")
                AteScoreRangeSlider(band: $draft.band)
            }
            VStack(alignment: .leading, spacing: AteMetrics.snug) {
                header("When", value: draft.window.title() ?? "Any time", identifier: "filter.date.value")
                AteMonthRangeSlider(window: $draft.window)
            }
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

    /// A section's name, muted, and its choice as the pill will print it.
    private func header(_ title: String, value: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AteMetrics.snug) {
            Text(title)
                .ateText(.meta)
                .foregroundStyle(AtePalette.surface.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: AteMetrics.snug)
            Text(value)
                .ateText(.controlSmall)
                .monospacedDigit()
                .foregroundStyle(AtePalette.surface.fg)
                .contentTransition(.numericText())
                .accessibilityIdentifier(identifier)
        }
    }
}
