import AteKit
import SwiftUI

/// **The Search tab's pill** — `Search.dc.html`'s segment: 40 tall, 16 in, `.ui` 14; ink when on,
/// the chip surface when off. The scopes and the filters are the same control, so they are one view;
/// the filters themselves are the design system's one filter control and sheet (``AteFilterSheet``).
struct SearchPill: View {
    let title: String
    let isOn: Bool
    var identifier: String?
    let action: () -> Void

    var body: some View {
        let height = AteMetrics.keyHeight
        let hit = AteHitOutset(height: height)
        Button(action: action) {
            Text(title)
                .ateText(.controlSmall)
                .lineLimit(1)
                .padding(.horizontal, AteMetrics.loose)
                .atePillHeight(height)
                .background(isOn ? AtePalette.automatic.solid : AtePalette.automatic.raised, in: .capsule)
                .foregroundStyle(isOn ? AtePalette.automatic.inverted : AtePalette.automatic.fg)
                .ateHitArea(hit)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(hit)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "search.pill")
    }
}

/// **Search's filter sheet** — the design system's one filter sheet (``AteFilterSheet``), the same
/// one the Journal opens, with Search's sections: cuisine (`search_cuisines()`), diet and a minimum
/// rating. Cuisines and tags are multi-choice — a dish must carry every picked tag (AND). Nothing is
/// applied until Done.
struct SearchFilterSheet: View {
    let store: SearchStore

    @State private var filters: SearchFilters

    init(store: SearchStore) {
        self.store = store
        _filters = State(initialValue: store.filters)
    }

    var body: some View {
        AteFilterSheet(isLoading: store.hasLoadedCuisines == false) {
            AteFilterSection(title: "Rating") {
                AteFilterChoice(title: "Any", isOn: filters.minimumScore == nil) { filters.minimumScore = nil }
                ForEach(SearchFilters.minimumScores, id: \.self) { score in
                    AteFilterChoice(
                        title: ScoreFormat.halfStep(score) + "+",
                        isOn: filters.minimumScore == score
                    ) { filters.minimumScore = score }
                }
            }
            AteFilterSection(title: "Diet") {
                AteFilterChoice(title: "Any", isOn: filters.tags.isEmpty) { filters = filters.clearingTags() }
                ForEach(DietTag.allCases, id: \.self) { tag in
                    AteFilterChoice(
                        title: tag.label,
                        isOn: filters.tags.contains(tag),
                        accessibilityName: tag.spokenName
                    ) { filters = filters.toggling(tag: tag) }
                }
            }
            if store.hasLoadedCuisines == false {
                // Still pills where the cuisines will be, until they have answered.
                AteFilterSection(title: "Cuisine") {
                    ForEach(Self.stillPillWidths, id: \.self) { width in
                        AteSkeletonBar(width: width, height: AteFilterPill.height, palette: .surface)
                    }
                }
                .accessibilityHidden(true)
            } else if store.cuisines.isEmpty == false {
                AteFilterSection(title: "Cuisine") {
                    AteFilterChoice(title: "Any", isOn: filters.cuisines.isEmpty) {
                        filters = filters.clearingCuisines()
                    }
                    ForEach(store.cuisines) { row in
                        AteFilterChoice(title: row.cuisine, isOn: filters.contains(cuisine: row.cuisine)) {
                            filters = filters.toggling(cuisine: row.cuisine)
                        }
                    }
                }
            }
        } onDone: {
            store.setFilters(filters)
        }
    }

    private static let stillPillWidths: [CGFloat] = [64, 88, 72, 96]
}

extension SearchFilters {
    /// The active filters as the row under the control draws them.
    var activeFilters: [AteActiveFilter] {
        pills.map { AteActiveFilter(id: $0.id, title: $0.title) }
    }

    func removing(_ filter: AteActiveFilter) -> SearchFilters {
        guard let pill = pills.first(where: { $0.id == filter.id }) else { return self }
        return removing(pill)
    }
}
