import AteKit
import SwiftUI

/// **Round 4's search-filter exploration** — two layouts behind `-ate-search-filters A|B` (Debug
/// only), built against the filter contract (``SearchFilters``). Neither is the default: without the
/// argument the tab has no filters, exactly as today, until Eamon picks one.
///
/// - **A** — a row of pills under the scopes, one per filter (Cuisine, Diet, Rating), each opening
///   its own picker. A pill that is on turns ink and prints what it is set to.
/// - **B** — one Filter pill, opening one sheet with all three.
enum SearchFilterLayout: String {
    case a = "A"
    case b = "B"
}

/// Which picker a pill opened. `all` is layout B's single sheet.
enum SearchFilterPicker: String, Identifiable {
    case cuisine, diet, rating, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cuisine: "Cuisine"
        case .diet: "Diet"
        case .rating: "Rating"
        case .all: "Filter"
        }
    }
}

/// **The Search tab's pill** — `Search.dc.html`'s segment: 40 tall, 16 in, `.ui` 14; ink when on,
/// the chip surface when off. The scopes and the filters are the same control, so they are one view;
/// a filter is the chip size (32, 12 in — `AteChip`'s, "a filter, a count"), one step down from the
/// scopes it narrows, so the two rows never read as one.
struct SearchPill: View {
    let title: String
    let isOn: Bool
    var isFilter = false
    var identifier: String?
    let action: () -> Void

    var body: some View {
        let height = isFilter ? AteMetrics.chipHeight : AteMetrics.keyHeight
        let hit = AteHitOutset(height: height)
        Button(action: action) {
            Text(title)
                .ateText(.controlSmall)
                .lineLimit(1)
                .padding(.horizontal, isFilter ? AteMetrics.regular : AteMetrics.loose)
                .atePillHeight(height)
                .background(isOn ? AtePalette.automatic.fg : AtePalette.automatic.chip, in: .capsule)
                .foregroundStyle(isOn ? AtePalette.automatic.inverted : AtePalette.automatic.fg)
                .ateHitArea(hit)
        }
        .buttonStyle(.plain)
        .ateHitFootprint(hit)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier ?? "search.pill")
    }
}

/// The filter pills under the scopes, in whichever layout is being judged.
struct SearchFilterBar: View {
    let layout: SearchFilterLayout
    let filters: SearchFilters
    let onOpen: (SearchFilterPicker) -> Void

    var body: some View {
        AteFlow(spacing: AteMetrics.snug - 2) {
            switch layout {
            case .a:
                SearchPill(
                    title: filters.cuisineSummary ?? SearchFilterPicker.cuisine.title,
                    isOn: filters.cuisines.isEmpty == false,
                    isFilter: true,
                    identifier: "search.filter.cuisine"
                ) { onOpen(.cuisine) }
                SearchPill(
                    title: filters.tagSummary ?? SearchFilterPicker.diet.title,
                    isOn: filters.tags.isEmpty == false,
                    isFilter: true,
                    identifier: "search.filter.diet"
                ) { onOpen(.diet) }
                SearchPill(
                    title: filters.scoreSummary ?? SearchFilterPicker.rating.title,
                    isOn: filters.minimumScore != nil,
                    isFilter: true,
                    identifier: "search.filter.rating"
                ) { onOpen(.rating) }
            case .b:
                // "Filter", and how many are on once any are — two values, a space apart (rule 2).
                SearchPill(
                    title: filters.isEmpty ? SearchFilterPicker.all.title : "Filter \(filters.count)",
                    isOn: filters.isEmpty == false,
                    isFilter: true,
                    identifier: "search.filter.all"
                ) { onOpen(.all) }
            }
        }
    }
}

/// **The pickers** — the app's own sheet (``AteSheet``) with radio rows, every change applied as it
/// is made. Multi-choice pickers close on the ink pill; the rating picker, a single answer, closes
/// on the answer (like the feed's area sheet) — except inside layout B's combined sheet.
struct SearchFilterSheet: View {
    let picker: SearchFilterPicker
    let store: SearchStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AteSheet(
            title: picker.title,
            primary: picker == .rating ? nil : (title: "Done", action: { dismiss() })
        ) {
            VStack(alignment: .leading, spacing: AteMetrics.section) {
                if picker == .cuisine || picker == .all { section(.cuisine) { cuisineRows } }
                if picker == .diet || picker == .all { section(.diet) { dietRows } }
                if picker == .rating || picker == .all { section(.rating) { ratingRows } }
            }
        }
        .presentationDetents(picker == .all ? [.large] : [.medium, .large])
        .task { await store.loadCuisines() }
    }

    private var filters: SearchFilters { store.filters }

    /// A section's label only where there is more than one section — a lone picker's title says it.
    private func section(_ kind: SearchFilterPicker, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if picker == .all {
                Text(kind.title)
                    .ateText(.meta)
                    .foregroundStyle(AtePalette.automatic.muted)
                    .padding(.bottom, AteMetrics.snug)
                    .accessibilityAddTraits(.isHeader)
            }
            rows()
        }
    }

    private var cuisineRows: some View {
        ForEach(store.cuisines) { row in
            AteRadioRow(
                title: row.cuisine,
                subtitle: row.placeCount == 1 ? "1 place" : "\(row.placeCount.formatted()) places",
                isSelected: filters.contains(cuisine: row.cuisine)
            ) { store.setFilters(filters.toggling(cuisine: row.cuisine)) }
        }
    }

    private var dietRows: some View {
        ForEach(DietTag.allCases, id: \.self) { tag in
            AteRadioRow(title: Self.name(of: tag), isSelected: filters.tags.contains(tag)) {
                store.setFilters(filters.toggling(tag: tag))
            }
        }
    }

    @ViewBuilder
    private var ratingRows: some View {
        AteRadioRow(title: "Any", isSelected: filters.minimumScore == nil) { setMinimum(nil) }
        ForEach(SearchFilters.minimumScores, id: \.self) { score in
            AteRadioRow(title: "\(ScoreFormat.halfStep(score))+", isSelected: filters.minimumScore == score) {
                setMinimum(score)
            }
        }
    }

    private func setMinimum(_ score: Double?) {
        var next = filters
        next.minimumScore = score
        store.setFilters(next)
        if picker == .rating { dismiss() }
    }

    /// "Gluten free" — the chip's spoken name, set as a label.
    private static func name(of tag: DietTag) -> String {
        tag.spokenName.prefix(1).uppercased() + tag.spokenName.dropFirst()
    }
}
