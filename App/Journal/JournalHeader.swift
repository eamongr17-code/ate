import SwiftUI

/// **The Journal's header** (round 5, Eamon: "so much dead space in prime real estate"; "the Ate
/// logo could be bigger"). Three layouts are on the table (``JSExplore/journalHeader``):
/// - **A, masthead** — a bigger logo with the filter and photo-stack controls beside it, and the
///   Journal | Saved segment across the full width under it;
/// - **B, one bar** — logo, a hugging segment, filter and photo stack, all on one row;
/// - **C, logo and rail** — the biggest logo with the photo stack; under it one rail carrying the
///   segment, the filter and the active filters inline.
///
/// The filter control is on both shelves in every layout, so nothing moves when the shelf changes.
struct JournalHeader: View {
    let variant: JSExplore.Variant
    @Binding var shelf: JournalScreen.Shelf
    let photoCount: Int
    let isFiltered: Bool
    let activeFilters: [AteActiveFilter]
    let onSuggestions: () -> Void
    let onFilter: () -> Void
    let onRemove: (AteActiveFilter) -> Void

    /// How tall the header is on the page, pills aside — where the list starts under it.
    static func height(_ variant: JSExplore.Variant) -> CGFloat {
        switch variant {
        case .a: Self.mastheadRow + AteMetrics.regular + Self.segmentRow
        case .b: Self.segmentRow
        case .c: Self.logoRowC + Self.railGap + Self.segmentRow
        }
    }

    /// The logo's height in each layout — 30 before round 5.
    static func wordmark(_ variant: JSExplore.Variant) -> CGFloat {
        switch variant {
        case .a: 44
        case .b: 34
        case .c: 52
        }
    }

    private static let mastheadRow: CGFloat = 52
    private static let logoRowC: CGFloat = 56
    private static let railGap: CGFloat = 10
    /// The segment: 36 drawn, 4 of field around it.
    private static let segmentRow: CGFloat = AteMetrics.segmentHeight + 2 * AteMetrics.tight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch variant {
            case .a: masthead
            case .b: oneBar
            case .c: logoAndRail
            }
            if variant != .c, activeFilters.isEmpty == false {
                AteActiveFilters(filters: activeFilters, identifier: "journal.filter.pill", onRemove: onRemove)
                    .padding(.top, AteMetrics.regular)
            }
        }
    }

    // MARK: - A

    private var masthead: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            HStack(spacing: AteMetrics.snug) {
                logo
                Spacer(minLength: AteMetrics.snug)
                filterButton
                PhotoStackButton(count: photoCount, action: onSuggestions)
            }
            .frame(height: Self.mastheadRow)
            .ateContentTop()
            segment(hugs: false)
        }
        .padding(.horizontal, AteMetrics.listGutter)
    }

    // MARK: - B

    private var oneBar: some View {
        HStack(spacing: AteMetrics.snug) {
            logo
            Spacer(minLength: 0)
            segment(hugs: true)
            filterButton
            PhotoStackButton(count: photoCount, action: onSuggestions)
        }
        .frame(height: Self.segmentRow)
        .padding(.horizontal, AteMetrics.listGutter)
        .ateContentTop()
    }

    // MARK: - C

    private var logoAndRail: some View {
        VStack(alignment: .leading, spacing: Self.railGap) {
            HStack(spacing: AteMetrics.snug) {
                logo
                Spacer(minLength: AteMetrics.snug)
                PhotoStackButton(count: photoCount, action: onSuggestions)
            }
            .frame(height: Self.logoRowC)
            .padding(.horizontal, AteMetrics.listGutter)
            .ateContentTop()
            ScrollView(.horizontal) {
                HStack(spacing: AteMetrics.snug) {
                    segment(hugs: true)
                    filterButton
                    ForEach(activeFilters) { filter in
                        AteFilterPill(title: filter.title, isOn: true) { onRemove(filter) }
                            .accessibilityIdentifier("journal.filter.pill.\(filter.id)")
                    }
                }
                .padding(.horizontal, AteMetrics.listGutter)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    // MARK: - Parts

    private var logo: some View {
        AteWordmark(height: Self.wordmark(variant))
            .ateLaunchLogoTarget()
    }

    private func segment(hugs: Bool) -> some View {
        AteSegments(
            options: [AteSegment(JournalScreen.Shelf.journal, "Journal"), AteSegment(.saved, "Saved")],
            selection: $shelf,
            hugs: hugs
        )
        .fixedSize(horizontal: hugs, vertical: false)
    }

    private var filterButton: some View {
        AteFilterButton(isActive: isFiltered, identifier: "journal.filter", action: onFilter)
    }
}
