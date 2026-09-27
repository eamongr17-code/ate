import SwiftUI

/// **The Journal's header** (round 5, Eamon's pick: one bar). The logo, the Journal | Saved segment
/// hugging its titles, the filter control and the photo stack, all on one row; the active filters
/// ride under it as removable pills.
///
/// The filter control is on both shelves, so nothing moves when the shelf changes (Eamon: "the same
/// filter options should persist on the Saved view, so the button layout should be the same").
///
/// At the accessibility sizes the row cannot hold all four, so it wraps: the logo and the two
/// controls on top, the segment across the width under them.
struct JournalHeader: View {
    @Binding var shelf: JournalScreen.Shelf
    let photoCount: Int
    let isFiltered: Bool
    let activeFilters: [AteActiveFilter]
    let onSuggestions: () -> Void
    let onFilter: () -> Void
    let onRemove: (AteActiveFilter) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The logo's height on the bar — 30 before round 5 ("the Ate logo could be bigger").
    static let wordmark: CGFloat = 34
    /// The bar: the segment's 36 and the 4 of field around it.
    static let row: CGFloat = AteMetrics.segmentHeight + 2 * AteMetrics.tight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    wrapped
                } else {
                    oneBar
                }
            }
            .padding(.horizontal, AteMetrics.listGutter)
            .ateContentTop()
            if activeFilters.isEmpty == false {
                AteActiveFilters(filters: activeFilters, identifier: "journal.filter.pill", onRemove: onRemove)
                    .padding(.top, AteMetrics.regular)
            }
        }
    }

    private var oneBar: some View {
        HStack(spacing: AteMetrics.snug) {
            AteWordmark(height: Self.wordmark)
            Spacer(minLength: 0)
            segment(hugs: true)
            filterButton
            photoStack
        }
        .frame(minHeight: Self.row)
    }

    private var wrapped: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            HStack(spacing: AteMetrics.snug) {
                AteWordmark(height: Self.wordmark)
                Spacer(minLength: AteMetrics.snug)
                filterButton
                photoStack
            }
            segment(hugs: false)
        }
    }

    private func segment(hugs: Bool) -> some View {
        AteSegments(
            options: [AteSegment(JournalScreen.Shelf.journal, "Journal"), AteSegment(.saved, "Saved")],
            selection: $shelf,
            hugs: hugs,
            identifier: "journal.shelf"
        )
        .fixedSize(horizontal: hugs, vertical: false)
    }

    /// "From your photos" only when there is something to suggest (round 5, #82): no button, no
    /// badge, no empty page behind it.
    @ViewBuilder
    private var photoStack: some View {
        if photoCount >= 1 {
            PhotoStackButton(count: photoCount, action: onSuggestions)
        }
    }

    private var filterButton: some View {
        AteFilterButton(isActive: isFiltered, identifier: "journal.filter", action: onFilter)
    }
}
