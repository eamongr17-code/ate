import AteKit
import SwiftUI

/// **The Journal's header** (round 7, `Main`): the logo, the Journal | Saved segment hugging its
/// titles, the photo stack when there is something to write up, and the calendar — all on one row —
/// with the shelf's filter chips under it. The chips are the same on both shelves, less the order on
/// Saved (which has none), so nothing else moves when the shelf changes.
///
/// At the accessibility sizes the row cannot hold it all, so it wraps: the logo and the two buttons
/// on top, the segment across the width under them.
struct JournalHeader: View {
    @Binding var shelf: JournalScreen.Shelf
    let photoCount: Int
    let filters: BrowseFilters
    let cityName: String?
    let onSuggestions: () -> Void
    let onCalendar: () -> Void
    let onChip: (BrowseChip) -> Void
    let onClearChip: (BrowseChip) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The logo's height on the bar — 30 before round 5 ("the Ate logo could be bigger").
    static let wordmark: CGFloat = 34
    /// The bar: the segment's 36 and the 4 of field around it.
    static let row: CGFloat = AteMetrics.segmentHeight + 2 * AteMetrics.tight
    /// `Main`: the header's `padding-bottom: 8px`, then the chip row's own 6.
    static let chipsGap: CGFloat = 8

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
            AteFilterChipRow(
                chips: BrowseChip.chips(on: shelf == .journal ? .journal : .saved),
                filters: filters,
                cityName: cityName,
                identifier: "journal.chip",
                onOpen: onChip,
                onClear: onClearChip
            )
            .padding(.top, Self.chipsGap)
        }
    }

    private var oneBar: some View {
        HStack(spacing: AteMetrics.snug) {
            AteWordmark(height: Self.wordmark)
            Spacer(minLength: 0)
            segment(hugs: true)
            photoStack
            JournalCalendarButton(action: onCalendar)
        }
        .frame(minHeight: Self.row)
    }

    private var wrapped: some View {
        VStack(alignment: .leading, spacing: AteMetrics.regular) {
            HStack(spacing: AteMetrics.snug) {
                AteWordmark(height: Self.wordmark)
                Spacer(minLength: AteMetrics.snug)
                photoStack
                JournalCalendarButton(action: onCalendar)
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
}

/// **The calendar button** — the Journal's corner disc, on the chrome's glass like every tab root's
/// corner control. It opens the month view (a pinch on the list does too).
struct JournalCalendarButton: View {
    let action: () -> Void

    var body: some View {
        AteGlassButton(icon: .calendar, label: "Calendar", size: 20, action: action)
            .accessibilityIdentifier("journal.calendar")
    }
}
